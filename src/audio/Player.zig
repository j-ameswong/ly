//! Decodes an audio file and plays it, keeping a copy of the most recently
//! played samples around for a visualizer to look at.
//!
//! The track can be played through an actual audio device, or to nowhere at
//! all: the latter still runs at normal speed, so that something reading the
//! samples doesn't see a difference.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ma = @import("miniaudio");

const Player = @This();

pub const CHANNELS = 2;

/// Number of frames kept for `latest`. A power of two, which must be at
/// least twice as large as the longest window anything asks for.
const TAP_FRAMES = 1 << 16;

/// Samples handed out by `latest` never go beyond this, in either direction.
/// Proper ones stay within -1 and 1.
const SAMPLE_LIMIT: f32 = 8.0;

/// The audio systems to try for audible output, in order of preference.
/// A sound server comes first, as it is the only way to get any sound out
/// when Ly is run from within a session.
const device_backends = [_]ma.ma_backend{
    ma.ma_backend_pulseaudio,
    ma.ma_backend_alsa,
    ma.ma_backend_sndio,
    ma.ma_backend_audio4,
    ma.ma_backend_oss,
};

pub const Output = enum {
    /// Nothing is being played
    closed,
    /// The track is being played to nowhere
    silent,
    /// The track is being played through an audio device
    audible,
};

pub const Options = struct {
    /// Start over once the end of the track is reached
    loop: bool,
    /// Between 0 and 1
    volume: f32,
    /// Name of the audio device to use instead of the default one. Its
    /// meaning depends on the audio system in use.
    device_name: ?[]const u8,
};

/// Sends the standard error stream to nowhere for as long as it lasts.
const QuietStderr = struct {
    saved_fd: std.c.fd_t,

    fn begin() ?QuietStderr {
        const null_fd = std.c.open(
            "/dev/null",
            .{ .ACCMODE = .WRONLY, .CLOEXEC = true },
        );
        if (null_fd < 0) return null;
        defer _ = std.c.close(null_fd);

        const saved_fd = std.c.dup(std.c.STDERR_FILENO);
        if (saved_fd < 0) return null;

        if (std.c.dup2(null_fd, std.c.STDERR_FILENO) < 0) {
            _ = std.c.close(saved_fd);
            return null;
        }

        return .{ .saved_fd = saved_fd };
    }

    fn end(self: QuietStderr) void {
        _ = std.c.dup2(self.saved_fd, std.c.STDERR_FILENO);
        _ = std.c.close(self.saved_fd);
    }
};

/// What it takes to play through one audio system. There are two of these
/// so that a new output can be set up while the previous one is still
/// playing.
const Slot = struct {
    context: ma.ma_context,
    device: ma.ma_device,
};

allocator: Allocator,
options: Options,
decoder: *ma.ma_decoder,
slots: *[2]Slot,
/// Index of the slot the output currently goes through
active: usize,
sample_rate: u32,
output: Output,
backend: ma.ma_backend,
/// Only touched by the audio thread while the output is open
ended: bool,
tap: []f32,
/// Total number of frames written to `tap` so far. Written by the audio
/// thread only.
tap_position: std.atomic.Value(u64),

pub fn init(allocator: Allocator, path: []const u8, options: Options) !*Player {
    const self = try allocator.create(Player);
    errdefer allocator.destroy(self);

    const decoder = try allocator.create(ma.ma_decoder);
    errdefer allocator.destroy(decoder);
    const slots = try allocator.create([2]Slot);
    errdefer allocator.destroy(slots);
    const tap = try allocator.alloc(f32, TAP_FRAMES * CHANNELS);
    errdefer allocator.free(tap);
    @memset(tap, 0.0);

    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    // Whatever the file contains, we want stereo floating-point samples at
    // the track's own sample rate out of it
    const config = ma.ma_decoder_config_init(ma.ma_format_f32, CHANNELS, 0);
    const result = ma.ma_decoder_init_file(path_z.ptr, &config, decoder);
    if (result != ma.MA_SUCCESS) return error.UnreadableAudioFile;
    errdefer _ = ma.ma_decoder_uninit(decoder);

    if (decoder.outputSampleRate == 0) return error.UnreadableAudioFile;

    self.* = .{
        .allocator = allocator,
        .options = options,
        .decoder = decoder,
        .slots = slots,
        .active = 0,
        .sample_rate = decoder.outputSampleRate,
        .output = .closed,
        .backend = ma.ma_backend_null,
        .ended = false,
        .tap = tap,
        .tap_position = .init(0),
    };

    return self;
}

pub fn deinit(self: *Player) void {
    const allocator = self.allocator;

    self.close();
    _ = ma.ma_decoder_uninit(self.decoder);

    allocator.destroy(self.decoder);
    allocator.destroy(self.slots);
    allocator.free(self.tap);
    allocator.destroy(self);
}

/// Plays the track from where it last stopped, either through an audio
/// device or to nowhere. If no audio device can be used, the current output
/// is left as it is.
pub fn open(self: *Player, audible: bool) !void {
    // Set up the new output on the side, so that we only let go of the
    // current one once we know we have something to replace it with
    const slot = &self.slots[1 - self.active];

    const backend = if (audible)
        try self.prepareDevice(slot)
    else
        try self.prepareSilence(slot);

    if (self.output != .closed) self.release(&self.slots[self.active]);
    self.active = 1 - self.active;
    self.backend = backend;

    if (ma.ma_device_start(&slot.device) != ma.MA_SUCCESS) {
        self.release(slot);
        self.output = .closed;
        @memset(self.tap, 0.0);
        return error.AudioDeviceUnavailable;
    }

    self.output = if (audible) .audible else .silent;
}

/// Stops playing and lets go of the audio device, if any.
pub fn close(self: *Player) void {
    if (self.output == .closed) return;

    self.release(&self.slots[self.active]);
    self.output = .closed;

    // Whoever is looking at the samples would otherwise keep seeing what
    // was played last
    @memset(self.tap, 0.0);
}

/// Name of the audio system the output currently goes through.
pub fn backendName(self: *const Player) []const u8 {
    return std.mem.span(ma.ma_get_backend_name(self.backend));
}

/// Total number of frames played so far. As long as the output is open
/// and working, this keeps going up.
pub fn framesPlayed(self: *const Player) u64 {
    return self.tap_position.load(.acquire);
}

/// Copies the most recently played frames into `frames`, as interleaved
/// stereo samples, all of which are finite. What hasn't been played yet is
/// silence.
pub fn latest(self: *const Player, frames: []f32) void {
    const count = frames.len / CHANNELS;
    std.debug.assert(count <= TAP_FRAMES / 2);

    while (true) {
        const end = self.tap_position.load(.acquire);
        const available: usize = @intCast(@min(end, count));
        const missing = count - available;

        @memset(frames[0 .. missing * CHANNELS], 0.0);

        var position = end - available;
        var copied = missing;
        while (copied < count) {
            const offset: usize = @intCast(position % TAP_FRAMES);
            const length = @min(count - copied, TAP_FRAMES - offset);

            @memcpy(
                frames[copied * CHANNELS ..][0 .. length * CHANNELS],
                self.tap[offset * CHANNELS ..][0 .. length * CHANNELS],
            );
            position += length;
            copied += length;
        }

        // The audio thread never stops for us. If it managed to wrap all
        // the way around to what we were copying in the meantime, what we
        // got is garbage, so start over.
        const written = self.tap_position.load(.acquire) - end;
        if (written <= TAP_FRAMES - count) return;
    }
}

fn prepareDevice(self: *Player, slot: *Slot) !ma.ma_backend {
    // Audio libraries tend to report whatever goes wrong on the standard
    // error stream, which is the very terminal we're drawing on
    const maybe_quiet = QuietStderr.begin();
    defer if (maybe_quiet) |quiet| quiet.end();

    for (device_backends) |backend| {
        self.prepare(slot, backend) catch continue;
        return backend;
    }

    return error.NoAudioDevice;
}

fn prepareSilence(self: *Player, slot: *Slot) !ma.ma_backend {
    try self.prepare(slot, ma.ma_backend_null);
    return ma.ma_backend_null;
}

/// Gets an output ready to play, without starting it yet.
fn prepare(self: *Player, slot: *Slot, backend: ma.ma_backend) !void {
    var context_config = ma.ma_context_config_init();
    context_config.pulse.pApplicationName = "ly";

    if (ma.ma_context_init(
        &backend,
        1,
        &context_config,
        &slot.context,
    ) != ma.MA_SUCCESS) return error.AudioBackendUnavailable;
    errdefer _ = ma.ma_context_uninit(&slot.context);

    var device_id: ma.ma_device_id = undefined;
    var device_config = ma.ma_device_config_init(ma.ma_device_type_playback);
    device_config.playback.format = ma.ma_format_f32;
    device_config.playback.channels = CHANNELS;
    device_config.sampleRate = self.sample_rate;
    device_config.dataCallback = &dataCallback;
    device_config.pUserData = self;
    device_config.pulse.pStreamNamePlayback = "ly";

    if (backend != ma.ma_backend_null) {
        if (self.options.device_name) |name| {
            device_id = try deviceIdFromName(backend, name);
            device_config.playback.pDeviceID = &device_id;
        }
    }

    if (ma.ma_device_init(
        &slot.context,
        &device_config,
        &slot.device,
    ) != ma.MA_SUCCESS) return error.AudioDeviceUnavailable;

    // The samples handed to `latest` aren't affected by this
    _ = ma.ma_device_set_master_volume(&slot.device, self.options.volume);
}

fn release(_: *Player, slot: *Slot) void {
    // This waits for the audio thread to be gone
    ma.ma_device_uninit(&slot.device);
    _ = ma.ma_context_uninit(&slot.context);
}

fn deviceIdFromName(backend: ma.ma_backend, name: []const u8) !ma.ma_device_id {
    var device_id = std.mem.zeroes(ma.ma_device_id);

    const destination: []u8 = switch (backend) {
        ma.ma_backend_pulseaudio => &device_id.pulse,
        ma.ma_backend_alsa => &device_id.alsa,
        ma.ma_backend_sndio => &device_id.sndio,
        ma.ma_backend_audio4 => &device_id.audio4,
        ma.ma_backend_oss => &device_id.oss,
        else => return error.AudioDeviceUnavailable,
    };

    // Leave room for the null terminator
    if (name.len >= destination.len) return error.AudioDeviceUnavailable;
    @memcpy(destination[0..name.len], name);

    return device_id;
}

/// Called by the audio thread whenever the output wants more frames.
fn dataCallback(
    device: [*c]ma.ma_device,
    maybe_output: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: ma.ma_uint32,
) callconv(.c) void {
    const self: *Player = @ptrCast(@alignCast(device.*.pUserData));
    const raw_output = maybe_output orelse return;
    const output_pointer: [*]f32 = @ptrCast(@alignCast(raw_output));
    // The buffer we're given is already filled with silence
    const output = output_pointer[0 .. frame_count * CHANNELS];

    var done: usize = 0;
    var rewound = false;
    while (done < frame_count and !self.ended) {
        var read: ma.ma_uint64 = 0;
        _ = ma.ma_decoder_read_pcm_frames(
            self.decoder,
            output[done * CHANNELS ..].ptr,
            frame_count - done,
            &read,
        );
        done += @intCast(read);
        if (done == frame_count) break;

        // We've reached the end of the track. Rewinding a track we can't
        // get anything out of would keep us here forever.
        if (read > 0) rewound = false;
        if (!self.options.loop or rewound) {
            self.ended = true;
            break;
        }
        if (ma.ma_decoder_seek_to_pcm_frame(self.decoder, 0) != ma.MA_SUCCESS) {
            self.ended = true;
            break;
        }
        rewound = true;
    }

    self.record(output);
}

fn record(self: *Player, samples: []const f32) void {
    const start = self.tap_position.load(.monotonic);
    const count = samples.len / CHANNELS;

    var copied: usize = 0;
    while (copied < count) {
        const offset: usize = @intCast((start + copied) % TAP_FRAMES);
        const length = @min(count - copied, TAP_FRAMES - offset);

        const kept = self.tap[offset * CHANNELS ..][0 .. length * CHANNELS];
        const played = samples[copied * CHANNELS ..][0 .. length * CHANNELS];

        // A file can hold anything, including what isn't a number at all.
        // Whoever does math on these samples shouldn't have to worry.
        for (kept, played) |*sample, value| {
            sample.* = if (std.math.isFinite(value))
                std.math.clamp(value, -SAMPLE_LIMIT, SAMPLE_LIMIT)
            else
                0.0;
        }
        copied += length;
    }

    self.tap_position.store(start + count, .release);
}

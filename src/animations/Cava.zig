//! Plays an audio track and visualizes it, in the manner of cava
//! (https://github.com/karlstav/cava).

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

const ly_ui = @import("ly-ui");
const Cell = ly_ui.Cell;
const TerminalBuffer = ly_ui.TerminalBuffer;
const Color = TerminalBuffer.Color;
const Styling = TerminalBuffer.Styling;
const Widget = ly_ui.Widget;

const ly_core = ly_ui.ly_core;
const interop = ly_core.interop;
const LogFile = ly_core.LogFile;
const TimeOfDay = interop.TimeOfDay;

const Player = @import("../audio/Player.zig");
const Spectrum = @import("../audio/Spectrum.zig");
const InfoLine = @import("../components/InfoLine.zig");
const Lang = @import("../config/Lang.zig");
const enums = @import("../enums.zig");
const CavaResolution = enums.CavaResolution;
const CavaStyle = enums.CavaStyle;

const Cava = @This();

const PALETTE_SIZE = 64;

const FULL_BLOCK = 0x2588;
const UPPER_HALF_BLOCK = 0x2580;
const LOWER_HALF_BLOCK = 0x2584;
/// The lower eighth blocks follow this codepoint, from the thinnest to the
/// thickest
const LOWER_BLOCKS_BASE = 0x2580;
const SHADES = [_]u32{ 0x2591, 0x2592, 0x2593, FULL_BLOCK };

/// Seconds to wait before looking for an audio device again. This doubles
/// after every failed attempt, up to the maximum.
const RETRY_INTERVAL: f32 = 2.0;
const MAX_RETRY_INTERVAL: f32 = 60.0;

/// Failed attempts at getting an audio device it takes before bothering the
/// user about it. More often than not the device is only busy for a few
/// seconds, typically because the session that just ended still has it.
const ATTEMPTS_BEFORE_ERROR = 3;

/// Seconds the output may go without playing anything before we give up on
/// it
const STALL_TIMEOUT: f32 = 1.5;

/// Seconds between two updates of the spectrum
const ANALYSIS_INTERVAL: f32 = 1.0 / 60.0;

/// Seconds of sound shown across the screen by the wave style
const WAVE_SPAN: f32 = 0.04;

/// Seconds the wave style takes to zoom back in after a loud passage
const WAVE_RELEASE: f32 = 2.0;

/// The wave style doesn't zoom in on anything quieter than this
const WAVE_FLOOR: f32 = 0.05;

/// Seconds between two rows of the spectrogram
const SPECTROGRAM_STEP: f32 = 0.04;

/// How quickly the spectrogram goes from dark to its full brightness as
/// bars get higher
const HEAT_GAIN: f32 = 2.5;

/// Rows the spectrogram may catch up on in a single frame
const SPECTROGRAM_MAX_CATCH_UP = 4;

const Direction = enum { up, down };

pub const Options = struct {
    audio_file: []const u8,
    audio_device: ?[]const u8,
    play_audio: bool,
    loop: bool,
    volume: u8,
    style: CavaStyle,
    resolution: CavaResolution,
    use_kmscon_vt: bool,
    stereo: bool,
    bar_width: u8,
    bar_spacing: u8,
    bottom_color: u32,
    middle_color: u32,
    top_color: u32,
    full_color: bool,
    error_fg: u32,
    error_bg: u32,
};

instance: ?Widget = null,
allocator: Allocator,
io: std.Io,
log_file: *LogFile,
terminal_buffer: *TerminalBuffer,
info_line: *InfoLine,
lang: Lang,
start_time: TimeOfDay,
animate: *bool,
timeout_sec: u12,
frame_delay: u16,
error_fg: u32,
error_bg: u32,
/// Null if the audio file couldn't be loaded, in which case there is
/// nothing to play nor to show
player: ?*Player,
spectrum: ?Spectrum,
/// The most recently played frames, as handed to the spectrum
frames: []f32,
style: CavaStyle,
stereo: bool,
full_color: bool,
bar_width: usize,
bar_spacing: usize,
/// How many steps a single cell can be divided into vertically
levels: usize,
/// Colors from the bottom one to the top one
palette: [PALETTE_SIZE]u32,
/// What the spectrogram uses instead of `palette` in eight-color mode
stops: [3]u32,
/// Whether the track should be heard, and not only seen
play_audio: bool,
/// Set once nothing can be played anymore, not even to nowhere
broken: bool,
failed_attempts: u8,
device_error_shown: bool,
retry_interval: f32,
retry_in: f32,
last_frames_played: u64,
stalled_for: f32,
last_draw: ?std.Io.Timestamp,
unprocessed_time: f32,
/// Width in cells of what a single bar takes, and of the gap between two
column_width: usize,
column_gap: usize,
bars_per_channel: usize,
left_margin: usize,
wave_peak: f32,
/// Past bar heights for the spectrogram, one row after the other
history: []f32,
history_rows: usize,
history_columns: usize,
/// Index of the most recent row in `history`
history_head: usize,
history_timer: f32,

pub fn init(
    allocator: Allocator,
    io: std.Io,
    log_file: *LogFile,
    terminal_buffer: *TerminalBuffer,
    info_line: *InfoLine,
    lang: Lang,
    options: Options,
    animate: *bool,
    timeout_sec: u12,
    frame_delay: u16,
) !Cava {
    var self: Cava = .{
        .allocator = allocator,
        .io = io,
        .log_file = log_file,
        .terminal_buffer = terminal_buffer,
        .info_line = info_line,
        .lang = lang,
        .start_time = try interop.getTimeOfDay(),
        .animate = animate,
        .timeout_sec = timeout_sec,
        .frame_delay = frame_delay,
        .error_fg = options.error_fg,
        .error_bg = options.error_bg,
        .player = null,
        .spectrum = null,
        .frames = &.{},
        .style = options.style,
        .stereo = options.stereo,
        .full_color = options.full_color,
        .bar_width = @max(options.bar_width, 1),
        .bar_spacing = options.bar_spacing,
        .levels = levelsOf(options.resolution, options.use_kmscon_vt),
        .palette = undefined,
        .stops = .{
            options.bottom_color,
            options.middle_color,
            options.top_color,
        },
        .play_audio = options.play_audio,
        .broken = false,
        .failed_attempts = 0,
        .device_error_shown = false,
        .retry_interval = RETRY_INTERVAL,
        .retry_in = 0.0,
        .last_frames_played = 0,
        .stalled_for = 0.0,
        .last_draw = null,
        .unprocessed_time = 0.0,
        .column_width = 1,
        .column_gap = 0,
        .bars_per_channel = 0,
        .left_margin = 0,
        .wave_peak = WAVE_FLOOR,
        .history = &.{},
        .history_rows = 0,
        .history_columns = 0,
        .history_head = 0,
        .history_timer = 0.0,
    };

    self.buildPalette();

    // A track that can't be played must not keep anyone from logging in, so
    // from here on failures are only reported
    self.load(options) catch |err| {
        self.unload();

        self.info_line.addMessage(
            lang.err_audio_file,
            self.error_bg,
            self.error_fg,
        ) catch {};
        self.log_file.err(
            io,
            "audio",
            "failed to load audio file '{s}': {s}",
            .{ options.audio_file, @errorName(err) },
        ) catch {};
    };

    return self;
}

pub fn widget(self: *Cava) *Widget {
    if (self.instance) |*instance| return instance;
    self.instance = Widget.init(
        "Cava",
        null,
        self,
        deinit,
        realloc,
        draw,
        update,
        null,
        calculateTimeout,
    );
    return &self.instance.?;
}

/// Switches between hearing the track and only seeing it.
pub fn toggleAudio(self: *Cava) void {
    const player = self.player orelse return;

    self.play_audio = !self.play_audio;
    self.forgetFailures();

    // Nothing is playing right now. The choice will be honored whenever it
    // starts again.
    if (player.output == .closed) return;

    if (self.play_audio) {
        // Whoever asks for sound deserves to be told right away if there
        // can't be any
        self.openDevice(player, .report_now);
    } else {
        player.open(false) catch player.close();
    }
}

/// Moves on to the next visualization style.
pub fn cycleStyle(self: *Cava) void {
    self.style = self.style.next();
    self.layout() catch |err| {
        self.log_file.err(
            self.io,
            "audio",
            "failed to change visualization style: {s}",
            .{@errorName(err)},
        ) catch {};
    };
}

/// Lets go of the audio device, so that whatever comes next can use it.
/// Playing picks up where it stopped the next time the animation is drawn.
pub fn releaseAudio(self: *Cava) void {
    if (self.player) |player| player.close();
    self.last_draw = null;
    self.forgetFailures();
}

fn load(self: *Cava, options: Options) !void {
    const player = try Player.init(self.allocator, options.audio_file, .{
        .loop = options.loop,
        .volume = @as(f32, @floatFromInt(@min(options.volume, 100))) / 100.0,
        .device_name = options.audio_device,
    });
    self.player = player;

    self.spectrum = try Spectrum.init(self.allocator, player.sample_rate);
    self.frames = try self.allocator.alloc(
        f32,
        self.spectrum.?.windowFrames() * Player.CHANNELS,
    );

    try self.layout();

    self.log_file.info(
        self.io,
        "audio",
        "loaded audio file '{s}' ({d} Hz)",
        .{ options.audio_file, player.sample_rate },
    ) catch {};
}

fn unload(self: *Cava) void {
    if (self.player) |player| player.deinit();
    if (self.spectrum) |*spectrum| spectrum.deinit();
    self.allocator.free(self.frames);
    self.allocator.free(self.history);

    self.player = null;
    self.spectrum = null;
    self.frames = &.{};
    self.history = &.{};
}

fn deinit(self: *Cava) void {
    self.unload();
}

fn realloc(self: *Cava) !void {
    try self.layout();
}

/// Works out where everything goes for the current style and screen size.
fn layout(self: *Cava) !void {
    const spectrum = if (self.spectrum) |*spectrum| spectrum else return;
    const width = self.terminal_buffer.width;
    const height = self.terminal_buffer.height;
    const channel_count: usize = if (self.stereo) 2 else 1;

    // Should this fail, draw nothing at all rather than something based on
    // what only got half set up
    errdefer {
        self.bars_per_channel = 0;
        self.history_rows = 0;
    }

    switch (self.style) {
        .bars, .mirror => {
            self.column_width = self.bar_width;
            self.column_gap = self.bar_spacing;
        },
        .wave, .spectrogram => {
            self.column_width = 1;
            self.column_gap = 0;
        },
    }

    const pitch = self.column_width + self.column_gap;
    const fitting = (width + self.column_gap) / pitch;
    self.bars_per_channel = fitting / channel_count;

    const displayed = self.bars_per_channel * channel_count;
    const used_width = (displayed * pitch) -| self.column_gap;
    self.left_margin = (width - used_width) / 2;

    try spectrum.setLayout(
        if (self.stereo) .stereo else .mono,
        self.bars_per_channel,
    );

    // In full color, a cell shows two rows of the spectrogram at once
    const history_rows = if (self.style != .spectrogram)
        0
    else if (self.full_color)
        height * 2
    else
        height;
    const history_columns = if (self.style == .spectrogram) displayed else 0;

    self.history = try self.allocator.realloc(
        self.history,
        history_rows * history_columns,
    );
    @memset(self.history, 0.0);
    self.history_rows = history_rows;
    self.history_columns = history_columns;
    self.history_head = 0;
    self.history_timer = 0.0;
}

fn draw(self: *Cava) void {
    if (!self.animate.*) return;

    const player = self.player orelse return;
    const spectrum = if (self.spectrum) |*spectrum| spectrum else return;

    const now = std.Io.Timestamp.now(self.io, .awake);
    const elapsed: f32 = if (self.last_draw) |last_draw| seconds: {
        const duration = last_draw.durationTo(now);
        const nanoseconds: f32 = @floatFromInt(duration.toNanoseconds());
        break :seconds @max(nanoseconds / std.time.ns_per_s, 0.0);
    } else 0.0;
    self.last_draw = now;

    self.keepPlaying(player, elapsed);
    player.latest(self.frames);

    if (self.style == .wave) {
        self.drawWave(spectrum.sample_rate, elapsed);
        return;
    }

    // The bars don't need to be worked out more often than anyone can see
    self.unprocessed_time += elapsed;
    if (self.unprocessed_time >= ANALYSIS_INTERVAL) {
        spectrum.process(self.frames, self.unprocessed_time);
        self.unprocessed_time = 0.0;
    }
    if (self.bars_per_channel == 0) return;

    switch (self.style) {
        .bars => self.drawBars(spectrum.values),
        .mirror => self.drawMirror(spectrum.values),
        .spectrogram => self.drawSpectrogram(spectrum.values, elapsed),
        .wave => unreachable,
    }
}

fn update(self: *Cava, _: *anyopaque) !void {
    const time = try interop.getTimeOfDay();

    const running_for = time.seconds - self.start_time.seconds;
    if (self.timeout_sec > 0 and running_for > self.timeout_sec) {
        self.animate.* = false;
        // An animation that has stopped shouldn't be heard anymore either
        if (self.player) |player| player.close();
    }
}

fn calculateTimeout(self: *Cava, _: *anyopaque) !?usize {
    return self.frame_delay;
}

/// Makes sure the track is playing the way it's supposed to.
fn keepPlaying(self: *Cava, player: *Player, elapsed: f32) void {
    if (self.broken) return;

    switch (player.output) {
        .closed => {
            if (self.play_audio and self.retry_in <= 0.0) {
                self.openDevice(player, .report_later);
            }

            // Without an audio device, the track is still played to
            // nowhere for the sake of the visualization
            if (player.output == .closed) player.open(false) catch |err| {
                self.broken = true;
                self.log_file.err(
                    self.io,
                    "audio",
                    "failed to play audio: {s}",
                    .{@errorName(err)},
                ) catch {};
                return;
            };
        },
        .silent => if (self.play_audio) {
            self.retry_in -= elapsed;
            if (self.retry_in <= 0.0) self.openDevice(player, .report_later);
        },
        .audible => {},
    }

    const frames_played = player.framesPlayed();
    if (frames_played != self.last_frames_played) {
        self.last_frames_played = frames_played;
        self.stalled_for = 0.0;
        return;
    }

    // An audio device can vanish at any time, and nothing tells us when it
    // does. Starting over lets us find another one, or do without.
    self.stalled_for += elapsed;
    if (self.stalled_for > STALL_TIMEOUT) {
        self.stalled_for = 0.0;
        if (player.output == .audible) self.postponeRetry();
        self.log_file.err(
            self.io,
            "audio",
            "audio output stalled ({s}), reopening it",
            .{player.backendName()},
        ) catch {};
        player.close();
    }
}

fn openDevice(
    self: *Cava,
    player: *Player,
    reporting: enum { report_now, report_later },
) void {
    player.open(true) catch |err| {
        self.postponeRetry();

        if (self.failed_attempts == 0) self.log_file.err(
            self.io,
            "audio",
            "failed to open audio device: {s}",
            .{@errorName(err)},
        ) catch {};
        self.failed_attempts +|= 1;

        if (self.device_error_shown) return;
        if (reporting == .report_later and
            self.failed_attempts < ATTEMPTS_BEFORE_ERROR) return;

        self.device_error_shown = true;
        self.info_line.addMessage(
            self.lang.err_audio_device,
            self.error_bg,
            self.error_fg,
        ) catch {};
        return;
    };

    self.forgetFailures();
    self.log_file.info(
        self.io,
        "audio",
        "playing audio through {s}",
        .{player.backendName()},
    ) catch {};
}

fn postponeRetry(self: *Cava) void {
    self.retry_in = self.retry_interval;
    self.retry_interval = @min(self.retry_interval * 2.0, MAX_RETRY_INTERVAL);
}

fn forgetFailures(self: *Cava) void {
    self.failed_attempts = 0;
    self.device_error_shown = false;
    self.retry_interval = RETRY_INTERVAL;
    self.retry_in = 0.0;
}

fn drawBars(self: *Cava, values: []const f32) void {
    const height = self.terminal_buffer.height;
    const max_units: f32 = @floatFromInt(height * self.levels);

    for (0..self.displayedBars()) |bar| {
        const units = self.barValue(values, bar) * max_units;
        self.fill(self.barColumn(bar), height, .up, toUnits(units), height);
    }
}

fn drawMirror(self: *Cava, values: []const f32) void {
    const center = self.terminal_buffer.height / 2;
    const max_units: f32 = @floatFromInt(center * self.levels);

    for (0..self.displayedBars()) |bar| {
        const units = toUnits(self.barValue(values, bar) * max_units);
        const x = self.barColumn(bar);

        self.fill(x, center, .up, units, center);
        self.fill(x, center, .down, units, center);
    }
}

fn drawWave(self: *Cava, sample_rate: u32, elapsed: f32) void {
    const height = self.terminal_buffer.height;
    const frame_count = self.frames.len / Player.CHANNELS;

    const rate: f32 = @floatFromInt(sample_rate);
    const span = @min(toUnits(WAVE_SPAN * rate), frame_count / 2);
    if (span == 0) return;

    // Start on a rising zero crossing whenever there is one, which keeps
    // steady sounds from sliding sideways from one frame to the next
    const latest_start = frame_count - span;
    var start = latest_start;
    var candidate = latest_start;
    while (candidate > latest_start - span / 2) : (candidate -= 1) {
        const before = self.sample(candidate - 1, null);
        const after = self.sample(candidate, null);

        if (before < 0.0 and after >= 0.0) {
            start = candidate;
            break;
        }
    }

    // Zoom in on quiet passages
    const first_sample = start * Player.CHANNELS;
    const shown = self.frames[first_sample..][0 .. span * Player.CHANNELS];
    var peak: f32 = 0.0;
    for (shown) |value| peak = @max(peak, @abs(value));
    const decayed = self.wave_peak * @exp(-elapsed / WAVE_RELEASE);
    self.wave_peak = @max(peak, decayed, WAVE_FLOOR);
    const gain = 1.0 / self.wave_peak;

    if (self.stereo) {
        const half = height / 2;
        self.drawTrace(0, 0, half, start, span, gain);
        self.drawTrace(1, half, height - half, start, span, gain);
    } else {
        self.drawTrace(null, 0, height, start, span, gain);
    }
}

/// Draws `span` frames starting from `start` as a waveform filling the
/// `rows` rows found from `top` downwards.
fn drawTrace(
    self: *Cava,
    channel: ?usize,
    top: usize,
    rows: usize,
    start: usize,
    span: usize,
    gain: f32,
) void {
    const width = self.terminal_buffer.width;
    const total_units = rows * self.levels;
    if (total_units < 2) return;

    const center = @as(f32, @floatFromInt(total_units)) / 2.0;
    // Half a cell is as thin as a line can get in every resolution
    const thickness: f32 = @floatFromInt(self.levels / 2);
    const amplitude = (center - thickness / 2.0) * gain;

    var previous = self.sample(start, channel);
    for (0..width) |x| {
        const from = start + x * span / width;
        const to = @max(start + (x + 1) * span / width, from + 1);

        // Including where the previous column ended keeps the line in one
        // piece
        var lowest = previous;
        var highest = previous;
        for (from..to) |frame| {
            previous = self.sample(frame, channel);
            lowest = @min(lowest, previous);
            highest = @max(highest, previous);
        }

        var upper = center - highest * amplitude;
        var lower = center - lowest * amplitude;
        if (lower - upper < thickness) {
            const middle = (upper + lower) / 2.0;
            upper = middle - thickness / 2.0;
            lower = middle + thickness / 2.0;
        }

        const limit: f32 = @floatFromInt(total_units);
        const from_unit = toUnits(math.clamp(upper, 0.0, limit - 1.0));
        const to_unit = toUnits(math.clamp(lower, 1.0, limit));

        self.drawSpan(x, top, rows, from_unit, @max(to_unit, from_unit + 1));
    }
}

/// Fills a column from `from_unit` to `to_unit` (exclusive), both counted
/// from the top of the `rows` rows found from `top` downwards.
fn drawSpan(
    self: *Cava,
    x: usize,
    top: usize,
    rows: usize,
    from_unit: usize,
    to_unit: usize,
) void {
    const levels = self.levels;
    const center_row = rows / 2;
    const first_row = from_unit / levels;
    const last_row = @min((to_unit - 1) / levels, rows - 1);

    for (first_row..last_row + 1) |row| {
        const row_start = row * levels;
        const filled_from = @max(from_unit, row_start) - row_start;
        const filled_to = @min(to_unit, row_start + levels) - row_start;

        const distance = if (row >= center_row)
            row - center_row
        else
            center_row - 1 - row;
        const color = self.colorAt(distance, @max(center_row, 1));

        const cell = if (filled_from == 0 and filled_to == levels)
            Cell.init(FULL_BLOCK, color, self.terminal_buffer.bg)
        else if (filled_to == levels)
            self.partialCell(.up, levels - filled_from, color)
        else if (filled_from == 0)
            self.partialCell(.down, filled_to, color)
        else if (filled_from <= levels - filled_to)
            // A cell can't be filled in its middle only, so extend
            // whichever end is the closest to an edge
            self.partialCell(.down, filled_to, color)
        else
            self.partialCell(.up, levels - filled_from, color);

        cell.put(x, top + row) catch {};
    }
}

fn drawSpectrogram(self: *Cava, values: []const f32, elapsed: f32) void {
    const rows = self.history_rows;
    const columns = self.history_columns;
    if (rows == 0 or columns == 0) return;

    // The picture moves up at a steady pace, whatever the frame rate is
    self.history_timer += elapsed;
    for (0..SPECTROGRAM_MAX_CATCH_UP) |_| {
        if (self.history_timer < SPECTROGRAM_STEP) break;
        self.history_timer -= SPECTROGRAM_STEP;

        self.history_head = (self.history_head + 1) % rows;
        const row = self.history[self.history_head * columns ..][0..columns];
        for (row, 0..) |*value, bar| value.* = self.barValue(values, bar);
    }
    if (self.history_timer >= SPECTROGRAM_STEP) self.history_timer = 0.0;

    const bg = self.terminal_buffer.bg;
    for (0..self.terminal_buffer.height) |y| {
        for (0..columns) |column| {
            const x = self.left_margin + column;

            if (!self.full_color) {
                // No color to fade with here, so use denser and denser
                // characters instead
                const steps = self.stops.len * SHADES.len;
                const value = self.historyAt(y, column);
                const step: usize = @intFromFloat(value * steps);
                if (step == 0) continue;

                const index = @min(step, steps) - 1;
                const cell = Cell.init(
                    SHADES[index % SHADES.len],
                    self.stops[index / SHADES.len],
                    bg,
                );
                cell.put(x, y) catch {};
                continue;
            }

            const upper = self.heatAt(self.historyAt(y * 2, column));
            const lower = self.heatAt(self.historyAt(y * 2 + 1, column));

            const cell = if (upper != null and lower != null)
                Cell.init(UPPER_HALF_BLOCK, upper.?, lower.?)
            else if (upper) |color|
                Cell.init(UPPER_HALF_BLOCK, color, bg)
            else if (lower) |color|
                Cell.init(LOWER_HALF_BLOCK, color, bg)
            else
                continue;

            cell.put(x, y) catch {};
        }
    }
}

/// Returns what the spectrogram shows on the given row, counted from the
/// top of the screen, the most recent one being at the very bottom.
fn historyAt(self: *const Cava, row: usize, column: usize) f32 {
    const index = (self.history_head + 1 + row) % self.history_rows;
    return self.history[index * self.history_columns + column];
}

/// Returns the color standing for a bar height in the spectrogram, or null
/// if it's too low to be shown at all.
fn heatAt(self: *const Cava, value: f32) ?u32 {
    const index = toUnits(math.clamp(value, 0.0, 1.0) * (PALETTE_SIZE - 1));
    if (index == 0) return null;

    // Low bars fade into the dark instead of all having the bottom color
    const brightness = @min(1.0, HEAT_GAIN * value);
    return scale(self.palette[index], brightness);
}

/// Fills cells from the `base` row and away from it, by `units` steps. The
/// colors are spread over `extent` cells, which is as far as this goes.
fn fill(
    self: *Cava,
    x: usize,
    base: usize,
    direction: Direction,
    units: usize,
    extent: usize,
) void {
    const full_cells = units / self.levels;
    const remainder = units % self.levels;

    for (0..extent) |i| {
        if (i > full_cells or (i == full_cells and remainder == 0)) break;

        const color = self.colorAt(i, extent);
        const cell = if (i < full_cells)
            Cell.init(FULL_BLOCK, color, self.terminal_buffer.bg)
        else
            self.partialCell(direction, remainder, color);

        const y = switch (direction) {
            .up => base - 1 - i,
            .down => base + i,
        };
        for (0..self.column_width) |offset| cell.put(x + offset, y) catch {};
    }
}

/// Returns a cell filled by `units` steps, either from its bottom up or
/// from its top down.
fn partialCell(
    self: *const Cava,
    direction: Direction,
    units: usize,
    color: u32,
) Cell {
    const bg = self.terminal_buffer.bg;

    if (self.levels == 2) return switch (direction) {
        .up => Cell.init(LOWER_HALF_BLOCK, color, bg),
        .down => Cell.init(UPPER_HALF_BLOCK, color, bg),
    };

    return switch (direction) {
        .up => Cell.init(@intCast(LOWER_BLOCKS_BASE + units), color, bg),
        // There are no such characters hanging from the top, so draw the
        // empty part instead with the colors swapped
        .down => Cell.init(
            @intCast(LOWER_BLOCKS_BASE + self.levels - units),
            color | Styling.REVERSE,
            bg,
        ),
    };
}

fn colorAt(self: *const Cava, index: usize, extent: usize) u32 {
    if (extent < 2) return self.palette[0];

    const last = extent - 1;
    return self.palette[@min(index, last) * (PALETTE_SIZE - 1) / last];
}

fn displayedBars(self: *const Cava) usize {
    return self.bars_per_channel * @as(usize, if (self.stereo) 2 else 1);
}

fn barColumn(self: *const Cava, bar: usize) usize {
    return self.left_margin + bar * (self.column_width + self.column_gap);
}

/// Returns the height of a bar counted from the left of the screen. In
/// stereo, the left channel is flipped so that the lowest frequencies of
/// both channels meet in the middle.
fn barValue(self: *const Cava, values: []const f32, bar: usize) f32 {
    if (!self.stereo) return values[bar];

    const per_channel = self.bars_per_channel;
    if (bar < per_channel) return values[per_channel - 1 - bar];
    return values[bar];
}

/// Returns a sample of one channel, or of both mixed together.
fn sample(self: *const Cava, frame: usize, channel: ?usize) f32 {
    const left = self.frames[frame * Player.CHANNELS];
    const right = self.frames[frame * Player.CHANNELS + 1];

    const index = channel orelse return (left + right) * 0.5;
    return if (index == 0) left else right;
}

fn buildPalette(self: *Cava) void {
    for (&self.palette, 0..) |*color, i| {
        if (!self.full_color) {
            // Eight colors can't be blended, so go from one to the next
            color.* = self.stops[i * self.stops.len / PALETTE_SIZE];
            continue;
        }

        const position = @as(f32, @floatFromInt(i)) / (PALETTE_SIZE - 1) * 2.0;
        color.* = if (position < 1.0)
            blend(self.stops[0], self.stops[1], position)
        else
            blend(self.stops[1], self.stops[2], position - 1.0);
    }
}

fn levelsOf(resolution: CavaResolution, use_kmscon_vt: bool) usize {
    return switch (resolution) {
        .high => 8,
        .low => 2,
        .auto => if (hasConsoleFont(use_kmscon_vt)) 2 else 8,
    };
}

/// Tells if we're drawing with the font of the Linux console, which only
/// has room for a few hundred characters. Half blocks are about all it's
/// guaranteed to have.
fn hasConsoleFont(use_kmscon_vt: bool) bool {
    if (use_kmscon_vt) return false;

    const term = std.c.getenv("TERM") orelse return false;
    return std.mem.eql(u8, std.mem.span(term), "linux");
}

/// Rounds a positive amount of something to a whole number of it.
fn toUnits(amount: f32) usize {
    return @intFromFloat(@round(amount));
}

/// Mixes two 24-bit colors, ignoring their styling.
fn blend(from: u32, to: u32, amount: f32) u32 {
    var result: u32 = 0;

    inline for (.{ 16, 8, 0 }) |shift| {
        const a: f32 = @floatFromInt((from >> shift) & 0xFF);
        const b: f32 = @floatFromInt((to >> shift) & 0xFF);
        const mixed: u32 = @intFromFloat(@round(a + (b - a) * amount));
        result |= mixed << shift;
    }

    return visible(result);
}

/// Darkens a 24-bit color.
fn scale(color: u32, brightness: f32) u32 {
    return blend(Color.TRUE_BLACK, color, brightness);
}

/// The terminal takes a color of all zeroes for its default one, so black
/// has to be asked for differently.
fn visible(color: u32) u32 {
    return if (color & 0x00FFFFFF == 0) Color.TRUE_BLACK else color;
}

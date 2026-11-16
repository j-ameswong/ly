//! Turns the most recent PCM samples of an audio stream into the heights of
//! spectrum bars.
//!
//! The processing follows the same recipe as cava
//! (https://github.com/karlstav/cava): bars are spread logarithmically over
//! the audible range, the lowest ones read from a longer FFT so that they
//! can still be told apart, and the result goes through a gravity fall-off,
//! an integral filter and an automatic sensitivity adjustment. Unlike cava,
//! every filter here is expressed in seconds rather than in frames, so the
//! bars behave the same whatever the refresh rate is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

const Spectrum = @This();

/// Frequency range covered by the bars, in Hz
const LOWER_CUTOFF: f32 = 50.0;
const UPPER_CUTOFF: f32 = 10_000.0;

/// Bars starting below this frequency read from the longer (bass) FFT
const BASS_CUTOFF: f32 = 100.0;

/// How much higher frequencies get boosted, as music carries a lot less
/// energy up there
const TILT_EXPONENT: f32 = 0.85;

/// Time a bar takes to fall all the way down once nothing holds it up
const FALL_TIME: f32 = 0.34;

/// Time constant of the integral filter that steadies the bars
const INTEGRAL_TIME: f32 = 0.058;

/// Sensitivity change rates per second (as exponents). It drops quickly
/// when a bar overshoots, creeps back up otherwise, and races up until the
/// first overshoot so that the bars find their scale right away.
const SENS_FALL_RATE: f32 = 1.33;
const SENS_RISE_RATE: f32 = 0.066;
const SENS_INITIAL_RISE_RATE: f32 = 6.3;
const SENS_INITIAL: f32 = 0.02;

/// The sensitivity stays within these, so that a track with next to nothing
/// in the frequencies we look at can't send it towards infinity
const SENS_MIN: f32 = 1.0e-6;
const SENS_MAX: f32 = 1.0e4;

/// Input below this level is considered silence, which must not be
/// amplified
const SILENCE_THRESHOLD: f32 = 1.0e-4;

pub const Layout = enum { mono, stereo };

const Plan = enum { bass, main };

const Band = struct {
    plan: Plan,
    first_bin: usize,
    last_bin: usize,
    weight: f32,
};

const Fft = struct {
    size: usize,
    bit_reversed: []usize,
    cos: []f32,
    sin: []f32,
    window: []f32,
    real: []f32,
    imaginary: []f32,
    /// Scales a magnitude into an amplitude density, which makes FFTs of
    /// different sizes comparable
    scale: f32,

    fn init(allocator: Allocator, size: usize, sample_rate: u32) !Fft {
        std.debug.assert(math.isPowerOfTwo(size));

        const bit_reversed = try allocator.alloc(usize, size);
        errdefer allocator.free(bit_reversed);
        const cos = try allocator.alloc(f32, size / 2);
        errdefer allocator.free(cos);
        const sin = try allocator.alloc(f32, size / 2);
        errdefer allocator.free(sin);
        const window = try allocator.alloc(f32, size);
        errdefer allocator.free(window);
        const real = try allocator.alloc(f32, size);
        errdefer allocator.free(real);
        const imaginary = try allocator.alloc(f32, size);
        errdefer allocator.free(imaginary);

        const bits: usize = math.log2_int(usize, size);
        for (bit_reversed, 0..) |*reversed, i| {
            reversed.* = @bitReverse(i) >> @intCast(@bitSizeOf(usize) - bits);
        }

        const size_f: f32 = @floatFromInt(size);
        const rate: f32 = @floatFromInt(sample_rate);
        for (cos, sin, 0..) |*c, *s, i| {
            const angle = -2.0 * math.pi * @as(f32, @floatFromInt(i)) / size_f;
            c.* = @cos(angle);
            s.* = @sin(angle);
        }

        // Hann window
        var window_power: f32 = 0.0;
        for (window, 0..) |*w, i| {
            const phase = 2.0 * math.pi * @as(f32, @floatFromInt(i)) / size_f;
            w.* = 0.5 * (1.0 - @cos(phase));
            window_power += w.* * w.*;
        }

        return .{
            .size = size,
            .bit_reversed = bit_reversed,
            .cos = cos,
            .sin = sin,
            .window = window,
            .real = real,
            .imaginary = imaginary,
            .scale = 1.0 / @sqrt(rate * window_power),
        };
    }

    fn deinit(self: *Fft, allocator: Allocator) void {
        allocator.free(self.bit_reversed);
        allocator.free(self.cos);
        allocator.free(self.sin);
        allocator.free(self.window);
        allocator.free(self.real);
        allocator.free(self.imaginary);
    }

    /// Transforms the windowed samples previously stored in `real` (in
    /// bit-reversed order, see `load`).
    fn run(self: *Fft) void {
        const real = self.real;
        const imaginary = self.imaginary;
        @memset(imaginary, 0.0);

        var half: usize = 1;
        while (half < self.size) : (half *= 2) {
            const twiddle_step = self.size / (half * 2);

            var start: usize = 0;
            while (start < self.size) : (start += half * 2) {
                for (0..half) |k| {
                    const w_re = self.cos[k * twiddle_step];
                    const w_im = self.sin[k * twiddle_step];
                    const a = start + k;
                    const b = a + half;

                    const t_re = real[b] * w_re - imaginary[b] * w_im;
                    const t_im = real[b] * w_im + imaginary[b] * w_re;

                    real[b] = real[a] - t_re;
                    imaginary[b] = imaginary[a] - t_im;
                    real[a] += t_re;
                    imaginary[a] += t_im;
                }
            }
        }
    }

    fn magnitude(self: *const Fft, bin: usize) f32 {
        return math.hypot(self.real[bin], self.imaginary[bin]) * self.scale;
    }
};

allocator: Allocator,
sample_rate: u32,
bass: Fft,
main: Fft,
layout: Layout,
bars_per_channel: usize,
bands: []Band,
/// Bar heights between 0 and 1, one channel after the other
values: []f32,
peaks: []f32,
fall_times: []f32,
previous: []f32,
integrals: []f32,
sensitivity: f32,
finding_sensitivity: bool,

pub fn init(allocator: Allocator, sample_rate: u32) !Spectrum {
    // Longer FFTs for higher sample rates keep the frequency resolution
    // roughly constant
    var main_size: usize = 512;
    if (sample_rate > 8_125) main_size *= 2;
    if (sample_rate > 16_250) main_size *= 2;
    if (sample_rate > 32_500) main_size *= 2;
    if (sample_rate > 75_000) main_size *= 2;
    if (sample_rate > 150_000) main_size *= 2;

    var bass = try Fft.init(allocator, main_size * 2, sample_rate);
    errdefer bass.deinit(allocator);
    var main = try Fft.init(allocator, main_size, sample_rate);
    errdefer main.deinit(allocator);

    return .{
        .allocator = allocator,
        .sample_rate = sample_rate,
        .bass = bass,
        .main = main,
        .layout = .mono,
        .bars_per_channel = 0,
        .bands = &.{},
        .values = &.{},
        .peaks = &.{},
        .fall_times = &.{},
        .previous = &.{},
        .integrals = &.{},
        .sensitivity = SENS_INITIAL,
        .finding_sensitivity = true,
    };
}

pub fn deinit(self: *Spectrum) void {
    self.bass.deinit(self.allocator);
    self.main.deinit(self.allocator);
    self.allocator.free(self.bands);
    self.allocator.free(self.values);
    self.allocator.free(self.peaks);
    self.allocator.free(self.fall_times);
    self.allocator.free(self.previous);
    self.allocator.free(self.integrals);
}

/// Number of frames `process` wants to be given.
pub fn windowFrames(self: *const Spectrum) usize {
    return self.bass.size;
}

/// Sets how many bars each channel is split into. The bars lose their
/// current heights.
pub fn setLayout(
    self: *Spectrum,
    layout: Layout,
    bars_per_channel: usize,
) !void {
    const channel_count: usize = if (layout == .stereo) 2 else 1;
    const total = bars_per_channel * channel_count;

    const bands = try self.allocator.alloc(Band, bars_per_channel);
    errdefer self.allocator.free(bands);
    const values = try self.allocator.alloc(f32, total);
    errdefer self.allocator.free(values);
    const peaks = try self.allocator.alloc(f32, total);
    errdefer self.allocator.free(peaks);
    const fall_times = try self.allocator.alloc(f32, total);
    errdefer self.allocator.free(fall_times);
    const previous = try self.allocator.alloc(f32, total);
    errdefer self.allocator.free(previous);
    const integrals = try self.allocator.alloc(f32, total);
    errdefer self.allocator.free(integrals);

    self.allocator.free(self.bands);
    self.allocator.free(self.values);
    self.allocator.free(self.peaks);
    self.allocator.free(self.fall_times);
    self.allocator.free(self.previous);
    self.allocator.free(self.integrals);

    self.layout = layout;
    self.bars_per_channel = bars_per_channel;
    self.bands = bands;
    self.values = values;
    self.peaks = peaks;
    self.fall_times = fall_times;
    self.previous = previous;
    self.integrals = integrals;

    @memset(values, 0.0);
    @memset(peaks, 0.0);
    @memset(fall_times, 0.0);
    @memset(previous, 0.0);
    @memset(integrals, 0.0);

    self.computeBands();
}

fn computeBands(self: *Spectrum) void {
    const rate: f32 = @floatFromInt(self.sample_rate);
    const upper_cutoff = @min(UPPER_CUTOFF, rate * 0.45);
    const lower_cutoff = @min(LOWER_CUTOFF, upper_cutoff * 0.5);
    const bar_count: f32 = @floatFromInt(self.bands.len);

    for (self.bands, 0..) |*band, i| {
        const index: f32 = @floatFromInt(i);
        const ratio = upper_cutoff / lower_cutoff;
        const lower_edge = lower_cutoff *
            math.pow(f32, ratio, index / bar_count);
        const upper_edge = lower_cutoff *
            math.pow(f32, ratio, (index + 1.0) / bar_count);

        const plan: Plan = if (lower_edge < BASS_CUTOFF) .bass else .main;
        const fft = self.fftOf(plan);
        const bin_width = rate / @as(f32, @floatFromInt(fft.size));
        const last_usable_bin = fft.size / 2 - 1;

        var first_bin: usize = @intFromFloat(@ceil(lower_edge / bin_width));
        var last_bin: usize = @intFromFloat(@ceil(upper_edge / bin_width));
        last_bin -|= 1;

        // Bars get narrower than a single FFT bin in the low end. Push
        // them up so that every bar has at least one bin of its own,
        // instead of several bars showing the very same thing.
        if (i > 0 and self.bands[i - 1].plan == plan) {
            first_bin = @max(first_bin, self.bands[i - 1].last_bin + 1);
        }
        first_bin = @min(@max(first_bin, 1), last_usable_bin);
        last_bin = @min(@max(last_bin, first_bin), last_usable_bin);

        const bin_count: f32 = @floatFromInt(last_bin - first_bin + 1);
        const end_bin: f32 = @floatFromInt(last_bin + 1);

        band.* = .{
            .plan = plan,
            .first_bin = first_bin,
            .last_bin = last_bin,
            // The bar shows the average of its bins, tilted
            .weight = math.pow(f32, end_bin * bin_width, TILT_EXPONENT) /
                bin_count,
        };
    }
}

fn fftOf(self: *Spectrum, plan: Plan) *Fft {
    return switch (plan) {
        .bass => &self.bass,
        .main => &self.main,
    };
}

/// Updates the bars from `frames`, the `windowFrames()` most recent
/// interleaved stereo frames. `elapsed` is the time in seconds since the
/// previous call.
pub fn process(self: *Spectrum, frames: []const f32, elapsed: f32) void {
    std.debug.assert(frames.len == self.windowFrames() * 2);

    var silent = true;
    for (frames) |sample| {
        if (@abs(sample) > SILENCE_THRESHOLD) {
            silent = false;
            break;
        }
    }

    const channel_count: usize = if (self.layout == .stereo) 2 else 1;
    for (0..channel_count) |channel| {
        const first = channel * self.bars_per_channel;
        const raw = self.values[first..][0..self.bars_per_channel];

        if (silent) {
            @memset(raw, 0.0);
            continue;
        }

        self.load(&self.bass, frames, channel);
        self.load(&self.main, frames, channel);
        self.bass.run();
        self.main.run();

        for (self.bands, raw) |band, *value| {
            const fft = self.fftOf(band.plan);

            var sum: f32 = 0.0;
            for (band.first_bin..band.last_bin + 1) |bin| {
                sum += fft.magnitude(bin);
            }

            value.* = sum * band.weight;
        }
    }

    self.smooth(elapsed, silent);
}

/// Stores the windowed tail of `frames` for one channel into the FFT's
/// input, in the bit-reversed order `Fft.run` expects.
fn load(self: *Spectrum, fft: *Fft, frames: []const f32, channel: usize) void {
    const tail = frames[frames.len - fft.size * 2 ..];

    switch (self.layout) {
        .stereo => for (fft.bit_reversed, fft.window, 0..) |target, w, i| {
            fft.real[target] = tail[i * 2 + channel] * w;
        },
        .mono => for (fft.bit_reversed, fft.window, 0..) |target, w, i| {
            fft.real[target] = (tail[i * 2] + tail[i * 2 + 1]) * 0.5 * w;
        },
    }
}

fn smooth(self: *Spectrum, elapsed: f32, silent: bool) void {
    // Guard against huge steps after the UI has been busy elsewhere
    const step = math.clamp(elapsed, 0.0, 0.25);
    const integral_gain = 1.0 - @exp(-step / INTEGRAL_TIME);
    var overshoot = false;

    for (
        self.values,
        self.peaks,
        self.fall_times,
        self.previous,
        self.integrals,
    ) |*value, *peak, *fall_time, *previous, *integral| {
        var height = value.* * self.sensitivity;

        // Gravity: a bar that isn't pushed up anymore falls, slowly at
        // first and then faster and faster
        if (height < previous.*) {
            fall_time.* += step;

            const fall = fall_time.* / FALL_TIME;
            height = @max(height, peak.* * (1.0 - fall * fall));
            height = @max(height, 0.0);
        } else {
            peak.* = height;
            fall_time.* = 0.0;
        }
        previous.* = height;

        integral.* += (height - integral.*) * integral_gain;
        height = integral.*;

        if (height > 1.0) {
            overshoot = true;
            height = 1.0;
        }

        value.* = height;
    }

    if (overshoot) {
        self.sensitivity *= @exp(-SENS_FALL_RATE * step);
        self.finding_sensitivity = false;
    } else if (!silent) {
        const rate = if (self.finding_sensitivity)
            SENS_INITIAL_RISE_RATE
        else
            SENS_RISE_RATE;
        self.sensitivity *= @exp(rate * step);
    }

    self.sensitivity = math.clamp(self.sensitivity, SENS_MIN, SENS_MAX);
}

test "a pure tone lights up the bar covering its frequency" {
    const allocator = std.testing.allocator;
    const sample_rate = 48_000;

    var spectrum = try Spectrum.init(allocator, sample_rate);
    defer spectrum.deinit();
    try spectrum.setLayout(.mono, 32);

    const frames = try allocator.alloc(f32, spectrum.windowFrames() * 2);
    defer allocator.free(frames);

    const frequency: f32 = 1_000.0;
    for (0..spectrum.windowFrames()) |i| {
        const time = @as(f32, @floatFromInt(i)) / sample_rate;
        const sample = 0.5 * @sin(2.0 * math.pi * frequency * time);
        frames[i * 2] = sample;
        frames[i * 2 + 1] = sample;
    }

    for (0..120) |_| spectrum.process(frames, 1.0 / 60.0);

    var loudest: usize = 0;
    for (spectrum.values, 0..) |value, i| {
        if (value > spectrum.values[loudest]) loudest = i;
    }

    const band = spectrum.bands[loudest];
    const fft_size: f32 = @floatFromInt(spectrum.main.size);
    const bin_width = @as(f32, sample_rate) / fft_size;
    const lower_edge = @as(f32, @floatFromInt(band.first_bin)) * bin_width;
    const upper_edge = @as(f32, @floatFromInt(band.last_bin + 1)) * bin_width;

    try std.testing.expect(lower_edge <= frequency and frequency <= upper_edge);
    // The automatic sensitivity must have brought the bar up to the top
    try std.testing.expect(spectrum.values[loudest] > 0.8);
}

test "bars stay sane when there is nothing to show" {
    const allocator = std.testing.allocator;

    var spectrum = try Spectrum.init(allocator, 48_000);
    defer spectrum.deinit();
    try spectrum.setLayout(.stereo, 24);

    const frames = try allocator.alloc(f32, spectrum.windowFrames() * 2);
    defer allocator.free(frames);

    // Not silence, yet nothing in the frequencies the bars cover
    @memset(frames, 0.5);

    // Plenty of time for the sensitivity to run away
    for (0..20 * 60) |_| spectrum.process(frames, 1.0 / 60.0);

    try std.testing.expect(spectrum.sensitivity <= SENS_MAX);
    for (spectrum.values) |value| {
        try std.testing.expect(value >= 0.0 and value <= 1.0);
    }
}

test "every bar reads its own bins" {
    const allocator = std.testing.allocator;

    var spectrum = try Spectrum.init(allocator, 44_100);
    defer spectrum.deinit();
    try spectrum.setLayout(.stereo, 120);

    const bands = spectrum.bands;
    for (bands[1..], bands[0 .. bands.len - 1]) |band, lower| {
        try std.testing.expect(band.first_bin <= band.last_bin);
        if (band.plan == lower.plan) {
            try std.testing.expect(band.first_bin > lower.last_bin);
        }
    }
}

test "bars fall back down in silence" {
    const allocator = std.testing.allocator;

    var spectrum = try Spectrum.init(allocator, 48_000);
    defer spectrum.deinit();
    try spectrum.setLayout(.stereo, 16);

    const frames = try allocator.alloc(f32, spectrum.windowFrames() * 2);
    defer allocator.free(frames);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (frames) |*sample| sample.* = random.float(f32) - 0.5;

    for (0..120) |_| spectrum.process(frames, 1.0 / 60.0);
    const sensitivity = spectrum.sensitivity;

    @memset(frames, 0.0);
    for (0..120) |_| spectrum.process(frames, 1.0 / 60.0);

    for (spectrum.values) |value| try std.testing.expect(value < 0.01);
    // Silence must not be amplified
    try std.testing.expectEqual(sensitivity, spectrum.sensitivity);
}

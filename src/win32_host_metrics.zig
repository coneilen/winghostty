//! DPI-independent font and terminal cell metrics for the embeddable host.
//!
//! The host API owns the conversion from logical (96 DPI) metrics to device
//! pixels.  Keeping this calculation allocation-free and independent of the
//! renderer makes monitor transitions deterministic and easy to test.

const std = @import("std");

pub const default_dpi: u32 = 96;

pub const BaseMetrics = extern struct {
    font_width: u32 = 8,
    font_height: u32 = 16,
    cell_width: u32 = 8,
    cell_height: u32 = 16,
    baseline: u32 = 13,
};

pub const Metrics = extern struct {
    dpi: u32,
    dpi_scale: f32,
    font_scale: f32,
    font_width: u32,
    font_height: u32,
    cell_width: u32,
    cell_height: u32,
    baseline: u32,
};

pub fn normalizeDpi(dpi: u32) u32 {
    return if (dpi == 0) default_dpi else dpi;
}

pub fn dpiScale(dpi: u32) f32 {
    return @as(f32, @floatFromInt(normalizeDpi(dpi))) /
        @as(f32, @floatFromInt(default_dpi));
}

pub fn scaleMetric(value: u32, dpi: u32, font_scale: f32) u32 {
    if (value == 0) return 0;
    if (!std.math.isFinite(font_scale) or font_scale <= 0) return 0;

    const scaled = @as(f64, @floatFromInt(value)) *
        @as(f64, @floatFromInt(normalizeDpi(dpi))) /
        @as(f64, @floatFromInt(default_dpi)) *
        @as(f64, font_scale);
    if (!std.math.isFinite(scaled)) return 0;
    return @max(@as(u32, 1), @as(u32, @intFromFloat(@round(scaled))));
}

pub fn calculate(base: BaseMetrics, dpi: u32, font_scale: f32) Metrics {
    const normalized_dpi = normalizeDpi(dpi);
    return .{
        .dpi = normalized_dpi,
        .dpi_scale = dpiScale(normalized_dpi),
        .font_scale = font_scale,
        .font_width = scaleMetric(base.font_width, normalized_dpi, font_scale),
        .font_height = scaleMetric(base.font_height, normalized_dpi, font_scale),
        .cell_width = scaleMetric(base.cell_width, normalized_dpi, font_scale),
        .cell_height = scaleMetric(base.cell_height, normalized_dpi, font_scale),
        .baseline = scaleMetric(base.baseline, normalized_dpi, font_scale),
    };
}

pub fn boundsForCells(columns: u32, rows: u32, metrics: Metrics) struct {
    width: u32,
    height: u32,
} {
    return .{
        .width = std.math.mul(u32, columns, metrics.cell_width) catch std.math.maxInt(u32),
        .height = std.math.mul(u32, rows, metrics.cell_height) catch std.math.maxInt(u32),
    };
}

test "DPI scale normalizes 100, 125, 150, and 200 percent" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dpiScale(96), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), dpiScale(120), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), dpiScale(144), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), dpiScale(192), 0.0001);
}

test "font and cell metrics recalculate without cumulative rounding" {
    const base: BaseMetrics = .{
        .font_width = 7,
        .font_height = 15,
        .cell_width = 8,
        .cell_height = 16,
        .baseline = 12,
    };
    const at_125 = calculate(base, 120, 1);
    try std.testing.expectEqual(@as(u32, 10), at_125.cell_width);
    try std.testing.expectEqual(@as(u32, 20), at_125.cell_height);
    try std.testing.expectEqual(@as(u32, 19), at_125.font_height);

    const at_150 = calculate(base, 144, 1);
    try std.testing.expectEqual(@as(u32, 12), at_150.cell_width);
    try std.testing.expectEqual(@as(u32, 24), at_150.cell_height);

    const returned = calculate(base, 96, 1);
    try std.testing.expectEqual(base.cell_width, returned.cell_width);
    try std.testing.expectEqual(base.cell_height, returned.cell_height);
}

test "font scale composes with monitor DPI" {
    const metrics = calculate(.{}, 144, 1.25);
    try std.testing.expectEqual(@as(u32, 15), metrics.cell_width);
    try std.testing.expectEqual(@as(u32, 30), metrics.cell_height);
}

test "cell bounds saturate instead of wrapping" {
    const metrics = calculate(.{}, 192, 1);
    const bounds = boundsForCells(std.math.maxInt(u32), 2, metrics);
    try std.testing.expectEqual(std.math.maxInt(u32), bounds.width);
    try std.testing.expectEqual(@as(u32, 64), bounds.height);
}

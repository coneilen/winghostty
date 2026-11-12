const std = @import("std");

pub const visible: u32 = 1;
pub const blinking: u32 = 2;
pub const wide_tail: u32 = 4;
pub const pending_wrap: u32 = 8;
pub const blink_interval_ms: u64 = 600;

pub const Cursor = extern struct {
    x: i32 = -1,
    y: i32 = -1,
    style: u32 = 0,
    flags: u32 = 0,
    color_rgb: u32 = 0xFFFFFF,
    text_rgb: u32 = 0x282C34,
    reserved: [2]u32 = .{ 0, 0 },
};

pub const Shape = enum { block, bar, underline, block_hollow };
pub const Placement = struct {
    column: u32,
    row: u32,
    columns: u32,
    shape: Shape,
};

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const Rects = struct { items: [4]Rect = undefined, len: usize = 0 };

pub fn rectangles(at: Placement, grid: Rect, columns: u32, rows: u32) Rects {
    var result = Rects{};
    if (columns == 0 or rows == 0 or grid.width <= 0 or grid.height <= 0) return result;
    const cw = grid.width / @as(f32, @floatFromInt(columns));
    const ch = grid.height / @as(f32, @floatFromInt(rows));
    const x = grid.x + cw * @as(f32, @floatFromInt(at.column));
    const y = grid.y + ch * @as(f32, @floatFromInt(at.row));
    const w = cw * @as(f32, @floatFromInt(at.columns));
    const tx = @min(1, w);
    const ty = @min(1, ch);
    switch (at.shape) {
        .block => {
            result.items[0] = .{ .x = x, .y = y, .width = w, .height = ch };
            result.len = 1;
        },
        .bar => {
            // Ghostty centers the one-device-pixel bar on the left boundary.
            const left = @max(grid.x, x - 1);
            const right = @min(grid.x + grid.width, x);
            // At the left grid edge keep the clipped bar visible.
            result.items[0] = .{ .x = left, .y = y, .width = @max(tx, right - left), .height = ch };
            result.len = 1;
        },
        .underline => {
            result.items[0] = .{ .x = x, .y = y + ch - ty, .width = w, .height = ty };
            result.len = 1;
        },
        .block_hollow => {
            result.items = .{
                .{ .x = x, .y = y, .width = w, .height = ty },
                .{ .x = x, .y = y + ch - ty, .width = w, .height = ty },
                .{ .x = x, .y = y, .width = tx, .height = ch },
                .{ .x = x + w - tx, .y = y, .width = tx, .height = ch },
            };
            result.len = 4;
        },
    }
    return result;
}

pub fn validate(cursor: Cursor) error{InvalidCursor}!void {
    if (cursor.style > 3 or
        cursor.flags & ~(visible | blinking | wide_tail | pending_wrap) != 0 or
        cursor.color_rgb > 0xFFFFFF or cursor.text_rgb > 0xFFFFFF or
        cursor.reserved[0] != 0 or cursor.reserved[1] != 0)
    {
        return error.InvalidCursor;
    }
}

pub fn inViewport(cursor: Cursor, columns: u32, rows: u32) bool {
    return cursor.x >= 0 and cursor.y >= 0 and
        @as(u32, @intCast(cursor.x)) < columns and
        @as(u32, @intCast(cursor.y)) < rows;
}

pub fn blinkOn(epoch_ms: u64, now_ms: u64) bool {
    return ((now_ms -| epoch_ms) / blink_interval_ms) % 2 == 0;
}

pub fn needsTimer(cursor: Cursor, columns: u32, rows: u32, focused: bool, surface_visible: bool) bool {
    return focused and surface_visible and
        cursor.flags & (visible | blinking) == (visible | blinking) and
        inViewport(cursor, columns, rows);
}

pub fn placement(
    cursor: Cursor,
    columns: u32,
    rows: u32,
    cell_width: u8,
    focused: bool,
    surface_visible: bool,
    epoch_ms: u64,
    now_ms: u64,
) ?Placement {
    if (!surface_visible or cursor.flags & visible == 0 or
        !inViewport(cursor, columns, rows)) return null;
    if (focused and cursor.flags & blinking != 0 and !blinkOn(epoch_ms, now_ms)) return null;
    const tail = cursor.flags & wide_tail != 0;
    if (tail and cursor.x == 0) return null;
    const column: u32 = @as(u32, @intCast(cursor.x)) - @intFromBool(tail);
    const width: u32 = if (tail or cell_width == 2) 2 else 1;
    return .{
        .column = column,
        .row = @intCast(cursor.y),
        .columns = @min(width, columns - column),
        .shape = if (!focused) .block_hollow else switch (cursor.style) {
            0 => .block,
            1 => .bar,
            2 => .underline,
            3 => .block_hollow,
            else => return null,
        },
    };
}

test "visual cursor visibility viewport and pending wrap" {
    var cursor = Cursor{ .x = 2, .y = 0, .flags = visible | pending_wrap };
    try std.testing.expect(placement(cursor, 3, 1, 1, true, true, 0, 0) != null);
    try std.testing.expectEqual(@as(u32, 2), placement(cursor, 3, 1, 1, true, true, 0, 0).?.column);
    cursor.flags = 0;
    try std.testing.expect(placement(cursor, 3, 1, 1, true, true, 0, 0) == null);
    cursor.flags = visible;
    cursor.x = -1;
    try std.testing.expect(placement(cursor, 3, 1, 1, true, true, 0, 0) == null);
    cursor.x = 3;
    try std.testing.expect(placement(cursor, 3, 1, 1, true, true, 0, 0) == null);
    cursor.x = 0;
    cursor.y = 1;
    try std.testing.expect(placement(cursor, 3, 1, 1, true, true, 0, 0) == null);
    cursor.y = 0;
    try std.testing.expect(placement(cursor, 3, 1, 1, true, false, 0, 0) == null);
}

test "visual cursor shape focus and idle blink deadlines" {
    var cursor = Cursor{ .x = 0, .y = 0, .flags = visible | blinking };
    for (0..4) |style| {
        cursor.style = @intCast(style);
        const shapes = [_]Shape{ .block, .bar, .underline, .block_hollow };
        try std.testing.expect(placement(cursor, 1, 1, 1, true, true, 100, 699) != null);
        try std.testing.expectEqual(shapes[style], placement(cursor, 1, 1, 1, true, true, 100, 699).?.shape);
        try std.testing.expect(placement(cursor, 1, 1, 1, true, true, 100, 700) == null);
        try std.testing.expectEqual(shapes[style], placement(cursor, 1, 1, 1, true, true, 100, 1300).?.shape);
        try std.testing.expectEqual(Shape.block_hollow, placement(cursor, 1, 1, 1, false, true, 100, 700).?.shape);
    }
    cursor.flags = visible;
    try std.testing.expect(placement(cursor, 1, 1, 1, true, true, 0, 600) != null);
}

test "visual cursor wide lead tail and row edge" {
    var cursor = Cursor{ .x = 1, .y = 0, .flags = visible };
    try std.testing.expect(placement(cursor, 3, 1, 2, true, true, 0, 0) != null);
    try std.testing.expectEqual(@as(u32, 2), placement(cursor, 3, 1, 2, true, true, 0, 0).?.columns);
    cursor.x = 2;
    cursor.flags |= wide_tail;
    const tail = placement(cursor, 3, 1, 0, true, true, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 1), tail.column);
    try std.testing.expectEqual(@as(u32, 2), tail.columns);
    cursor.x = 0;
    try std.testing.expect(placement(cursor, 3, 1, 0, true, true, 0, 0) == null);
    cursor.flags = visible;
    cursor.x = 2;
    try std.testing.expectEqual(@as(u32, 1), placement(cursor, 3, 1, 2, true, true, 0, 0).?.columns);
}

test "visual cursor rejects invalid descriptors" {
    var cursor = Cursor{};
    try validate(cursor);
    cursor.style = 4;
    try std.testing.expectError(error.InvalidCursor, validate(cursor));
    cursor = .{ .flags = 16 };
    try std.testing.expectError(error.InvalidCursor, validate(cursor));
    cursor = .{ .color_rgb = 0x1000000 };
    try std.testing.expectError(error.InvalidCursor, validate(cursor));
    cursor = .{ .text_rgb = 0x1000000 };
    try std.testing.expectError(error.InvalidCursor, validate(cursor));
    cursor = .{ .reserved = .{ 0, 1 } };
    try std.testing.expectError(error.InvalidCursor, validate(cursor));
}

test "visual cursor timer eligibility stops when hidden unfocused or outside viewport" {
    var cursor = Cursor{ .x = 0, .y = 0, .flags = visible | blinking };
    try std.testing.expect(needsTimer(cursor, 1, 1, true, true));
    try std.testing.expect(!needsTimer(cursor, 1, 1, false, true));
    try std.testing.expect(!needsTimer(cursor, 1, 1, true, false));
    try std.testing.expect(!needsTimer(cursor, 0, 0, true, true));
    cursor.flags = blinking;
    try std.testing.expect(!needsTimer(cursor, 1, 1, true, true));
    cursor.flags = visible;
    try std.testing.expect(!needsTimer(cursor, 1, 1, true, true));
}

test "visual cursor padded grid geometry scales with DPI without a second scale" {
    const at = Placement{ .column = 2, .row = 1, .columns = 1, .shape = .block };
    const rect96 = rectangles(at, .{ .x = 4, .y = 6, .width = 80, .height = 40 }, 4, 2).items[0];
    const rect192 = rectangles(at, .{ .x = 8, .y = 12, .width = 160, .height = 80 }, 4, 2).items[0];
    try std.testing.expectEqual(Rect{ .x = 44, .y = 26, .width = 20, .height = 20 }, rect96);
    try std.testing.expectEqual(Rect{ .x = 88, .y = 52, .width = 40, .height = 40 }, rect192);
    for ([_]Shape{ .block, .bar, .underline, .block_hollow }) |shape| {
        const tiny = rectangles(.{ .column = 0, .row = 0, .columns = 1, .shape = shape }, .{ .x = 7, .y = 9, .width = 0.5, .height = 0.5 }, 1, 1);
        for (tiny.items[0..tiny.len]) |rect| {
            try std.testing.expect(rect.x >= 7 and rect.y >= 9);
            try std.testing.expect(rect.width > 0 and rect.height > 0);
            try std.testing.expect(rect.x + rect.width <= 7.5 and rect.y + rect.height <= 9.5);
        }
    }
}

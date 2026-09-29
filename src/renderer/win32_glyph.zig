//! Grapheme-aware glyph description and native GDI rasterization for the
//! embeddable Win32 host renderer.
//!
//! The v1 render-state ABI carries a single `codepoint` per cell, which
//! cannot describe a grapheme cluster (base + combining marks) and cannot
//! describe East Asian wide cells that occupy two columns. This module owns
//! the additive v2 description (a UTF-8 blob plus one span per cell) and the
//! GDI raster that turns a span into an 8-bit coverage bitmap suitable for a
//! GL_ALPHA texture.
//!
//! Deliberate scope limits (native GDI subset only):
//!   * No complex shaping. There is no HarfBuzz/Uniscribe/DirectWrite pass,
//!     so ligatures, contextual forms, and bidi reordering are not performed.
//!   * No color emoji. Rasterization is grayscale coverage only.
//!   * No LCD/subpixel filtering; `ANTIALIASED_QUALITY` grayscale AA is used
//!     so a single coverage channel is meaningful.
//!   * Font fallback is whatever GDI font linking provides for the selected
//!     face; there is no explicit fallback chain.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("win32_glyph is only available for Windows targets");
    }
}

/// A copied terminal render cell. This is the v1 ABI shape and must never
/// change: the host and every external caller depend on the 16-byte layout.
pub const Cell = extern struct {
    codepoint: u32,
    foreground: u32,
    background: u32,
    flags: u32,
};

comptime {
    std.debug.assert(@sizeOf(Cell) == 16);
    std.debug.assert(@alignOf(Cell) == 4);
    std.debug.assert(@offsetOf(Cell, "codepoint") == 0);
    std.debug.assert(@offsetOf(Cell, "foreground") == 4);
    std.debug.assert(@offsetOf(Cell, "background") == 8);
    std.debug.assert(@offsetOf(Cell, "flags") == 12);
}

/// Width class for a cell in the v2 description.
pub const width_continuation: u8 = 0;
pub const width_narrow: u8 = 1;
pub const width_wide: u8 = 2;

/// Per-cell grapheme span into the snapshot's UTF-8 blob.
///
/// `width` is the column count the grapheme occupies: 1 for a narrow lead
/// cell, 2 for a wide lead cell, and 0 for the continuation cell that a wide
/// lead reserves. Continuation cells carry no ink of their own; the lead
/// cell's raster covers both columns.
pub const GlyphSpan = extern struct {
    offset: u32,
    length: u16,
    width: u8,
    reserved: u8,
};

comptime {
    std.debug.assert(@sizeOf(GlyphSpan) == 8);
    std.debug.assert(@alignOf(GlyphSpan) == 4);
    std.debug.assert(@offsetOf(GlyphSpan, "offset") == 0);
    std.debug.assert(@offsetOf(GlyphSpan, "length") == 4);
    std.debug.assert(@offsetOf(GlyphSpan, "width") == 6);
    std.debug.assert(@offsetOf(GlyphSpan, "reserved") == 7);
}

/// Bounded-allocation ceilings. A malformed or hostile caller must not be
/// able to make the host allocate without limit, so both the cell grid and
/// the text blob are capped before anything is copied.
pub const max_cells: u64 = 1 << 24;
pub const max_text_bytes: u64 = 16 * 1024 * 1024;
pub const max_dimension: u32 = 1 << 16;

pub const ValidationError = error{
    DimensionTooLarge,
    CountMismatch,
    CellsMissing,
    GlyphsMissing,
    TextMissing,
    TooManyCells,
    TextTooLarge,
    InvalidUtf8,
    SpanOutOfRange,
    SpanNotBoundary,
    SpanEmptyForInkCell,
    SpanPresentForEmptyCell,
    BaseCodepointMismatch,
    InvalidWidth,
    ContinuationHasText,
    WideRunTruncated,
    OrphanContinuation,
};

/// A borrowed, not-yet-validated v2 description.
pub const Description = struct {
    columns: u32,
    rows: u32,
    cells: []const Cell,
    glyphs: []const GlyphSpan,
    text: []const u8,
};

/// Validate every invariant of a v2 description.
///
/// This is total: it never mutates, never allocates, and rejects before the
/// caller copies anything, which is what makes the host's snapshot swap
/// atomic (a rejected snapshot leaves the previous one intact).
pub fn validate(description: Description) ValidationError!void {
    const columns = description.columns;
    const rows = description.rows;
    if (columns > max_dimension or rows > max_dimension) {
        return error.DimensionTooLarge;
    }

    const expected = std.math.mul(u64, columns, rows) catch
        return error.DimensionTooLarge;
    if (expected > max_cells) return error.TooManyCells;
    if (expected != description.cells.len) return error.CountMismatch;
    if (expected != description.glyphs.len) return error.CountMismatch;
    if (description.text.len > max_text_bytes) return error.TextTooLarge;

    if (expected != 0 and description.cells.len == 0) return error.CellsMissing;
    if (expected != 0 and description.glyphs.len == 0) return error.GlyphsMissing;

    if (description.text.len != 0 and
        !std.unicode.utf8ValidateSlice(description.text))
    {
        return error.InvalidUtf8;
    }

    if (expected == 0) return;

    for (description.glyphs, description.cells, 0..) |span, cell, index| {
        const column = index % columns;

        switch (span.width) {
            width_continuation => {
                if (span.length != 0) return error.ContinuationHasText;
                // A continuation must be claimed by a wide lead in the same
                // row. Row-relative checks keep a wide run from wrapping.
                if (column == 0) return error.OrphanContinuation;
                if (description.glyphs[index - 1].width != width_wide) {
                    return error.OrphanContinuation;
                }
            },
            width_narrow, width_wide => {
                if (span.width == width_wide) {
                    // The reserved column must exist in this row and must be
                    // an actual continuation cell.
                    if (column + 1 >= columns) return error.WideRunTruncated;
                    if (description.glyphs[index + 1].width != width_continuation) {
                        return error.WideRunTruncated;
                    }
                }
                try validateLeadSpan(description.text, span, cell);
            },
            else => return error.InvalidWidth,
        }
    }
}

fn validateLeadSpan(
    text: []const u8,
    span: GlyphSpan,
    cell: Cell,
) ValidationError!void {
    const blank = cell.codepoint == 0 or cell.codepoint == ' ';
    if (span.length == 0) {
        if (!blank) return error.SpanEmptyForInkCell;
        return;
    }
    if (cell.codepoint == 0) return error.SpanPresentForEmptyCell;

    const offset: usize = span.offset;
    const length: usize = span.length;
    const end = std.math.add(usize, offset, length) catch
        return error.SpanOutOfRange;
    if (end > text.len) return error.SpanOutOfRange;

    // The blob as a whole is valid UTF-8, so a span is well-formed exactly
    // when both of its edges land on a scalar boundary.
    if (isContinuationByte(text[offset])) return error.SpanNotBoundary;
    if (end < text.len and isContinuationByte(text[end])) {
        return error.SpanNotBoundary;
    }

    const run = text[offset..end];
    const first_len = std.unicode.utf8ByteSequenceLength(run[0]) catch
        return error.InvalidUtf8;
    if (first_len > run.len) return error.SpanNotBoundary;
    const first = std.unicode.utf8Decode(run[0..first_len]) catch
        return error.InvalidUtf8;
    if (@as(u32, first) != cell.codepoint) return error.BaseCodepointMismatch;
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

/// Cache identity for a rasterized grapheme. Two runs with different bytes,
/// face, pixel metrics, DPI, or width class must never collide, and any of
/// those changing must invalidate the cached raster.
pub const CacheKey = struct {
    text_hash: u64,
    text_len: u32,
    width: u8,
    cell_width: u16,
    cell_height: u16,
    dpi: u16,
    face_hash: u32,

    pub fn eql(self: CacheKey, other: CacheKey) bool {
        return std.meta.eql(self, other);
    }
};

pub fn cacheKey(
    text: []const u8,
    width: u8,
    options: RasterOptions,
) CacheKey {
    return .{
        // Hash the byte run, not just the base scalar: two graphemes sharing
        // a base (for example "e" and "e" + U+0301) must not collide.
        .text_hash = std.hash.Wyhash.hash(0x9E3779B97F4A7C15, text),
        .text_len = @intCast(@min(text.len, std.math.maxInt(u32))),
        .width = width,
        .cell_width = @intCast(@min(options.cell_width, std.math.maxInt(u16))),
        .cell_height = @intCast(@min(options.cell_height, std.math.maxInt(u16))),
        .dpi = @intCast(@min(options.dpi, std.math.maxInt(u16))),
        .face_hash = @truncate(
            std.hash.Wyhash.hash(0x1F83D9AB, options.face),
        ),
    };
}

// -- Native GDI rasterization ----------------------------------------------

const HDC = ?*anyopaque;
const HBITMAP = ?*anyopaque;
const HFONT = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
const BOOL = i32;

const BITMAPINFOHEADER = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32,
};

const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const LOGFONTW = extern struct {
    lfHeight: i32,
    lfWidth: i32,
    lfEscapement: i32,
    lfOrientation: i32,
    lfWeight: i32,
    lfItalic: u8,
    lfUnderline: u8,
    lfStrikeOut: u8,
    lfCharSet: u8,
    lfOutPrecision: u8,
    lfClipPrecision: u8,
    lfQuality: u8,
    lfPitchAndFamily: u8,
    lfFaceName: [32]u16,
};

const TEXTMETRICW = extern struct {
    tmHeight: i32,
    tmAscent: i32,
    tmDescent: i32,
    tmInternalLeading: i32,
    tmExternalLeading: i32,
    tmAveCharWidth: i32,
    tmMaxCharWidth: i32,
    tmWeight: i32,
    tmOverhang: i32,
    tmDigitizedAspectX: i32,
    tmDigitizedAspectY: i32,
    tmFirstChar: u16,
    tmLastChar: u16,
    tmDefaultChar: u16,
    tmBreakChar: u16,
    tmItalic: u8,
    tmUnderlined: u8,
    tmStruckOut: u8,
    tmPitchAndFamily: u8,
    tmCharSet: u8,
};

const BI_RGB: u32 = 0;
const DIB_RGB_COLORS: u32 = 0;
const TRANSPARENT: i32 = 1;
const ETO_CLIPPED: u32 = 0x0004;
const ETO_OPAQUE: u32 = 0x0002;
const DEFAULT_CHARSET: u8 = 1;
const OUT_TT_PRECIS: u8 = 4;
const CLIP_DEFAULT_PRECIS: u8 = 0;
const ANTIALIASED_QUALITY: u8 = 4;
const FIXED_PITCH: u8 = 1;
const FF_MODERN: u8 = 3 << 4;
const FW_NORMAL: i32 = 400;
const TA_LEFT: u32 = 0;
const TA_TOP: u32 = 0;

extern "gdi32" fn CreateCompatibleDC(hdc: HDC) callconv(.winapi) HDC;
extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn CreateDIBSection(
    hdc: HDC,
    info: *const BITMAPINFO,
    usage: u32,
    bits: *?[*]u8,
    section: ?*anyopaque,
    offset: u32,
) callconv(.winapi) HBITMAP;
extern "gdi32" fn DeleteObject(object: HGDIOBJ) callconv(.winapi) BOOL;
extern "gdi32" fn SelectObject(hdc: HDC, object: HGDIOBJ) callconv(.winapi) HGDIOBJ;
extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkColor(hdc: HDC, color: u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextAlign(hdc: HDC, mode: u32) callconv(.winapi) u32;
extern "gdi32" fn CreateFontIndirectW(font: *const LOGFONTW) callconv(.winapi) HFONT;
extern "gdi32" fn GetTextMetricsW(
    hdc: HDC,
    metrics: *TEXTMETRICW,
) callconv(.winapi) BOOL;
extern "gdi32" fn ExtTextOutW(
    hdc: HDC,
    x: i32,
    y: i32,
    options: u32,
    rect: ?*const RECT,
    string: [*]const u16,
    count: u32,
    dx: ?[*]const i32,
) callconv(.winapi) BOOL;
extern "gdi32" fn GdiFlush() callconv(.winapi) BOOL;

pub const RasterError = error{
    OutOfMemory,
    InvalidUtf8,
    EmptyRun,
    InvalidMetrics,
    CreateDcFailed,
    CreateBitmapFailed,
    CreateFontFailed,
    DrawFailed,
};

pub const default_face = "Consolas";

pub const RasterOptions = struct {
    face: []const u8 = default_face,
    /// Width of a single terminal column in pixels.
    cell_width: u32,
    /// Height of a terminal row in pixels.
    cell_height: u32,
    dpi: u32 = 96,
    /// When true the raster target is clipped to a single column even for a
    /// wide grapheme. This is what makes "spill" observably different from a
    /// real width-2 run: a clipped narrow target cannot contain second-cell
    /// ink because the second cell is not part of the target at all.
    clip_to_cell: bool = true,
};

/// An 8-bit coverage bitmap, one byte per pixel, top-down.
pub const Coverage = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Coverage, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = .{ .width = 0, .height = 0, .pixels = &.{} };
    }

    pub fn at(self: Coverage, x: u32, y: u32) u8 {
        if (x >= self.width or y >= self.height) return 0;
        return self.pixels[y * self.width + x];
    }

    /// Total coverage inside a column-aligned band. Used by tests and by the
    /// renderer's "does this run actually put ink in the second cell" check.
    pub fn bandInk(self: Coverage, left: u32, width: u32) u64 {
        var total: u64 = 0;
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = left;
            const end = @min(left + width, self.width);
            while (x < end) : (x += 1) {
                total += self.pixels[y * self.width + x];
            }
        }
        return total;
    }

    pub fn inkPixels(self: Coverage) u64 {
        var total: u64 = 0;
        for (self.pixels) |value| {
            if (value != 0) total += 1;
        }
        return total;
    }
};

/// Rasterize one grapheme run into a coverage bitmap sized to the destination
/// cells. Clipping is real: `ETO_CLIPPED` with the destination rect means a
/// narrow target physically cannot receive ink outside its own column.
pub fn rasterize(
    alloc: std.mem.Allocator,
    text: []const u8,
    width: u8,
    options: RasterOptions,
) RasterError!Coverage {
    if (text.len == 0) return error.EmptyRun;
    if (options.cell_width == 0 or options.cell_height == 0) {
        return error.InvalidMetrics;
    }
    if (options.cell_width > 4096 or options.cell_height > 4096) {
        return error.InvalidMetrics;
    }

    const columns: u32 = if (width == width_wide and !options.clip_to_cell)
        2
    else
        1;
    const bitmap_width = options.cell_width * columns;
    const bitmap_height = options.cell_height;

    const utf16 = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidUtf8,
        };
    };
    defer alloc.free(utf16);
    if (utf16.len == 0) return error.EmptyRun;

    const hdc = CreateCompatibleDC(null);
    if (hdc == null) return error.CreateDcFailed;
    defer _ = DeleteDC(hdc);

    const info = BITMAPINFO{
        .bmiHeader = .{
            .biSize = @sizeOf(BITMAPINFOHEADER),
            .biWidth = @intCast(bitmap_width),
            // Negative height requests a top-down DIB so row 0 is the top.
            .biHeight = -@as(i32, @intCast(bitmap_height)),
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = BI_RGB,
            .biSizeImage = 0,
            .biXPelsPerMeter = 0,
            .biYPelsPerMeter = 0,
            .biClrUsed = 0,
            .biClrImportant = 0,
        },
        .bmiColors = .{0},
    };

    var bits: ?[*]u8 = null;
    const bitmap = CreateDIBSection(hdc, &info, DIB_RGB_COLORS, &bits, null, 0);
    if (bitmap == null or bits == null) return error.CreateBitmapFailed;
    defer _ = DeleteObject(bitmap);
    const previous_bitmap = SelectObject(hdc, bitmap);
    defer _ = SelectObject(hdc, previous_bitmap);

    const byte_count: usize = @as(usize, bitmap_width) *
        @as(usize, bitmap_height) * 4;
    @memset(bits.?[0..byte_count], 0);

    var logfont = std.mem.zeroes(LOGFONTW);
    // A positive lfHeight is a cell height request (it includes internal
    // leading), which is what keeps a glyph inside one terminal row.
    logfont.lfHeight = @intCast(options.cell_height);
    logfont.lfWeight = FW_NORMAL;
    logfont.lfCharSet = DEFAULT_CHARSET;
    logfont.lfOutPrecision = OUT_TT_PRECIS;
    logfont.lfClipPrecision = CLIP_DEFAULT_PRECIS;
    // Grayscale AA, deliberately not ClearType: a single coverage channel is
    // only meaningful without LCD subpixel filtering.
    logfont.lfQuality = ANTIALIASED_QUALITY;
    logfont.lfPitchAndFamily = FIXED_PITCH | FF_MODERN;
    setFaceName(&logfont.lfFaceName, options.face);

    const font = CreateFontIndirectW(&logfont);
    if (font == null) return error.CreateFontFailed;
    defer _ = DeleteObject(font);
    const previous_font = SelectObject(hdc, font);
    defer _ = SelectObject(hdc, previous_font);

    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetBkColor(hdc, 0x000000);
    _ = SetTextColor(hdc, 0x00FFFFFF);
    _ = SetTextAlign(hdc, TA_LEFT | TA_TOP);

    const clip = RECT{
        .left = 0,
        .top = 0,
        .right = @intCast(bitmap_width),
        .bottom = @intCast(bitmap_height),
    };
    // No DT_NOCLIP-equivalent: ETO_CLIPPED plus the destination rect is the
    // whole point, so a width-1 target cannot paint into a neighbor column.
    if (ExtTextOutW(
        hdc,
        0,
        0,
        ETO_CLIPPED,
        &clip,
        utf16.ptr,
        @intCast(utf16.len),
        null,
    ) == 0) {
        return error.DrawFailed;
    }
    _ = GdiFlush();

    const pixels = try alloc.alloc(u8, @as(usize, bitmap_width) * bitmap_height);
    errdefer alloc.free(pixels);
    var index: usize = 0;
    while (index < pixels.len) : (index += 1) {
        const base = index * 4;
        const blue = bits.?[base];
        const green = bits.?[base + 1];
        const red = bits.?[base + 2];
        pixels[index] = @max(red, @max(green, blue));
    }

    return .{
        .width = bitmap_width,
        .height = bitmap_height,
        .pixels = pixels,
    };
}

fn setFaceName(destination: *[32]u16, face: []const u8) void {
    @memset(destination, 0);
    var written: usize = 0;
    var view = std.unicode.Utf8View.init(face) catch return;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint > 0xFFFF) continue;
        if (written + 1 >= destination.len) break;
        destination[written] = @intCast(codepoint);
        written += 1;
    }
}

/// Smallest power of two at or above `value`, clamped to at least 1.
///
/// OpenGL 1.1 (including the Microsoft software implementation the host can
/// fall back to) has no non-power-of-two texture support, so glyph coverage
/// must be uploaded into a padded power-of-two texture.
pub fn nextPowerOfTwo(value: u32) u32 {
    if (value <= 1) return 1;
    return @as(u32, 1) << @intCast(32 - @clz(value - 1));
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

fn testDescription(
    columns: u32,
    rows: u32,
    cells: []const Cell,
    glyphs: []const GlyphSpan,
    text: []const u8,
) Description {
    return .{
        .columns = columns,
        .rows = rows,
        .cells = cells,
        .glyphs = glyphs,
        .text = text,
    };
}

test "v2 validation accepts a narrow grapheme cluster" {
    const text = "e\u{0301}";
    const cells = [_]Cell{.{
        .codepoint = 'e',
        .foreground = 0,
        .background = 0,
        .flags = 0,
    }};
    const glyphs = [_]GlyphSpan{.{
        .offset = 0,
        .length = @intCast(text.len),
        .width = width_narrow,
        .reserved = 0,
    }};
    try validate(testDescription(1, 1, &cells, &glyphs, text));
}

test "v2 validation accepts a wide lead plus continuation" {
    const text = "\u{4E2D}";
    const cells = [_]Cell{
        .{ .codepoint = 0x4E2D, .foreground = 0, .background = 0, .flags = 0 },
        .{ .codepoint = 0, .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = @intCast(text.len), .width = width_wide, .reserved = 0 },
        .{ .offset = 0, .length = 0, .width = width_continuation, .reserved = 0 },
    };
    try validate(testDescription(2, 1, &cells, &glyphs, text));
}

test "v2 validation rejects a count mismatch" {
    const cells = [_]Cell{
        .{ .codepoint = 'a', .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 1, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.CountMismatch,
        validate(testDescription(2, 1, &cells, &glyphs, "a")),
    );
}

test "v2 validation rejects invalid UTF-8 in the blob" {
    const text = [_]u8{ 0xE4, 0xB8 };
    const cells = [_]Cell{
        .{ .codepoint = 0x4E2D, .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 2, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.InvalidUtf8,
        validate(testDescription(1, 1, &cells, &glyphs, &text)),
    );
}

test "v2 validation rejects a span past the end of the blob" {
    const cells = [_]Cell{
        .{ .codepoint = 'a', .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 1, .length = 4, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.SpanOutOfRange,
        validate(testDescription(1, 1, &cells, &glyphs, "a")),
    );
}

test "v2 validation rejects a span that splits a scalar" {
    const text = "\u{4E2D}";
    const cells = [_]Cell{
        .{ .codepoint = 0x4E2D, .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 1, .length = 2, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.SpanNotBoundary,
        validate(testDescription(1, 1, &cells, &glyphs, text)),
    );
}

test "v2 validation rejects a truncated span end" {
    const text = "\u{4E2D}";
    const cells = [_]Cell{
        .{ .codepoint = 0x4E2D, .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 2, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.SpanNotBoundary,
        validate(testDescription(1, 1, &cells, &glyphs, text)),
    );
}

test "v2 validation rejects a base codepoint mismatch" {
    const cells = [_]Cell{
        .{ .codepoint = 'b', .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 1, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.BaseCodepointMismatch,
        validate(testDescription(1, 1, &cells, &glyphs, "a")),
    );
}

test "v2 validation rejects an unknown width class" {
    const cells = [_]Cell{
        .{ .codepoint = 'a', .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 1, .width = 3, .reserved = 0 },
    };
    try testing.expectError(
        error.InvalidWidth,
        validate(testDescription(1, 1, &cells, &glyphs, "a")),
    );
}

test "v2 validation rejects a wide lead in the last column" {
    const text = "\u{4E2D}";
    const cells = [_]Cell{
        .{ .codepoint = 0x4E2D, .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = @intCast(text.len), .width = width_wide, .reserved = 0 },
    };
    try testing.expectError(
        error.WideRunTruncated,
        validate(testDescription(1, 1, &cells, &glyphs, text)),
    );
}

test "v2 validation rejects a wide run that wraps to the next row" {
    const text = "\u{4E2D}";
    const cells = [_]Cell{
        .{ .codepoint = 0x4E2D, .foreground = 0, .background = 0, .flags = 0 },
        .{ .codepoint = 0, .foreground = 0, .background = 0, .flags = 0 },
    };
    // One column, two rows: the lead is in the last column of row 0 and the
    // continuation is in row 1. That must not be accepted as a wide run.
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = @intCast(text.len), .width = width_wide, .reserved = 0 },
        .{ .offset = 0, .length = 0, .width = width_continuation, .reserved = 0 },
    };
    try testing.expectError(
        error.WideRunTruncated,
        validate(testDescription(1, 2, &cells, &glyphs, text)),
    );
}

test "v2 validation rejects an orphan continuation" {
    const cells = [_]Cell{
        .{ .codepoint = 0, .foreground = 0, .background = 0, .flags = 0 },
        .{ .codepoint = 'a', .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 0, .width = width_continuation, .reserved = 0 },
        .{ .offset = 0, .length = 1, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.OrphanContinuation,
        validate(testDescription(2, 1, &cells, &glyphs, "a")),
    );
}

test "v2 validation rejects a continuation carrying text" {
    const text = "\u{4E2D}";
    const cells = [_]Cell{
        .{ .codepoint = 0x4E2D, .foreground = 0, .background = 0, .flags = 0 },
        .{ .codepoint = 0, .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = @intCast(text.len), .width = width_wide, .reserved = 0 },
        .{ .offset = 0, .length = @intCast(text.len), .width = width_continuation, .reserved = 0 },
    };
    try testing.expectError(
        error.ContinuationHasText,
        validate(testDescription(2, 1, &cells, &glyphs, text)),
    );
}

test "v2 validation rejects ink cells with no span" {
    const cells = [_]Cell{
        .{ .codepoint = 'a', .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 0, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.SpanEmptyForInkCell,
        validate(testDescription(1, 1, &cells, &glyphs, "")),
    );
}

test "v2 validation rejects text on an empty cell" {
    const cells = [_]Cell{
        .{ .codepoint = 0, .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 1, .width = width_narrow, .reserved = 0 },
    };
    try testing.expectError(
        error.SpanPresentForEmptyCell,
        validate(testDescription(1, 1, &cells, &glyphs, "a")),
    );
}

test "v2 validation accepts blank cells with empty spans" {
    const cells = [_]Cell{
        .{ .codepoint = 0, .foreground = 0, .background = 0x112233, .flags = 0 },
        .{ .codepoint = ' ', .foreground = 0, .background = 0, .flags = 0 },
    };
    const glyphs = [_]GlyphSpan{
        .{ .offset = 0, .length = 0, .width = width_narrow, .reserved = 0 },
        .{ .offset = 0, .length = 0, .width = width_narrow, .reserved = 0 },
    };
    try validate(testDescription(2, 1, &cells, &glyphs, ""));
}

test "v2 validation accepts an empty grid" {
    try validate(testDescription(0, 0, &.{}, &.{}, ""));
}

test "v2 validation rejects an oversized grid" {
    try testing.expectError(
        error.DimensionTooLarge,
        validate(testDescription(max_dimension + 1, 1, &.{}, &.{}, "")),
    );
}

test "glyph cache keys separate combining sequences and widths" {
    const options = RasterOptions{ .cell_width = 12, .cell_height = 24 };
    const base = cacheKey("e", width_narrow, options);
    const combined = cacheKey("e\u{0301}", width_narrow, options);
    try testing.expect(!base.eql(combined));

    const wide = cacheKey("e", width_wide, options);
    try testing.expect(!base.eql(wide));

    var scaled = options;
    scaled.cell_height = 48;
    try testing.expect(!base.eql(cacheKey("e", width_narrow, scaled)));

    var dpi = options;
    dpi.dpi = 192;
    try testing.expect(!base.eql(cacheKey("e", width_narrow, dpi)));

    var face = options;
    face.face = "Cascadia Mono";
    try testing.expect(!base.eql(cacheKey("e", width_narrow, face)));

    try testing.expect(base.eql(cacheKey("e", width_narrow, options)));
}

test "power-of-two padding covers GL 1.1 texture limits" {
    try testing.expectEqual(@as(u32, 1), nextPowerOfTwo(0));
    try testing.expectEqual(@as(u32, 1), nextPowerOfTwo(1));
    try testing.expectEqual(@as(u32, 16), nextPowerOfTwo(12));
    try testing.expectEqual(@as(u32, 32), nextPowerOfTwo(24));
    try testing.expectEqual(@as(u32, 32), nextPowerOfTwo(32));
}

test "GDI raster distinguishes a combining sequence from its base" {
    const alloc = testing.allocator;
    const options = RasterOptions{ .cell_width = 12, .cell_height = 24 };

    var base = try rasterize(alloc, "e", width_narrow, options);
    defer base.deinit(alloc);
    var combined = try rasterize(alloc, "e\u{0301}", width_narrow, options);
    defer combined.deinit(alloc);

    try testing.expectEqual(base.width, combined.width);
    try testing.expectEqual(base.height, combined.height);
    try testing.expect(base.inkPixels() > 0);

    var changed: u64 = 0;
    for (base.pixels, combined.pixels) |a, b| {
        if (a != b) changed += 1;
    }
    std.debug.print(
        "\n[raster] e vs e+U+0301: changed_pixels={d} base_ink={d} combined_ink={d}\n",
        .{ changed, base.inkPixels(), combined.inkPixels() },
    );
    try testing.expect(changed > 0);
}

test "GDI raster keeps a clipped narrow target free of second-cell ink" {
    const alloc = testing.allocator;
    const options = RasterOptions{ .cell_width = 12, .cell_height = 24 };

    var narrow = try rasterize(alloc, "\u{4E2D}", width_wide, options);
    defer narrow.deinit(alloc);
    try testing.expectEqual(@as(u32, 12), narrow.width);
    // The clipped target is one column wide, so there is no second cell to
    // hold ink. This is a clipping property, not a width property.
    try testing.expectEqual(@as(u64, 0), narrow.bandInk(12, 12));

    var wide_options = options;
    wide_options.clip_to_cell = false;
    var wide = try rasterize(alloc, "\u{4E2D}", width_wide, wide_options);
    defer wide.deinit(alloc);
    try testing.expectEqual(@as(u32, 24), wide.width);

    const second_cell_ink = wide.bandInk(12, 12);
    std.debug.print(
        "\n[raster] U+4E2D width2 second-cell ink={d}, width1 clipped second-cell ink={d}\n",
        .{ second_cell_ink, narrow.bandInk(12, 12) },
    );
    try testing.expect(second_cell_ink > 0);
}

test "GDI raster separates distinct Han glyphs" {
    const alloc = testing.allocator;
    var options = RasterOptions{ .cell_width = 12, .cell_height = 24 };
    options.clip_to_cell = false;

    var first = try rasterize(alloc, "\u{4E2D}", width_wide, options);
    defer first.deinit(alloc);
    var second = try rasterize(alloc, "\u{6587}", width_wide, options);
    defer second.deinit(alloc);

    var changed: u64 = 0;
    for (first.pixels, second.pixels) |a, b| {
        if (a != b) changed += 1;
    }
    std.debug.print(
        "\n[raster] U+4E2D vs U+6587: changed_pixels={d}\n",
        .{changed},
    );
    try testing.expect(changed > 0);
}

test "GDI raster rejects empty and malformed runs" {
    const alloc = testing.allocator;
    const options = RasterOptions{ .cell_width = 12, .cell_height = 24 };
    try testing.expectError(
        error.EmptyRun,
        rasterize(alloc, "", width_narrow, options),
    );
    try testing.expectError(
        error.InvalidMetrics,
        rasterize(alloc, "a", width_narrow, .{ .cell_width = 0, .cell_height = 24 }),
    );
}

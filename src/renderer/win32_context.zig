//! Small, ownership-explicit WGL context used by the embeddable Win32 host.
//!
//! The application runtime has a richer OpenGL loader and renderer.  This
//! boundary deliberately keeps the WGL device lifetime independent from the
//! application runtime so an embedding caller can own the message loop while
//! the renderer owns only the child window's HDC/HGLRC pair.

const std = @import("std");
const win32_types = @import("../apprt/win32_types.zig");
const glyph = @import("win32_glyph.zig");
const log = std.log.scoped(.win32_context);

const HWND = win32_types.HWND;
const HDC = win32_types.HDC;
const HGLRC = win32_types.HGLRC;
const BOOL = win32_types.BOOL;
const DWORD = win32_types.DWORD;
const BYTE = win32_types.BYTE;
const WORD = win32_types.WORD;

const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
const PFD_DOUBLEBUFFER: u32 = 0x00000001;
const PFD_TYPE_RGBA: BYTE = 0;
const PFD_MAIN_PLANE: BYTE = 0;
const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;
const GL_QUADS: u32 = 0x0007;
const GL_TEXTURE_2D: u32 = 0x0DE1;
const GL_BLEND: u32 = 0x0BE2;
const GL_SRC_ALPHA: u32 = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
const GL_UNPACK_ALIGNMENT: u32 = 0x0CF5;
const GL_LUMINANCE_ALPHA: i32 = 0x190A;
const GL_UNSIGNED_BYTE: u32 = 0x1401;
const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
const GL_TEXTURE_WRAP_S: u32 = 0x2802;
const GL_TEXTURE_WRAP_T: u32 = 0x2803;
const GL_NEAREST: i32 = 0x2600;
const GL_CLAMP_TO_EDGE: i32 = 0x812F;
const GL_CLAMP: i32 = 0x2900;
const GL_TEXTURE_ENV: u32 = 0x2300;
const GL_TEXTURE_ENV_MODE: u32 = 0x2200;
const GL_MODULATE: i32 = 0x2100;
const GL_MAX_TEXTURE_SIZE: u32 = 0x0D33;

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD,
    nVersion: WORD,
    dwFlags: u32,
    iPixelType: BYTE,
    cColorBits: BYTE,
    cRedBits: BYTE,
    cRedShift: BYTE,
    cGreenBits: BYTE,
    cGreenShift: BYTE,
    cBlueBits: BYTE,
    cBlueShift: BYTE,
    cAlphaBits: BYTE,
    cAlphaShift: BYTE,
    cAccumBits: BYTE,
    cAccumRedBits: BYTE,
    cAccumGreenBits: BYTE,
    cAccumBlueBits: BYTE,
    cAccumAlphaBits: BYTE,
    cDepthBits: BYTE,
    cStencilBits: BYTE,
    cAuxBuffers: BYTE,
    iLayerType: BYTE,
    bReserved: BYTE,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

extern "user32" fn GetDC(hwnd: HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(hwnd: HWND, hdc: HDC) callconv(.winapi) i32;
extern "gdi32" fn ChoosePixelFormat(
    hdc: HDC,
    descriptor: *const PIXELFORMATDESCRIPTOR,
) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(
    hdc: HDC,
    format: i32,
    descriptor: *const PIXELFORMATDESCRIPTOR,
) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetCurrentContext() callconv(.winapi) HGLRC;
extern "opengl32" fn wglGetCurrentDC() callconv(.winapi) HDC;
extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn glClearColor(
    red: f32,
    green: f32,
    blue: f32,
    alpha: f32,
) callconv(.winapi) void;
extern "opengl32" fn glClear(mask: u32) callconv(.winapi) void;
extern "opengl32" fn glViewport(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.winapi) void;
extern "opengl32" fn glBegin(mode: u32) callconv(.winapi) void;
extern "opengl32" fn glColor3f(red: f32, green: f32, blue: f32) callconv(.winapi) void;
extern "opengl32" fn glVertex2f(x: f32, y: f32) callconv(.winapi) void;
extern "opengl32" fn glEnd() callconv(.winapi) void;
// Texture entry points are deliberately limited to the OpenGL 1.1 set. The
// embeddable host links only `opengl32` and its pixel tests can run against
// the Microsoft software implementation, so shaders, VBOs, and non-power-of-
// two textures are all unavailable here.
extern "opengl32" fn glEnable(cap: u32) callconv(.winapi) void;
extern "opengl32" fn glDisable(cap: u32) callconv(.winapi) void;
extern "opengl32" fn glBlendFunc(source: u32, destination: u32) callconv(.winapi) void;
extern "opengl32" fn glGenTextures(count: i32, textures: [*]u32) callconv(.winapi) void;
extern "opengl32" fn glDeleteTextures(count: i32, textures: [*]const u32) callconv(.winapi) void;
extern "opengl32" fn glBindTexture(target: u32, texture: u32) callconv(.winapi) void;
extern "opengl32" fn glTexImage2D(
    target: u32,
    level: i32,
    internal_format: i32,
    width: i32,
    height: i32,
    border: i32,
    format: u32,
    kind: u32,
    pixels: ?*const anyopaque,
) callconv(.winapi) void;
extern "opengl32" fn glTexParameteri(
    target: u32,
    name: u32,
    value: i32,
) callconv(.winapi) void;
extern "opengl32" fn glTexEnvi(target: u32, name: u32, value: i32) callconv(.winapi) void;
extern "opengl32" fn glPixelStorei(name: u32, value: i32) callconv(.winapi) void;
extern "opengl32" fn glTexCoord2f(s: f32, t: f32) callconv(.winapi) void;
extern "opengl32" fn glGetIntegerv(name: u32, value: *i32) callconv(.winapi) void;
extern "opengl32" fn glGetError() callconv(.winapi) u32;

pub const Error = error{
    GetDCFailed,
    ChoosePixelFormatFailed,
    SetPixelFormatFailed,
    CreateContextFailed,
    MakeCurrentFailed,
    RestoreCurrentFailed,
    SwapBuffersFailed,
    WrongThread,
    Destroying,
    GlyphDimensionsUnsupported,
    GlyphRasterFailed,
    GlyphUploadFailed,
    GlErrorBoundaryFailed,
};

const max_prior_gl_error_queries = 16;

fn consumePriorGlErrors(
    comptime query_error: fn () callconv(.winapi) u32,
    comptime report_error: fn (u32) void,
) Error!void {
    for (0..max_prior_gl_error_queries) |_| {
        const gl_error = query_error();
        if (gl_error == 0) return;
        report_error(gl_error);
    }
    return error.GlErrorBoundaryFailed;
}

fn reportCallerGlError(gl_error: u32) void {
    log.warn("consumed pre-existing caller GL error before provider render gl_error=0x{x}", .{gl_error});
}

fn checkGlyphUploadError(gl_error: u32) Error!void {
    if (gl_error != 0) return error.GlyphUploadFailed;
}

pub const Theme = enum(i32) {
    system = 0,
    light = 1,
    dark = 2,
};

pub const TerminalCell = glyph.Cell;
pub const TerminalGlyph = glyph.GlyphSpan;

pub const terminal_cell_foreground_set: u32 = 1 << 0;
pub const terminal_cell_background_set: u32 = 1 << 1;
pub const terminal_cell_foreground_default: u32 = 1 << 2;
pub const terminal_cell_background_default: u32 = 1 << 3;

pub const RenderState = struct {
    theme: Theme = .system,
    font_scale: f32 = 1.0,
    width: u32 = 1,
    height: u32 = 1,
    terminal_columns: u32 = 0,
    terminal_rows: u32 = 0,
    terminal_cells: []const TerminalCell = &.{},
    /// v2 render state. When `terminal_glyphs` is populated it is the same
    /// length as `terminal_cells` and describes each cell's grapheme run
    /// inside `terminal_text`. Empty means the caller supplied a v1
    /// snapshot, which still renders through the legacy path.
    terminal_glyphs: []const TerminalGlyph = &.{},
    terminal_text: []const u8 = &.{},

    fn hasGlyphs(self: RenderState) bool {
        return self.terminal_glyphs.len != 0 and
            self.terminal_glyphs.len == self.terminal_cells.len;
    }
};

const CurrentBinding = struct {
    hdc: HDC,
    hglrc: HGLRC,

    fn matches(self: CurrentBinding, context: *const Context) bool {
        return self.hdc == context.hdc and self.hglrc == context.hglrc;
    }

    fn isBound(self: CurrentBinding) bool {
        return self.hdc != null and self.hglrc != null;
    }
};

/// GPU-side cache of rasterized graphemes.
///
/// Entries are keyed by the full grapheme bytes plus face, pixel metrics,
/// DPI, and width class, so "e" and "e" + U+0301 never share a texture and a
/// metrics change cannot resurrect a stale raster. Textures live in the
/// owning WGL context; deleting the context reclaims anything still cached.
const GlyphCache = struct {
    const capacity = 256;

    const Entry = struct {
        key: glyph.CacheKey,
        texture: u32,
        texture_width: u32,
        texture_height: u32,
        glyph_width: u32,
        glyph_height: u32,
        used: u64,
    };

    entries: [capacity]Entry = undefined,
    /// Staging buffer for the padded power-of-two upload. It lives with the
    /// cache (which the host heap-allocates) rather than on the render
    /// thread's stack.
    staging: [max_glyph_texels * 2]u8 = undefined,
    count: usize = 0,
    clock: u64 = 0,
    cell_width: u32 = 0,
    cell_height: u32 = 0,

    /// Drop every cached texture. Called when cell metrics change so a new
    /// raster size cannot be served from an old one.
    fn flush(self: *GlyphCache) void {
        for (self.entries[0..self.count]) |entry| {
            const texture = [_]u32{entry.texture};
            glDeleteTextures(1, &texture);
        }
        self.count = 0;
    }

    /// Forget every entry without issuing GL calls. Used on teardown, where
    /// the context may no longer be current and destroying it reclaims the
    /// textures anyway.
    fn forget(self: *GlyphCache) void {
        self.count = 0;
    }

    fn syncMetrics(self: *GlyphCache, cell_width: u32, cell_height: u32) void {
        if (self.cell_width == cell_width and self.cell_height == cell_height) {
            return;
        }
        self.flush();
        self.cell_width = cell_width;
        self.cell_height = cell_height;
    }

    fn find(self: *GlyphCache, key: glyph.CacheKey) ?*Entry {
        for (self.entries[0..self.count]) |*entry| {
            if (entry.key.eql(key)) {
                self.clock += 1;
                entry.used = self.clock;
                return entry;
            }
        }
        return null;
    }

    fn reserve(self: *GlyphCache) *Entry {
        if (self.count < capacity) {
            const entry = &self.entries[self.count];
            self.count += 1;
            return entry;
        }
        var victim: *Entry = &self.entries[0];
        for (self.entries[0..self.count]) |*entry| {
            if (entry.used < victim.used) victim = entry;
        }
        const texture = [_]u32{victim.texture};
        glDeleteTextures(1, &texture);
        return victim;
    }

    fn upload(
        self: *GlyphCache,
        key: glyph.CacheKey,
        coverage: glyph.Coverage,
        texture_limit: u32,
    ) Error!*Entry {
        // OpenGL 1.1 has no non-power-of-two texture support, so the
        // coverage is padded and addressed with partial texture coordinates.
        const layout = glyph.textureLayout(coverage.width, coverage.height, texture_limit, max_glyph_texels) catch |err| {
            log.err("glyph upload dimensions rejected raster={d}x{d} texture_limit={d} texel_limit={d}: {s}", .{
                coverage.width, coverage.height, texture_limit, max_glyph_texels, @errorName(err),
            });
            return error.GlyphDimensionsUnsupported;
        };
        const texture_width = layout.width;
        const texture_height = layout.height;
        var texels: []u8 = self.staging[0..layout.byte_count];
        @memset(texels, 0);
        var y: u32 = 0;
        while (y < coverage.height) : (y += 1) {
            var x: u32 = 0;
            while (x < coverage.width) : (x += 1) {
                const destination = (@as(usize, y) * texture_width + x) * 2;
                // Luminance is fixed at full so GL_MODULATE keeps the
                // caller's foreground color; alpha carries coverage.
                texels[destination] = 0xFF;
                texels[destination + 1] = coverage.pixels[y * coverage.width + x];
            }
        }

        var handle: [1]u32 = .{0};
        glGenTextures(1, &handle);
        if (handle[0] == 0) {
            const gl_error = glGetError();
            log.err("glyph texture creation failed gl_error=0x{x}", .{gl_error});
            return error.GlyphUploadFailed;
        }
        errdefer glDeleteTextures(1, &handle);
        glBindTexture(GL_TEXTURE_2D, handle[0]);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP);
        glTexImage2D(
            GL_TEXTURE_2D,
            0,
            GL_LUMINANCE_ALPHA,
            @intCast(texture_width),
            @intCast(texture_height),
            0,
            @intCast(GL_LUMINANCE_ALPHA),
            GL_UNSIGNED_BYTE,
            texels.ptr,
        );
        const gl_error = glGetError();
        checkGlyphUploadError(gl_error) catch |err| {
            log.err("glyph texture upload failed padded={d}x{d} gl_error=0x{x}", .{ texture_width, texture_height, gl_error });
            return err;
        };

        const entry = self.reserve();
        self.clock += 1;
        entry.* = .{
            .key = key,
            .texture = handle[0],
            .texture_width = texture_width,
            .texture_height = texture_height,
            .glyph_width = coverage.width,
            .glyph_height = coverage.height,
            .used = self.clock,
        };
        return entry;
    }
};

/// Upper bound on a single glyph texture, which bounds the cache staging
/// buffer used for the padded upload.
const max_glyph_texels: usize = 256 * 256;

/// A WGL device/context pair. `render` is scoped: it claims the render
/// thread, binds as needed, presents, and restores the prior binding before
/// returning. The explicit current/clear methods are available for callers
/// that need to issue their own OpenGL commands.
pub const Context = struct {
    hwnd: ?HWND,
    hdc: HDC,
    hglrc: HGLRC,
    render_thread_id: DWORD = 0,
    operation_mutex: std.Thread.Mutex = .{},
    operation_done: std.Thread.Condition = .{},
    active_operations: usize = 0,
    destroying: bool = false,
    persistent_current: bool = false,
    glyph_cache: GlyphCache = .{},

    const PersistentTransfer = struct {
        context: *Context,

        fn cancel(self: *PersistentTransfer) void {
            self.context.operation_mutex.unlock();
        }

        fn complete(self: *PersistentTransfer) void {
            self.context.persistent_current = false;
            std.debug.assert(self.context.active_operations > 0);
            self.context.active_operations -= 1;
            if (self.context.active_operations == 0) {
                self.context.operation_done.broadcast();
            }
            self.context.operation_mutex.unlock();
        }
    };

    pub fn init(hwnd: HWND) Error!Context {
        const hdc = GetDC(hwnd) orelse return error.GetDCFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        const descriptor = pixelFormatDescriptor();
        const format = ChoosePixelFormat(hdc, &descriptor);
        if (format == 0) return error.ChoosePixelFormatFailed;
        if (SetPixelFormat(hdc, format, &descriptor) == 0) {
            return error.SetPixelFormatFailed;
        }

        const hglrc = wglCreateContext(hdc) orelse return error.CreateContextFailed;
        return .{
            .hwnd = hwnd,
            .hdc = hdc,
            .hglrc = hglrc,
        };
    }

    pub fn deinit(self: *Context) void {
        self.operation_mutex.lock();
        if (self.persistent_current and
            GetCurrentThreadId() == self.render_thread_id)
        {
            if (wglGetCurrentContext() == self.hglrc and
                wglGetCurrentDC() == self.hdc)
            {
                _ = wglMakeCurrent(null, null);
            }
            self.persistent_current = false;
            std.debug.assert(self.active_operations > 0);
            self.active_operations -= 1;
            if (self.active_operations == 0) self.operation_done.broadcast();
            if (persistent_context == self) persistent_context = null;
        }

        self.destroying = true;
        while (self.active_operations != 0) {
            self.operation_done.wait(&self.operation_mutex);
        }
        self.operation_mutex.unlock();

        if (wglGetCurrentContext() == self.hglrc and
            wglGetCurrentDC() == self.hdc)
        {
            _ = wglMakeCurrent(null, null);
        }
        if (self.hglrc) |hglrc| {
            _ = wglDeleteContext(hglrc);
            self.hglrc = null;
        }
        // Deleting the context reclaims its textures, so the cache only has
        // to drop its bookkeeping here.
        self.glyph_cache.forget();
        if (self.hdc) |hdc| {
            if (self.hwnd) |hwnd| _ = ReleaseDC(hwnd, hdc);
            self.hdc = null;
        }
        self.hwnd = null;
    }

    pub fn claimRenderThread(self: *Context) Error!void {
        const thread_id = GetCurrentThreadId();
        self.operation_mutex.lock();
        defer self.operation_mutex.unlock();
        if (self.destroying) return error.Destroying;
        if (self.render_thread_id == 0) {
            self.render_thread_id = thread_id;
        } else if (self.render_thread_id != thread_id) {
            return error.WrongThread;
        }
    }

    pub fn makeCurrent(self: *Context) Error!void {
        try self.claimRenderThread();
        const current = currentBinding();

        var previous_transfer: ?PersistentTransfer = null;
        if (persistent_context) |previous| {
            if (previous != self) {
                previous_transfer = previous.beginPersistentTransfer();
            }
        }

        if (self.persistent_current) {
            if (!current.matches(self) and
                wglMakeCurrent(self.hdc, self.hglrc) == 0)
            {
                if (previous_transfer) |*transfer| transfer.cancel();
                return error.MakeCurrentFailed;
            }
            persistent_context = self;
            if (previous_transfer) |*transfer| transfer.complete();
            return;
        }
        self.beginOperation() catch |err| {
            if (previous_transfer) |*transfer| transfer.cancel();
            return err;
        };
        if (!current.matches(self)) {
            if (wglMakeCurrent(self.hdc, self.hglrc) == 0) {
                self.endOperation();
                if (previous_transfer) |*transfer| transfer.cancel();
                return error.MakeCurrentFailed;
            }
        }
        self.persistent_current = true;
        persistent_context = self;
        if (previous_transfer) |*transfer| transfer.complete();
    }

    pub fn clearCurrent(self: *Context) void {
        self.operation_mutex.lock();
        defer self.operation_mutex.unlock();
        const actual_current = currentBinding().matches(self);
        if (!self.persistent_current and !actual_current) return;
        if (actual_current) {
            _ = wglMakeCurrent(null, null);
        }
        if (self.persistent_current) {
            self.persistent_current = false;
            std.debug.assert(self.active_operations > 0);
            self.active_operations -= 1;
            if (self.active_operations == 0) self.operation_done.broadcast();
        }
        if (persistent_context == self) persistent_context = null;
    }

    pub fn ownsPersistentCurrent(self: *Context) bool {
        self.operation_mutex.lock();
        defer self.operation_mutex.unlock();
        return self.persistent_current and
            self.render_thread_id == GetCurrentThreadId() and
            currentBinding().matches(self);
    }

    pub fn present(self: *Context) Error!void {
        try self.claimRenderThread();
        self.beginOperation() catch |err| return err;
        defer self.endOperation();

        const previous = currentBinding();
        const rebound = !previous.matches(self);
        if (rebound) {
            if (wglMakeCurrent(self.hdc, self.hglrc) == 0) {
                return error.MakeCurrentFailed;
            }
        }
        var operation_error: ?Error = null;
        if (SwapBuffers(self.hdc) == 0) operation_error = error.SwapBuffersFailed;
        if (rebound) {
            restoreCurrent(previous) catch |err| {
                if (operation_error == null) operation_error = err;
            };
        }
        if (operation_error) |err| return err;
    }

    pub fn render(self: *Context, state: RenderState) Error!void {
        try self.claimRenderThread();
        self.beginOperation() catch |err| return err;
        defer self.endOperation();

        const previous = currentBinding();
        const rebound = !previous.matches(self);
        if (rebound and wglMakeCurrent(self.hdc, self.hglrc) == 0) {
            return error.MakeCurrentFailed;
        }

        var operation_error: ?Error = null;
        consumePriorGlErrors(glGetError, reportCallerGlError) catch |err| {
            log.err("caller GL error boundary did not clear within {d} queries", .{max_prior_gl_error_queries});
            operation_error = err;
        };
        const texture_limit = if (operation_error == null) preflightGlyphDimensions(state) catch |err| failed: {
            operation_error = err;
            break :failed 0;
        } else 0;
        if (operation_error == null) {
            const width: i32 = @intCast(@min(state.width, @as(u32, std.math.maxInt(i32))));
            const height: i32 = @intCast(@min(state.height, @as(u32, std.math.maxInt(i32))));
            glViewport(0, 0, width, height);
            const background = backgroundColor(state.theme);
            glClearColor(background[0], background[1], background[2], 1.0);
            glClear(GL_COLOR_BUFFER_BIT);
            renderTerminalCells(self, state, texture_limit) catch |err| {
                operation_error = err;
            };
            if (operation_error == null and SwapBuffers(self.hdc) == 0) {
                operation_error = error.SwapBuffersFailed;
            }
        }
        if (rebound) {
            restoreCurrent(previous) catch |err| {
                if (operation_error == null) operation_error = err;
            };
        }
        if (operation_error) |err| return err;
    }

    const Grid = struct { columns: u32, rows: u32 };

    fn terminalGrid(state: RenderState) ?Grid {
        if (state.terminal_columns == 0 or
            state.terminal_rows == 0 or
            state.terminal_cells.len == 0)
        {
            return null;
        }

        const columns = @min(
            state.terminal_columns,
            @as(u32, @intCast(state.terminal_cells.len)),
        );
        const rows = @min(
            state.terminal_rows,
            @divFloor(
                @as(u32, @intCast(state.terminal_cells.len)),
                columns,
            ),
        );
        if (columns == 0 or rows == 0) return null;
        return .{ .columns = columns, .rows = rows };
    }

    const InkRun = struct {
        cell: TerminalCell,
        span: TerminalGlyph,
        text: []const u8,
        cells_wide: u32,
    };

    fn inkRun(state: RenderState, index: usize, columns: u32) ?InkRun {
        const span = state.terminal_glyphs[index];
        if (span.width == glyph.width_continuation or span.length == 0) return null;
        const cell = state.terminal_cells[index];
        if (cell.codepoint == 0 or cell.codepoint == ' ') return null;
        const start: usize = span.offset;
        const end = std.math.add(usize, start, span.length) catch return null;
        if (end > state.terminal_text.len) return null;
        const cells_wide: u32 = if (span.width == glyph.width_wide) 2 else 1;
        if (index % columns + cells_wide > columns) return null;
        return .{ .cell = cell, .span = span, .text = state.terminal_text[start..end], .cells_wide = cells_wide };
    }

    /// Refusal happens before clear, cache flushing, raster allocation, or swap.
    fn preflightGlyphDimensions(state: RenderState) Error!u32 {
        if (!state.hasGlyphs()) return 0;
        const grid = terminalGrid(state) orelse return 0;
        const options = glyph.RasterOptions{
            .cell_width = state.width / grid.columns,
            .cell_height = state.height / grid.rows,
            .clip_to_cell = false,
        };
        // Zero-pixel cells still use the legacy path, as before.
        if (options.cell_width == 0 or options.cell_height == 0) return 0;
        var texture_limit: u32 = 0;
        var checked_narrow = false;
        var checked_wide = false;
        for (0..@as(usize, grid.columns) * grid.rows) |index| {
            const run = inkRun(state, index, grid.columns) orelse continue;
            const checked = if (run.cells_wide == 2) &checked_wide else &checked_narrow;
            if (checked.*) continue;
            const dimensions = glyph.rasterDimensions(run.span.width, options) catch |err| {
                log.err("unsupported glyph metrics cell={d}x{d} columns={d} raster_cell_limit={d}: {s}", .{
                    options.cell_width, options.cell_height, run.cells_wide, glyph.max_raster_cell_dimension, @errorName(err),
                });
                return error.GlyphDimensionsUnsupported;
            };
            if (texture_limit == 0) {
                var limit: i32 = 0;
                glGetIntegerv(GL_MAX_TEXTURE_SIZE, &limit);
                if (limit <= 0) {
                    log.err("invalid GL glyph texture limit: {d}", .{limit});
                    return error.GlyphDimensionsUnsupported;
                }
                texture_limit = @intCast(limit);
            }
            _ = glyph.textureLayout(dimensions.width, dimensions.height, texture_limit, max_glyph_texels) catch |err| {
                log.err("unsupported glyph dimensions cell={d}x{d} raster={d}x{d} texture_limit={d} texel_limit={d}: {s}", .{
                    options.cell_width, options.cell_height, dimensions.width, dimensions.height, texture_limit, max_glyph_texels, @errorName(err),
                });
                return error.GlyphDimensionsUnsupported;
            };
            checked.* = true;
        }
        return texture_limit;
    }

    fn renderTerminalCells(self: *Context, state: RenderState, texture_limit: u32) Error!void {
        const grid = terminalGrid(state) orelse return;
        const columns = grid.columns;
        const rows = grid.rows;

        const cell_width = 2.0 / @as(f32, @floatFromInt(columns));
        const cell_height = 2.0 / @as(f32, @floatFromInt(rows));
        const default_background = backgroundColor(state.theme);

        // Background pass. Every cell paints its own background, including
        // the continuation cell a wide grapheme reserves.
        for (0..@intCast(rows)) |row| {
            for (0..@intCast(columns)) |column| {
                const cell = state.terminal_cells[row * @as(usize, @intCast(columns)) + column];
                const left = -1.0 + @as(f32, @floatFromInt(column)) * cell_width;
                const top = 1.0 - @as(f32, @floatFromInt(row)) * cell_height;
                const background = if (backgroundIsSet(cell))
                    rgb(cell.background)
                else
                    default_background;
                drawRect(left, top, cell_width, -cell_height, background);
            }
        }

        const pixel_cell_width = state.width / columns;
        const pixel_cell_height = state.height / rows;
        if (state.hasGlyphs() and
            pixel_cell_width > 0 and
            pixel_cell_height > 0)
        {
            try self.renderGlyphInk(
                state,
                columns,
                rows,
                cell_width,
                cell_height,
                pixel_cell_width,
                pixel_cell_height,
                texture_limit,
            );
            return;
        }

        renderLegacyInk(state, columns, rows, cell_width, cell_height);
    }

    /// v2 ink pass: real glyph coverage rasterized by GDI and uploaded as a
    /// luminance/alpha texture, tinted with the cell foreground. There is no
    /// pseudo-hash fallback here; a cell either draws its grapheme or draws
    /// nothing.
    fn renderGlyphInk(
        self: *Context,
        state: RenderState,
        columns: u32,
        rows: u32,
        cell_width: f32,
        cell_height: f32,
        pixel_cell_width: u32,
        pixel_cell_height: u32,
        texture_limit: u32,
    ) Error!void {
        self.glyph_cache.syncMetrics(pixel_cell_width, pixel_cell_height);

        glEnable(GL_TEXTURE_2D);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
        defer {
            glBindTexture(GL_TEXTURE_2D, 0);
            glDisable(GL_BLEND);
            glDisable(GL_TEXTURE_2D);
        }

        for (0..@intCast(rows)) |row| {
            for (0..@intCast(columns)) |column| {
                const index = row * @as(usize, @intCast(columns)) + column;
                const run = inkRun(state, index, columns) orelse continue;

                const options = glyph.RasterOptions{
                    .cell_width = pixel_cell_width,
                    .cell_height = pixel_cell_height,
                    .clip_to_cell = false,
                };
                const key = glyph.cacheKey(run.text, run.span.width, options);
                const entry = self.glyph_cache.find(key) orelse cached: {
                    var coverage = glyph.rasterize(
                        raster_allocator,
                        run.text,
                        run.span.width,
                        options,
                    ) catch |err| {
                        log.err("glyph raster failed cell={d}x{d}: {s}", .{ pixel_cell_width, pixel_cell_height, @errorName(err) });
                        return error.GlyphRasterFailed;
                    };
                    defer coverage.deinit(raster_allocator);
                    break :cached try self.glyph_cache.upload(key, coverage, texture_limit);
                };

                const left = -1.0 + @as(f32, @floatFromInt(column)) * cell_width;
                const top = 1.0 - @as(f32, @floatFromInt(row)) * cell_height;
                const quad_width = cell_width * @as(f32, @floatFromInt(run.cells_wide));
                const max_s = @as(f32, @floatFromInt(entry.glyph_width)) /
                    @as(f32, @floatFromInt(entry.texture_width));
                const max_t = @as(f32, @floatFromInt(entry.glyph_height)) /
                    @as(f32, @floatFromInt(entry.texture_height));
                const foreground = foregroundColor(run.cell);

                glBindTexture(GL_TEXTURE_2D, entry.texture);
                glBegin(GL_QUADS);
                glColor3f(foreground[0], foreground[1], foreground[2]);
                glTexCoord2f(0.0, 0.0);
                glVertex2f(left, top);
                glTexCoord2f(max_s, 0.0);
                glVertex2f(left + quad_width, top);
                glTexCoord2f(max_s, max_t);
                glVertex2f(left + quad_width, top - cell_height);
                glTexCoord2f(0.0, max_t);
                glVertex2f(left, top - cell_height);
                glEnd();
            }
        }
    }

    /// v1 ink pass, retained byte-for-byte in behavior for callers that only
    /// supply the 16-byte cell snapshot and therefore have no grapheme text.
    fn renderLegacyInk(
        state: RenderState,
        columns: u32,
        rows: u32,
        cell_width: f32,
        cell_height: f32,
    ) void {
        const scale = std.math.clamp(state.font_scale, 0.25, 4.0);
        const glyph_width = @min(cell_width * 0.72 * scale, cell_width * 0.86);
        const glyph_height = @min(cell_height * 0.72 * scale, cell_height * 0.86);

        for (0..@intCast(rows)) |row| {
            for (0..@intCast(columns)) |column| {
                const cell = state.terminal_cells[row * @as(usize, @intCast(columns)) + column];
                if (cell.codepoint == 0 or cell.codepoint == ' ') continue;
                const left = -1.0 + @as(f32, @floatFromInt(column)) * cell_width;
                const top = 1.0 - @as(f32, @floatFromInt(row)) * cell_height;

                const foreground = foregroundColor(cell);
                const seed = cell.codepoint *% 0x9E3779B1;
                const glyph_left = left + (cell_width - glyph_width) * 0.5;
                const glyph_top = top - (cell_height - glyph_height) * 0.5;
                const pixel_width = glyph_width / 5.0;
                const pixel_height = glyph_height / 7.0;
                for (0..7) |glyph_y| {
                    for (0..5) |glyph_x| {
                        const bit = (glyph_y * 5 + glyph_x) % 32;
                        if ((seed & (@as(u32, 1) << @intCast(bit))) == 0) continue;
                        drawRect(
                            glyph_left + @as(f32, @floatFromInt(glyph_x)) * pixel_width,
                            glyph_top - @as(f32, @floatFromInt(glyph_y)) * pixel_height,
                            pixel_width * 0.9,
                            -pixel_height * 0.9,
                            foreground,
                        );
                    }
                }
            }
        }
    }

    fn backgroundIsSet(cell: TerminalCell) bool {
        const legacy_colors = cell.flags == 0;
        return (cell.flags & terminal_cell_background_set) != 0 or
            (legacy_colors and cell.background != 0);
    }

    fn foregroundColor(cell: TerminalCell) [3]f32 {
        const legacy_colors = cell.flags == 0;
        const foreground_set =
            (cell.flags & terminal_cell_foreground_set) != 0 or
            (legacy_colors and cell.foreground != 0);
        if (!foreground_set) return .{ 0.90, 0.90, 0.92 };
        return rgb(cell.foreground);
    }

    fn drawRect(
        left: f32,
        top: f32,
        width: f32,
        height: f32,
        color: [3]f32,
    ) void {
        glBegin(GL_QUADS);
        glColor3f(color[0], color[1], color[2]);
        glVertex2f(left, top);
        glVertex2f(left + width, top);
        glVertex2f(left + width, top + height);
        glVertex2f(left, top + height);
        glEnd();
    }

    fn rgb(value: u32) [3]f32 {
        return .{
            @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
        };
    }

    fn currentBinding() CurrentBinding {
        return .{
            .hdc = wglGetCurrentDC(),
            .hglrc = wglGetCurrentContext(),
        };
    }

    fn restoreCurrent(previous: CurrentBinding) Error!void {
        const restored = if (previous.isBound())
            wglMakeCurrent(previous.hdc, previous.hglrc)
        else
            wglMakeCurrent(null, null);
        if (restored == 0) return error.RestoreCurrentFailed;
    }

    fn beginOperation(self: *Context) Error!void {
        self.operation_mutex.lock();
        defer self.operation_mutex.unlock();
        if (self.destroying) return error.Destroying;
        self.active_operations += 1;
    }

    fn beginPersistentTransfer(self: *Context) ?PersistentTransfer {
        self.operation_mutex.lock();
        if (!self.persistent_current) {
            self.operation_mutex.unlock();
            return null;
        }
        return .{ .context = self };
    }

    fn endOperation(self: *Context) void {
        self.operation_mutex.lock();
        std.debug.assert(self.active_operations > 0);
        self.active_operations -= 1;
        if (self.active_operations == 0) self.operation_done.broadcast();
        self.operation_mutex.unlock();
    }

    fn pixelFormatDescriptor() PIXELFORMATDESCRIPTOR {
        return .{
            .nSize = @sizeOf(PIXELFORMATDESCRIPTOR),
            .nVersion = 1,
            .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            .iPixelType = PFD_TYPE_RGBA,
            .cColorBits = 32,
            .cRedBits = 0,
            .cRedShift = 0,
            .cGreenBits = 0,
            .cGreenShift = 0,
            .cBlueBits = 0,
            .cBlueShift = 0,
            .cAlphaBits = 8,
            .cAlphaShift = 0,
            .cAccumBits = 0,
            .cAccumRedBits = 0,
            .cAccumGreenBits = 0,
            .cAccumBlueBits = 0,
            .cAccumAlphaBits = 0,
            .cDepthBits = 24,
            .cStencilBits = 8,
            .cAuxBuffers = 0,
            .iLayerType = PFD_MAIN_PLANE,
            .bReserved = 0,
            .dwLayerMask = 0,
            .dwVisibleMask = 0,
            .dwDamageMask = 0,
        };
    }

    fn backgroundColor(theme: Theme) [3]f32 {
        return switch (theme) {
            .light => .{ 0.96, 0.96, 0.96 },
            .dark => .{ 0.06, 0.07, 0.09 },
            .system => .{ 0.12, 0.13, 0.15 },
        };
    }
};

// WGL current bindings are thread-local, so this tracks the last successful
// API-owned persistent binding that must be transferred before a switch.
threadlocal var persistent_context: ?*Context = null;

/// Transient allocator for glyph rasterization. Coverage buffers live only
/// between the GDI raster and the texture upload on a cache miss.
const raster_allocator = std.heap.page_allocator;

const GlErrorTestProbe = struct {
    var errors: []const u32 = &.{};
    var fallback: u32 = 0;
    var queries: usize = 0;
    var report_count: usize = 0;
    var reported: [max_prior_gl_error_queries]u32 = undefined;

    fn reset(values: []const u32, fallback_error: u32) void {
        errors = values;
        fallback = fallback_error;
        queries = 0;
        report_count = 0;
    }

    fn query() callconv(.winapi) u32 {
        const index = queries;
        queries += 1;
        return if (index < errors.len) errors[index] else fallback;
    }

    fn report(gl_error: u32) void {
        reported[report_count] = gl_error;
        report_count += 1;
    }
};

test "GL error boundary records caller flags without consuming a later provider error" {
    const errors = [_]u32{ 0x500, 0x501, 0, 0x505 };
    GlErrorTestProbe.reset(&errors, 0);
    try consumePriorGlErrors(GlErrorTestProbe.query, GlErrorTestProbe.report);
    try std.testing.expectEqual(@as(usize, 3), GlErrorTestProbe.queries);
    try std.testing.expectEqualSlices(u32, errors[0..2], GlErrorTestProbe.reported[0..GlErrorTestProbe.report_count]);
    const provider_error = GlErrorTestProbe.query();
    try std.testing.expectEqual(@as(u32, 0x505), provider_error);
    try std.testing.expectError(error.GlyphUploadFailed, checkGlyphUploadError(provider_error));
}

test "GL error boundary refuses a non-clearing source after bounded queries" {
    GlErrorTestProbe.reset(&.{}, 0x502);
    try std.testing.expectError(
        error.GlErrorBoundaryFailed,
        consumePriorGlErrors(GlErrorTestProbe.query, GlErrorTestProbe.report),
    );
    try std.testing.expectEqual(@as(usize, max_prior_gl_error_queries), GlErrorTestProbe.queries);
    try std.testing.expectEqual(@as(usize, max_prior_gl_error_queries), GlErrorTestProbe.report_count);
}

test "glyph-upload check still fails for provider GL errors" {
    try checkGlyphUploadError(0);
    try std.testing.expectError(error.GlyphUploadFailed, checkGlyphUploadError(0x500));
    try std.testing.expectError(error.GlyphUploadFailed, checkGlyphUploadError(0x505));
}

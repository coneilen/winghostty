//! Small, ownership-explicit WGL context used by the embeddable Win32 host.
//!
//! The application runtime has a richer OpenGL loader and renderer.  This
//! boundary deliberately keeps the WGL device lifetime independent from the
//! application runtime so an embedding caller can own the message loop while
//! the renderer owns only the child window's HDC/HGLRC pair.

const std = @import("std");
const win32_types = @import("../apprt/win32_types.zig");

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
};

pub const Theme = enum(i32) {
    system = 0,
    light = 1,
    dark = 2,
};

pub const TerminalCell = extern struct {
    codepoint: u32,
    foreground: u32,
    background: u32,
    flags: u32,
};

pub const RenderState = struct {
    theme: Theme = .system,
    font_scale: f32 = 1.0,
    width: u32 = 1,
    height: u32 = 1,
    terminal_columns: u32 = 0,
    terminal_rows: u32 = 0,
    terminal_cells: []const TerminalCell = &.{},
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

        const width: i32 = @intCast(@min(state.width, @as(u32, std.math.maxInt(i32))));
        const height: i32 = @intCast(@min(state.height, @as(u32, std.math.maxInt(i32))));
        glViewport(0, 0, width, height);
        const background = backgroundColor(state.theme);
        glClearColor(background[0], background[1], background[2], 1.0);
        glClear(GL_COLOR_BUFFER_BIT);

        renderTerminalCells(state);

        var operation_error: ?Error = null;
        if (SwapBuffers(self.hdc) == 0) operation_error = error.SwapBuffersFailed;
        if (rebound) {
            restoreCurrent(previous) catch |err| {
                if (operation_error == null) operation_error = err;
            };
        }
        if (operation_error) |err| return err;
    }

    fn renderTerminalCells(state: RenderState) void {
        if (state.terminal_columns == 0 or
            state.terminal_rows == 0 or
            state.terminal_cells.len == 0)
        {
            return;
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
        if (columns == 0 or rows == 0) return;

        const cell_width = 2.0 / @as(f32, @floatFromInt(columns));
        const cell_height = 2.0 / @as(f32, @floatFromInt(rows));
        const scale = std.math.clamp(state.font_scale, 0.25, 4.0);
        const glyph_width = @min(cell_width * 0.72 * scale, cell_width * 0.86);
        const glyph_height = @min(cell_height * 0.72 * scale, cell_height * 0.86);

        for (0..@intCast(rows)) |row| {
            for (0..@intCast(columns)) |column| {
                const cell = state.terminal_cells[row * @as(usize, @intCast(columns)) + column];
                const left = -1.0 + @as(f32, @floatFromInt(column)) * cell_width;
                const top = 1.0 - @as(f32, @floatFromInt(row)) * cell_height;

                if (cell.background != 0) {
                    drawRect(
                        left,
                        top,
                        cell_width,
                        -cell_height,
                        rgb(cell.background),
                    );
                }
                if (cell.codepoint == 0 or cell.codepoint == ' ') continue;

                const foreground = if (cell.foreground == 0)
                    .{ 0.90, 0.90, 0.92 }
                else
                    rgb(cell.foreground);
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

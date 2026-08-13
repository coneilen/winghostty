const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32_types = @import("apprt/win32_types.zig");

comptime {
    if (builtin.target.os.tag != .windows) {
        @compileError("win32_host is only available for Windows targets");
    }
}

const HWND = win32_types.HWND;
const HINSTANCE = win32_types.HINSTANCE;
const HMENU = win32_types.HMENU;
const HBRUSH = win32_types.HBRUSH;
const HCURSOR = win32_types.HCURSOR;
const HICON = win32_types.HICON;
const HDC = win32_types.HDC;
const LPCWSTR = win32_types.LPCWSTR;
const LPARAM = win32_types.LPARAM;
const WPARAM = win32_types.WPARAM;
const LRESULT = win32_types.LRESULT;
const LONG_PTR = win32_types.LONG_PTR;
const UINT = win32_types.UINT;
const DWORD = win32_types.DWORD;
const BOOL = win32_types.BOOL;
const ATOM = win32_types.ATOM;
const WNDCLASSEXW = win32_types.WNDCLASSEXW;
const CREATESTRUCTW = win32_types.CREATESTRUCTW;
const PAINTSTRUCT = win32_types.PAINTSTRUCT;
const RECT = win32_types.RECT;

const allocator: Allocator = std.heap.c_allocator;

const GWLP_USERDATA: i32 = -21;
const WM_NCCREATE: u32 = 0x0081;
const WM_NCDESTROY: u32 = 0x0082;
const WM_PAINT: u32 = 0x000F;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_SETFOCUS: u32 = 0x0007;
const WM_KILLFOCUS: u32 = 0x0008;

const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const SW_HIDE: i32 = 0;
const SW_SHOW: i32 = 5;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "WinghosttyEmbeddableSurface",
);
const empty_title = std.unicode.utf8ToUtf16LeStringLiteral("");

extern "user32" fn RegisterClassExW(
    class: *const WNDCLASSEXW,
) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name_: LPCWSTR,
    window_name: LPCWSTR,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: HMENU,
    instance: HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(
    hwnd: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hwnd: HWND, paint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hwnd: HWND, paint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowLongPtrW(
    hwnd: HWND,
    index: i32,
) callconv(.winapi) LONG_PTR;
extern "user32" fn InvalidateRect(
    hwnd: HWND,
    rect: ?*const RECT,
    erase: BOOL,
) callconv(.winapi) BOOL;
extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
extern "user32" fn SetWindowLongPtrW(
    hwnd: HWND,
    index: i32,
    value: LONG_PTR,
) callconv(.winapi) LONG_PTR;
extern "user32" fn SetWindowPos(
    hwnd: HWND,
    insert_after: ?*anyopaque,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    flags: UINT,
) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hwnd: HWND, command: i32) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetModuleHandleW(module: ?LPCWSTR) callconv(.winapi) HINSTANCE;

pub const Result = i32;
pub const Theme = i32;

const result_ok: Result = 0;
const result_invalid_argument: Result = 1;
const result_wrong_thread: Result = 2;
const result_out_of_memory: Result = 3;
const result_shutting_down: Result = 4;
const result_win32_error: Result = 5;
const result_surface_invalidated: Result = 6;

const theme_system: Theme = 0;

pub const Rect = extern struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Host = opaque {};
pub const Surface = opaque {};

pub const ExitCallback = *const fn (?*anyopaque, *Surface, i32) callconv(.c) void;
pub const TitleCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const CwdCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const BellCallback = *const fn (?*anyopaque, *Surface) callconv(.c) void;
pub const NotificationCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const RedrawCallback = *const fn (?*anyopaque, *Surface) callconv(.c) void;
pub const FocusCallback = *const fn (?*anyopaque, *Surface, u8) callconv(.c) void;
pub const FatalErrorCallback = *const fn (?*anyopaque, *Surface, Result, [*:0]const u8) callconv(.c) void;

pub const Callbacks = extern struct {
    on_exit: ?ExitCallback,
    on_title: ?TitleCallback,
    on_cwd: ?CwdCallback,
    on_bell: ?BellCallback,
    on_notification: ?NotificationCallback,
    on_redraw: ?RedrawCallback,
    on_focus: ?FocusCallback,
    on_fatal_error: ?FatalErrorCallback,
};

pub const SurfaceOptions = extern struct {
    command: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    environment: ?[*:0]const u8,
    bounds: Rect,
    visible: u8,
    focus: u8,
    theme: Theme,
    font_scale: f32,
    callbacks: Callbacks,
    user_data: ?*anyopaque,
};

const OwnedOptions = struct {
    command: ?[:0]u8 = null,
    cwd: ?[:0]u8 = null,
    environment: ?[:0]u8 = null,
    bounds: Rect,
    visible: u8,
    focus: u8,
    theme: Theme,
    font_scale: f32,
    callbacks: Callbacks,
    user_data: ?*anyopaque,

    fn init(options: *const SurfaceOptions) !OwnedOptions {
        var result = OwnedOptions{
            .bounds = options.bounds,
            .visible = if (options.visible == 0) 0 else 1,
            .focus = if (options.focus == 0) 0 else 1,
            .theme = options.theme,
            .font_scale = options.font_scale,
            .callbacks = options.callbacks,
            .user_data = options.user_data,
        };
        errdefer result.deinit();
        result.command = try duplicate(options.command);
        result.cwd = try duplicate(options.cwd);
        result.environment = try duplicate(options.environment);
        return result;
    }

    fn deinit(self: *OwnedOptions) void {
        if (self.command) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.environment) |value| allocator.free(value);
        self.command = null;
        self.cwd = null;
        self.environment = null;
    }
};

const SurfaceState = struct {
    host: *HostState,
    parent: HWND,
    hwnd: ?HWND = null,
    options: OwnedOptions,
    invalidated: bool = false,
    creation_in_progress: bool = false,
    destroying: bool = false,
};

const HostState = struct {
    thread_id: DWORD,
    surfaces: std.ArrayListUnmanaged(*SurfaceState) = .empty,
    shutting_down: bool = false,
    deinitialize_requested: bool = false,
    creation_depth: usize = 0,
};

fn duplicate(value: ?[*:0]const u8) !?[:0]u8 {
    const source = value orelse return null;
    return try allocator.dupeZ(u8, std.mem.span(source));
}

fn hostHandle(host: *HostState) *Host {
    return @ptrCast(host);
}

fn surfaceHandle(surface: *SurfaceState) *Surface {
    return @ptrCast(surface);
}

fn hostState(host: ?*Host) ?*HostState {
    const handle = host orelse return null;
    return @ptrCast(@alignCast(handle));
}

fn surfaceState(surface: ?*Surface) ?*SurfaceState {
    const handle = surface orelse return null;
    return @ptrCast(@alignCast(handle));
}

fn checkHost(host: *HostState) Result {
    if (host.shutting_down) return result_shutting_down;
    if (GetCurrentThreadId() != host.thread_id) return result_wrong_thread;
    return result_ok;
}

fn checkSurface(surface: *SurfaceState) Result {
    const result = checkHost(surface.host);
    if (result != result_ok) return result;
    if (surface.invalidated) return result_surface_invalidated;
    return result_ok;
}

fn registerSurfaceClass() void {
    const class: WNDCLASSEXW = .{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = surfaceWindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    _ = RegisterClassExW(&class);
}

fn getSurface(hwnd: HWND) ?*SurfaceState {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn setUserData(hwnd: HWND, surface: ?*SurfaceState) void {
    const value: LONG_PTR = if (surface) |ptr|
        @intCast(@intFromPtr(ptr))
    else
        0;
    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, value);
}

fn notifyFocus(surface: *SurfaceState, focused: bool) void {
    if (surface.destroying) return;
    if (surface.options.callbacks.on_focus) |callback| {
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            if (focused) 1 else 0,
        );
    }
}

fn notifyRedraw(surface: *SurfaceState) void {
    if (surface.destroying) return;
    if (surface.options.callbacks.on_redraw) |callback| {
        callback(surface.options.user_data, surfaceHandle(surface));
    }
}

fn surfaceWindowProc(
    hwnd: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT {
    if (message == WM_NCCREATE) {
        const create: *const CREATESTRUCTW =
            @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (create.lpCreateParams) |ptr| {
            setUserData(hwnd, @ptrCast(@alignCast(ptr)));
        }
    }

    const surface = getSurface(hwnd);
    switch (message) {
        WM_SETFOCUS => {
            if (surface) |value| notifyFocus(value, true);
            return 0;
        },
        WM_KILLFOCUS => {
            if (surface) |value| notifyFocus(value, false);
            return 0;
        },
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            var paint: PAINTSTRUCT = undefined;
            _ = BeginPaint(hwnd, &paint);
            defer _ = EndPaint(hwnd, &paint);
            if (surface) |value| notifyRedraw(value);
            return 0;
        },
        WM_NCDESTROY => {
            setUserData(hwnd, null);
            if (surface) |value| {
                value.hwnd = null;
                if (!value.destroying) value.invalidated = true;
            }
            return DefWindowProcW(hwnd, message, wparam, lparam);
        },
        else => return DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn removeSurface(host: *HostState, surface: *SurfaceState) void {
    var index: usize = 0;
    while (index < host.surfaces.items.len) : (index += 1) {
        if (host.surfaces.items[index] == surface) {
            _ = host.surfaces.swapRemove(index);
            return;
        }
    }
}

fn destroySurfaceNow(surface: *SurfaceState) void {
    surface.destroying = true;
    removeSurface(surface.host, surface);
    if (surface.hwnd) |hwnd| {
        setUserData(hwnd, null);
        _ = DestroyWindow(hwnd);
        surface.hwnd = null;
    }
    surface.options.deinit();
    allocator.destroy(surface);
}

fn requestSurfaceDestroy(surface: *SurfaceState) void {
    surface.destroying = true;
    if (!surface.creation_in_progress) destroySurfaceNow(surface);
}

fn cleanupUnregisteredSurface(
    surface: *SurfaceState,
    hwnd: ?HWND,
) void {
    surface.destroying = true;
    if (hwnd) |value| {
        setUserData(value, null);
        _ = DestroyWindow(value);
        surface.hwnd = null;
    }
    surface.options.deinit();
    allocator.destroy(surface);
}

fn finishUnregisteredSurfaceCreation(
    state: *HostState,
    surface: *SurfaceState,
    hwnd: ?HWND,
    result: Result,
) Result {
    surface.creation_in_progress = false;
    cleanupUnregisteredSurface(surface, hwnd);
    state.creation_depth -= 1;
    const deinitialize_requested = state.deinitialize_requested;
    if (deinitialize_requested and state.creation_depth == 0) {
        deinitializeHost(state);
    }
    return if (deinitialize_requested) result_shutting_down else result;
}

fn deinitializeHost(state: *HostState) void {
    state.shutting_down = true;
    while (state.surfaces.items.len > 0) {
        const surface = state.surfaces.items[state.surfaces.items.len - 1];
        destroySurfaceNow(surface);
    }
    state.surfaces.deinit(allocator);
    allocator.destroy(state);
}

pub export fn winghostty_surface_options_init(options: *SurfaceOptions) void {
    options.* = .{
        .command = null,
        .cwd = null,
        .environment = null,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .visible = 1,
        .focus = 0,
        .theme = theme_system,
        .font_scale = 1.0,
        .callbacks = .{
            .on_exit = null,
            .on_title = null,
            .on_cwd = null,
            .on_bell = null,
            .on_notification = null,
            .on_redraw = null,
            .on_focus = null,
            .on_fatal_error = null,
        },
        .user_data = null,
    };
}

pub export fn winghostty_host_initialize(out_host: ?*?*Host) Result {
    const output = out_host orelse return result_invalid_argument;
    output.* = null;

    const host = allocator.create(HostState) catch return result_out_of_memory;
    host.* = .{ .thread_id = GetCurrentThreadId() };
    registerSurfaceClass();
    output.* = hostHandle(host);
    return result_ok;
}

pub export fn winghostty_host_deinitialize(host: ?*Host) Result {
    const state = hostState(host) orelse return result_invalid_argument;
    const result = checkHost(state);
    if (result != result_ok) return result;

    state.shutting_down = true;
    if (state.creation_depth != 0) {
        state.deinitialize_requested = true;
        return result_ok;
    }
    deinitializeHost(state);
    return result_ok;
}

pub export fn winghostty_host_create_surface(
    host: ?*Host,
    parent: ?HWND,
    options: ?*const SurfaceOptions,
    out_surface: ?*?*Surface,
) Result {
    const output = out_surface orelse return result_invalid_argument;
    output.* = null;
    const state = hostState(host) orelse return result_invalid_argument;
    const parent_hwnd = parent orelse return result_invalid_argument;
    const source = options orelse return result_invalid_argument;
    const thread_result = checkHost(state);
    if (thread_result != result_ok) return thread_result;
    if (source.font_scale <= 0 or !std.math.isFinite(source.font_scale)) {
        return result_invalid_argument;
    }
    if (source.bounds.width > std.math.maxInt(i32) or
        source.bounds.height > std.math.maxInt(i32))
    {
        return result_invalid_argument;
    }

    const owned = OwnedOptions.init(source) catch return result_out_of_memory;
    const surface = allocator.create(SurfaceState) catch {
        var cleanup = owned;
        cleanup.deinit();
        return result_out_of_memory;
    };
    surface.* = .{
        .host = state,
        .parent = parent_hwnd,
        .options = owned,
    };
    state.creation_depth += 1;
    surface.creation_in_progress = true;
    const hwnd = CreateWindowExW(
        0,
        class_name,
        empty_title,
        WS_CHILD | if (source.visible != 0) WS_VISIBLE else 0,
        source.bounds.x,
        source.bounds.y,
        @intCast(source.bounds.width),
        @intCast(source.bounds.height),
        parent_hwnd,
        null,
        GetModuleHandleW(null),
        surface,
    ) orelse {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            null,
            result_win32_error,
        );
    };
    surface.hwnd = hwnd;

    if (state.shutting_down) {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_shutting_down,
        );
    }

    state.surfaces.append(allocator, surface) catch {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_out_of_memory,
        );
    };

    if (source.focus != 0) {
        _ = SetFocus(hwnd);
    }
    surface.creation_in_progress = false;
    state.creation_depth -= 1;

    if (surface.destroying or surface.invalidated or state.shutting_down) {
        const was_invalidated = surface.invalidated;
        const was_shutting_down = state.shutting_down;
        if (!surface.destroying) surface.destroying = true;
        destroySurfaceNow(surface);
        const deinitialize_requested = state.deinitialize_requested;
        if (deinitialize_requested and state.creation_depth == 0) {
            deinitializeHost(state);
        }
        return if (was_invalidated and !was_shutting_down)
            result_surface_invalidated
        else
            result_shutting_down;
    }

    output.* = surfaceHandle(surface);
    return result_ok;
}

pub export fn winghostty_surface_destroy(surface: ?*Surface) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkHost(state.host);
    if (result != result_ok) return result;
    if (state.destroying) return result_ok;
    requestSurfaceDestroy(state);
    return result_ok;
}

pub export fn winghostty_surface_set_bounds(
    surface: ?*Surface,
    bounds: ?*const Rect,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const next = bounds orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (next.width > std.math.maxInt(i32) or next.height > std.math.maxInt(i32)) {
        return result_invalid_argument;
    }
    state.options.bounds = next.*;
    const hwnd = state.hwnd orelse return result_shutting_down;
    if (SetWindowPos(
        hwnd,
        null,
        next.x,
        next.y,
        @intCast(next.width),
        @intCast(next.height),
        SWP_NOZORDER | SWP_NOACTIVATE,
    ) == 0) return result_win32_error;
    return result_ok;
}

pub export fn winghostty_surface_set_visible(
    surface: ?*Surface,
    visible: u8,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    state.options.visible = if (visible == 0) 0 else 1;
    const hwnd = state.hwnd orelse return result_shutting_down;
    _ = ShowWindow(hwnd, if (state.options.visible != 0) SW_SHOW else SW_HIDE);
    return result_ok;
}

pub export fn winghostty_surface_set_focus(
    surface: ?*Surface,
    focused: u8,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    state.options.focus = if (focused == 0) 0 else 1;
    const hwnd = state.hwnd orelse return result_shutting_down;
    if (focused != 0) {
        _ = SetFocus(hwnd);
    } else if (GetFocus()) |current| {
        if (current == hwnd) _ = SetFocus(null);
    }
    return result_ok;
}

pub export fn winghostty_surface_set_theme(
    surface: ?*Surface,
    theme: Theme,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    state.options.theme = theme;
    if (state.hwnd) |hwnd| _ = InvalidateRect(hwnd, null, 0);
    return result_ok;
}

pub export fn winghostty_surface_set_font_scale(
    surface: ?*Surface,
    font_scale: f32,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (font_scale <= 0 or !std.math.isFinite(font_scale)) {
        return result_invalid_argument;
    }
    state.options.font_scale = font_scale;
    if (state.hwnd) |hwnd| _ = InvalidateRect(hwnd, null, 0);
    return result_ok;
}

pub export fn winghostty_surface_notify_exit(
    surface: ?*Surface,
    status: i32,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.options.callbacks.on_exit) |callback| {
        callback(state.options.user_data, surfaceHandle(state), status);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_title(
    surface: ?*Surface,
    title: ?[*:0]const u8,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const value = title orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.options.callbacks.on_title) |callback| {
        callback(state.options.user_data, surfaceHandle(state), value);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_cwd(
    surface: ?*Surface,
    cwd: ?[*:0]const u8,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const value = cwd orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.options.callbacks.on_cwd) |callback| {
        callback(state.options.user_data, surfaceHandle(state), value);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_bell(surface: ?*Surface) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.options.callbacks.on_bell) |callback| {
        callback(state.options.user_data, surfaceHandle(state));
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_notification(
    surface: ?*Surface,
    notification: ?[*:0]const u8,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const value = notification orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.options.callbacks.on_notification) |callback| {
        callback(state.options.user_data, surfaceHandle(state), value);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_redraw(surface: ?*Surface) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    notifyRedraw(state);
    return result_ok;
}

pub export fn winghostty_surface_notify_focus(
    surface: ?*Surface,
    focused: u8,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    notifyFocus(state, focused != 0);
    return result_ok;
}

pub export fn winghostty_surface_notify_fatal_error(
    surface: ?*Surface,
    result_code: Result,
    message: ?[*:0]const u8,
) Result {
    const state = surfaceState(surface) orelse return result_invalid_argument;
    const value = message orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.options.callbacks.on_fatal_error) |callback| {
        callback(state.options.user_data, surfaceHandle(state), result_code, value);
    }
    return result_ok;
}

pub export fn winghostty_surface_get_hwnd(surface: ?*const Surface) ?HWND {
    const state = surfaceState(@constCast(surface)) orelse return null;
    if (checkSurface(state) != result_ok or state.destroying) return null;
    return state.hwnd;
}

pub export fn winghostty_host_drain(
    host: ?*Host,
    out_drained: ?*u32,
) Result {
    const state = hostState(host) orelse return result_invalid_argument;
    const result = checkHost(state);
    if (result != result_ok) return result;
    if (out_drained) |count| count.* = 0;
    return result_ok;
}

test "SurfaceOptions copies caller-owned strings" {
    var command = [_:0]u8{ 'c', 'm', 'd', '.', 'e', 'x', 'e' };
    var cwd = [_:0]u8{ 'C', ':', '\\' };
    var environment = [_:0]u8{ 'A', '=', 'B' };
    const options = SurfaceOptions{
        .command = &command,
        .cwd = &cwd,
        .environment = &environment,
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .visible = 0,
        .focus = 0,
        .theme = theme_system,
        .font_scale = 1,
        .callbacks = .{
            .on_exit = null,
            .on_title = null,
            .on_cwd = null,
            .on_bell = null,
            .on_notification = null,
            .on_redraw = null,
            .on_focus = null,
            .on_fatal_error = null,
        },
        .user_data = null,
    };
    var owned = try OwnedOptions.init(&options);
    defer owned.deinit();
    command[0] = 'X';
    try std.testing.expectEqualStrings("cmd.exe", owned.command.?);
    try std.testing.expectEqualStrings("C:\\", owned.cwd.?);
    try std.testing.expectEqualStrings("A=B", owned.environment.?);
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32_types = @import("apprt/win32_types.zig");
const host_metrics = @import("win32_host_metrics.zig");
const host_uia = @import("win32_host_uia.zig");
const win32_context = @import("renderer/win32_context.zig");
const win32_presentation = @import("renderer/win32_presentation.zig");
const paste_protection = @import("apprt/win32_paste_protection.zig");
const win32_clipboard_html = @import("apprt/win32_clipboard_html.zig");

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
const HGLRC = win32_types.HGLRC;
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
const POINT = win32_types.POINT;
const CellMetrics = host_metrics.BaseMetrics;
const ScaledMetrics = host_metrics.Metrics;

const allocator: Allocator = std.heap.c_allocator;

const GWLP_USERDATA: i32 = -21;
const WM_NCCREATE: u32 = 0x0081;
const WM_NCDESTROY: u32 = 0x0082;
const WM_PAINT: u32 = 0x000F;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_MOVE: u32 = 0x0003;
const WM_WINDOWPOSCHANGED: u32 = 0x0047;
const WM_SETFOCUS: u32 = 0x0007;
const WM_KILLFOCUS: u32 = 0x0008;
const WM_GETOBJECT: u32 = 0x003D;
const WM_DPICHANGED: u32 = 0x02E0;
const WM_KEYDOWN: u32 = 0x0100;
const WM_KEYUP: u32 = 0x0101;
const WM_CHAR: u32 = 0x0102;
const WM_DEADCHAR: u32 = 0x0103;
const WM_SYSKEYDOWN: u32 = 0x0104;
const WM_SYSKEYUP: u32 = 0x0105;
const WM_SYSCHAR: u32 = 0x0106;
const WM_SYSDEADCHAR: u32 = 0x0107;
const WM_UNICHAR: u32 = 0x0109;
const WM_IME_STARTCOMPOSITION: u32 = 0x010D;
const WM_IME_ENDCOMPOSITION: u32 = 0x010E;
const WM_IME_COMPOSITION: u32 = 0x010F;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_LBUTTONDBLCLK: u32 = 0x0203;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_RBUTTONDBLCLK: u32 = 0x0206;
const WM_MBUTTONDOWN: u32 = 0x0207;
const WM_MBUTTONUP: u32 = 0x0208;
const WM_MBUTTONDBLCLK: u32 = 0x0209;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_XBUTTONDOWN: u32 = 0x020B;
const WM_XBUTTONUP: u32 = 0x020C;
const WM_XBUTTONDBLCLK: u32 = 0x020D;
const WM_MOUSEHWHEEL: u32 = 0x020E;
const WM_MOUSELEAVE: u32 = 0x02A3;
const WM_INPUTLANGCHANGE: u32 = 0x0051;
const WM_CAPTURECHANGED: u32 = 0x0215;
const WM_UIA_SELECTION: u32 = 0x8000 + 0x41;

const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const CS_DBLCLKS: u32 = 0x0008;
const SW_HIDE: i32 = 0;
const SW_SHOW: i32 = 5;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;
const CF_TEXT: u32 = 1;
const CF_UNICODETEXT: u32 = 13;
const GMEM_MOVEABLE: u32 = 0x0002;
const GCS_COMPSTR: u32 = 0x0008;
const GCS_RESULTSTR: u32 = 0x0800;
const WHEEL_DELTA: i32 = 120;
const UNICODE_NOCHAR: WPARAM = 0xFFFF;
const TME_LEAVE: u32 = 0x00000002;
const TOUNICODE_NO_STATE_CHANGE: u32 = 0x00000004;
const VK_SHIFT: i32 = 0x10;
const VK_CONTROL: i32 = 0x11;
const VK_MENU: i32 = 0x12;
const MK_LBUTTON: u32 = 0x0001;
const MK_RBUTTON: u32 = 0x0002;
const MK_SHIFT: u32 = 0x0004;
const MK_CONTROL: u32 = 0x0008;
const MK_MBUTTON: u32 = 0x0010;
const MK_XBUTTON1: u32 = 0x0020;
const MK_XBUTTON2: u32 = 0x0040;
const max_input_text_bytes: u32 = 16 * 1024 * 1024;

const TrackMouseEventArgs = extern struct {
    cbSize: u32,
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32,
};

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
extern "user32" fn SendMessageW(
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
extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn ScreenToClient(hwnd: HWND, point: *POINT) callconv(.winapi) BOOL;
extern "user32" fn TrackMouseEvent(event: *TrackMouseEventArgs) callconv(.winapi) BOOL;
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
extern "user32" fn ClientToScreen(
    hwnd: HWND,
    point: *POINT,
) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hwnd: HWND, command: i32) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;
extern "user32" fn GetKeyState(virtual_key: i32) callconv(.winapi) i16;
extern "user32" fn GetKeyboardLayout(thread_id: DWORD) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetKeyboardState(state: *[256]u8) callconv(.winapi) BOOL;
extern "user32" fn MapVirtualKeyExW(
    code: u32,
    map_type: u32,
    keyboard_layout: ?*anyopaque,
) callconv(.winapi) u32;
extern "user32" fn ToUnicodeEx(
    virtual_key: u32,
    scan_code: u32,
    keyboard_state: *const [256]u8,
    chars: [*]u16,
    char_count: i32,
    flags: u32,
    keyboard_layout: ?*anyopaque,
) callconv(.winapi) i32;
extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetClipboardData(format: u32, data: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(memory: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalSize(memory: ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn lstrlenW(string: [*:0]const u16) callconv(.winapi) i32;
extern "imm32" fn ImmGetContext(hwnd: HWND) callconv(.winapi) ?*anyopaque;
extern "imm32" fn ImmReleaseContext(hwnd: HWND, context: ?*anyopaque) callconv(.winapi) BOOL;
extern "imm32" fn ImmGetCompositionStringW(
    context: ?*anyopaque,
    index: u32,
    data: ?*anyopaque,
    bytes: u32,
) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
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
const result_renderer_error: Result = 7;
const result_context_error: Result = 8;
const result_present_error: Result = 9;
const result_paste_requires_confirmation: Result = 10;
const result_invalid_utf8: Result = 11;
const result_clipboard_unavailable: Result = 12;

const theme_system: Theme = 0;

const key_release: u32 = 0;
const key_press: u32 = 1;
const key_repeat: u32 = 2;
const mouse_move: u32 = 0;
const mouse_button_down: u32 = 1;
const mouse_button_up: u32 = 2;
const mouse_wheel: u32 = 3;
const mouse_leave: u32 = 4;
const clipboard_text: u32 = 0;
const clipboard_html: u32 = 1;

pub const Rect = extern struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Host = opaque {};
pub const Surface = opaque {};

const HandleKind = enum {
    host,
    surface,
};

const HandleIdentity = struct {
    id: usize,
    generation: u64,
    kind: HandleKind,
};

const SelectionDispatch = struct {
    lock: std.Thread.Mutex = .{},
    refs: usize = 1,
    active: bool = true,
    hwnd: ?HWND,
    owner_thread_id: DWORD,

    fn create(hwnd: HWND) !*SelectionDispatch {
        const result = try allocator.create(SelectionDispatch);
        result.* = .{
            .hwnd = hwnd,
            .owner_thread_id = GetCurrentThreadId(),
        };
        return result;
    }

    fn acquire(self: *SelectionDispatch) ?*SelectionDispatch {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.active) return null;
        self.refs += 1;
        return self;
    }

    fn retain(self: *SelectionDispatch) void {
        self.lock.lock();
        self.refs += 1;
        self.lock.unlock();
    }

    fn release(self: *SelectionDispatch) void {
        self.lock.lock();
        self.refs -= 1;
        const destroy = self.refs == 0;
        self.lock.unlock();
        if (destroy) allocator.destroy(self);
    }

    fn deactivate(self: *SelectionDispatch) void {
        self.lock.lock();
        self.active = false;
        self.hwnd = null;
        self.refs -= 1;
        const destroy = self.refs == 0;
        self.lock.unlock();
        if (destroy) allocator.destroy(self);
    }

    fn isActive(self: *SelectionDispatch) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.active;
    }

    fn retainContext(ctx: *anyopaque) void {
        const self: *SelectionDispatch = @ptrCast(@alignCast(ctx));
        self.retain();
    }

    fn releaseContext(ctx: *anyopaque) void {
        const self: *SelectionDispatch = @ptrCast(@alignCast(ctx));
        self.release();
    }

    fn invoke(self: *SelectionDispatch, start: usize, end: usize) void {
        const retained = self.acquire() orelse return;
        defer retained.release();
        const hwnd = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.hwnd;
        } orelse return;
        var message = SelectionMessage{
            .dispatch = self,
            .start = start,
            .end = end,
        };
        _ = SendMessageW(
            hwnd,
            WM_UIA_SELECTION,
            0,
            @bitCast(@as(isize, @intCast(@intFromPtr(&message)))),
        );
    }
};

const SelectionMessage = struct {
    dispatch: *SelectionDispatch,
    start: usize,
    end: usize,
};

const SelectionDispatchTestGate = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allow: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

var selection_dispatch_test_gate: ?*SelectionDispatchTestGate = null;

fn gatedAccessibilitySelection(
    ctx: *anyopaque,
    start: usize,
    end: usize,
) void {
    const dispatch: *SelectionDispatch = @ptrCast(@alignCast(ctx));
    const gate = selection_dispatch_test_gate orelse {
        dispatch.invoke(start, end);
        return;
    };
    gate.entered.store(true, .release);
    while (!gate.allow.load(.acquire)) std.Thread.yield() catch {};
    dispatch.invoke(start, end);
}

pub const ExitCallback = *const fn (?*anyopaque, *Surface, i32) callconv(.c) void;
pub const TitleCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const CwdCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const BellCallback = *const fn (?*anyopaque, *Surface) callconv(.c) void;
pub const NotificationCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const RedrawCallback = *const fn (?*anyopaque, *Surface) callconv(.c) void;
pub const FocusCallback = *const fn (?*anyopaque, *Surface, u8) callconv(.c) void;
pub const FatalErrorCallback = *const fn (?*anyopaque, *Surface, Result, [*:0]const u8) callconv(.c) void;
pub const DpiChangedCallback = *const fn (?*anyopaque, *Surface, u32, f32) callconv(.c) void;
pub const MetricsChangedCallback = *const fn (?*anyopaque, *Surface, *const CellMetrics) callconv(.c) void;
pub const AccessibilitySelectionCallback = *const fn (?*anyopaque, *Surface, u64, u64) callconv(.c) void;

pub const LegacyCallbacks = extern struct {
    on_exit: ?ExitCallback,
    on_title: ?TitleCallback,
    on_cwd: ?CwdCallback,
    on_bell: ?BellCallback,
    on_notification: ?NotificationCallback,
    on_redraw: ?RedrawCallback,
    on_focus: ?FocusCallback,
    on_fatal_error: ?FatalErrorCallback,
};

pub const Callbacks = extern struct {
    on_exit: ?ExitCallback,
    on_title: ?TitleCallback,
    on_cwd: ?CwdCallback,
    on_bell: ?BellCallback,
    on_notification: ?NotificationCallback,
    on_redraw: ?RedrawCallback,
    on_focus: ?FocusCallback,
    on_fatal_error: ?FatalErrorCallback,
    on_dpi_changed: ?DpiChangedCallback,
    on_metrics_changed: ?MetricsChangedCallback,
    on_accessibility_selection: ?AccessibilitySelectionCallback,
};

pub const KeyEvent = extern struct {
    action: u32,
    virtual_key: u32,
    scan_code: u32,
    repeat_count: u32,
    flags: u32,
    modifiers: u32,
    keyboard_layout: usize,
    composing: u8,
    dead_key: u8,
    reserved: [6]u8,
    keyboard_layout_name: ?[*:0]const u8,
};

pub const MouseEvent = extern struct {
    kind: u32,
    button: u32,
    modifiers: u32,
    x: i32,
    y: i32,
    cell_x: i32,
    cell_y: i32,
    wheel_delta: i32,
    click_count: u32,
};

pub const SelectionEvent = extern struct {
    active: u8,
    dragging: u8,
    rectangular: u8,
    reserved: u8,
    anchor_x: i32,
    anchor_y: i32,
    current_x: i32,
    current_y: i32,
};

pub const OnKeyCallback = *const fn (?*anyopaque, *Surface, *const KeyEvent) callconv(.c) void;
pub const OnTextCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8, u32) callconv(.c) void;
pub const OnImeStartCallback = *const fn (?*anyopaque, *Surface) callconv(.c) void;
pub const OnImeUpdateCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8, u32, u8) callconv(.c) void;
pub const OnImeEndCallback = *const fn (?*anyopaque, *Surface) callconv(.c) void;
pub const OnMouseCallback = *const fn (?*anyopaque, *Surface, *const MouseEvent) callconv(.c) void;
pub const OnSelectionCallback = *const fn (?*anyopaque, *Surface, *const SelectionEvent) callconv(.c) void;
pub const OnLinkCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8, u8, u8) callconv(.c) void;
pub const OnPasteCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8, u32, u8) callconv(.c) void;
pub const OnClipboardReadCallback = *const fn (?*anyopaque, *Surface, u32, [*:0]const u8, u32) callconv(.c) void;
pub const OnClipboardWriteCallback = *const fn (?*anyopaque, *Surface, u32, [*:0]const u8, u32) callconv(.c) void;

pub const InputCallbacks = extern struct {
    on_key: ?OnKeyCallback,
    on_text: ?OnTextCallback,
    on_ime_start: ?OnImeStartCallback,
    on_ime_update: ?OnImeUpdateCallback,
    on_ime_end: ?OnImeEndCallback,
    on_mouse: ?OnMouseCallback,
    on_selection: ?OnSelectionCallback,
    on_link: ?OnLinkCallback,
    on_paste: ?OnPasteCallback,
    on_clipboard_read: ?OnClipboardReadCallback,
    on_clipboard_write: ?OnClipboardWriteCallback,
};

pub const InputOptions = extern struct {
    cell_width: u32,
    cell_height: u32,
    selection_enabled: u8,
    links_enabled: u8,
    paste_protection: u8,
    bracketed_paste: u8,
    reserved: [4]u8,
    keyboard_layout: ?[*:0]const u8,
};

pub const LegacySurfaceOptions = extern struct {
    command: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    environment: ?[*:0]const u8,
    bounds: Rect,
    visible: u8,
    focus: u8,
    theme: Theme,
    font_scale: f32,
    callbacks: LegacyCallbacks,
    user_data: ?*anyopaque,
};

pub const SurfaceOptions = extern struct {
    size: u32,
    version: u32,
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
    input_callbacks: InputCallbacks,
    input: InputOptions,
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
    input_callbacks: InputCallbacks,
    input: InputOptionsOwned,

    fn init(options: *const SurfaceOptions) !OwnedOptions {
        var result = OwnedOptions{
            .bounds = options.bounds,
            .visible = if (options.visible == 0) 0 else 1,
            .focus = if (options.focus == 0) 0 else 1,
            .theme = options.theme,
            .font_scale = options.font_scale,
            .callbacks = options.callbacks,
            .user_data = options.user_data,
            .input_callbacks = options.input_callbacks,
            .input = .{
                .cell_width = options.input.cell_width,
                .cell_height = options.input.cell_height,
                .selection_enabled = if (options.input.selection_enabled == 0) 0 else 1,
                .links_enabled = if (options.input.links_enabled == 0) 0 else 1,
                .paste_protection = if (options.input.paste_protection == 0) 0 else 1,
                .bracketed_paste = if (options.input.bracketed_paste == 0) 0 else 1,
                .keyboard_layout = null,
            },
        };
        errdefer result.deinit();
        result.command = try duplicate(options.command);
        result.cwd = try duplicate(options.cwd);
        result.environment = try duplicate(options.environment);
        result.input.keyboard_layout = try duplicate(options.input.keyboard_layout);
        return result;
    }

    fn deinit(self: *OwnedOptions) void {
        if (self.command) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.environment) |value| allocator.free(value);
        self.command = null;
        self.cwd = null;
        self.environment = null;
        self.input.deinit();
    }
};

const InputOptionsOwned = struct {
    cell_width: u32,
    cell_height: u32,
    selection_enabled: u8,
    links_enabled: u8,
    paste_protection: u8,
    bracketed_paste: u8,
    keyboard_layout: ?[:0]u8,

    fn deinit(self: *InputOptionsOwned) void {
        if (self.keyboard_layout) |value| allocator.free(value);
        self.keyboard_layout = null;
    }
};

const AdmissionState = struct {
    mutex: std.Thread.Mutex = .{},
    done: std.Thread.Condition = .{},
    accepting: bool = true,
    clearable: bool = true,
    admitted: usize = 0,
    clear_admitted: usize = 0,
};

const SurfaceState = struct {
    handle: HandleIdentity,
    host: *HostState,
    parent: HWND,
    hwnd: ?HWND = null,
    options: OwnedOptions,
    admission: AdmissionState = .{},
    options_mutex: std.Thread.Mutex = .{},
    renderer: ?*win32_context.Context = null,
    retired_renderer: ?*win32_context.Context = null,
    renderer_mutex: std.Thread.Mutex = .{},
    renderer_done: std.Thread.Condition = .{},
    active_renderer_operations: usize = 0,
    renderer_destroying: bool = false,
    last_error: std.atomic.Value(DWORD) = .init(0),
    present_count: std.atomic.Value(u64) = .init(0),
    invalidated: std.atomic.Value(bool) = .init(false),
    base_metrics: CellMetrics = .{},
    metrics: ScaledMetrics = host_metrics.calculate(.{}, 96, 1),
    dpi: u32 = host_metrics.default_dpi,
    screen_origin: POINT = .{ .x = 0, .y = 0 },
    uia: ?*host_uia.SurfaceProvider = null,
    selection_dispatch: ?*SelectionDispatch = null,
    creation_in_progress: bool = false,
    pin_count: usize = 0,
    destroying: std.atomic.Value(bool) = .init(false),
    retired: bool = false,
    retain_until_host_teardown: bool = false,
    retired_next: ?*SurfaceState = null,
    focused: bool = false,
    ime_composing: bool = false,
    dead_key_active: bool = false,
    pending_high_surrogate: ?u16 = null,
    selection_active: bool = false,
    selection_dragging: bool = false,
    selection_anchor_x: i32 = 0,
    selection_anchor_y: i32 = 0,
    selection_current_x: i32 = 0,
    selection_current_y: i32 = 0,
    selection_text: ?[:0]u8 = null,
    link_url: ?[:0]u8 = null,
    link_hovered: bool = false,
    last_click_tick: u32 = 0,
    click_count: u32 = 0,
    keyboard_layout: ?*anyopaque = null,
    wheel_remainder_x: i32 = 0,
    wheel_remainder_y: i32 = 0,
    active_dispatches: usize = 0,
    storage_retained: bool = false,
};

const HostState = struct {
    handle: HandleIdentity,
    thread_id: DWORD,
    surfaces: std.ArrayListUnmanaged(*SurfaceState) = .empty,
    admission: AdmissionState = .{},
    shutting_down: std.atomic.Value(bool) = .init(false),
    retired_surfaces: ?*SurfaceState = null,
    deinitialize_requested: bool = false,
    creation_depth: usize = 0,
    destroy_surface_depth: usize = 0,
    active_operations: usize = 0,
    render_thread_mutex: std.Thread.Mutex = .{},
    render_thread_id: DWORD = 0,
    active_dispatches: usize = 0,
};

var admission_registry_mutex: std.Thread.Mutex = .{};
var host_registry: std.AutoHashMapUnmanaged(usize, *HostState) = .empty;
var surface_registry: std.AutoHashMapUnmanaged(usize, *SurfaceState) = .empty;
var next_handle_id: std.atomic.Value(usize) = .init(1);
var next_handle_generation: std.atomic.Value(u64) = .init(1);

fn duplicate(value: ?[*:0]const u8) !?[:0]u8 {
    const source = value orelse return null;
    return try allocator.dupeZ(u8, std.mem.span(source));
}

fn duplicateSlice(value: []const u8) ![:0]u8 {
    return try allocator.dupeZ(u8, value);
}

fn hostHandle(host: *HostState) *Host {
    return @ptrFromInt(host.handle.id);
}

fn surfaceHandle(surface: *SurfaceState) *Surface {
    return @ptrFromInt(surface.handle.id);
}

fn nextHandleId() ?usize {
    var current = next_handle_id.load(.monotonic);
    while (current != 0) {
        const next = if (current == std.math.maxInt(usize))
            0
        else
            current + 1;
        if (next_handle_id.cmpxchgWeak(
            current,
            next,
            .monotonic,
            .monotonic,
        ) == null) {
            return current;
        }
        current = next_handle_id.load(.monotonic);
    }
    return null;
}

fn nextHandleGeneration() ?u64 {
    var current = next_handle_generation.load(.monotonic);
    while (current != 0) {
        const next = if (current == std.math.maxInt(u64))
            0
        else
            current + 1;
        if (next_handle_generation.cmpxchgWeak(
            current,
            next,
            .monotonic,
            .monotonic,
        ) == null) {
            return current;
        }
        current = next_handle_generation.load(.monotonic);
    }
    return null;
}

fn allocateHandleIdentity(kind: HandleKind) ?HandleIdentity {
    return .{
        .id = nextHandleId() orelse return null,
        .generation = nextHandleGeneration() orelse return null,
        .kind = kind,
    };
}

fn hostStateFromId(id: usize) ?*HostState {
    const state = host_registry.get(id) orelse return null;
    if (state.handle.id != id or
        state.handle.generation == 0 or
        state.handle.kind != .host)
    {
        return null;
    }
    return state;
}

fn surfaceStateFromId(id: usize) ?*SurfaceState {
    const state = surface_registry.get(id) orelse return null;
    if (state.handle.id != id or
        state.handle.generation == 0 or
        state.handle.kind != .surface)
    {
        return null;
    }
    return state;
}

fn hostState(handle: ?*Host) ?*HostState {
    const pointer = handle orelse return null;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    return hostStateFromId(@intFromPtr(pointer));
}

const HostAdmission = struct {
    state: *HostState,
    released: bool = false,
};

const SurfaceAdmission = struct {
    surface: *SurfaceState,
    host: ?*HostState = null,
    clear: bool = false,
    released: bool = false,
    defer_finalize: bool = false,
};

fn unavailableHostResult(handle: ?*Host) Result {
    const pointer = handle orelse return result_invalid_argument;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const state = hostStateFromId(@intFromPtr(pointer)) orelse
        return result_invalid_argument;
    state.admission.mutex.lock();
    const accepting = state.admission.accepting;
    state.admission.mutex.unlock();
    return if (accepting) result_invalid_argument else result_shutting_down;
}

fn unavailableSurfaceResult(handle: ?*Surface) Result {
    const pointer = handle orelse return result_invalid_argument;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const surface = surfaceStateFromId(@intFromPtr(pointer)) orelse
        return result_invalid_argument;
    surface.admission.mutex.lock();
    const accepting = surface.admission.accepting;
    const clearable = surface.admission.clearable;
    surface.admission.mutex.unlock();

    const host = surface.host;
    const host_shutting_down = host.shutting_down.load(.acquire);
    if (!accepting or !clearable or host_shutting_down) {
        return if (host_shutting_down)
            result_shutting_down
        else
            result_surface_invalidated;
    }
    return result_invalid_argument;
}

fn registerHost(state: *HostState) !void {
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    try host_registry.put(allocator, state.handle.id, state);
}

fn registerSurface(state: *SurfaceState) !void {
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    try surface_registry.put(allocator, state.handle.id, state);
}

fn unregisterHost(state: *HostState) void {
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    _ = host_registry.remove(state.handle.id);
    if (host_registry.count() == 0) {
        host_registry.deinit(allocator);
        host_registry = .empty;
    }
}

fn unregisterSurface(state: *SurfaceState) void {
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    _ = surface_registry.remove(state.handle.id);
    if (surface_registry.count() == 0) {
        surface_registry.deinit(allocator);
        surface_registry = .empty;
    }
}

fn admitHost(handle: ?*Host) ?HostAdmission {
    const pointer = handle orelse return null;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const state = hostStateFromId(@intFromPtr(pointer)) orelse return null;
    state.admission.mutex.lock();
    defer state.admission.mutex.unlock();
    if (!state.admission.accepting) return null;
    state.admission.admitted += 1;
    return .{ .state = state };
}

fn admitSurface(handle: ?*Surface) ?SurfaceAdmission {
    const pointer = handle orelse return null;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const surface = surfaceStateFromId(@intFromPtr(pointer)) orelse return null;
    surface.admission.mutex.lock();
    defer surface.admission.mutex.unlock();
    if (!surface.admission.accepting) return null;

    const host = surface.host;
    const host_admission = hostStateFromId(host.handle.id) orelse return null;
    host_admission.admission.mutex.lock();
    defer host_admission.admission.mutex.unlock();
    if (!host_admission.admission.accepting) return null;

    surface.admission.admitted += 1;
    host_admission.admission.admitted += 1;
    return .{
        .surface = surface,
        .host = host_admission,
    };
}

fn admitClearSurface(handle: ?*Surface) ?SurfaceAdmission {
    const pointer = handle orelse return null;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const surface = surfaceStateFromId(@intFromPtr(pointer)) orelse return null;
    surface.admission.mutex.lock();
    defer surface.admission.mutex.unlock();
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    const renderer = surface.renderer orelse return null;
    const persistent_release = renderer.ownsPersistentCurrent();
    if (!surface.admission.clearable or
        (!persistent_release and
            (surface.destroying.load(.acquire) or
                surface.invalidated.load(.acquire) or
                surface.host.shutting_down.load(.acquire) or
                surface.renderer_destroying)))
    {
        return null;
    }
    surface.admission.clear_admitted += 1;
    return .{
        .surface = surface,
        .clear = true,
    };
}

fn releaseHostAdmission(admission: *HostAdmission) void {
    if (admission.released) return;
    const state = admission.state;
    state.admission.mutex.lock();
    std.debug.assert(state.admission.admitted > 0);
    state.admission.admitted -= 1;
    state.admission.done.broadcast();
    state.admission.mutex.unlock();
    admission.released = true;
    maybeFinishHostDeinitialize(state);
}

fn releaseSurfaceAdmission(admission: *SurfaceAdmission) void {
    if (admission.released) return;
    const host = admission.host;
    admission.surface.admission.mutex.lock();
    if (admission.clear) {
        std.debug.assert(admission.surface.admission.clear_admitted > 0);
        admission.surface.admission.clear_admitted -= 1;
    } else {
        std.debug.assert(admission.surface.admission.admitted > 0);
        admission.surface.admission.admitted -= 1;
    }
    admission.surface.admission.done.broadcast();
    admission.surface.admission.mutex.unlock();
    if (host) |value| {
        value.admission.mutex.lock();
        std.debug.assert(value.admission.admitted > 0);
        value.admission.admitted -= 1;
        value.admission.done.broadcast();
        value.admission.mutex.unlock();
    }
    admission.released = true;
    if (!admission.defer_finalize) {
        maybeFinalizeRetiredSurface(admission.surface);
    }
    if (host) |value| maybeFinishHostDeinitialize(value);
}

fn closeHostAdmission(state: *HostState) void {
    admission_registry_mutex.lock();
    state.admission.mutex.lock();
    state.admission.accepting = false;
    state.shutting_down.store(true, .release);
    state.admission.mutex.unlock();
    admission_registry_mutex.unlock();
}

fn closeSurfaceAdmission(state: *SurfaceState) void {
    admission_registry_mutex.lock();
    state.admission.mutex.lock();
    state.admission.accepting = false;
    state.admission.mutex.unlock();
    admission_registry_mutex.unlock();
}

fn waitHostAdmissions(state: *HostState, remaining: usize) void {
    state.admission.mutex.lock();
    while (state.admission.admitted > remaining) {
        state.admission.done.wait(&state.admission.mutex);
    }
    state.admission.mutex.unlock();
}

fn waitSurfaceAdmissions(state: *SurfaceState, remaining: usize) void {
    state.admission.mutex.lock();
    while (state.admission.admitted > remaining) {
        state.admission.done.wait(&state.admission.mutex);
    }
    state.admission.mutex.unlock();
}

fn disableClearAdmissionAndWait(
    state: *SurfaceState,
    remaining: usize,
) void {
    state.admission.mutex.lock();
    state.admission.clearable = false;
    while (state.admission.admitted > remaining or
        state.admission.clear_admitted != 0)
    {
        state.admission.done.wait(&state.admission.mutex);
    }
    state.admission.mutex.unlock();
}

fn disableClearAdmissionOnlyAndWait(state: *SurfaceState) void {
    state.admission.mutex.lock();
    state.admission.clearable = false;
    while (state.admission.clear_admitted != 0) {
        state.admission.done.wait(&state.admission.mutex);
    }
    state.admission.mutex.unlock();
}

fn getDpi(hwnd: HWND) u32 {
    const value = GetDpiForWindow(hwnd);
    return if (value == 0) host_metrics.default_dpi else value;
}

fn metricsFor(surface: *const SurfaceState) ScaledMetrics {
    return host_metrics.calculate(
        surface.base_metrics,
        surface.dpi,
        surface.options.font_scale,
    );
}

fn beginSurfaceOperation(surface: *SurfaceState) bool {
    if (surface.destroying.load(.acquire) or
        surface.invalidated.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return false;
    }
    surface.pin_count += 1;
    surface.host.active_operations += 1;
    return true;
}

fn endSurfaceOperation(surface: *SurfaceState) void {
    const host = surface.host;
    surface.pin_count -= 1;
    host.active_operations -= 1;
    const destroy = surface.pin_count == 0 and
        surface.destroying.load(.acquire) and
        !surface.creation_in_progress;
    if (destroy) destroySurfaceNow(surface, 0);
    maybeFinishHostDeinitialize(host);
}

fn updateUiaMetrics(surface: *SurfaceState) void {
    if (surface.uia) |provider| {
        provider.updateMetrics(.{
            .cell_width = @floatFromInt(surface.metrics.cell_width),
            .cell_height = @floatFromInt(surface.metrics.cell_height),
            .origin_x = @floatFromInt(surface.screen_origin.x),
            .origin_y = @floatFromInt(surface.screen_origin.y),
        });
    }
}

fn updateScreenOrigin(surface: *SurfaceState) void {
    const hwnd = surface.hwnd orelse return;
    var origin: POINT = .{ .x = 0, .y = 0 };
    if (ClientToScreen(hwnd, &origin) == 0) return;
    surface.screen_origin = origin;
    updateUiaMetrics(surface);
}

fn notifyMetrics(surface: *SurfaceState) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    if (surface.options.callbacks.on_metrics_changed) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        const metrics: CellMetrics = .{
            .font_width = surface.metrics.font_width,
            .font_height = surface.metrics.font_height,
            .cell_width = surface.metrics.cell_width,
            .cell_height = surface.metrics.cell_height,
            .baseline = surface.metrics.baseline,
        };
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            &metrics,
        );
    }
}

fn updateDpi(surface: *SurfaceState, dpi: u32) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const normalized = host_metrics.normalizeDpi(dpi);
    if (surface.dpi == normalized) return;
    surface.dpi = normalized;
    surface.metrics = metricsFor(surface);
    updateScreenOrigin(surface);
    if (surface.options.callbacks.on_dpi_changed) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            normalized,
            host_metrics.dpiScale(normalized),
        );
    }
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    notifyMetrics(surface);
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    if (surface.hwnd) |hwnd| _ = InvalidateRect(hwnd, null, 0);
}

fn accessibilitySelection(
    ctx: *anyopaque,
    start: usize,
    end: usize,
) void {
    const dispatch: *SelectionDispatch = @ptrCast(@alignCast(ctx));
    dispatch.invoke(start, end);
}

fn deliverAccessibilitySelection(
    surface: *SurfaceState,
    start: usize,
    end: usize,
) void {
    if (GetCurrentThreadId() != surface.host.thread_id) return;
    if (!beginSurfaceOperation(surface)) return;
    defer endSurfaceOperation(surface);
    if (surface.options.callbacks.on_accessibility_selection) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(surface.options.user_data, surfaceHandle(surface), start, end);
    }
}

fn checkHost(host: *HostState) Result {
    if (host.shutting_down.load(.acquire)) return result_shutting_down;
    if (GetCurrentThreadId() != host.thread_id) return result_wrong_thread;
    return result_ok;
}

fn checkSurface(surface: *SurfaceState) Result {
    const result = checkHost(surface.host);
    if (result != result_ok) return result;
    if (surface.invalidated.load(.acquire)) return result_surface_invalidated;
    return result_ok;
}

fn checkRenderSurface(surface: *SurfaceState) Result {
    if (surface.host.shutting_down.load(.acquire)) return result_shutting_down;
    if (surface.invalidated.load(.acquire) or
        surface.destroying.load(.acquire))
    {
        return result_surface_invalidated;
    }
    return result_ok;
}

fn claimRenderThread(host: *HostState) Result {
    if (host.shutting_down.load(.acquire)) return result_shutting_down;
    const thread_id = GetCurrentThreadId();
    host.render_thread_mutex.lock();
    defer host.render_thread_mutex.unlock();
    if (host.render_thread_id == 0) {
        host.render_thread_id = thread_id;
        return result_ok;
    }
    return if (host.render_thread_id == thread_id)
        result_ok
    else
        result_wrong_thread;
}

fn rendererResult(surface: *SurfaceState, err: win32_context.Error) Result {
    surface.last_error.store(GetLastError(), .release);
    return switch (err) {
        error.WrongThread => result_wrong_thread,
        error.Destroying => result_shutting_down,
        error.SwapBuffersFailed => result_present_error,
        error.MakeCurrentFailed,
        error.RestoreCurrentFailed,
        => result_context_error,
        else => result_renderer_error,
    };
}

fn destroyRenderer(surface: *SurfaceState) void {
    surface.renderer_mutex.lock();
    surface.renderer_destroying = true;
    while (surface.active_renderer_operations != 0) {
        surface.renderer_done.wait(&surface.renderer_mutex);
    }
    const renderer = surface.renderer;
    surface.renderer_mutex.unlock();

    if (renderer) |value| {
        value.deinit();
    }

    surface.renderer_mutex.lock();
    if (renderer) |value| {
        if (surface.renderer == value) {
            surface.renderer = null;
            surface.retired_renderer = value;
        }
    }
    surface.renderer_destroying = false;
    surface.renderer_done.broadcast();
    surface.renderer_mutex.unlock();
}

fn freeRendererStorage(surface: *SurfaceState) void {
    if (surface.retired_renderer) |renderer| {
        allocator.destroy(renderer);
        surface.retired_renderer = null;
    }
}

fn beginRendererOperation(surface: *SurfaceState) ?*win32_context.Context {
    if (surface.host.shutting_down.load(.acquire)) return null;
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    if (surface.invalidated.load(.acquire) or
        surface.destroying.load(.acquire) or
        surface.renderer_destroying)
    {
        return null;
    }
    const renderer = surface.renderer orelse return null;
    surface.active_renderer_operations += 1;
    return renderer;
}

fn beginClearRendererOperation(surface: *SurfaceState) ?*win32_context.Context {
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    const renderer = surface.renderer orelse return null;
    const persistent_release = renderer.ownsPersistentCurrent();
    if ((!persistent_release and surface.host.shutting_down.load(.acquire)) or
        ((!persistent_release) and
            (surface.invalidated.load(.acquire) or
                surface.destroying.load(.acquire) or
                surface.renderer_destroying)))
    {
        return null;
    }
    surface.active_renderer_operations += 1;
    return renderer;
}

fn endRendererOperation(surface: *SurfaceState) void {
    surface.renderer_mutex.lock();
    std.debug.assert(surface.active_renderer_operations > 0);
    surface.active_renderer_operations -= 1;
    if (surface.active_renderer_operations == 0) {
        surface.renderer_done.broadcast();
    }
    surface.renderer_mutex.unlock();
}

fn rendererHdc(surface: *SurfaceState) HDC {
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    if (surface.host.shutting_down.load(.acquire) or
        surface.invalidated.load(.acquire) or
        surface.destroying.load(.acquire) or
        surface.renderer_destroying)
    {
        return null;
    }
    return if (surface.renderer) |renderer| renderer.hdc else null;
}

fn rendererHglrc(surface: *SurfaceState) HGLRC {
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    if (surface.host.shutting_down.load(.acquire) or
        surface.invalidated.load(.acquire) or
        surface.destroying.load(.acquire) or
        surface.renderer_destroying)
    {
        return null;
    }
    return if (surface.renderer) |renderer| renderer.hglrc else null;
}

fn storeRendererError(surface: *SurfaceState) void {
    surface.last_error.store(GetLastError(), .release);
}

fn loadRendererError(surface: *SurfaceState) DWORD {
    return surface.last_error.load(.acquire);
}

fn beginDispatch(surface: *SurfaceState) void {
    surface.active_dispatches += 1;
    surface.host.active_dispatches += 1;
}

fn endDispatch(surface: *SurfaceState) void {
    std.debug.assert(surface.active_dispatches > 0);
    std.debug.assert(surface.host.active_dispatches > 0);
    surface.active_dispatches -= 1;
    surface.host.active_dispatches -= 1;
    maybeFinalizeRetiredSurface(surface);
    maybeFinishHostDeinitialize(surface.host);
}

fn maybeFinishHostDeinitialize(state: *HostState) void {
    if (state.deinitialize_requested and
        state.creation_depth == 0 and
        state.destroy_surface_depth == 0 and
        state.active_dispatches == 0 and
        state.active_operations == 0)
    {
        state.admission.mutex.lock();
        const admitted = state.admission.admitted;
        state.admission.mutex.unlock();
        if (admitted != 0) return;
        state.deinitialize_requested = false;
        deinitializeHost(state, 0);
        allocator.destroy(state);
    }
}

fn retainRetiredSurface(host: *HostState, surface: *SurfaceState) void {
    if (surface.storage_retained) return;
    surface.storage_retained = true;
    surface.retired_next = host.retired_surfaces;
    host.retired_surfaces = surface;
}

fn maybeFinalizeRetiredSurface(surface: *SurfaceState) void {
    if (!surface.storage_retained or
        surface.active_dispatches != 0 or
        surface.retain_until_host_teardown)
    {
        return;
    }
    surface.admission.mutex.lock();
    const admitted = surface.admission.admitted;
    const clear_admitted = surface.admission.clear_admitted;
    surface.admission.mutex.unlock();
    if (admitted != 0 or clear_admitted != 0) return;

    var link: *?*SurfaceState = &surface.host.retired_surfaces;
    while (link.*) |value| {
        if (value == surface) {
            link.* = value.retired_next;
            break;
        }
        link = &value.retired_next;
    }
    surface.storage_retained = false;
    surface.retired_next = null;
    unregisterSurface(surface);
    deinitSurfaceResources(surface);
    allocator.destroy(surface);
}

fn registerSurfaceClass() void {
    const class: WNDCLASSEXW = .{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = CS_DBLCLKS,
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

fn detachSurfaceProvider(surface: *SurfaceState) void {
    if (surface.uia) |provider| {
        _ = provider.disconnect();
        _ = host_uia.SurfaceProvider.Release(&provider.base);
        surface.uia = null;
    }
    if (surface.selection_dispatch) |dispatch| {
        surface.selection_dispatch = null;
        dispatch.deactivate();
    }
}

fn notifyFocus(surface: *SurfaceState, focused: bool) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    surface.focused = focused;
    if (surface.uia) |provider| provider.updateFocus(focused);
    if (surface.options.callbacks.on_focus) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            if (focused) 1 else 0,
        );
    }
}

fn notifyRedraw(surface: *SurfaceState) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    if (surface.options.callbacks.on_redraw) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(surface.options.user_data, surfaceHandle(surface));
    }
}

fn emitKey(surface: *SurfaceState, event: KeyEvent) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    if (surface.options.input_callbacks.on_key) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            &event,
        );
    }
}

fn emitText(surface: *SurfaceState, text: []const u8) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const owned = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(owned);
    if (surface.options.input_callbacks.on_text) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            owned,
            @intCast(text.len),
        );
    }
}

fn emitImeUpdate(surface: *SurfaceState, text: []const u8, committed: bool) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const owned = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(owned);
    if (surface.options.input_callbacks.on_ime_update) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            owned,
            @intCast(text.len),
            if (committed) 1 else 0,
        );
    }
}

fn emitMouse(surface: *SurfaceState, event: MouseEvent) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    if (surface.options.input_callbacks.on_mouse) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(surface.options.user_data, surfaceHandle(surface), &event);
    }
}

fn emitSelection(surface: *SurfaceState) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const event = SelectionEvent{
        .active = if (surface.selection_active) 1 else 0,
        .dragging = if (surface.selection_dragging) 1 else 0,
        .rectangular = 0,
        .reserved = 0,
        .anchor_x = surface.selection_anchor_x,
        .anchor_y = surface.selection_anchor_y,
        .current_x = surface.selection_current_x,
        .current_y = surface.selection_current_y,
    };
    if (surface.options.input_callbacks.on_selection) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(surface.options.user_data, surfaceHandle(surface), &event);
    }
}

fn emitLink(surface: *SurfaceState, hovered: bool, clicked: bool) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const url = surface.link_url orelse return;
    const owned_url = allocator.dupeZ(u8, url) catch return;
    defer allocator.free(owned_url);
    if (surface.options.input_callbacks.on_link) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            owned_url,
            if (hovered) 1 else 0,
            if (clicked) 1 else 0,
        );
    }
}

fn emitPaste(surface: *SurfaceState, text: []const u8, bracketed: bool) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const owned = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(owned);
    if (surface.options.input_callbacks.on_paste) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            owned,
            @intCast(text.len),
            if (bracketed) 1 else 0,
        );
    }
}

fn emitClipboardRead(surface: *SurfaceState, format: u32, text: []const u8) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const owned = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(owned);
    if (surface.options.input_callbacks.on_clipboard_read) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            format,
            owned,
            @intCast(text.len),
        );
    }
}

fn emitClipboardWrite(surface: *SurfaceState, format: u32, text: []const u8) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const owned = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(owned);
    if (surface.options.input_callbacks.on_clipboard_write) |callback| {
        beginDispatch(surface);
        defer endDispatch(surface);
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            format,
            owned,
            @intCast(text.len),
        );
    }
}

fn signedWord(value: usize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(value))));
}

fn mouseModifiers(wparam: WPARAM) u32 {
    var result: u32 = 0;
    if ((wparam & MK_LBUTTON) != 0) result |= MK_LBUTTON;
    if ((wparam & MK_RBUTTON) != 0) result |= MK_RBUTTON;
    if ((wparam & MK_SHIFT) != 0 or (GetKeyState(VK_SHIFT) < 0)) result |= MK_SHIFT;
    if ((wparam & MK_CONTROL) != 0 or (GetKeyState(VK_CONTROL) < 0)) result |= MK_CONTROL;
    if ((wparam & MK_MBUTTON) != 0) result |= MK_MBUTTON;
    if ((wparam & MK_XBUTTON1) != 0) result |= MK_XBUTTON1;
    if ((wparam & MK_XBUTTON2) != 0) result |= MK_XBUTTON2;
    return result;
}

fn keyModifiers() u32 {
    var result: u32 = 0;
    if (GetKeyState(VK_SHIFT) < 0) result |= MK_SHIFT;
    if (GetKeyState(VK_CONTROL) < 0) result |= MK_CONTROL;
    if (GetKeyState(VK_MENU) < 0) result |= 0x0080;
    return result;
}

fn cellCoordinate(value: i32, cell: u32) i32 {
    if (cell == 0) return value;
    if (value < 0) return -1;
    return @intCast(@divTrunc(@as(u32, @intCast(value)), cell));
}

fn mouseButton(message: UINT, wparam: WPARAM) u32 {
    return switch (message) {
        WM_LBUTTONDOWN, WM_LBUTTONUP, WM_LBUTTONDBLCLK => 1,
        WM_RBUTTONDOWN, WM_RBUTTONUP, WM_RBUTTONDBLCLK => 2,
        WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MBUTTONDBLCLK => 3,
        WM_XBUTTONDOWN, WM_XBUTTONUP, WM_XBUTTONDBLCLK => if (((wparam >> 16) & 0xffff) == 2) 5 else 4,
        else => 0,
    };
}

fn mouseKind(message: UINT) u32 {
    return switch (message) {
        WM_MOUSEMOVE => mouse_move,
        WM_LBUTTONDOWN,
        WM_RBUTTONDOWN,
        WM_MBUTTONDOWN,
        WM_XBUTTONDOWN,
        WM_LBUTTONDBLCLK,
        WM_RBUTTONDBLCLK,
        WM_MBUTTONDBLCLK,
        WM_XBUTTONDBLCLK,
        => mouse_button_down,
        WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP, WM_XBUTTONUP => mouse_button_up,
        WM_MOUSEWHEEL, WM_MOUSEHWHEEL => mouse_wheel,
        WM_MOUSELEAVE => mouse_leave,
        else => mouse_move,
    };
}

fn isMouseButtonDown(message: UINT) bool {
    return switch (message) {
        WM_LBUTTONDOWN,
        WM_RBUTTONDOWN,
        WM_MBUTTONDOWN,
        WM_XBUTTONDOWN,
        WM_LBUTTONDBLCLK,
        WM_RBUTTONDBLCLK,
        WM_MBUTTONDBLCLK,
        WM_XBUTTONDBLCLK,
        => true,
        else => false,
    };
}

fn isMouseDoubleClick(message: UINT) bool {
    return switch (message) {
        WM_LBUTTONDBLCLK,
        WM_RBUTTONDBLCLK,
        WM_MBUTTONDBLCLK,
        WM_XBUTTONDBLCLK,
        => true,
        else => false,
    };
}

fn emitMouseMessage(
    surface: *SurfaceState,
    hwnd: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const kind = mouseKind(message);
    var x = signedWord(@as(usize, @bitCast(lparam)));
    var y = signedWord(@as(usize, @bitCast(lparam)) >> 16);
    if (kind == mouse_wheel) {
        var point = POINT{ .x = x, .y = y };
        if (ScreenToClient(hwnd, &point) != 0) {
            x = point.x;
            y = point.y;
        }
    }
    const event = MouseEvent{
        .kind = kind,
        .button = mouseButton(message, wparam),
        .modifiers = mouseModifiers(wparam),
        .x = x,
        .y = y,
        .cell_x = cellCoordinate(x, surface.options.input.cell_width),
        .cell_y = cellCoordinate(y, surface.options.input.cell_height),
        .wheel_delta = if (kind == mouse_wheel)
            @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(wparam)) >> 16))))
        else
            0,
        .click_count = surface.click_count,
    };
    emitMouse(surface, event);
}

fn utf16ToUtf8(alloc: Allocator, units: []const u16) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const first = units[index];
        var codepoint: u21 = first;
        if (first >= 0xD800 and first <= 0xDBFF and index + 1 < units.len) {
            const second = units[index + 1];
            if (second >= 0xDC00 and second <= 0xDFFF) {
                codepoint = 0x10000 + (@as(u21, first - 0xD800) << 10) + (second - 0xDC00);
                index += 1;
            }
        } else if (first >= 0xDC00 and first <= 0xDFFF) {
            codepoint = 0xFFFD;
        }
        var encoded: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &encoded);
        try result.appendSlice(alloc, encoded[0..len]);
    }
    return try result.toOwnedSlice(alloc);
}

fn emitUtf16Text(surface: *SurfaceState, units: []const u16) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const utf8 = utf16ToUtf8(allocator, units) catch return;
    defer allocator.free(utf8);
    emitText(surface, utf8);
}

fn emitCodepointText(surface: *SurfaceState, codepoint: u21) void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &encoded) catch return;
    emitText(surface, encoded[0..length]);
}

fn handleUtf16Unit(surface: *SurfaceState, unit: u16) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        surface.pending_high_surrogate = unit;
        return;
    }
    if (surface.pending_high_surrogate) |high| {
        surface.pending_high_surrogate = null;
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            emitUtf16Text(surface, &.{ high, unit });
            return;
        }
        emitUtf16Text(surface, &.{high});
    }
    emitUtf16Text(surface, &.{unit});
    surface.dead_key_active = false;
}

fn emitImeComposition(surface: *SurfaceState, index: u32, committed: bool) void {
    if (surface.destroying.load(.acquire) or
        surface.host.shutting_down.load(.acquire))
    {
        return;
    }
    const hwnd = surface.hwnd orelse return;
    const context = ImmGetContext(hwnd) orelse return;
    defer _ = ImmReleaseContext(hwnd, context);
    const byte_count = ImmGetCompositionStringW(context, index, null, 0);
    if (byte_count <= 0) return;
    const units_count: usize = @intCast(@divExact(byte_count, 2));
    const units = allocator.alloc(u16, units_count) catch return;
    defer allocator.free(units);
    if (ImmGetCompositionStringW(
        context,
        index,
        @ptrCast(units.ptr),
        @intCast(byte_count),
    ) < 0) return;
    const utf8 = utf16ToUtf8(allocator, units) catch return;
    defer allocator.free(utf8);
    emitImeUpdate(surface, utf8, committed);
}

fn isDeadKeyDown(surface: *SurfaceState, wparam: WPARAM, lparam: LPARAM) bool {
    var keyboard_state: [256]u8 = undefined;
    if (GetKeyboardState(&keyboard_state) == 0) return false;
    const scan_code: u32 = @intCast((@as(usize, @bitCast(lparam)) >> 16) & 0xff);
    var chars: [8]u16 = undefined;
    const layout = surface.keyboard_layout orelse GetKeyboardLayout(0);
    return ToUnicodeEx(
        @intCast(wparam & 0xffff),
        scan_code,
        &keyboard_state,
        &chars,
        chars.len,
        TOUNICODE_NO_STATE_CHANGE,
        layout,
    ) < 0;
}

fn keyEventFromMessage(
    surface: *SurfaceState,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
    dead_key: bool,
) KeyEvent {
    const repeat_count: u32 = @intCast(@as(usize, @bitCast(lparam)) & 0xffff);
    const scan_code: u32 = @intCast((@as(usize, @bitCast(lparam)) >> 16) & 0xff);
    const previous_down = ((@as(usize, @bitCast(lparam)) >> 30) & 1) != 0;
    const is_up = message == WM_KEYUP or message == WM_SYSKEYUP;
    const layout = surface.keyboard_layout orelse GetKeyboardLayout(0);
    return .{
        .action = if (is_up) key_release else if (previous_down) key_repeat else key_press,
        .virtual_key = @intCast(wparam & 0xffff),
        .scan_code = scan_code,
        .repeat_count = if (repeat_count == 0) 1 else repeat_count,
        .flags = @intCast((@as(usize, @bitCast(lparam)) >> 24) & 0xff),
        .modifiers = keyModifiers(),
        .keyboard_layout = if (layout) |value| @intFromPtr(value) else 0,
        .composing = if (surface.ime_composing or
            surface.dead_key_active or
            surface.pending_high_surrogate != null) 1 else 0,
        .dead_key = if (dead_key) 1 else 0,
        .reserved = .{0} ** 6,
        .keyboard_layout_name = if (surface.options.input.keyboard_layout) |value|
            value.ptr
        else
            null,
    };
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
    if (surface) |value| beginDispatch(value);
    defer if (surface) |value| endDispatch(value);
    if (message == WM_UNICHAR and wparam == UNICODE_NOCHAR) return 1;
    switch (message) {
        WM_GETOBJECT => {
            if (surface) |value| {
                if (value.uia) |provider| {
                    if (host_uia.returnProvider(hwnd, wparam, lparam, provider)) |result| {
                        return result;
                    }
                }
            }
            return DefWindowProcW(hwnd, message, wparam, lparam);
        },
        WM_UIA_SELECTION => {
            if (surface) |value| {
                if (lparam != 0) {
                    const message_ptr: *const SelectionMessage =
                        @ptrFromInt(@as(usize, @bitCast(lparam)));
                    if (value.selection_dispatch == message_ptr.dispatch and
                        message_ptr.dispatch.owner_thread_id == GetCurrentThreadId() and
                        message_ptr.dispatch.isActive())
                    {
                        deliverAccessibilitySelection(
                            value,
                            message_ptr.start,
                            message_ptr.end,
                        );
                    }
                }
            }
            return 0;
        },
        WM_DPICHANGED => {
            if (surface) |value| {
                const next_dpi: u32 = @as(u32, @intCast(wparam)) & 0xffff;
                updateDpi(value, next_dpi);
            }
            return 0;
        },
        WM_MOVE, WM_WINDOWPOSCHANGED => {
            if (surface) |value| updateScreenOrigin(value);
            return DefWindowProcW(hwnd, message, wparam, lparam);
        },
        WM_SETFOCUS => {
            if (surface) |value| notifyFocus(value, true);
            return 0;
        },
        WM_KILLFOCUS => {
            if (surface) |value| notifyFocus(value, false);
            if (surface) |value| {
                if (value.ime_composing) {
                    value.ime_composing = false;
                    if (value.options.input_callbacks.on_ime_end) |callback| {
                        if (!value.destroying.load(.acquire) and
                            !value.host.shutting_down.load(.acquire))
                        {
                            beginDispatch(value);
                            defer endDispatch(value);
                            callback(value.options.user_data, surfaceHandle(value));
                        }
                    }
                }
            }
            return 0;
        },
        WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP => {
            if (surface) |value| {
                if (value.focused or GetFocus() == hwnd) {
                    const dead_key = (message == WM_KEYDOWN or message == WM_SYSKEYDOWN) and
                        isDeadKeyDown(value, wparam, lparam);
                    if (dead_key) value.dead_key_active = true;
                    const event = keyEventFromMessage(
                        value,
                        message,
                        wparam,
                        lparam,
                        dead_key,
                    );
                    emitKey(value, event);
                }
            }
            return 0;
        },
        WM_CHAR, WM_SYSCHAR, WM_UNICHAR => {
            if (surface) |value| {
                if ((value.focused or GetFocus() == hwnd) and wparam != UNICODE_NOCHAR) {
                    if (message == WM_UNICHAR and wparam > 0xffff) {
                        emitCodepointText(value, @intCast(wparam));
                    } else {
                        handleUtf16Unit(value, @intCast(wparam & 0xffff));
                    }
                }
            }
            return 0;
        },
        WM_DEADCHAR, WM_SYSDEADCHAR => {
            if (surface) |value| {
                if (value.focused or GetFocus() == hwnd) {
                    value.dead_key_active = true;
                }
            }
            return 0;
        },
        WM_IME_STARTCOMPOSITION => {
            if (surface) |value| {
                if (!value.destroying.load(.acquire) and
                    !value.host.shutting_down.load(.acquire) and
                    (value.focused or GetFocus() == hwnd))
                {
                    value.ime_composing = true;
                    if (value.options.input_callbacks.on_ime_start) |callback| {
                        beginDispatch(value);
                        defer endDispatch(value);
                        callback(value.options.user_data, surfaceHandle(value));
                    }
                }
            }
            return 0;
        },
        WM_IME_COMPOSITION => {
            if (surface) |value| {
                if ((value.focused or GetFocus() == hwnd) and
                    (@as(usize, @bitCast(lparam)) & GCS_COMPSTR) != 0)
                {
                    emitImeComposition(value, GCS_COMPSTR, false);
                }
                if ((value.focused or GetFocus() == hwnd) and
                    (@as(usize, @bitCast(lparam)) & GCS_RESULTSTR) != 0)
                {
                    emitImeComposition(value, GCS_RESULTSTR, true);
                }
            }
            return 0;
        },
        WM_IME_ENDCOMPOSITION => {
            if (surface) |value| {
                if (!value.destroying.load(.acquire) and
                    !value.host.shutting_down.load(.acquire) and
                    (value.focused or GetFocus() == hwnd))
                {
                    value.ime_composing = false;
                    if (value.options.input_callbacks.on_ime_end) |callback| {
                        beginDispatch(value);
                        defer endDispatch(value);
                        callback(value.options.user_data, surfaceHandle(value));
                    }
                }
            }
            return 0;
        },
        WM_MOUSEMOVE,
        WM_LBUTTONDOWN,
        WM_LBUTTONUP,
        WM_LBUTTONDBLCLK,
        WM_RBUTTONDOWN,
        WM_RBUTTONUP,
        WM_RBUTTONDBLCLK,
        WM_MBUTTONDOWN,
        WM_MBUTTONUP,
        WM_MBUTTONDBLCLK,
        WM_XBUTTONDOWN,
        WM_XBUTTONUP,
        WM_XBUTTONDBLCLK,
        WM_MOUSEWHEEL,
        WM_MOUSEHWHEEL,
        WM_MOUSELEAVE,
        => {
            if (surface) |value| {
                if (isMouseButtonDown(message)) {
                    value.click_count = if (isMouseDoubleClick(message)) 2 else 1;
                }
                if (message == WM_LBUTTONDOWN or message == WM_LBUTTONDBLCLK) {
                    _ = SetFocus(hwnd);
                    if (value.options.input.selection_enabled != 0) {
                        _ = SetCapture(hwnd);
                        const x = signedWord(@as(usize, @bitCast(lparam)));
                        const y = signedWord(@as(usize, @bitCast(lparam)) >> 16);
                        value.selection_active = true;
                        value.selection_dragging = true;
                        value.selection_anchor_x = cellCoordinate(x, value.options.input.cell_width);
                        value.selection_anchor_y = cellCoordinate(y, value.options.input.cell_height);
                        value.selection_current_x = value.selection_anchor_x;
                        value.selection_current_y = value.selection_anchor_y;
                        emitSelection(value);
                    }
                    if (value.link_hovered) emitLink(value, true, true);
                } else if (message == WM_LBUTTONUP) {
                    value.selection_dragging = false;
                    if (value.selection_active) emitSelection(value);
                    if (value.options.input.selection_enabled != 0) _ = ReleaseCapture();
                } else if (message == WM_MOUSEMOVE and value.selection_dragging) {
                    const x = signedWord(@as(usize, @bitCast(lparam)));
                    const y = signedWord(@as(usize, @bitCast(lparam)) >> 16);
                    value.selection_current_x = cellCoordinate(x, value.options.input.cell_width);
                    value.selection_current_y = cellCoordinate(y, value.options.input.cell_height);
                    emitSelection(value);
                } else if (message == WM_MOUSELEAVE) {
                    if (value.link_hovered) {
                        value.link_hovered = false;
                        emitLink(value, false, false);
                    }
                }
                emitMouseMessage(value, hwnd, message, wparam, lparam);
                if (message == WM_MOUSEMOVE and
                    (value.options.input_callbacks.on_mouse != null or
                        value.options.input.selection_enabled != 0 or
                        value.options.input.links_enabled != 0))
                {
                    var tracking = TrackMouseEventArgs{
                        .cbSize = @sizeOf(TrackMouseEventArgs),
                        .dwFlags = TME_LEAVE,
                        .hwndTrack = hwnd,
                        .dwHoverTime = 0,
                    };
                    _ = TrackMouseEvent(&tracking);
                }
                if (message == WM_MOUSEMOVE and
                    value.options.input.links_enabled != 0 and
                    value.link_url != null and
                    !value.link_hovered)
                {
                    value.link_hovered = true;
                    emitLink(value, true, false);
                }
            }
            return 0;
        },
        WM_CAPTURECHANGED => {
            if (surface) |value| {
                const was_dragging = value.selection_dragging;
                value.selection_dragging = false;
                if (was_dragging and value.selection_active) emitSelection(value);
            }
            return 0;
        },
        WM_INPUTLANGCHANGE => {
            if (surface) |value| value.keyboard_layout = @ptrFromInt(@as(usize, @bitCast(lparam)));
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
                detachSurfaceProvider(value);
                value.hwnd = null;
                destroyRenderer(value);
                disableClearAdmissionOnlyAndWait(value);
                if (!value.destroying.load(.acquire)) {
                    value.invalidated.store(true, .release);
                }
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

fn destroySurfaceNow(
    surface: *SurfaceState,
    remaining_admissions: usize,
) void {
    const reentrant_dispatch =
        surface.active_dispatches != 0 and
        GetCurrentThreadId() == surface.host.thread_id;
    if (surface.retired) return;
    if (reentrant_dispatch) surface.retain_until_host_teardown = true;
    surface.destroying.store(true, .release);
    surface.invalidated.store(true, .release);
    surface.retired = true;
    removeSurface(surface.host, surface);
    if (remaining_admissions == 0 or surface.active_dispatches != 0) {
        retainRetiredSurface(surface.host, surface);
    }
    if (!reentrant_dispatch) {
        waitSurfaceAdmissions(surface, remaining_admissions);
    }
    detachSurfaceProvider(surface);
    destroyRenderer(surface);
    if (reentrant_dispatch) {
        disableClearAdmissionOnlyAndWait(surface);
    } else {
        disableClearAdmissionAndWait(surface, remaining_admissions);
    }
    if (surface.hwnd) |hwnd| {
        setUserData(hwnd, null);
        _ = DestroyWindow(hwnd);
        surface.hwnd = null;
    }
    if (!surface.storage_retained) unregisterSurface(surface);
    freeRendererStorage(surface);
}

fn cleanupUnregisteredSurface(
    surface: *SurfaceState,
    hwnd: ?HWND,
) void {
    surface.destroying.store(true, .release);
    detachSurfaceProvider(surface);
    if (hwnd) |value| {
        setUserData(value, null);
        _ = DestroyWindow(value);
        surface.hwnd = null;
    }
    closeSurfaceAdmission(surface);
    destroyRenderer(surface);
    disableClearAdmissionOnlyAndWait(surface);
    unregisterSurface(surface);
    freeRendererStorage(surface);
    deinitSurfaceResources(surface);
    allocator.destroy(surface);
}

fn deinitSurfaceResources(surface: *SurfaceState) void {
    if (surface.selection_text) |value| allocator.free(value);
    if (surface.link_url) |value| allocator.free(value);
    surface.selection_text = null;
    surface.link_url = null;
    surface.options.deinit();
}

fn finishUnregisteredSurfaceCreation(
    state: *HostState,
    surface: *SurfaceState,
    hwnd: ?HWND,
    result: Result,
    host_admission: *HostAdmission,
) Result {
    surface.creation_in_progress = false;
    cleanupUnregisteredSurface(surface, hwnd);
    state.creation_depth -= 1;
    const deinitialize_requested = state.deinitialize_requested;
    if (deinitialize_requested and state.creation_depth == 0 and
        state.active_dispatches == 0 and
        state.active_operations == 0)
    {
        state.deinitialize_requested = false;
        deinitializeHost(state, 1);
        releaseHostAdmission(host_admission);
        allocator.destroy(state);
    }
    return if (deinitialize_requested) result_shutting_down else result;
}

fn deinitializeHost(
    state: *HostState,
    remaining_host_admissions: usize,
) void {
    closeHostAdmission(state);
    waitHostAdmissions(state, remaining_host_admissions);
    while (state.surfaces.items.len > 0) {
        const surface = state.surfaces.items[state.surfaces.items.len - 1];
        closeSurfaceAdmission(surface);
        destroySurfaceNow(surface, 0);
    }
    state.surfaces.deinit(allocator);
    unregisterHost(state);
    var retired = state.retired_surfaces;
    while (retired) |surface| {
        retired = surface.retired_next;
        unregisterSurface(surface);
        deinitSurfaceResources(surface);
        allocator.destroy(surface);
    }
}

fn finishDeferredHostDeinitialize(
    state: *HostState,
    remaining_host_admissions: usize,
) bool {
    if (!state.deinitialize_requested or
        state.creation_depth != 0 or
        state.destroy_surface_depth != 0 or
        state.active_dispatches != 0)
    {
        return false;
    }
    state.deinitialize_requested = false;
    deinitializeHost(state, remaining_host_admissions);
    return true;
}

fn defaultSurfaceOptions() SurfaceOptions {
    return .{
        .size = @sizeOf(SurfaceOptions),
        .version = 2,
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
            .on_dpi_changed = null,
            .on_metrics_changed = null,
            .on_accessibility_selection = null,
        },
        .user_data = null,
        .input_callbacks = .{
            .on_key = null,
            .on_text = null,
            .on_ime_start = null,
            .on_ime_update = null,
            .on_ime_end = null,
            .on_mouse = null,
            .on_selection = null,
            .on_link = null,
            .on_paste = null,
            .on_clipboard_read = null,
            .on_clipboard_write = null,
        },
        .input = .{
            .cell_width = 8,
            .cell_height = 16,
            .selection_enabled = 1,
            .links_enabled = 1,
            .paste_protection = 1,
            .bracketed_paste = 1,
            .reserved = .{0} ** 4,
            .keyboard_layout = null,
        },
    };
}

pub export fn winghostty_surface_options_v2_init(options: *SurfaceOptions) void {
    options.* = .{
        .size = @sizeOf(SurfaceOptions),
        .version = 2,
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
            .on_dpi_changed = null,
            .on_metrics_changed = null,
            .on_accessibility_selection = null,
        },
        .user_data = null,
        .input_callbacks = .{
            .on_key = null,
            .on_text = null,
            .on_ime_start = null,
            .on_ime_update = null,
            .on_ime_end = null,
            .on_mouse = null,
            .on_selection = null,
            .on_link = null,
            .on_paste = null,
            .on_clipboard_read = null,
            .on_clipboard_write = null,
        },
        .input = .{
            .cell_width = 8,
            .cell_height = 16,
            .selection_enabled = 1,
            .links_enabled = 1,
            .paste_protection = 1,
            .bracketed_paste = 1,
            .reserved = .{0} ** 4,
            .keyboard_layout = null,
        },
    };
}

pub export fn winghostty_surface_options_init(options: *LegacySurfaceOptions) void {
    const full = defaultSurfaceOptions();
    options.* = .{
        .command = full.command,
        .cwd = full.cwd,
        .environment = full.environment,
        .bounds = full.bounds,
        .visible = full.visible,
        .focus = full.focus,
        .theme = full.theme,
        .font_scale = full.font_scale,
        .callbacks = .{
            .on_exit = full.callbacks.on_exit,
            .on_title = full.callbacks.on_title,
            .on_cwd = full.callbacks.on_cwd,
            .on_bell = full.callbacks.on_bell,
            .on_notification = full.callbacks.on_notification,
            .on_redraw = full.callbacks.on_redraw,
            .on_focus = full.callbacks.on_focus,
            .on_fatal_error = full.callbacks.on_fatal_error,
        },
        .user_data = full.user_data,
    };
}

pub export fn winghostty_host_initialize(out_host: ?*?*Host) Result {
    const output = out_host orelse return result_invalid_argument;
    output.* = null;

    const host = allocator.create(HostState) catch return result_out_of_memory;
    const handle = allocateHandleIdentity(.host) orelse {
        allocator.destroy(host);
        return result_out_of_memory;
    };
    host.* = .{
        .handle = handle,
        .thread_id = GetCurrentThreadId(),
    };
    registerHost(host) catch {
        allocator.destroy(host);
        return result_out_of_memory;
    };
    registerSurfaceClass();
    output.* = hostHandle(host);
    return result_ok;
}

pub export fn winghostty_host_deinitialize(host: ?*Host) Result {
    var admission = admitHost(host) orelse
        return unavailableHostResult(host);
    const state = admission.state;
    const result = checkHost(state);
    if (result != result_ok) {
        releaseHostAdmission(&admission);
        return result;
    }

    state.shutting_down.store(true, .release);
    if (state.creation_depth != 0 or
        state.destroy_surface_depth != 0 or
        state.active_dispatches != 0 or
        state.active_operations != 0)
    {
        state.deinitialize_requested = true;
        releaseHostAdmission(&admission);
        return result_ok;
    }
    deinitializeHost(state, 1);
    releaseHostAdmission(&admission);
    allocator.destroy(state);
    return result_ok;
}

fn legacyToV2(source: *const LegacySurfaceOptions) SurfaceOptions {
    var result = defaultSurfaceOptions();
    result.command = source.command;
    result.cwd = source.cwd;
    result.environment = source.environment;
    result.bounds = source.bounds;
    result.visible = source.visible;
    result.focus = source.focus;
    result.theme = source.theme;
    result.font_scale = source.font_scale;
    result.callbacks.on_exit = source.callbacks.on_exit;
    result.callbacks.on_title = source.callbacks.on_title;
    result.callbacks.on_cwd = source.callbacks.on_cwd;
    result.callbacks.on_bell = source.callbacks.on_bell;
    result.callbacks.on_notification = source.callbacks.on_notification;
    result.callbacks.on_redraw = source.callbacks.on_redraw;
    result.callbacks.on_focus = source.callbacks.on_focus;
    result.callbacks.on_fatal_error = source.callbacks.on_fatal_error;
    result.user_data = source.user_data;
    return result;
}

fn createSurface(
    state: *HostState,
    parent_hwnd: HWND,
    source: *const SurfaceOptions,
    output: *?*Surface,
    host_admission: *HostAdmission,
) Result {
    if (source.font_scale <= 0 or !std.math.isFinite(source.font_scale)) {
        return result_invalid_argument;
    }
    if (source.theme < 0 or source.theme > 2) {
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
    const handle = allocateHandleIdentity(.surface) orelse {
        var cleanup = owned;
        cleanup.deinit();
        allocator.destroy(surface);
        return result_out_of_memory;
    };
    surface.* = .{
        .handle = handle,
        .host = state,
        .parent = parent_hwnd,
        .options = owned,
        .keyboard_layout = GetKeyboardLayout(0),
    };
    registerSurface(surface) catch {
        surface.options.deinit();
        allocator.destroy(surface);
        return result_out_of_memory;
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
            host_admission,
        );
    };
    surface.hwnd = hwnd;
    if (state.shutting_down.load(.acquire)) {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_shutting_down,
            host_admission,
        );
    }
    surface.dpi = getDpi(hwnd);
    surface.metrics = metricsFor(surface);
    surface.selection_dispatch = SelectionDispatch.create(hwnd) catch {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_out_of_memory,
            host_admission,
        );
    };
    surface.uia = host_uia.SurfaceProvider.create(
        allocator,
        hwnd,
        .{
            .name = "Terminal",
            .text = "",
            .visible = surface.options.visible != 0,
            .metrics = .{
                .cell_width = @floatFromInt(surface.metrics.cell_width),
                .cell_height = @floatFromInt(surface.metrics.cell_height),
            },
            .callback_ctx = surface.selection_dispatch,
            .callback_ctx_retain = SelectionDispatch.retainContext,
            .callback_ctx_release = SelectionDispatch.releaseContext,
            .on_selection = accessibilitySelection,
        },
    ) catch {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_out_of_memory,
            host_admission,
        );
    };
    updateScreenOrigin(surface);

    const renderer = allocator.create(win32_context.Context) catch {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_out_of_memory,
            host_admission,
        );
    };
    renderer.* = win32_context.Context.init(hwnd) catch |err| {
        storeRendererError(surface);
        allocator.destroy(renderer);
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            switch (err) {
                error.GetDCFailed,
                error.ChoosePixelFormatFailed,
                error.SetPixelFormatFailed,
                => result_renderer_error,
                error.CreateContextFailed => result_context_error,
                else => result_renderer_error,
            },
            host_admission,
        );
    };
    surface.renderer = renderer;

    state.surfaces.append(allocator, surface) catch {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_out_of_memory,
            host_admission,
        );
    };

    if (source.focus != 0) {
        _ = SetFocus(hwnd);
    }
    surface.creation_in_progress = false;
    state.creation_depth -= 1;

    if (surface.destroying.load(.acquire) or
        surface.invalidated.load(.acquire) or
        state.shutting_down.load(.acquire))
    {
        const was_invalidated = surface.invalidated.load(.acquire);
        const was_shutting_down = state.shutting_down.load(.acquire);
        if (!surface.destroying.load(.acquire)) {
            surface.destroying.store(true, .release);
        }
        closeSurfaceAdmission(surface);
        destroySurfaceNow(surface, 0);
        const deinitialize_requested = state.deinitialize_requested;
        if (deinitialize_requested and state.creation_depth == 0 and
            state.active_operations == 0 and
            state.active_dispatches == 0)
        {
            state.deinitialize_requested = false;
            deinitializeHost(state, 1);
            releaseHostAdmission(host_admission);
            allocator.destroy(state);
        }
        return if (was_invalidated and !was_shutting_down)
            result_surface_invalidated
        else
            result_shutting_down;
    }

    output.* = surfaceHandle(surface);
    return result_ok;
}

pub export fn winghostty_host_create_surface(
    host: ?*Host,
    parent: ?HWND,
    options: ?*const LegacySurfaceOptions,
    out_surface: ?*?*Surface,
) Result {
    const output = out_surface orelse return result_invalid_argument;
    output.* = null;
    var host_admission = admitHost(host) orelse
        return unavailableHostResult(host);
    defer releaseHostAdmission(&host_admission);
    const state = host_admission.state;
    const parent_hwnd = parent orelse return result_invalid_argument;
    const source = options orelse return result_invalid_argument;
    const thread_result = checkHost(state);
    if (thread_result != result_ok) return thread_result;
    var v2 = legacyToV2(source);
    return createSurface(state, parent_hwnd, &v2, output, &host_admission);
}

pub export fn winghostty_host_create_surface_v2(
    host: ?*Host,
    parent: ?HWND,
    options: ?*const SurfaceOptions,
    out_surface: ?*?*Surface,
) Result {
    const output = out_surface orelse return result_invalid_argument;
    output.* = null;
    var host_admission = admitHost(host) orelse
        return unavailableHostResult(host);
    defer releaseHostAdmission(&host_admission);
    const state = host_admission.state;
    const parent_hwnd = parent orelse return result_invalid_argument;
    const source = options orelse return result_invalid_argument;
    const thread_result = checkHost(state);
    if (thread_result != result_ok) return thread_result;
    if (source.version != 2 or source.size < @sizeOf(SurfaceOptions)) {
        return result_invalid_argument;
    }
    return createSurface(state, parent_hwnd, source, output, &host_admission);
}

pub export fn winghostty_surface_destroy(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    admission.defer_finalize = true;
    const result = checkHost(state.host);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (state.destroying.load(.acquire)) {
        releaseSurfaceAdmission(&admission);
        return result_ok;
    }
    if (state.creation_in_progress) {
        state.destroying.store(true, .release);
        releaseSurfaceAdmission(&admission);
        return result_ok;
    }
    const host = state.host;
    host.destroy_surface_depth += 1;
    closeSurfaceAdmission(state);
    destroySurfaceNow(state, 1);
    host.destroy_surface_depth -= 1;
    const host_deinitialized = finishDeferredHostDeinitialize(host, 1);
    releaseSurfaceAdmission(&admission);
    if (!host_deinitialized and
        !state.storage_retained and
        state.active_dispatches == 0)
    {
        deinitSurfaceResources(state);
        allocator.destroy(state);
    }
    if (host_deinitialized) allocator.destroy(host);
    return result_ok;
}

pub export fn winghostty_surface_set_bounds(
    surface: ?*Surface,
    bounds: ?*const Rect,
) Result {
    const next = bounds orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (next.width > std.math.maxInt(i32) or next.height > std.math.maxInt(i32)) {
        releaseSurfaceAdmission(&admission);
        return result_invalid_argument;
    }
    state.options_mutex.lock();
    state.options.bounds = next.*;
    state.options_mutex.unlock();
    const hwnd = state.hwnd orelse {
        releaseSurfaceAdmission(&admission);
        return result_shutting_down;
    };
    releaseSurfaceAdmission(&admission);
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
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const next_visible: u8 = if (visible == 0) 0 else 1;
    state.options_mutex.lock();
    state.options.visible = next_visible;
    state.options_mutex.unlock();
    if (state.uia) |provider| provider.updateVisibility(next_visible != 0);
    const hwnd = state.hwnd orelse {
        releaseSurfaceAdmission(&admission);
        return result_shutting_down;
    };
    releaseSurfaceAdmission(&admission);
    _ = ShowWindow(hwnd, if (next_visible != 0) SW_SHOW else SW_HIDE);
    return result_ok;
}

pub export fn winghostty_surface_set_focus(
    surface: ?*Surface,
    focused: u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const next_focused: u8 = if (focused == 0) 0 else 1;
    state.options_mutex.lock();
    state.options.focus = next_focused;
    state.options_mutex.unlock();
    const hwnd = state.hwnd orelse {
        releaseSurfaceAdmission(&admission);
        return result_shutting_down;
    };
    releaseSurfaceAdmission(&admission);
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
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (theme < 0 or theme > 2) {
        releaseSurfaceAdmission(&admission);
        return result_invalid_argument;
    }
    state.options_mutex.lock();
    state.options.theme = theme;
    state.options_mutex.unlock();
    const hwnd = state.hwnd;
    releaseSurfaceAdmission(&admission);
    if (hwnd) |value| _ = InvalidateRect(value, null, 0);
    return result_ok;
}

pub export fn winghostty_surface_set_font_scale(
    surface: ?*Surface,
    font_scale: f32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (font_scale <= 0 or !std.math.isFinite(font_scale)) {
        releaseSurfaceAdmission(&admission);
        return result_invalid_argument;
    }
    state.options_mutex.lock();
    state.options.font_scale = font_scale;
    state.options_mutex.unlock();
    state.metrics = metricsFor(state);
    updateScreenOrigin(state);
    notifyMetrics(state);
    const hwnd = state.hwnd;
    releaseSurfaceAdmission(&admission);
    if (hwnd) |value| _ = InvalidateRect(value, null, 0);
    return result_ok;
}

pub export fn winghostty_surface_set_cell_metrics(
    surface: ?*Surface,
    metrics: ?*const CellMetrics,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const next = metrics orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (!beginSurfaceOperation(state)) return result_surface_invalidated;
    defer endSurfaceOperation(state);
    if (next.font_width == 0 or next.font_height == 0 or
        next.cell_width == 0 or next.cell_height == 0 or
        next.baseline > next.font_height)
    {
        return result_invalid_argument;
    }
    state.base_metrics = next.*;
    state.metrics = metricsFor(state);
    updateScreenOrigin(state);
    notifyMetrics(state);
    if (state.destroying.load(.acquire) or
        state.host.shutting_down.load(.acquire))
    {
        return result_ok;
    }
    if (state.hwnd) |hwnd| _ = InvalidateRect(hwnd, null, 0);
    return result_ok;
}

pub export fn winghostty_surface_get_cell_metrics(
    surface: ?*const Surface,
    out_metrics: ?*CellMetrics,
) Result {
    var admission = admitSurface(@constCast(surface)) orelse
        return unavailableSurfaceResult(@constCast(surface));
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const output = out_metrics orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    output.* = .{
        .font_width = state.metrics.font_width,
        .font_height = state.metrics.font_height,
        .cell_width = state.metrics.cell_width,
        .cell_height = state.metrics.cell_height,
        .baseline = state.metrics.baseline,
    };
    return result_ok;
}

pub export fn winghostty_surface_get_dpi(surface: ?*const Surface) u32 {
    var admission = admitSurface(@constCast(surface)) orelse return 0;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (checkSurface(state) != result_ok) return 0;
    return state.dpi;
}

pub export fn winghostty_surface_notify_dpi_changed(
    surface: ?*Surface,
    dpi: u32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (dpi == 0) return result_invalid_argument;
    updateDpi(state, dpi);
    return result_ok;
}

pub export fn winghostty_surface_make_current(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkRenderSurface(state);
    if (result != result_ok) return result;
    const render_result = claimRenderThread(state.host);
    if (render_result != result_ok) return render_result;
    const renderer = beginRendererOperation(state) orelse
        return if (state.host.shutting_down.load(.acquire))
            result_shutting_down
        else
            result_surface_invalidated;
    defer endRendererOperation(state);
    renderer.makeCurrent() catch |err| return rendererResult(state, err);
    return result_ok;
}

pub export fn winghostty_surface_clear_current(surface: ?*Surface) Result {
    var admission = admitClearSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    state.host.render_thread_mutex.lock();
    const render_thread_id = state.host.render_thread_id;
    state.host.render_thread_mutex.unlock();
    if (GetCurrentThreadId() != render_thread_id) {
        return result_wrong_thread;
    }
    const renderer = beginClearRendererOperation(state) orelse
        return result_surface_invalidated;
    defer endRendererOperation(state);
    renderer.clearCurrent();
    return result_ok;
}

pub export fn winghostty_surface_render(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (state.invalidated.load(.acquire) or
        state.destroying.load(.acquire))
    {
        return result_surface_invalidated;
    }
    const render_result = claimRenderThread(state.host);
    if (render_result != result_ok) return render_result;
    const renderer = beginRendererOperation(state) orelse
        return if (state.host.shutting_down.load(.acquire))
            result_shutting_down
        else
            result_surface_invalidated;
    defer endRendererOperation(state);

    state.options_mutex.lock();
    const render_state = win32_presentation.RenderState{
        .theme = @enumFromInt(state.options.theme),
        .font_scale = state.options.font_scale,
        .width = state.options.bounds.width,
        .height = state.options.bounds.height,
    };
    state.options_mutex.unlock();

    win32_presentation.render(renderer, render_state) catch |err| {
        return rendererResult(state, err);
    };
    _ = state.present_count.fetchAdd(1, .release);
    return result_ok;
}

pub export fn winghostty_surface_present(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (state.invalidated.load(.acquire) or
        state.destroying.load(.acquire))
    {
        return result_surface_invalidated;
    }
    const render_result = claimRenderThread(state.host);
    if (render_result != result_ok) return render_result;
    const renderer = beginRendererOperation(state) orelse
        return if (state.host.shutting_down.load(.acquire))
            result_shutting_down
        else
            result_surface_invalidated;
    defer endRendererOperation(state);
    win32_presentation.present(renderer) catch |err| {
        return rendererResult(state, err);
    };
    _ = state.present_count.fetchAdd(1, .release);
    return result_ok;
}

fn pasteSeverity(text: []const u8) u32 {
    return switch (paste_protection.inspect(text).severity) {
        .safe => 0,
        .contains_newline => 1,
        .shell_metachar => 2,
        .control_chars => 3,
        .mixed_content => 4,
    };
}

fn bracketPaste(alloc: Allocator, text: []const u8) ![]u8 {
    const prefix = "\x1b[200~";
    const suffix = "\x1b[201~";
    var result = try alloc.alloc(u8, prefix.len + text.len + suffix.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len .. prefix.len + text.len], text);
    @memcpy(result[prefix.len + text.len ..], suffix);
    return result;
}

fn clipboardFormatId(format: u32) u32 {
    if (format == clipboard_html) {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("HTML Format");
        return RegisterClipboardFormatW(name);
    }
    return CF_UNICODETEXT;
}

fn clipboardBytes(format: u32) ?[]u8 {
    const id = clipboardFormatId(format);
    const preferred = GetClipboardData(id);
    const using_html = preferred != null and format == clipboard_html;
    const handle = preferred orelse if (format == clipboard_html)
        GetClipboardData(CF_UNICODETEXT)
    else
        null;
    const value = handle orelse return null;
    const raw = GlobalLock(value) orelse return null;
    defer _ = GlobalUnlock(value);
    const bytes = GlobalSize(value);
    if (bytes == 0) return null;
    if (using_html) {
        return allocator.dupe(u8, @as([*]const u8, @ptrCast(raw))[0..bytes]) catch null;
    }
    const units = @as([*]const u16, @ptrCast(@alignCast(raw)));
    var count: usize = 0;
    while (count * 2 + 1 < bytes and units[count] != 0) : (count += 1) {}
    return utf16ToUtf8(allocator, units[0..count]) catch null;
}

fn setClipboardGlobal(format: u32, bytes: []const u8, utf16: bool) bool {
    const size = if (utf16) (bytes.len + 1) * 2 else bytes.len + 1;
    const memory = GlobalAlloc(GMEM_MOVEABLE, size) orelse return false;
    const target = GlobalLock(memory) orelse {
        _ = GlobalFree(memory);
        return false;
    };
    if (utf16) {
        const units = @as([*]u16, @ptrCast(@alignCast(target)));
        var index: usize = 0;
        var iterator = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint <= 0xffff) {
                units[index] = @intCast(codepoint);
                index += 1;
            } else {
                const value = codepoint - 0x10000;
                units[index] = @intCast(0xD800 + (value >> 10));
                units[index + 1] = @intCast(0xDC00 + (value & 0x3ff));
                index += 2;
            }
        }
        units[index] = 0;
    } else {
        const target_bytes = @as([*]u8, @ptrCast(target));
        @memcpy(target_bytes[0..bytes.len], bytes);
        target_bytes[bytes.len] = 0;
    }
    _ = GlobalUnlock(memory);
    if (SetClipboardData(format, memory) == null) {
        _ = GlobalFree(memory);
        return false;
    }
    return true;
}

pub export fn winghostty_paste_validate(
    text: ?[*]const u8,
    length: u32,
) u32 {
    const source = text orelse return 3;
    if (length > max_input_text_bytes) return 3;
    return pasteSeverity(source[0..length]);
}

pub export fn winghostty_surface_paste_text(
    surface: ?*Surface,
    text: ?[*]const u8,
    length: u32,
    allow_unsafe: u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const source = text orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (length > max_input_text_bytes) return result_invalid_argument;
    const bytes = source[0..length];
    if (!std.unicode.utf8ValidateSlice(bytes)) return result_invalid_utf8;
    const severity = pasteSeverity(bytes);
    if (state.options.input.paste_protection != 0 and severity != 0 and allow_unsafe == 0) {
        return result_paste_requires_confirmation;
    }
    const bracketed = state.options.input.bracketed_paste != 0;
    const payload = if (bracketed) bracketPaste(allocator, bytes) catch
        return result_out_of_memory else allocator.dupe(u8, bytes) catch return result_out_of_memory;
    defer allocator.free(payload);
    emitPaste(state, payload, bracketed);
    return result_ok;
}

pub export fn winghostty_surface_read_clipboard(
    surface: ?*Surface,
    format: u32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (format != clipboard_text and format != clipboard_html) {
        return result_invalid_argument;
    }
    if (OpenClipboard(state.parent) == 0) return result_clipboard_unavailable;
    defer _ = CloseClipboard();
    const value = clipboardBytes(format) orelse return result_win32_error;
    defer allocator.free(value);
    emitClipboardRead(state, format, value);
    return result_ok;
}

pub export fn winghostty_surface_write_clipboard(
    surface: ?*Surface,
    format: u32,
    text: ?[*]const u8,
    length: u32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const source = text orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (length > max_input_text_bytes) return result_invalid_argument;
    if (format != clipboard_text and format != clipboard_html) {
        return result_invalid_argument;
    }
    const bytes = source[0..length];
    if (!std.unicode.utf8ValidateSlice(bytes)) return result_invalid_utf8;
    if (OpenClipboard(state.parent) == 0) return result_clipboard_unavailable;
    defer _ = CloseClipboard();
    if (EmptyClipboard() == 0) return result_win32_error;
    if (format == clipboard_html) {
        const wrapped = win32_clipboard_html.wrapFragment(allocator, bytes) catch
            return result_out_of_memory;
        defer allocator.free(wrapped);
        const id = clipboardFormatId(format);
        if (!setClipboardGlobal(id, wrapped, false)) return result_win32_error;
        if (!setClipboardGlobal(CF_UNICODETEXT, bytes, true)) return result_win32_error;
    } else {
        if (!setClipboardGlobal(CF_UNICODETEXT, bytes, true)) return result_win32_error;
    }
    emitClipboardWrite(state, format, bytes);
    return result_ok;
}

pub export fn winghostty_surface_clipboard_read(
    surface: ?*Surface,
    format: u32,
) Result {
    return winghostty_surface_read_clipboard(surface, format);
}

pub export fn winghostty_surface_clipboard_write(
    surface: ?*Surface,
    format: u32,
    text: ?[*]const u8,
    length: u32,
) Result {
    return winghostty_surface_write_clipboard(surface, format, text, length);
}

pub export fn winghostty_surface_set_keyboard_layout(
    surface: ?*Surface,
    keyboard_layout: usize,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    state.keyboard_layout = if (keyboard_layout == 0)
        GetKeyboardLayout(0)
    else
        @ptrFromInt(keyboard_layout);
    return result_ok;
}

pub export fn winghostty_surface_ime_update(
    surface: ?*Surface,
    text: ?[*]const u8,
    length: u32,
    committed: u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const source = text orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (length > max_input_text_bytes) return result_invalid_argument;
    const bytes = source[0..length];
    if (!std.unicode.utf8ValidateSlice(bytes)) return result_invalid_utf8;
    state.ime_composing = committed == 0;
    emitImeUpdate(state, bytes, committed != 0);
    return result_ok;
}

pub export fn winghostty_surface_set_link(
    surface: ?*Surface,
    url: ?[*:0]const u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const value = url orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (std.mem.span(value).len == 0) return result_invalid_argument;
    const owned = allocator.dupeZ(u8, std.mem.span(value)) catch return result_out_of_memory;
    if (state.link_url) |old| allocator.free(old);
    state.link_url = owned;
    state.link_hovered = false;
    return result_ok;
}

pub export fn winghostty_surface_clear_link(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.link_url) |old| allocator.free(old);
    state.link_url = null;
    if (state.link_hovered) {
        state.link_hovered = false;
        emitLink(state, false, false);
    }
    return result_ok;
}

pub export fn winghostty_surface_set_selection_text(
    surface: ?*Surface,
    text: ?[*]const u8,
    length: u32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const source = text orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (length > max_input_text_bytes) return result_invalid_argument;
    const bytes = source[0..length];
    if (!std.unicode.utf8ValidateSlice(bytes)) return result_invalid_utf8;
    const owned = allocator.dupeZ(u8, bytes) catch return result_out_of_memory;
    if (state.selection_text) |old| allocator.free(old);
    state.selection_text = owned;
    state.selection_active = bytes.len != 0;
    emitSelection(state);
    return result_ok;
}

pub export fn winghostty_surface_clear_selection(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.selection_text) |old| allocator.free(old);
    state.selection_text = null;
    state.selection_active = false;
    state.selection_dragging = false;
    emitSelection(state);
    return result_ok;
}

pub export fn winghostty_surface_copy_selection(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    const text = state.selection_text orelse return result_invalid_argument;
    return winghostty_surface_write_clipboard(
        surface,
        clipboard_text,
        text.ptr,
        @intCast(text.len),
    );
}

pub export fn winghostty_surface_notify_exit(
    surface: ?*Surface,
    status: i32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_exit;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |value| {
        beginDispatch(state);
        defer endDispatch(state);
        value(user_data, handle, status);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_title(
    surface: ?*Surface,
    title: ?[*:0]const u8,
) Result {
    const value = title orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (state.uia) |provider| {
        provider.updateName(std.mem.span(value)) catch |err| {
            releaseSurfaceAdmission(&admission);
            return switch (err) {
                error.OutOfMemory => result_out_of_memory,
                else => result_surface_invalidated,
            };
        };
    }
    const callback = state.options.callbacks.on_title;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |callback_value| {
        beginDispatch(state);
        defer endDispatch(state);
        callback_value(user_data, handle, value);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_cwd(
    surface: ?*Surface,
    cwd: ?[*:0]const u8,
) Result {
    const value = cwd orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_cwd;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |callback_value| {
        beginDispatch(state);
        defer endDispatch(state);
        callback_value(user_data, handle, value);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_bell(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_bell;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |value| {
        beginDispatch(state);
        defer endDispatch(state);
        value(user_data, handle);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_notification(
    surface: ?*Surface,
    notification: ?[*:0]const u8,
) Result {
    const value = notification orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_notification;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |callback_value| {
        beginDispatch(state);
        defer endDispatch(state);
        callback_value(user_data, handle, value);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_redraw(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_redraw;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |value| {
        beginDispatch(state);
        defer endDispatch(state);
        value(user_data, handle);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_focus(
    surface: ?*Surface,
    focused: u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_focus;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |value| {
        beginDispatch(state);
        defer endDispatch(state);
        value(user_data, handle, if (focused == 0) 0 else 1);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_fatal_error(
    surface: ?*Surface,
    result_code: Result,
    message: ?[*:0]const u8,
) Result {
    const value = message orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_fatal_error;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |callback_value| {
        beginDispatch(state);
        defer endDispatch(state);
        callback_value(user_data, handle, result_code, value);
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_accessibility_name(
    surface: ?*Surface,
    name: ?[*:0]const u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const value = name orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.uia) |provider| {
        provider.updateName(std.mem.span(value)) catch |err| return switch (err) {
            error.OutOfMemory => result_out_of_memory,
            else => result_surface_invalidated,
        };
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_accessibility_text(
    surface: ?*Surface,
    text: ?[*]const u8,
    text_length: u64,
    visible_start: u64,
    visible_end: u64,
    selection_start: u64,
    selection_end: u64,
    caret: u64,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    const length = std.math.cast(usize, text_length) orelse return result_invalid_argument;
    const value = if (text) |ptr|
        ptr[0..length]
    else if (length == 0)
        &.{}
    else
        return result_invalid_argument;
    const visible = host_uia.Range{
        .start = std.math.cast(usize, visible_start) orelse return result_invalid_argument,
        .end = std.math.cast(usize, visible_end) orelse return result_invalid_argument,
    };
    const selection = host_uia.Range{
        .start = std.math.cast(usize, selection_start) orelse return result_invalid_argument,
        .end = std.math.cast(usize, selection_end) orelse return result_invalid_argument,
    };
    if (state.uia) |provider| {
        provider.updateText(
            value[0..length],
            visible,
            selection,
            std.math.cast(usize, caret) orelse return result_invalid_argument,
        ) catch |err| return switch (err) {
            error.OutOfMemory => result_out_of_memory,
            error.InvalidUtf8 => result_invalid_argument,
            else => result_surface_invalidated,
        };
    }
    return result_ok;
}

pub export fn winghostty_surface_notify_terminal_text(
    surface: ?*Surface,
    text: ?[*]const u8,
    text_length: u64,
    visible_start: u64,
    visible_end: u64,
    selection_start: u64,
    selection_end: u64,
    caret: u64,
) Result {
    return winghostty_surface_notify_accessibility_text(
        surface,
        text,
        text_length,
        visible_start,
        visible_end,
        selection_start,
        selection_end,
        caret,
    );
}

pub export fn winghostty_surface_notify_accessibility_focus(
    surface: ?*Surface,
    focused: u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    if (state.uia) |provider| provider.updateFocus(focused != 0);
    return result_ok;
}

pub export fn winghostty_surface_set_accessibility_role(
    surface: ?*Surface,
    role: i32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    const value: host_uia.Role = switch (role) {
        0 => .terminal,
        1 => .edit,
        else => return result_invalid_argument,
    };
    if (state.uia) |provider| provider.updateRole(value);
    return result_ok;
}

pub export fn winghostty_surface_copy_accessibility_range(
    surface: ?*Surface,
    start: u64,
    end: u64,
    buffer: ?[*]u8,
    buffer_length: u64,
    out_written: ?*u64,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const output_length = out_written orelse return result_invalid_argument;
    const result = checkSurface(state);
    if (result != result_ok) return result;
    const range = host_uia.Range{
        .start = std.math.cast(usize, start) orelse return result_invalid_argument,
        .end = std.math.cast(usize, end) orelse return result_invalid_argument,
    };
    const copy = if (state.uia) |provider|
        provider.copyRangeUtf8(range, allocator) catch |err| return switch (err) {
            error.OutOfMemory => result_out_of_memory,
            else => result_surface_invalidated,
        }
    else
        return result_surface_invalidated;
    defer allocator.free(copy);
    output_length.* = copy.len;
    const capacity = std.math.cast(usize, buffer_length) orelse return result_invalid_argument;
    if (copy.len > capacity) return result_invalid_argument;
    if (copy.len != 0) {
        const destination = buffer orelse return result_invalid_argument;
        @memcpy(destination[0..copy.len], copy);
    }
    return result_ok;
}

pub export fn winghostty_surface_get_hwnd(surface: ?*const Surface) ?HWND {
    var admission = admitSurface(@constCast(surface)) orelse return null;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (checkSurface(state) != result_ok or
        state.destroying.load(.acquire))
    {
        return null;
    }
    return state.hwnd;
}

pub export fn winghostty_surface_get_hdc(surface: ?*const Surface) HDC {
    var admission = admitSurface(@constCast(surface)) orelse return null;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    return rendererHdc(state);
}

pub export fn winghostty_surface_get_hglrc(surface: ?*const Surface) HGLRC {
    var admission = admitSurface(@constCast(surface)) orelse return null;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    return rendererHglrc(state);
}

pub export fn winghostty_host_get_ui_thread_id(host: ?*const Host) DWORD {
    var admission = admitHost(@constCast(host)) orelse return 0;
    defer releaseHostAdmission(&admission);
    const state = admission.state;
    if (state.shutting_down.load(.acquire)) return 0;
    return state.thread_id;
}

pub export fn winghostty_host_get_render_thread_id(host: ?*const Host) DWORD {
    var admission = admitHost(@constCast(host)) orelse return 0;
    defer releaseHostAdmission(&admission);
    const state = admission.state;
    if (state.shutting_down.load(.acquire)) return 0;
    state.render_thread_mutex.lock();
    defer state.render_thread_mutex.unlock();
    return state.render_thread_id;
}

pub export fn winghostty_surface_get_last_error(
    surface: ?*const Surface,
) DWORD {
    var admission = admitSurface(@constCast(surface)) orelse return 0;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (state.host.shutting_down.load(.acquire) or
        state.invalidated.load(.acquire) or
        state.destroying.load(.acquire))
    {
        return 0;
    }
    return loadRendererError(state);
}

pub export fn winghostty_surface_get_present_count(
    surface: ?*const Surface,
) u64 {
    var admission = admitSurface(@constCast(surface)) orelse return 0;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (state.host.shutting_down.load(.acquire) or
        state.invalidated.load(.acquire) or
        state.destroying.load(.acquire))
    {
        return 0;
    }
    return state.present_count.load(.acquire);
}

pub export fn winghostty_host_drain(
    host: ?*Host,
    out_drained: ?*u32,
) Result {
    var admission = admitHost(host) orelse
        return unavailableHostResult(host);
    defer releaseHostAdmission(&admission);
    const state = admission.state;
    const result = checkHost(state);
    if (result != result_ok) return result;
    if (out_drained) |count| count.* = 0;
    return result_ok;
}

test "SurfaceOptions copies caller-owned strings" {
    var command = [_:0]u8{ 'c', 'm', 'd', '.', 'e', 'x', 'e' };
    var cwd = [_:0]u8{ 'C', ':', '\\' };
    var environment = [_:0]u8{ 'A', '=', 'B' };
    var options = defaultSurfaceOptions();
    options.command = &command;
    options.cwd = &cwd;
    options.environment = &environment;
    var owned = try OwnedOptions.init(&options);
    defer owned.deinit();
    command[0] = 'X';
    try std.testing.expectEqualStrings("cmd.exe", owned.command.?);
    try std.testing.expectEqualStrings("C:\\", owned.cwd.?);
    try std.testing.expectEqualStrings("A=B", owned.environment.?);
}

test "retired surface retention survives allocator failure" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(error.OutOfMemory, failing.allocator().alloc(u8, 1));

    var host: HostState = undefined;
    host.retired_surfaces = null;
    var first: SurfaceState = undefined;
    var second: SurfaceState = undefined;
    retainRetiredSurface(&host, &first);
    retainRetiredSurface(&host, &second);
    try std.testing.expectEqual(@as(?*SurfaceState, &second), host.retired_surfaces);
    try std.testing.expectEqual(@as(?*SurfaceState, &first), second.retired_next);
}

test "selection dispatch retains state across owner-thread teardown" {
    var dispatch = try SelectionDispatch.create(@ptrFromInt(1));
    const retained = dispatch.acquire().?;
    dispatch.deactivate();
    try std.testing.expect(!retained.isActive());
    retained.release();
}

test "provider-owned selection dispatch survives teardown before invoke" {
    var dispatch = try SelectionDispatch.create(@ptrFromInt(1));
    var provider = try host_uia.SurfaceProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .{
            .callback_ctx = dispatch,
            .callback_ctx_retain = SelectionDispatch.retainContext,
            .callback_ctx_release = SelectionDispatch.releaseContext,
            .on_selection = gatedAccessibilitySelection,
        },
    );
    var gate = SelectionDispatchTestGate{};
    selection_dispatch_test_gate = &gate;
    defer selection_dispatch_test_gate = null;

    const selection_thread = try std.Thread.spawn(.{}, struct {
        fn run(value: *host_uia.SurfaceProvider) void {
            _ = value.setSelectedRange(.{ .start = 0, .end = 0 });
        }
    }.run, .{provider});
    while (!gate.entered.load(.acquire)) std.Thread.yield() catch {};

    provider.detach();
    dispatch.deactivate();
    gate.allow.store(true, .release);
    selection_thread.join();
    _ = host_uia.SurfaceProvider.Release(&provider.base);
}

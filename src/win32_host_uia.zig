//! Standalone UI Automation provider for an embeddable terminal surface.
//!
//! This module deliberately depends only on the Win32 UIA ABI declarations.
//! It does not reach into the renderer, terminal, input, clipboard, or
//! product runtime. The host updates the provider with immutable UTF-8
//! snapshots and UTF-16 selection offsets.

const std = @import("std");
const builtin = @import("builtin");
const com = @import("apprt/win32_uia/com.zig");

extern "user32" fn IsWindow(hwnd: com.HWND) callconv(.winapi) com.BOOL;
pub const ScreenOrigin = extern struct {
    x: i32,
    y: i32,
};
extern "user32" fn ClientToScreen(
    hwnd: com.HWND,
    point: *ScreenOrigin,
) callconv(.winapi) com.BOOL;
extern "kernel32" fn CompareStringOrdinal(
    first: [*]const u16,
    first_length: i32,
    second: [*]const u16,
    second_length: i32,
    ignore_case: com.BOOL,
) callconv(.winapi) i32;
pub const ScreenOriginQuery = *const fn (com.HWND) ?ScreenOrigin;

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn normalized(self: Range, limit: usize) Range {
        return .{
            .start = @min(self.start, limit),
            .end = @min(@max(self.end, self.start), limit),
        };
    }
};

pub const Role = enum {
    terminal,
    edit,
};

pub const Metrics = struct {
    /// Geometry is expressed in terminal grid cells. Text ranges convert
    /// Unicode scalars to display-cell columns before applying these metrics.
    cell_width: f64 = 8,
    cell_height: f64 = 16,
    origin_x: f64 = 0,
    origin_y: f64 = 0,
};

pub const SelectionCallback = *const fn (
    ctx: *anyopaque,
    start: usize,
    end: usize,
) void;
pub const SelectionContextRetain = *const fn (ctx: *anyopaque) void;
pub const SelectionContextRelease = *const fn (ctx: *anyopaque) void;

pub const Config = struct {
    name: []const u8 = "Terminal",
    text: []const u8 = "",
    visible_range: Range = .{ .start = 0, .end = 0 },
    selection: Range = .{ .start = 0, .end = 0 },
    caret: usize = 0,
    role: Role = .terminal,
    focused: bool = false,
    visible: bool = true,
    metrics: Metrics = .{},
    screen_origin_query: ?ScreenOriginQuery = null,
    callback_ctx: ?*anyopaque = null,
    callback_ctx_retain: ?SelectionContextRetain = null,
    callback_ctx_release: ?SelectionContextRelease = null,
    on_selection: ?SelectionCallback = null,
};

fn boundingRectangle(
    metrics: Metrics,
    line_index: usize,
    line_column: usize,
    line_width: usize,
) com.UiaRect {
    return .{
        .left = metrics.origin_x +
            metrics.cell_width * @as(f64, @floatFromInt(line_column)),
        .top = metrics.origin_y +
            metrics.cell_height * @as(f64, @floatFromInt(line_index)),
        .width = metrics.cell_width *
            @as(f64, @floatFromInt(@max(line_width, 1))),
        .height = metrics.cell_height,
    };
}

fn lineIndexAtByte(snapshot: *const Snapshot, byte_index: usize) usize {
    var row: usize = 0;
    for (snapshot.text[0..@min(byte_index, snapshot.text.len)]) |byte| {
        if (byte == '\n') row += 1;
    }
    return row;
}

fn lineStartAtByte(snapshot: *const Snapshot, byte_index: usize) usize {
    var start = @min(byte_index, snapshot.text.len);
    while (start > 0 and snapshot.text[start - 1] != '\n') start -= 1;
    return start;
}

const DecodedCodepoint = struct {
    value: u21,
    byte_len: usize,
};

fn decodeCodepoint(text: []const u8, byte_index: usize) DecodedCodepoint {
    const byte_len = std.unicode.utf8ByteSequenceLength(text[byte_index]) catch 1;
    return .{
        .value = std.unicode.utf8Decode(text[byte_index .. byte_index + byte_len]) catch 0xfffd,
        .byte_len = byte_len,
    };
}

fn testDisplayCellWidth(codepoint: u21) usize {
    if (codepoint < 0x20 or codepoint == 0x7f or
        codepoint == 0x0301 or codepoint == 0x200d or codepoint == 0xfe0f) return 0;
    if ((codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        codepoint == 0x1b000 or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff)) return 2;
    return 1;
}

fn displayCellWidth(codepoint: u21) usize {
    if (comptime builtin.is_test) return testDisplayCellWidth(codepoint);
    const uucode = @import("uucode");
    if (codepoint > uucode.config.max_code_point) return 1;
    return @intCast(uucode.get(.width, @intCast(codepoint)));
}

fn displayCellWidthRange(text: []const u8, start: usize, end: usize) usize {
    var width: usize = 0;
    var index = start;
    while (index < end) {
        const decoded = decodeCodepoint(text, index);
        width += displayCellWidth(decoded.value);
        index += decoded.byte_len;
    }
    return width;
}

fn lineColumnAtByte(
    snapshot: *const Snapshot,
    byte_index: usize,
    anchor_combining: bool,
) usize {
    const line_start = lineStartAtByte(snapshot, byte_index);
    const clamped = @min(byte_index, snapshot.text.len);
    const column = displayCellWidthRange(
        snapshot.text,
        line_start,
        clamped,
    );
    if (anchor_combining and clamped < snapshot.text.len) {
        const current = decodeCodepoint(snapshot.text, clamped);
        const is_control = current.value < 0x20 or current.value == 0x7f;
        if (!is_control and displayCellWidth(current.value) == 0 and column > 0) {
            var previous = line_start;
            var previous_width: usize = 0;
            while (previous < clamped) {
                const decoded = decodeCodepoint(snapshot.text, previous);
                const width = displayCellWidth(decoded.value);
                if (width != 0) previous_width = width;
                previous += decoded.byte_len;
            }
            return column - previous_width;
        }
    }
    return column;
}

fn lineDisplayCellWidth(snapshot: *const Snapshot, row: usize) usize {
    var current_row: usize = 0;
    var width: usize = 0;
    var index: usize = 0;
    while (index < snapshot.text.len) {
        if (snapshot.text[index] == '\n') {
            if (current_row == row) return width;
            current_row += 1;
            width = 0;
            index += 1;
            continue;
        }
        const decoded = decodeCodepoint(snapshot.text, index);
        if (current_row == row) width += displayCellWidth(decoded.value);
        index += decoded.byte_len;
    }
    return if (current_row == row) width else 0;
}

fn cellCoordinate(value: f64, origin: f64, cell_size: f64, limit: usize) usize {
    const coordinate = @floor((value - origin) / cell_size);
    if (!std.math.isFinite(coordinate)) return if (coordinate > 0) limit else 0;
    if (coordinate <= 0) return 0;
    const limit_float = @as(f64, @floatFromInt(limit));
    if (coordinate >= limit_float) return limit;
    return @intFromFloat(coordinate);
}

const Snapshot = struct {
    text: []u8,
    utf16_for_byte: []usize,
    utf16_len: usize,
    visible: Range,
    selection: Range,
    caret: usize,
    metrics: Metrics,

    fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.utf16_for_byte);
        alloc.free(self.text);
        self.* = undefined;
    }

    fn byteForUtf16(self: *const Snapshot, offset: usize) usize {
        const clamped = @min(offset, self.utf16_len);
        for (0..self.text.len + 1) |index| {
            if (self.utf16_for_byte[index] >= clamped) return index;
        }
        return self.text.len;
    }

    fn utf16RangeToBytes(self: *const Snapshot, range: Range) Range {
        const normalized = range.normalized(self.utf16_len);
        return .{
            .start = self.byteForUtf16(normalized.start),
            .end = self.byteForUtf16(normalized.end),
        };
    }
};

fn snapshotFromUtf8(
    alloc: std.mem.Allocator,
    text: []const u8,
    visible: Range,
    selection: Range,
    caret: usize,
    metrics: Metrics,
) !Snapshot {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const owned_text = try alloc.dupe(u8, text);
    errdefer alloc.free(owned_text);
    const map = try alloc.alloc(usize, text.len + 1);
    errdefer alloc.free(map);

    var byte_index: usize = 0;
    var utf16_index: usize = 0;
    while (byte_index < text.len) {
        const sequence_len = try std.unicode.utf8ByteSequenceLength(text[byte_index]);
        const codepoint = try std.unicode.utf8Decode(
            text[byte_index .. byte_index + sequence_len],
        );
        @memset(map[byte_index .. byte_index + sequence_len], utf16_index);
        byte_index += sequence_len;
        utf16_index += if (codepoint <= 0xffff) 1 else 2;
    }
    map[text.len] = utf16_index;

    return .{
        .text = owned_text,
        .utf16_for_byte = map,
        .utf16_len = utf16_index,
        .visible = visible.normalized(utf16_index),
        .selection = selection.normalized(utf16_index),
        .caret = @min(caret, utf16_index),
        .metrics = metrics,
    };
}

fn snapshotClone(
    alloc: std.mem.Allocator,
    snapshot: *const Snapshot,
) !Snapshot {
    return snapshotFromUtf8(
        alloc,
        snapshot.text,
        snapshot.visible,
        snapshot.selection,
        snapshot.caret,
        snapshot.metrics,
    );
}

pub const SurfaceProvider = struct {
    base: com.IRawElementProviderSimple,
    value_iface: com.IValueProvider,
    text_iface: com.ITextProvider,
    text2_iface: com.ITextProvider2,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state_lock: std.Thread.RwLock,
    callback_lock: std.Thread.Mutex,
    callback_inflight: usize,
    lifetime_lock: std.Thread.Mutex,
    active_calls: usize,
    destroying: bool,
    name: []u8,
    snapshot: Snapshot,
    role: Role,
    focused: std.atomic.Value(bool),
    visible: std.atomic.Value(bool),
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),
    connected: std.atomic.Value(bool),
    screen_origin_query: ?ScreenOriginQuery,
    callback_ctx: ?*anyopaque,
    callback_ctx_retain: ?SelectionContextRetain,
    callback_ctx_release: ?SelectionContextRelease,
    on_selection: ?SelectionCallback,

    const simple_vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .get_ProviderOptions = getProviderOptions,
        .GetPatternProvider = GetPatternProvider,
        .GetPropertyValue = GetPropertyValue,
        .get_HostRawElementProvider = getHostRawElementProvider,
    };
    const value_vtbl: com.IValueProviderVtbl = .{
        .QueryInterface = ValueQueryInterface,
        .AddRef = ValueAddRef,
        .Release = ValueRelease,
        .SetValue = ValueSetValue,
        .get_Value = ValueGetValue,
        .get_IsReadOnly = ValueGetIsReadOnly,
    };
    const text_vtbl: com.ITextProviderVtbl = .{
        .QueryInterface = TextQueryInterface,
        .AddRef = TextAddRef,
        .Release = TextRelease,
        .GetSelection = TextGetSelection,
        .GetVisibleRanges = TextGetVisibleRanges,
        .RangeFromChild = TextRangeFromChild,
        .RangeFromPoint = TextRangeFromPoint,
        .get_DocumentRange = TextGetDocumentRange,
        .get_SupportedTextSelection = TextGetSupportedTextSelection,
    };
    const text2_vtbl: com.ITextProvider2Vtbl = .{
        .QueryInterface = Text2QueryInterface,
        .AddRef = Text2AddRef,
        .Release = Text2Release,
        .GetSelection = Text2GetSelection,
        .GetVisibleRanges = Text2GetVisibleRanges,
        .RangeFromChild = Text2RangeFromChild,
        .RangeFromPoint = Text2RangeFromPoint,
        .get_DocumentRange = Text2GetDocumentRange,
        .get_SupportedTextSelection = Text2GetSupportedTextSelection,
        .RangeFromAnnotation = Text2RangeFromAnnotation,
        .GetCaretRange = Text2GetCaretRange,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        config: Config,
    ) !*SurfaceProvider {
        const name = try alloc.dupe(u8, config.name);
        const snapshot = snapshotFromUtf8(
            alloc,
            config.text,
            config.visible_range,
            config.selection,
            config.caret,
            config.metrics,
        ) catch |err| {
            alloc.free(name);
            return err;
        };
        const self = alloc.create(SurfaceProvider) catch |err| {
            var owned = snapshot;
            owned.deinit(alloc);
            alloc.free(name);
            return err;
        };
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .value_iface = .{ .vtbl = &value_vtbl },
            .text_iface = .{ .vtbl = &text_vtbl },
            .text2_iface = .{ .vtbl = &text2_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .state_lock = .{},
            .callback_lock = .{},
            .callback_inflight = 0,
            .lifetime_lock = .{},
            .active_calls = 0,
            .destroying = false,
            .name = name,
            .snapshot = snapshot,
            .role = config.role,
            .focused = std.atomic.Value(bool).init(config.focused),
            .visible = std.atomic.Value(bool).init(config.visible),
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
            .connected = std.atomic.Value(bool).init(false),
            .screen_origin_query = config.screen_origin_query,
            .callback_ctx = config.callback_ctx,
            .callback_ctx_retain = config.callback_ctx_retain,
            .callback_ctx_release = config.callback_ctx_release,
            .on_selection = config.on_selection,
        };
        if (config.callback_ctx) |ctx| {
            if (config.callback_ctx_retain) |retain| retain(ctx);
        }
        return self;
    }

    const CallGuard = struct {
        provider: *SurfaceProvider,

        fn deinit(self: *CallGuard) void {
            self.provider.lifetime_lock.lock();
            self.provider.active_calls -= 1;
            const destroy = self.provider.active_calls == 0 and
                self.provider.destroying and
                self.provider.refcount.load(.acquire) == 0;
            self.provider.lifetime_lock.unlock();
            if (destroy) self.provider.destroyStorage();
        }
    };

    fn beginCall(self: *SurfaceProvider) ?CallGuard {
        self.lifetime_lock.lock();
        defer self.lifetime_lock.unlock();
        if (self.destroying or self.detached.load(.acquire)) return null;
        self.active_calls += 1;
        return .{ .provider = self };
    }

    fn snapshotCopy(self: *SurfaceProvider, alloc: std.mem.Allocator) !Snapshot {
        self.state_lock.lockShared();
        defer self.state_lock.unlockShared();
        return snapshotFromUtf8(
            alloc,
            self.snapshot.text,
            self.snapshot.visible,
            self.snapshot.selection,
            self.snapshot.caret,
            self.snapshot.metrics,
        );
    }

    pub fn detach(self: *SurfaceProvider) void {
        self.detached.store(true, .release);
        self.callback_lock.lock();
        const callback_ctx = self.callback_ctx;
        const callback_ctx_release = self.callback_ctx_release;
        self.on_selection = null;
        self.callback_ctx = null;
        self.callback_ctx_retain = null;
        self.callback_ctx_release = null;
        self.callback_lock.unlock();
        if (callback_ctx) |ctx| {
            if (callback_ctx_release) |release_ctx| release_ctx(ctx);
        }
    }

    pub fn disconnect(self: *SurfaceProvider) com.HRESULT {
        if (self.disconnected.load(.acquire)) return com.S_OK;
        if (!self.connected.load(.acquire)) {
            self.detach();
            self.disconnected.store(true, .release);
            return com.S_OK;
        }
        const hr = com.UiaDisconnectProvider(&self.base);
        if (hr == com.S_OK or
            hr == com.E_INVALIDARG or
            hr == com.UIA_E_ELEMENTNOTAVAILABLE)
        {
            self.connected.store(false, .release);
            self.disconnected.store(true, .release);
            self.detach();
            return com.S_OK;
        } else {
            self.connected.store(true, .release);
            self.detach();
        }
        return hr;
    }

    pub fn updateName(self: *SurfaceProvider, name: []const u8) !void {
        var call = self.beginCall() orelse return error.ElementNotAvailable;
        defer call.deinit();
        const owned = try self.alloc.dupe(u8, name);
        self.state_lock.lock();
        if (self.detached.load(.acquire)) {
            self.state_lock.unlock();
            self.alloc.free(owned);
            return error.ElementNotAvailable;
        }
        self.alloc.free(self.name);
        self.name = owned;
        self.state_lock.unlock();
        raiseNameChanged(self);
    }

    pub fn updateText(
        self: *SurfaceProvider,
        text: []const u8,
        visible: Range,
        next_selection: Range,
        caret: usize,
    ) !void {
        var call = self.beginCall() orelse return error.ElementNotAvailable;
        defer call.deinit();
        self.state_lock.lockShared();
        const metrics = self.snapshot.metrics;
        self.state_lock.unlockShared();
        const next = try snapshotFromUtf8(
            self.alloc,
            text,
            visible,
            next_selection,
            caret,
            metrics,
        );
        self.state_lock.lock();
        if (self.detached.load(.acquire)) {
            self.state_lock.unlock();
            var owned = next;
            owned.deinit(self.alloc);
            return error.ElementNotAvailable;
        }
        self.snapshot.deinit(self.alloc);
        self.snapshot = next;
        self.state_lock.unlock();
        raiseAutomationEvent(self, 20015);
        raiseAutomationEvent(self, 20014);
    }

    pub fn updateSelection(self: *SurfaceProvider, next_selection: Range, caret: usize) void {
        var call = self.beginCall() orelse return;
        defer call.deinit();
        self.state_lock.lock();
        if (self.detached.load(.acquire)) {
            self.state_lock.unlock();
            return;
        }
        const next = next_selection.normalized(self.snapshot.utf16_len);
        self.snapshot.selection = next;
        self.snapshot.caret = @min(caret, self.snapshot.utf16_len);
        self.state_lock.unlock();
        raiseAutomationEvent(self, 20014);
    }

    pub fn updateFocus(self: *SurfaceProvider, focused: bool) void {
        var call = self.beginCall() orelse return;
        defer call.deinit();
        if (self.detached.load(.acquire)) return;
        self.focused.store(focused, .release);
        raiseAutomationEvent(self, 20005);
    }

    pub fn updateVisibility(self: *SurfaceProvider, visible: bool) void {
        var call = self.beginCall() orelse return;
        defer call.deinit();
        if (self.detached.load(.acquire)) return;
        self.visible.store(visible, .release);
    }

    pub fn updateRole(self: *SurfaceProvider, role: Role) void {
        var call = self.beginCall() orelse return;
        defer call.deinit();
        self.state_lock.lock();
        if (self.detached.load(.acquire)) {
            self.state_lock.unlock();
            return;
        }
        const previous = self.role;
        if (previous == role) {
            self.state_lock.unlock();
            return;
        }
        self.role = role;
        self.state_lock.unlock();
        raiseRoleChanged(self, previous, role);
    }

    pub fn updateMetrics(self: *SurfaceProvider, metrics: Metrics) void {
        var call = self.beginCall() orelse return;
        defer call.deinit();
        self.state_lock.lock();
        if (self.detached.load(.acquire)) {
            self.state_lock.unlock();
            return;
        }
        self.snapshot.metrics = metrics;
        self.state_lock.unlock();
        raiseAutomationEvent(self, 20015);
    }

    pub fn textUtf8(self: *SurfaceProvider, alloc: std.mem.Allocator) ![]u8 {
        var call = self.beginCall() orelse return error.ElementNotAvailable;
        defer call.deinit();
        self.state_lock.lockShared();
        defer self.state_lock.unlockShared();
        return alloc.dupe(u8, self.snapshot.text);
    }

    pub fn selectionRange(self: *SurfaceProvider) Range {
        self.state_lock.lockShared();
        defer self.state_lock.unlockShared();
        return self.snapshot.selection;
    }

    pub fn copyRangeUtf8(
        self: *SurfaceProvider,
        range: Range,
        alloc: std.mem.Allocator,
    ) ![]u8 {
        var call = self.beginCall() orelse return error.ElementNotAvailable;
        defer call.deinit();
        self.state_lock.lockShared();
        defer self.state_lock.unlockShared();
        const bytes = self.snapshot.utf16RangeToBytes(range);
        return alloc.dupe(u8, self.snapshot.text[bytes.start..bytes.end]);
    }

    pub fn available(self: *const SurfaceProvider) bool {
        return !self.detached.load(.acquire);
    }

    fn refreshScreenOrigin(self: *SurfaceProvider) void {
        const origin_query = self.screen_origin_query;
        if (origin_query) |origin_fn| {
            if (origin_fn(self.hwnd)) |origin| {
                self.state_lock.lock();
                self.snapshot.metrics.origin_x = @floatFromInt(origin.x);
                self.snapshot.metrics.origin_y = @floatFromInt(origin.y);
                self.state_lock.unlock();
            }
            return;
        }
        var origin: ScreenOrigin = .{ .x = 0, .y = 0 };
        if (ClientToScreen(self.hwnd, &origin) != 0) {
            self.state_lock.lock();
            self.snapshot.metrics.origin_x = @floatFromInt(origin.x);
            self.snapshot.metrics.origin_y = @floatFromInt(origin.y);
            self.state_lock.unlock();
        }
    }

    fn fromBase(value: *com.IRawElementProviderSimple) *SurfaceProvider {
        return @fieldParentPtr("base", value);
    }
    fn fromValue(value: *com.IValueProvider) *SurfaceProvider {
        return @fieldParentPtr("value_iface", value);
    }
    fn fromText(value: *com.ITextProvider) *SurfaceProvider {
        return @fieldParentPtr("text_iface", value);
    }
    fn fromText2(value: *com.ITextProvider2) *SurfaceProvider {
        return @fieldParentPtr("text2_iface", value);
    }

    fn query(
        self: *SurfaceProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) com.HRESULT {
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
        } else if (iidEqual(iid, &com.IID_IValueProvider)) {
            self.state_lock.lockShared();
            const supported = self.role == .edit;
            self.state_lock.unlockShared();
            if (!supported) return com.E_NOINTERFACE;
            out.* = @ptrCast(&self.value_iface);
        } else if (iidEqual(iid, &com.IID_ITextProvider)) {
            out.* = @ptrCast(&self.text_iface);
        } else if (iidEqual(iid, &com.IID_ITextProvider2)) {
            out.* = @ptrCast(&self.text2_iface);
        } else {
            return com.E_NOINTERFACE;
        }
        _ = self.refcount.fetchAdd(1, .monotonic);
        return com.S_OK;
    }

    fn release(self: *SurfaceProvider) u32 {
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            self.lifetime_lock.lock();
            self.destroying = true;
            const destroy = self.active_calls == 0;
            self.lifetime_lock.unlock();
            if (destroy) self.destroyStorage();
            return 0;
        }
        return previous - 1;
    }

    fn destroyStorage(self: *SurfaceProvider) void {
        self.callback_lock.lock();
        const callback_ctx = self.callback_ctx;
        const callback_ctx_release = self.callback_ctx_release;
        self.callback_ctx = null;
        self.callback_ctx_retain = null;
        self.callback_ctx_release = null;
        self.on_selection = null;
        self.callback_lock.unlock();
        if (callback_ctx) |ctx| {
            if (callback_ctx_release) |release_ctx| release_ctx(ctx);
        }
        self.state_lock.lock();
        self.snapshot.deinit(self.alloc);
        self.alloc.free(self.name);
        self.state_lock.unlock();
        self.alloc.destroy(self);
    }

    fn propertyBstr(self: *SurfaceProvider, text: []const u8) ?com.BSTR {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, text) catch return null;
        defer self.alloc.free(wide);
        return com.SysAllocStringLen(wide.ptr, @intCast(wide.len));
    }

    fn controlType(role: Role) i32 {
        return if (role == .edit) 50004 else 50030;
    }

    fn localizedControlType(role: Role) []const u8 {
        return if (role == .edit) "edit" else "terminal document";
    }

    fn selectedRange(self: *const SurfaceProvider) Range {
        const current = self.snapshot.selection;
        return if (current.start == current.end)
            .{ .start = self.snapshot.caret, .end = self.snapshot.caret }
        else
            current;
    }

    fn makeRangeFromSnapshot(
        self: *SurfaceProvider,
        snapshot: *const Snapshot,
        range: Range,
    ) ?*SurfaceTextRangeProvider {
        var copy = snapshotClone(self.alloc, snapshot) catch return null;
        return SurfaceTextRangeProvider.createWithSnapshot(
            self.alloc,
            self,
            range,
            copy,
        ) catch {
            copy.deinit(self.alloc);
            return null;
        };
    }

    fn selectedRangeFromSnapshot(snapshot: *const Snapshot) Range {
        return if (snapshot.selection.start == snapshot.selection.end)
            .{ .start = snapshot.caret, .end = snapshot.caret }
        else
            snapshot.selection;
    }

    pub fn setSelectedRange(self: *SurfaceProvider, range: Range) com.HRESULT {
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        self.state_lock.lock();
        if (self.detached.load(.acquire)) {
            self.state_lock.unlock();
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        }
        const next = range.normalized(self.snapshot.utf16_len);
        self.snapshot.selection = next;
        self.snapshot.caret = next.end;
        self.state_lock.unlock();
        var callback: ?SelectionCallback = null;
        var callback_ctx: ?*anyopaque = null;
        var callback_ctx_release: ?SelectionContextRelease = null;
        self.callback_lock.lock();
        if (!self.detached.load(.acquire)) {
            callback = self.on_selection;
            callback_ctx = self.callback_ctx;
            callback_ctx_release = self.callback_ctx_release;
            if (callback != null and callback_ctx != null) {
                if (self.callback_ctx_retain) |retain| retain(callback_ctx.?);
                self.callback_inflight += 1;
            }
        }
        self.callback_lock.unlock();
        if (callback) |selection_callback| {
            if (callback_ctx) |ctx| {
                selection_callback(ctx, next.start, next.end);
                self.callback_lock.lock();
                self.callback_inflight -= 1;
                self.callback_lock.unlock();
                if (callback_ctx_release) |release_ctx| release_ctx(ctx);
            }
        }
        raiseAutomationEvent(self, 20014);
        return com.S_OK;
    }

    fn getSelectionArray(self: *SurfaceProvider) com.HRESULT {
        _ = self;
        return com.S_OK;
    }

    pub fn QueryInterface(
        value: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromBase(value).query(iid, out);
    }
    pub fn AddRef(value: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(value).refcount.fetchAdd(1, .monotonic) + 1;
    }
    pub fn Release(value: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(value).release();
    }

    fn getProviderOptions(
        value: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        out.* = com.ProviderOptions_ServerSideProvider | com.ProviderOptions_UseComThreading;
        return if (self.available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }

    fn GetPatternProvider(
        value: *com.IRawElementProviderSimple,
        pattern: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        out.* = null;
        self.state_lock.lockShared();
        defer self.state_lock.unlockShared();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (pattern == 10002 and self.role == .edit) {
            out.* = @ptrCast(&self.value_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
        } else if (pattern == 10014) {
            out.* = @ptrCast(&self.text_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
        } else if (pattern == 10024) {
            out.* = @ptrCast(&self.text2_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
        }
        return com.S_OK;
    }

    fn GetPropertyValue(
        value: *com.IRawElementProviderSimple,
        property: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        out.* = com.VARIANT.empty();
        self.state_lock.lockShared();
        defer self.state_lock.unlockShared();
        switch (property) {
            30003 => out.* = com.VARIANT.fromI4(
                controlType(self.role),
            ),
            30004 => {
                const bstr = self.propertyBstr(localizedControlType(self.role)) orelse
                    return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            30005 => {
                const bstr = self.propertyBstr(self.name) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            30008 => out.* = com.VARIANT.fromBool(self.focused.load(.acquire)),
            30009 => out.* = com.VARIANT.fromBool(true),
            30010, 30016, 30017 => out.* = com.VARIANT.fromBool(true),
            30022 => out.* = com.VARIANT.fromBool(!self.visible.load(.acquire)),
            30024 => {
                const bstr = self.propertyBstr("Win32") orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            30045 => {
                const bytes = self.snapshot.utf16RangeToBytes(.{
                    .start = 0,
                    .end = self.snapshot.utf16_len,
                });
                const bstr = self.propertyBstr(self.snapshot.text[bytes.start..bytes.end]) orelse
                    return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            30046 => out.* = com.VARIANT.fromBool(true),
            else => {},
        }
        return com.S_OK;
    }

    fn getHostRawElementProvider(
        value: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }

    fn ValueQueryInterface(
        value: *com.IValueProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromValue(value).query(iid, out);
    }
    fn ValueAddRef(value: *com.IValueProvider) callconv(.winapi) u32 {
        return fromValue(value).refcount.fetchAdd(1, .monotonic) + 1;
    }
    fn ValueRelease(value: *com.IValueProvider) callconv(.winapi) u32 {
        return fromValue(value).release();
    }
    fn ValueSetValue(
        value: *com.IValueProvider,
        _: [*:0]const u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(value);
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        return com.UIA_E_INVALIDOPERATION;
    }
    fn ValueGetValue(
        value: *com.IValueProvider,
        out: *?[*:0]u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(value);
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        out.* = null;
        self.state_lock.lockShared();
        defer self.state_lock.unlockShared();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const bytes = self.snapshot.utf16RangeToBytes(.{
            .start = 0,
            .end = self.snapshot.utf16_len,
        });
        const bstr = self.propertyBstr(self.snapshot.text[bytes.start..bytes.end]) orelse
            return com.E_OUTOFMEMORY;
        out.* = bstr;
        return com.S_OK;
    }
    fn ValueGetIsReadOnly(
        value: *com.IValueProvider,
        out: *com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(value);
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        self.state_lock.lockShared();
        defer self.state_lock.unlockShared();
        out.* = 1;
        return if (self.available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }

    fn textQuery(
        self: *SurfaceProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) com.HRESULT {
        return self.query(iid, out);
    }
    fn TextQueryInterface(value: *com.ITextProvider, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return fromText(value).textQuery(iid, out);
    }
    fn TextAddRef(value: *com.ITextProvider) callconv(.winapi) u32 {
        return fromText(value).refcount.fetchAdd(1, .monotonic) + 1;
    }
    fn TextRelease(value: *com.ITextProvider) callconv(.winapi) u32 {
        return fromText(value).release();
    }
    fn Text2QueryInterface(value: *com.ITextProvider2, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return fromText2(value).textQuery(iid, out);
    }
    fn Text2AddRef(value: *com.ITextProvider2) callconv(.winapi) u32 {
        return fromText2(value).refcount.fetchAdd(1, .monotonic) + 1;
    }
    fn Text2Release(value: *com.ITextProvider2) callconv(.winapi) u32 {
        return fromText2(value).release();
    }

    fn makeSafeArrayRange(
        self: *SurfaceProvider,
        snapshot: *const Snapshot,
        ranges: []const Range,
        out: *?*com.SAFEARRAY,
    ) com.HRESULT {
        out.* = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, @intCast(ranges.len));
        if (out.* == null) return com.E_OUTOFMEMORY;
        for (ranges, 0..) |range, index| {
            const item = self.makeRangeFromSnapshot(snapshot, range) orelse {
                _ = com.SafeArrayDestroy(out.*);
                out.* = null;
                return com.E_OUTOFMEMORY;
            };
            defer _ = SurfaceTextRangeProvider.Release(&item.base);
            var array_index: i32 = @intCast(index);
            if (com.SafeArrayPutElement(out.*.?, &array_index, @ptrCast(&item.base)) != com.S_OK) {
                _ = com.SafeArrayDestroy(out.*);
                out.* = null;
                return com.E_OUTOFMEMORY;
            }
        }
        return com.S_OK;
    }

    fn textGetSelection(
        self: *SurfaceProvider,
        out: *?*com.SAFEARRAY,
    ) com.HRESULT {
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        var snapshot = self.snapshotCopy(self.alloc) catch {
            out.* = null;
            return com.E_OUTOFMEMORY;
        };
        defer snapshot.deinit(self.alloc);
        const range = selectedRangeFromSnapshot(&snapshot);
        return self.makeSafeArrayRange(&snapshot, &.{range}, out);
    }
    fn textGetVisibleRanges(
        self: *SurfaceProvider,
        out: *?*com.SAFEARRAY,
    ) com.HRESULT {
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        var snapshot = self.snapshotCopy(self.alloc) catch {
            out.* = null;
            return com.E_OUTOFMEMORY;
        };
        defer snapshot.deinit(self.alloc);
        const visible = snapshot.visible;
        return self.makeSafeArrayRange(&snapshot, &.{visible}, out);
    }
    fn textRangeFromPoint(
        self: *SurfaceProvider,
        point: com.UiaPoint,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return com.S_OK;
        self.refreshScreenOrigin();
        var snapshot = self.snapshotCopy(self.alloc) catch return com.E_OUTOFMEMORY;
        const cell_height = @max(snapshot.metrics.cell_height, 1);
        const cell_width = @max(snapshot.metrics.cell_width, 1);
        const last_row = lineIndexAtByte(&snapshot, snapshot.text.len);
        const row = cellCoordinate(
            point.y,
            snapshot.metrics.origin_y,
            cell_height,
            last_row,
        );
        const column = cellCoordinate(
            point.x,
            snapshot.metrics.origin_x,
            cell_width,
            lineDisplayCellWidth(&snapshot, row),
        );
        var current_row: usize = 0;
        var current_column: usize = 0;
        var utf16_start: usize = 0;
        var index: usize = 0;
        while (index < snapshot.text.len) {
            const byte = snapshot.text[index];
            if (byte == '\n') {
                if (current_row >= row) break;
                current_row += 1;
                current_column = 0;
                utf16_start = snapshot.utf16_for_byte[index + 1];
                index += 1;
                continue;
            }
            const decoded = decodeCodepoint(snapshot.text, index);
            const display_width = displayCellWidth(decoded.value);
            if (current_row == row and current_column >= column and display_width != 0) break;
            current_column += display_width;
            index += decoded.byte_len;
        }
        const offset = if (index <= snapshot.text.len)
            snapshot.utf16_for_byte[index]
        else
            utf16_start;
        const range = SurfaceTextRangeProvider.createWithSnapshot(
            self.alloc,
            self,
            .{ .start = offset, .end = offset },
            snapshot,
        ) catch {
            snapshot.deinit(self.alloc);
            return com.E_OUTOFMEMORY;
        };
        out.* = &range.base;
        return com.S_OK;
    }
    fn textGetDocumentRange(
        self: *SurfaceProvider,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        var snapshot = self.snapshotCopy(self.alloc) catch return com.E_OUTOFMEMORY;
        const range = SurfaceTextRangeProvider.createWithSnapshot(
            self.alloc,
            self,
            .{ .start = 0, .end = snapshot.utf16_len },
            snapshot,
        ) catch {
            snapshot.deinit(self.alloc);
            return com.E_OUTOFMEMORY;
        };
        out.* = &range.base;
        return com.S_OK;
    }
    fn textGetSupported(
        self: *SurfaceProvider,
        out: *i32,
    ) com.HRESULT {
        var call = self.beginCall() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        defer call.deinit();
        out.* = com.SupportedTextSelection_Single;
        return if (self.available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }
    fn TextGetSelection(value: *com.ITextProvider, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        return fromText(value).textGetSelection(out);
    }
    fn TextGetVisibleRanges(value: *com.ITextProvider, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        return fromText(value).textGetVisibleRanges(out);
    }
    fn TextRangeFromChild(value: *com.ITextProvider, _: ?*com.IRawElementProviderSimple, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromText(value);
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        out.* = null;
        return if (self.available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }
    fn TextRangeFromPoint(value: *com.ITextProvider, point: com.UiaPoint, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return fromText(value).textRangeFromPoint(point, out);
    }
    fn TextGetDocumentRange(value: *com.ITextProvider, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return fromText(value).textGetDocumentRange(out);
    }
    fn TextGetSupportedTextSelection(value: *com.ITextProvider, out: *i32) callconv(.winapi) com.HRESULT {
        return fromText(value).textGetSupported(out);
    }
    fn Text2GetSelection(value: *com.ITextProvider2, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        return fromText2(value).textGetSelection(out);
    }
    fn Text2GetVisibleRanges(value: *com.ITextProvider2, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        return fromText2(value).textGetVisibleRanges(out);
    }
    fn Text2RangeFromChild(value: *com.ITextProvider2, child: ?*com.IRawElementProviderSimple, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromText2(value);
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        out.* = null;
        _ = child;
        return if (self.available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }
    fn Text2RangeFromPoint(value: *com.ITextProvider2, point: com.UiaPoint, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return fromText2(value).textRangeFromPoint(point, out);
    }
    fn Text2GetDocumentRange(value: *com.ITextProvider2, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return fromText2(value).textGetDocumentRange(out);
    }
    fn Text2GetSupportedTextSelection(value: *com.ITextProvider2, out: *i32) callconv(.winapi) com.HRESULT {
        return fromText2(value).textGetSupported(out);
    }
    fn Text2RangeFromAnnotation(value: *com.ITextProvider2, _: ?*com.IRawElementProviderSimple, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromText2(value);
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        out.* = null;
        return if (self.available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }
    fn Text2GetCaretRange(value: *com.ITextProvider2, active: *com.BOOL, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromText2(value);
        var call = self.beginCall() orelse {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer call.deinit();
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        var snapshot = self.snapshotCopy(self.alloc) catch return com.E_OUTOFMEMORY;
        active.* = if (self.focused.load(.acquire)) 1 else 0;
        const caret = snapshot.caret;
        const range = SurfaceTextRangeProvider.createWithSnapshot(
            self.alloc,
            self,
            .{ .start = caret, .end = caret },
            snapshot,
        ) catch {
            snapshot.deinit(self.alloc);
            return com.E_OUTOFMEMORY;
        };
        out.* = &range.base;
        return com.S_OK;
    }
};

const SurfaceTextRangeProvider = struct {
    base: com.ITextRangeProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    parent: *SurfaceProvider,
    snapshot: Snapshot,
    range_lock: std.Thread.Mutex,
    range: Range,

    const vtbl: com.ITextRangeProviderVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .Clone = Clone,
        .Compare = Compare,
        .CompareEndpoints = CompareEndpoints,
        .ExpandToEnclosingUnit = ExpandToEnclosingUnit,
        .FindAttribute = FindAttribute,
        .FindText = FindText,
        .GetAttributeValue = GetAttributeValue,
        .GetBoundingRectangles = GetBoundingRectangles,
        .GetEnclosingElement = GetEnclosingElement,
        .GetText = GetText,
        .Move = Move,
        .MoveEndpointByUnit = MoveEndpointByUnit,
        .MoveEndpointByRange = MoveEndpointByRange,
        .Select = Select,
        .AddToSelection = AddToSelection,
        .RemoveFromSelection = RemoveFromSelection,
        .ScrollIntoView = ScrollIntoView,
        .GetChildren = GetChildren,
    };

    fn create(
        alloc: std.mem.Allocator,
        parent: *SurfaceProvider,
        range: Range,
    ) !*SurfaceTextRangeProvider {
        var copy = try parent.snapshotCopy(alloc);
        errdefer copy.deinit(alloc);
        return createWithSnapshot(alloc, parent, range, copy);
    }

    fn createWithSnapshot(
        alloc: std.mem.Allocator,
        parent: *SurfaceProvider,
        range: Range,
        snapshot: Snapshot,
    ) !*SurfaceTextRangeProvider {
        const self = try alloc.create(SurfaceTextRangeProvider);
        errdefer alloc.destroy(self);
        _ = SurfaceProvider.AddRef(&parent.base);
        errdefer _ = SurfaceProvider.Release(&parent.base);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .parent = parent,
            .snapshot = snapshot,
            .range_lock = .{},
            .range = range.normalized(snapshot.utf16_len),
        };
        return self;
    }

    fn fromBase(value: *com.ITextRangeProvider) *SurfaceTextRangeProvider {
        return @fieldParentPtr("base", value);
    }
    fn available(self: *const SurfaceTextRangeProvider) bool {
        return self.parent.available();
    }
    fn release(self: *SurfaceTextRangeProvider) u32 {
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            self.snapshot.deinit(self.alloc);
            _ = SurfaceProvider.Release(&self.parent.base);
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }
    fn query(self: *SurfaceTextRangeProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or iidEqual(iid, &com.IID_ITextRangeProvider)) {
            out.* = @ptrCast(&self.base);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        return com.E_NOINTERFACE;
    }
    fn clone(self: *SurfaceTextRangeProvider) ?*SurfaceTextRangeProvider {
        self.range_lock.lock();
        const current = self.range;
        self.range_lock.unlock();
        var snapshot = snapshotClone(self.alloc, &self.snapshot) catch return null;
        return SurfaceTextRangeProvider.createWithSnapshot(
            self.alloc,
            self.parent,
            current,
            snapshot,
        ) catch {
            snapshot.deinit(self.alloc);
            return null;
        };
    }
    fn rangeCopy(self: *SurfaceTextRangeProvider) Range {
        self.range_lock.lock();
        defer self.range_lock.unlock();
        return self.range;
    }
    fn byteRange(self: *const SurfaceTextRangeProvider) Range {
        return self.snapshot.utf16RangeToBytes(self.range);
    }

    fn geometryMetrics(self: *SurfaceTextRangeProvider) Metrics {
        self.parent.state_lock.lockShared();
        defer self.parent.state_lock.unlockShared();
        return self.parent.snapshot.metrics;
    }

    fn lineBounds(self: *const SurfaceTextRangeProvider) Range {
        const bytes = self.snapshot.utf16RangeToBytes(self.range);
        var start = bytes.start;
        while (start > 0 and self.snapshot.text[start - 1] != '\n') start -= 1;
        var end = bytes.end;
        while (end < self.snapshot.text.len and self.snapshot.text[end] != '\n') end += 1;
        return .{
            .start = self.snapshot.utf16_for_byte[start],
            .end = self.snapshot.utf16_for_byte[end],
        };
    }

    fn textForRange(self: *const SurfaceTextRangeProvider, limit: i32) ?com.BSTR {
        const bytes = self.byteRange();
        var end = bytes.end;
        if (limit >= 0) {
            const wanted = @min(@as(usize, @intCast(limit)), self.range.end - self.range.start);
            end = self.snapshot.byteForUtf16(self.range.start + wanted);
        }
        const utf8 = self.snapshot.text[bytes.start..end];
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, utf8) catch return null;
        defer self.alloc.free(wide);
        return com.SysAllocStringLen(wide.ptr, @intCast(wide.len));
    }

    fn moveEndpoint(self: *SurfaceTextRangeProvider, endpoint: i32, offset: usize) void {
        if (endpoint == com.TextPatternRangeEndpoint_Start) {
            self.range.start = @min(offset, self.range.end);
        } else {
            self.range.end = @max(self.range.start, @min(offset, self.snapshot.utf16_len));
        }
    }

    fn QueryInterface(value: *com.ITextRangeProvider, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return fromBase(value).query(iid, out);
    }
    fn AddRef(value: *com.ITextRangeProvider) callconv(.winapi) u32 {
        return fromBase(value).refcount.fetchAdd(1, .monotonic) + 1;
    }
    pub fn Release(value: *com.ITextRangeProvider) callconv(.winapi) u32 {
        return fromBase(value).release();
    }
    fn Clone(value: *com.ITextRangeProvider, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const copy = self.clone() orelse return com.E_OUTOFMEMORY;
        out.* = &copy.base;
        return com.S_OK;
    }
    fn Compare(value: *com.ITextRangeProvider, other: ?*com.ITextRangeProvider, out: *com.BOOL) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        const rhs = other orelse {
            out.* = 0;
            return com.E_INVALIDARG;
        };
        const other_range = fromBase(rhs);
        if (!self.available() or !other_range.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const lhs = self.rangeCopy();
        const rhs_range = other_range.rangeCopy();
        out.* = if (std.mem.eql(u8, self.snapshot.text, other_range.snapshot.text) and
            lhs.start == rhs_range.start and
            lhs.end == rhs_range.end) 1 else 0;
        return com.S_OK;
    }
    fn CompareEndpoints(
        value: *com.ITextRangeProvider,
        endpoint: i32,
        other: ?*com.ITextRangeProvider,
        other_endpoint: i32,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        const rhs = other orelse return com.E_INVALIDARG;
        const other_range = fromBase(rhs);
        if (!self.available() or !other_range.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const lhs_range = self.rangeCopy();
        const rhs_range = other_range.rangeCopy();
        const lhs_value = if (endpoint == com.TextPatternRangeEndpoint_Start) lhs_range.start else lhs_range.end;
        const rhs_value = if (other_endpoint == com.TextPatternRangeEndpoint_Start) rhs_range.start else rhs_range.end;
        out.* = if (lhs_value < rhs_value) -1 else if (lhs_value > rhs_value) 1 else 0;
        return com.S_OK;
    }
    fn ExpandToEnclosingUnit(value: *com.ITextRangeProvider, unit: i32) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        self.range_lock.lock();
        defer self.range_lock.unlock();
        switch (unit) {
            com.TextUnit_Document => self.range = .{ .start = 0, .end = self.snapshot.utf16_len },
            com.TextUnit_Line, com.TextUnit_Paragraph => self.range = self.lineBounds(),
            else => return com.UIA_E_NOTSUPPORTED,
        }
        return com.S_OK;
    }
    fn FindAttribute(_: *com.ITextRangeProvider, _: i32, _: com.VARIANT, _: com.BOOL, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }
    fn FindText(
        value: *com.ITextRangeProvider,
        needle: ?[*]const u16,
        backward: com.BOOL,
        ignore_case: com.BOOL,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        self.range_lock.lock();
        defer self.range_lock.unlock();
        const needle_ptr = needle orelse return com.E_INVALIDARG;
        var length: usize = 0;
        while (needle_ptr[length] != 0) : (length += 1) {}
        const bytes = self.byteRange();
        const haystack = self.snapshot.text[bytes.start..bytes.end];
        var start_byte: usize = undefined;
        var end_byte: usize = undefined;
        if (ignore_case != 0) {
            if (length == 0 or length > std.math.maxInt(i32)) return com.S_OK;
            const haystack_utf16 = std.unicode.utf8ToUtf16LeAlloc(
                self.alloc,
                haystack,
            ) catch return com.E_INVALIDARG;
            defer self.alloc.free(haystack_utf16);
            if (length > haystack_utf16.len) return com.S_OK;

            const no_boundary = std.math.maxInt(usize);
            const byte_for_utf16 = self.alloc.alloc(
                usize,
                haystack_utf16.len + 1,
            ) catch return com.E_OUTOFMEMORY;
            defer self.alloc.free(byte_for_utf16);
            @memset(byte_for_utf16, no_boundary);
            byte_for_utf16[0] = 0;
            var byte_offset: usize = 0;
            var utf16_offset: usize = 0;
            while (byte_offset < haystack.len) {
                const scalar_len = std.unicode.utf8ByteSequenceLength(
                    haystack[byte_offset],
                ) catch return com.E_INVALIDARG;
                if (byte_offset + scalar_len > haystack.len) return com.E_INVALIDARG;
                const codepoint = std.unicode.utf8Decode(
                    haystack[byte_offset .. byte_offset + scalar_len],
                ) catch return com.E_INVALIDARG;
                byte_offset += scalar_len;
                utf16_offset += if (codepoint <= 0xffff) 1 else 2;
                byte_for_utf16[utf16_offset] = byte_offset;
            }

            const first_start: usize = 0;
            const first_end = haystack_utf16.len;
            if (first_end < first_start + length) return com.S_OK;
            const last_start = first_end - length;
            var match_start: ?usize = null;
            var start = first_start;
            while (start <= last_start) : (start += 1) {
                const end = start + length;
                if (byte_for_utf16[start] == no_boundary or
                    byte_for_utf16[end] == no_boundary) continue;
                if (CompareStringOrdinal(
                    haystack_utf16.ptr + start,
                    @intCast(length),
                    needle_ptr,
                    @intCast(length),
                    1,
                ) != 2) continue;
                match_start = start;
                if (backward == 0) break;
            }
            const matched_start = match_start orelse return com.S_OK;
            start_byte = bytes.start + byte_for_utf16[matched_start];
            end_byte = bytes.start + byte_for_utf16[matched_start + length];
        } else {
            const needle_utf8 = std.unicode.utf16LeToUtf8Alloc(
                self.alloc,
                needle_ptr[0..length],
            ) catch return com.E_INVALIDARG;
            defer self.alloc.free(needle_utf8);
            const found = if (backward != 0)
                std.mem.lastIndexOf(u8, haystack, needle_utf8)
            else
                std.mem.indexOf(u8, haystack, needle_utf8);
            const at = found orelse return com.S_OK;
            start_byte = bytes.start + at;
            end_byte = start_byte + needle_utf8.len;
        }
        var snapshot = snapshotClone(self.alloc, &self.snapshot) catch
            return com.E_OUTOFMEMORY;
        const range = SurfaceTextRangeProvider.createWithSnapshot(
            self.alloc,
            self.parent,
            .{
                .start = self.snapshot.utf16_for_byte[start_byte],
                .end = self.snapshot.utf16_for_byte[end_byte],
            },
            snapshot,
        ) catch {
            snapshot.deinit(self.alloc);
            return com.E_OUTOFMEMORY;
        };
        out.* = &range.base;
        return com.S_OK;
    }
    fn GetAttributeValue(_: *com.ITextRangeProvider, _: i32, out: *com.VARIANT) callconv(.winapi) com.HRESULT {
        out.* = com.VARIANT.empty();
        return com.S_OK;
    }
    fn GetBoundingRectangles(
        value: *com.ITextRangeProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        self.range_lock.lock();
        defer self.range_lock.unlock();
        const metrics = self.geometryMetrics();
        if (self.range.start == self.range.end) {
            out.* = com.SafeArrayCreateVector(com.VT_R8, 0, 0);
            return if (out.* == null) com.E_OUTOFMEMORY else com.S_OK;
        }
        const bytes = self.byteRange();
        const document_row = lineIndexAtByte(&self.snapshot, bytes.start);
        var line_count: usize = 1;
        for (self.snapshot.text[bytes.start..bytes.end]) |byte| {
            if (byte == '\n') line_count += 1;
        }
        out.* = com.SafeArrayCreateVector(com.VT_R8, 0, @intCast(line_count * 4));
        if (out.* == null) return com.E_OUTOFMEMORY;
        var line_start = bytes.start;
        var line_index: usize = 0;
        while (line_index < line_count) : (line_index += 1) {
            var line_end = line_start;
            while (line_end < bytes.end and self.snapshot.text[line_end] != '\n') line_end += 1;
            const start_column = if (line_index == 0)
                lineColumnAtByte(&self.snapshot, bytes.start, true)
            else
                0;
            const end_column = lineColumnAtByte(&self.snapshot, line_end, false);
            const line_width = end_column -| start_column;
            const rectangle = boundingRectangle(
                metrics,
                document_row + line_index,
                start_column,
                line_width,
            );
            const values = [_]f64{
                rectangle.left,
                rectangle.top,
                rectangle.width,
                rectangle.height,
            };
            for (values, 0..) |item, component| {
                var scalar = item;
                var array_index: i32 = @intCast(line_index * 4 + component);
                if (com.SafeArrayPutElement(out.*.?, &array_index, &scalar) != com.S_OK) {
                    _ = com.SafeArrayDestroy(out.*);
                    out.* = null;
                    return com.E_OUTOFMEMORY;
                }
            }
            line_start = if (line_end < bytes.end) line_end + 1 else line_end;
        }
        return com.S_OK;
    }
    fn GetEnclosingElement(
        value: *com.ITextRangeProvider,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = &self.parent.base;
        _ = SurfaceProvider.AddRef(&self.parent.base);
        return com.S_OK;
    }
    fn GetText(value: *com.ITextRangeProvider, max_length: i32, out: *?[*:0]u16) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        self.range_lock.lock();
        defer self.range_lock.unlock();
        const bstr = self.textForRange(max_length) orelse return com.E_OUTOFMEMORY;
        out.* = bstr;
        return com.S_OK;
    }
    fn Move(value: *com.ITextRangeProvider, unit: i32, count: i32, moved: *i32) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        self.range_lock.lock();
        defer self.range_lock.unlock();
        moved.* = 0;
        if (unit == com.TextUnit_Document) {
            if (count != 0) self.range = if (count > 0)
                .{ .start = self.snapshot.utf16_len, .end = self.snapshot.utf16_len }
            else
                .{ .start = 0, .end = 0 };
            moved.* = if (count == 0) 0 else if (count > 0) 1 else -1;
        } else if (unit == com.TextUnit_Line or unit == com.TextUnit_Paragraph) {
            const original = self.range;
            var steps = @abs(count);
            const direction: i32 = if (count >= 0) 1 else -1;
            while (steps > 0) : (steps -= 1) {
                if (direction > 0) {
                    const end_byte = self.snapshot.byteForUtf16(self.range.end);
                    if (end_byte >= self.snapshot.text.len) break;
                    var next = end_byte;
                    while (next < self.snapshot.text.len and self.snapshot.text[next] != '\n') next += 1;
                    if (next < self.snapshot.text.len) next += 1;
                    self.range = .{ .start = self.snapshot.utf16_for_byte[next], .end = self.snapshot.utf16_for_byte[next] };
                } else {
                    var previous = self.snapshot.byteForUtf16(self.range.start);
                    if (previous == 0) break;
                    previous -= 1;
                    while (previous > 0 and self.snapshot.text[previous - 1] != '\n') previous -= 1;
                    self.range = .{ .start = self.snapshot.utf16_for_byte[previous], .end = self.snapshot.utf16_for_byte[previous] };
                }
                moved.* += direction;
            }
            _ = original;
        } else return com.UIA_E_NOTSUPPORTED;
        return com.S_OK;
    }
    fn MoveEndpointByUnit(
        value: *com.ITextRangeProvider,
        endpoint: i32,
        unit: i32,
        count: i32,
        moved: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        self.range_lock.lock();
        defer self.range_lock.unlock();
        moved.* = 0;
        if (unit == com.TextUnit_Document) {
            if (count == 0) return com.S_OK;
            const target = if (count > 0) self.snapshot.utf16_len else 0;
            const current = if (endpoint == com.TextPatternRangeEndpoint_Start) self.range.start else self.range.end;
            self.moveEndpoint(endpoint, target);
            moved.* = if (target == current) 0 else if (target > current) 1 else -1;
        } else if (unit == com.TextUnit_Character) {
            const current = if (endpoint == com.TextPatternRangeEndpoint_Start) self.range.start else self.range.end;
            const current_signed = std.math.cast(i64, current) orelse return com.E_INVALIDARG;
            const delta: i64 = current_signed + @as(i64, count);
            const target: usize = @intCast(std.math.clamp(delta, 0, @as(i64, @intCast(self.snapshot.utf16_len))));
            self.moveEndpoint(endpoint, target);
            const target_signed = std.math.cast(i64, target) orelse return com.E_INVALIDARG;
            moved.* = @intCast(target_signed - current_signed);
        } else return com.UIA_E_NOTSUPPORTED;
        return com.S_OK;
    }
    fn MoveEndpointByRange(
        value: *com.ITextRangeProvider,
        endpoint: i32,
        other: ?*com.ITextRangeProvider,
        other_endpoint: i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        const rhs = other orelse return com.E_INVALIDARG;
        const other_range = fromBase(rhs);
        if (!self.available() or !other_range.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const other_copy = other_range.rangeCopy();
        self.range_lock.lock();
        defer self.range_lock.unlock();
        const target = if (other_endpoint == com.TextPatternRangeEndpoint_Start)
            other_copy.start
        else
            other_copy.end;
        self.moveEndpoint(endpoint, target);
        return com.S_OK;
    }
    fn Select(value: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        return self.parent.setSelectedRange(self.rangeCopy());
    }
    fn AddToSelection(value: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return Select(value);
    }
    fn RemoveFromSelection(value: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return Select(value);
    }
    fn ScrollIntoView(value: *com.ITextRangeProvider, _: com.BOOL) callconv(.winapi) com.HRESULT {
        return if (fromBase(value).available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }
    fn GetChildren(value: *com.ITextRangeProvider, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        out.* = null;
        if (!fromBase(value).available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, 0);
        return if (out.* == null) com.E_OUTOFMEMORY else com.S_OK;
    }
};

fn iidEqual(a: *const com.GUID, b: *const com.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn raiseAutomationEvent(self: *SurfaceProvider, event_id: i32) void {
    if (!self.available() or
        !self.connected.load(.acquire) or
        IsWindow(self.hwnd) == 0 or
        com.UiaClientsAreListening() == 0) return;
    _ = com.UiaRaiseAutomationEvent(&self.base, event_id);
}

fn raiseNameChanged(self: *SurfaceProvider) void {
    if (!self.available() or
        !self.connected.load(.acquire) or
        IsWindow(self.hwnd) == 0 or
        com.UiaClientsAreListening() == 0) return;
    self.state_lock.lockShared();
    const bstr = self.propertyBstr(self.name);
    self.state_lock.unlockShared();
    const value = bstr orelse return;
    defer com.SysFreeString(value);
    _ = com.UiaRaiseAutomationPropertyChangedEvent(
        &self.base,
        30005,
        com.VARIANT.empty(),
        com.VARIANT.fromBstr(value),
    );
}

fn raiseRoleChanged(self: *SurfaceProvider, previous: Role, next: Role) void {
    if (!self.available() or
        !self.connected.load(.acquire) or
        IsWindow(self.hwnd) == 0 or
        com.UiaClientsAreListening() == 0) return;
    _ = com.UiaRaiseAutomationPropertyChangedEvent(
        &self.base,
        30003,
        com.VARIANT.fromI4(SurfaceProvider.controlType(previous)),
        com.VARIANT.fromI4(SurfaceProvider.controlType(next)),
    );
    const old_value = self.propertyBstr(
        SurfaceProvider.localizedControlType(previous),
    ) orelse return;
    defer com.SysFreeString(old_value);
    const new_value = self.propertyBstr(
        SurfaceProvider.localizedControlType(next),
    ) orelse return;
    defer com.SysFreeString(new_value);
    _ = com.UiaRaiseAutomationPropertyChangedEvent(
        &self.base,
        30004,
        com.VARIANT.fromBstr(old_value),
        com.VARIANT.fromBstr(new_value),
    );
}

pub fn handleGetObject(
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    wparam: com.WPARAM,
    lparam: com.LPARAM,
    config: Config,
) ?com.LRESULT {
    if (lparam != com.UiaRootObjectId) return null;
    const provider = SurfaceProvider.create(alloc, hwnd, config) catch return null;
    defer _ = SurfaceProvider.Release(&provider.base);
    return com.UiaReturnRawElementProvider(hwnd, wparam, lparam, &provider.base);
}

pub fn returnProvider(
    hwnd: com.HWND,
    wparam: com.WPARAM,
    lparam: com.LPARAM,
    provider: *SurfaceProvider,
) ?com.LRESULT {
    if (lparam != com.UiaRootObjectId or !provider.available()) return null;
    const result = com.UiaReturnRawElementProvider(
        hwnd,
        wparam,
        lparam,
        &provider.base,
    );
    if (result != 0) provider.connected.store(true, .release);
    return result;
}

test "UTF-16 offsets preserve supplementary characters" {
    var snapshot = try snapshotFromUtf8(
        std.testing.allocator,
        "A🔥B",
        .{ .start = 0, .end = 0 },
        .{ .start = 0, .end = 0 },
        0,
        .{},
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), snapshot.utf16_len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.utf16_for_byte[1]);
    try std.testing.expectEqual(@as(usize, 3), snapshot.utf16_for_byte[5]);
}

test "provider owns independent names and text snapshots" {
    var first = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .name = "first",
        .text = "one",
    });
    defer _ = SurfaceProvider.Release(&first.base);
    var second = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(2), .{
        .name = "second",
        .text = "two",
    });
    defer _ = SurfaceProvider.Release(&second.base);

    const first_text = try first.textUtf8(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    const second_text = try second.textUtf8(std.testing.allocator);
    defer std.testing.allocator.free(second_text);
    try std.testing.expectEqualStrings("one", first_text);
    try std.testing.expectEqualStrings("two", second_text);
    first.detach();
    try std.testing.expect(!first.available());
    try std.testing.expect(second.available());
}

test "selection update clamps ranges and is rejected after detach" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "hello",
    });
    provider.updateSelection(.{ .start = 2, .end = 100 }, 100);
    try std.testing.expectEqual(Range{ .start = 2, .end = 5 }, provider.selectionRange());
    provider.detach();
    provider.updateSelection(.{ .start = 0, .end = 1 }, 1);
    try std.testing.expectEqual(Range{ .start = 2, .end = 5 }, provider.selectionRange());
    _ = SurfaceProvider.Release(&provider.base);
}

test "range geometry tracks independent screen-space origins" {
    var first = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "AB",
        .metrics = .{
            .cell_width = 10,
            .cell_height = 20,
            .origin_x = 100,
            .origin_y = 200,
        },
    });
    defer _ = SurfaceProvider.Release(&first.base);
    var second = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(2), .{
        .text = "AB",
        .metrics = .{
            .cell_width = 10,
            .cell_height = 20,
            .origin_x = 500,
            .origin_y = 700,
        },
    });
    defer _ = SurfaceProvider.Release(&second.base);

    var first_range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        first.textRangeFromPoint(.{ .x = 111, .y = 205 }, &first_range),
    );
    const first_value = SurfaceTextRangeProvider.fromBase(first_range.?);
    try std.testing.expectEqual(Range{ .start = 1, .end = 1 }, first_value.range);
    _ = SurfaceTextRangeProvider.Release(first_range.?);

    var second_range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        second.textRangeFromPoint(.{ .x = 501, .y = 705 }, &second_range),
    );
    const second_value = SurfaceTextRangeProvider.fromBase(second_range.?);
    try std.testing.expectEqual(Range{ .start = 0, .end = 0 }, second_value.range);
    _ = SurfaceTextRangeProvider.Release(second_range.?);

    const first_rect = boundingRectangle(first.snapshot.metrics, 0, 0, 2);
    const second_rect = boundingRectangle(second.snapshot.metrics, 0, 0, 2);
    try std.testing.expectEqual(@as(f64, 100), first_rect.left);
    try std.testing.expectEqual(@as(f64, 500), second_rect.left);
    try std.testing.expectEqual(@as(f64, 200), first_rect.top);
    try std.testing.expectEqual(@as(f64, 700), second_rect.top);
}

test "RangeFromPoint clamps extreme finite coordinates" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "top\nbottom",
        .metrics = .{
            .cell_width = 10,
            .cell_height = 20,
        },
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    const extreme = std.math.floatMax(f64);
    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.textRangeFromPoint(.{ .x = extreme, .y = extreme }, &range),
    );
    const value = SurfaceTextRangeProvider.fromBase(range.?);
    try std.testing.expectEqual(
        Range{ .start = provider.snapshot.utf16_len, .end = provider.snapshot.utf16_len },
        value.range,
    );
    _ = SurfaceTextRangeProvider.Release(range.?);

    range = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.textRangeFromPoint(.{ .x = -extreme, .y = -extreme }, &range),
    );
    const negative_value = SurfaceTextRangeProvider.fromBase(range.?);
    try std.testing.expectEqual(Range{ .start = 0, .end = 0 }, negative_value.range);
    _ = SurfaceTextRangeProvider.Release(range.?);
}

fn testScreenOriginQuery(_: com.HWND) ?ScreenOrigin {
    return .{ .x = 300, .y = 400 };
}

test "geometry queries refresh screen-space origin" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "AB",
        .metrics = .{ .cell_width = 10, .cell_height = 20 },
        .screen_origin_query = testScreenOriginQuery,
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.textRangeFromPoint(.{ .x = 311, .y = 405 }, &range),
    );
    const value = SurfaceTextRangeProvider.fromBase(range.?);
    try std.testing.expectEqual(Range{ .start = 1, .end = 1 }, value.range);
    _ = SurfaceTextRangeProvider.Release(range.?);
}

test "role mapping exposes control type and localized control type" {
    var provider = try SurfaceProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .{},
    );
    defer _ = SurfaceProvider.Release(&provider.base);
    provider.updateFocus(true);
    provider.updateRole(.edit);
    try std.testing.expectEqual(Role.edit, provider.role);
    try std.testing.expect(provider.focused.load(.acquire));
    try std.testing.expectEqual(@as(i32, 50030), SurfaceProvider.controlType(.terminal));
    try std.testing.expectEqual(@as(i32, 50004), SurfaceProvider.controlType(.edit));
    try std.testing.expectEqualStrings(
        "terminal document",
        SurfaceProvider.localizedControlType(.terminal),
    );
    try std.testing.expectEqualStrings("edit", SurfaceProvider.localizedControlType(.edit));
}

test "terminal value pattern is not advertised and edit values are read-only" {
    var provider = try SurfaceProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .{ .text = "terminal" },
    );
    defer _ = SurfaceProvider.Release(&provider.base);

    var pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.base.vtbl.GetPatternProvider(&provider.base, 10002, &pattern),
    );
    try std.testing.expect(pattern == null);
    var queried: ?*anyopaque = null;
    try std.testing.expectEqual(
        com.E_NOINTERFACE,
        provider.base.vtbl.QueryInterface(
            &provider.base,
            &com.IID_IValueProvider,
            &queried,
        ),
    );

    provider.updateRole(.edit);
    try std.testing.expectEqual(
        com.S_OK,
        provider.base.vtbl.GetPatternProvider(&provider.base, 10002, &pattern),
    );
    const value: *com.IValueProvider = @ptrCast(pattern.?);
    var read_only: com.BOOL = 0;
    try std.testing.expectEqual(
        com.S_OK,
        value.vtbl.get_IsReadOnly(value, &read_only),
    );
    try std.testing.expectEqual(@as(com.BOOL, 1), read_only);
    const empty: [1:0]u16 = .{0};
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        value.vtbl.SetValue(value, &empty),
    );
    _ = value.vtbl.Release(value);
}

test "unsupported text units return an explicit UIA error" {
    var provider = try SurfaceProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .{ .text = "one two" },
    );
    defer _ = SurfaceProvider.Release(&provider.base);
    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.textGetDocumentRange(&range),
    );
    const value = range.?;
    defer _ = SurfaceTextRangeProvider.Release(value);
    var moved: i32 = -1;
    try std.testing.expectEqual(
        com.UIA_E_NOTSUPPORTED,
        value.vtbl.Move(value, com.TextUnit_Character, 1, &moved),
    );
    try std.testing.expectEqual(@as(i32, 0), moved);
    try std.testing.expectEqual(
        com.UIA_E_NOTSUPPORTED,
        value.vtbl.MoveEndpointByUnit(
            value,
            com.TextPatternRangeEndpoint_Start,
            com.TextUnit_Word,
            1,
            &moved,
        ),
    );
    try std.testing.expectEqual(
        com.UIA_E_NOTSUPPORTED,
        value.vtbl.ExpandToEnclosingUnit(value, com.TextUnit_Character),
    );
}

test "clones and FindText retain the source snapshot" {
    var provider = try SurfaceProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .{ .text = "prefix target suffix" },
    );
    defer _ = SurfaceProvider.Release(&provider.base);

    var document: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.textGetDocumentRange(&document),
    );
    const original = document.?;
    defer _ = SurfaceTextRangeProvider.Release(original);
    try provider.updateText(
        "x",
        .{ .start = 0, .end = 1 },
        .{ .start = 0, .end = 0 },
        0,
    );

    var clone: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        original.vtbl.Clone(original, &clone),
    );
    defer _ = SurfaceTextRangeProvider.Release(clone.?);
    var clone_text: ?[*:0]u16 = null;
    try std.testing.expectEqual(
        com.S_OK,
        clone.?.vtbl.GetText(clone.?, -1, &clone_text),
    );
    defer com.SysFreeString(clone_text);
    const clone_utf8 = try std.unicode.utf16LeToUtf8Alloc(
        std.testing.allocator,
        std.mem.span(clone_text.?),
    );
    defer std.testing.allocator.free(clone_utf8);
    try std.testing.expectEqualStrings(
        "prefix target suffix",
        clone_utf8,
    );

    var needle: [7]u16 = .{ 't', 'a', 'r', 'g', 'e', 't', 0 };
    var found: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        original.vtbl.FindText(original, &needle, 0, 0, &found),
    );
    defer _ = SurfaceTextRangeProvider.Release(found.?);
    var found_text: ?[*:0]u16 = null;
    try std.testing.expectEqual(
        com.S_OK,
        found.?.vtbl.GetText(found.?, -1, &found_text),
    );
    defer com.SysFreeString(found_text);
    const found_utf8 = try std.unicode.utf16LeToUtf8Alloc(
        std.testing.allocator,
        std.mem.span(found_text.?),
    );
    defer std.testing.allocator.free(found_utf8);
    try std.testing.expectEqualStrings(
        "target",
        found_utf8,
    );
}

test "FindText ignoreCase is Unicode-aware, bounded, and directional" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "one Äpfel two äPFEL three",
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var document: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.textGetDocumentRange(&document),
    );
    defer _ = SurfaceTextRangeProvider.Release(document.?);

    const needle = try std.unicode.utf8ToUtf16LeAllocZ(
        std.testing.allocator,
        "ÄPFEL",
    );
    defer std.testing.allocator.free(needle);

    var forward: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        document.?.vtbl.FindText(document.?, needle.ptr, 0, 1, &forward),
    );
    defer _ = SurfaceTextRangeProvider.Release(forward.?);
    const first_byte = std.mem.indexOf(u8, provider.snapshot.text, "Äpfel").?;
    const first_start = provider.snapshot.utf16_for_byte[first_byte];
    try std.testing.expectEqual(
        Range{ .start = first_start, .end = first_start + needle.len },
        SurfaceTextRangeProvider.fromBase(forward.?).range,
    );

    var backward: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        document.?.vtbl.FindText(document.?, needle.ptr, 1, 1, &backward),
    );
    defer _ = SurfaceTextRangeProvider.Release(backward.?);
    const second_byte = std.mem.indexOf(u8, provider.snapshot.text, "äPFEL").?;
    const second_start = provider.snapshot.utf16_for_byte[second_byte];
    try std.testing.expectEqual(
        Range{ .start = second_start, .end = second_start + needle.len },
        SurfaceTextRangeProvider.fromBase(backward.?).range,
    );

    var bounded = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 0, .end = first_start + needle.len },
    );
    defer _ = SurfaceTextRangeProvider.Release(&bounded.base);
    var bounded_found: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        bounded.base.vtbl.FindText(&bounded.base, needle.ptr, 1, 1, &bounded_found),
    );
    defer _ = SurfaceTextRangeProvider.Release(bounded_found.?);
    try std.testing.expectEqual(
        Range{ .start = first_start, .end = first_start + needle.len },
        SurfaceTextRangeProvider.fromBase(bounded_found.?).range,
    );
}

test "provider creation cleans up name exactly once on allocation failure" {
    for (1..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            SurfaceProvider.create(failing.allocator(), @ptrFromInt(1), .{
                .name = "Terminal",
                .text = "text",
            }),
        );
    }
}

test "bounding rectangles use document rows and empty degenerate ranges" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "top\nmiddle\nbottom",
        .metrics = .{
            .cell_width = 10,
            .cell_height = 20,
            .origin_x = 50,
            .origin_y = 100,
        },
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var range = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 4, .end = 10 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&range.base);

    var rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&range.base, &rectangles),
    );
    var index: i32 = 1;
    var top: f64 = 0;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(rectangles.?, &index, &top),
    );
    try std.testing.expectEqual(@as(f64, 120), top);
    _ = com.SafeArrayDestroy(rectangles);

    var degenerate = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 4, .end = 4 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&degenerate.base);
    var empty: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&degenerate.base, &empty),
    );
    try std.testing.expectEqual(@as(u32, 1), com.SafeArrayGetDim(empty.?));
    var lower: i32 = 0;
    var upper: i32 = 0;
    try std.testing.expectEqual(
        com.DISP_E_BADINDEX,
        com.SafeArrayGetLBound(empty.?, 0, &lower),
    );
    try std.testing.expectEqual(
        com.DISP_E_BADINDEX,
        com.SafeArrayGetUBound(empty.?, 0, &upper),
    );
    _ = com.SafeArrayDestroy(empty);
}

test "retained ranges follow current geometry without replacing their snapshot" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "AB",
        .metrics = .{
            .cell_width = 10,
            .cell_height = 20,
            .origin_x = 100,
            .origin_y = 200,
        },
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var range = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 0, .end = 2 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&range.base);

    provider.updateMetrics(.{
        .cell_width = 15,
        .cell_height = 30,
        .origin_x = 400,
        .origin_y = 500,
    });

    var text: ?[*:0]u16 = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetText(&range.base, -1, &text),
    );
    defer com.SysFreeString(text);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(
        std.testing.allocator,
        std.mem.span(text.?),
    );
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("AB", utf8);

    var rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&range.base, &rectangles),
    );
    var left: f64 = 0;
    var top: f64 = 0;
    var width: f64 = 0;
    var height: f64 = 0;
    var left_index: i32 = 0;
    var top_index: i32 = 1;
    var width_index: i32 = 2;
    var height_index: i32 = 3;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(rectangles.?, &left_index, &left),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(rectangles.?, &top_index, &top),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(rectangles.?, &width_index, &width),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(rectangles.?, &height_index, &height),
    );
    try std.testing.expectEqual(@as(f64, 400), left);
    try std.testing.expectEqual(@as(f64, 500), top);
    try std.testing.expectEqual(@as(f64, 30), width);
    try std.testing.expectEqual(@as(f64, 30), height);
    _ = com.SafeArrayDestroy(rectangles);
}

test "bounding rectangles use the selected column and exact line widths" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "abcdef\nuvwxyz",
        .metrics = .{
            .cell_width = 10,
            .cell_height = 20,
            .origin_x = 50,
            .origin_y = 100,
        },
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var mid_line = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 2, .end = 4 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&mid_line.base);
    var mid_line_rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&mid_line.base, &mid_line_rectangles),
    );
    var mid_line_left: f64 = 0;
    var mid_line_width: f64 = 0;
    var left_index: i32 = 0;
    var width_index: i32 = 2;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(mid_line_rectangles.?, &left_index, &mid_line_left),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(mid_line_rectangles.?, &width_index, &mid_line_width),
    );
    try std.testing.expectEqual(@as(f64, 70), mid_line_left);
    try std.testing.expectEqual(@as(f64, 20), mid_line_width);
    _ = com.SafeArrayDestroy(mid_line_rectangles);

    var multi_line = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 2, .end = 10 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&multi_line.base);
    var multi_line_rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&multi_line.base, &multi_line_rectangles),
    );
    var first_left: f64 = 0;
    var first_width: f64 = 0;
    var second_left: f64 = 0;
    var second_width: f64 = 0;
    var first_left_index: i32 = 0;
    var first_width_index: i32 = 2;
    var second_left_index: i32 = 4;
    var second_width_index: i32 = 6;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(multi_line_rectangles.?, &first_left_index, &first_left),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(multi_line_rectangles.?, &first_width_index, &first_width),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(multi_line_rectangles.?, &second_left_index, &second_left),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(multi_line_rectangles.?, &second_width_index, &second_width),
    );
    try std.testing.expectEqual(@as(f64, 70), first_left);
    try std.testing.expectEqual(@as(f64, 40), first_width);
    try std.testing.expectEqual(@as(f64, 50), second_left);
    try std.testing.expectEqual(@as(f64, 30), second_width);
    _ = com.SafeArrayDestroy(multi_line_rectangles);
}

test "bounding rectangles use display-cell columns for Unicode text" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "e\u{0301}é界x",
        .metrics = .{
            .cell_width = 10,
            .cell_height = 20,
            .origin_x = 100,
            .origin_y = 200,
        },
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var combining = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 0, .end = 2 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&combining.base);
    var combining_rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&combining.base, &combining_rectangles),
    );
    var combining_left: f64 = 0;
    var combining_width: f64 = 0;
    var combining_left_index: i32 = 0;
    var combining_width_index: i32 = 2;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(combining_rectangles.?, &combining_left_index, &combining_left),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(combining_rectangles.?, &combining_width_index, &combining_width),
    );
    try std.testing.expectEqual(@as(f64, 100), combining_left);
    try std.testing.expectEqual(@as(f64, 10), combining_width);
    _ = com.SafeArrayDestroy(combining_rectangles);

    var combining_only = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 1, .end = 2 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&combining_only.base);
    var combining_only_rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&combining_only.base, &combining_only_rectangles),
    );
    var combining_only_left: f64 = 0;
    var combining_only_left_index: i32 = 0;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(
            combining_only_rectangles.?,
            &combining_only_left_index,
            &combining_only_left,
        ),
    );
    try std.testing.expectEqual(@as(f64, 100), combining_only_left);
    _ = com.SafeArrayDestroy(combining_only_rectangles);

    var wide = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 2, .end = 4 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&wide.base);
    var wide_rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&wide.base, &wide_rectangles),
    );
    var wide_left: f64 = 0;
    var wide_width: f64 = 0;
    var wide_left_index: i32 = 0;
    var wide_width_index: i32 = 2;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(wide_rectangles.?, &wide_left_index, &wide_left),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(wide_rectangles.?, &wide_width_index, &wide_width),
    );
    try std.testing.expectEqual(@as(f64, 110), wide_left);
    try std.testing.expectEqual(@as(f64, 30), wide_width);
    _ = com.SafeArrayDestroy(wide_rectangles);

    var combining_start = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 1, .end = 3 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&combining_start.base);
    var combining_start_rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&combining_start.base, &combining_start_rectangles),
    );
    var combining_start_width: f64 = 0;
    var combining_start_width_index: i32 = 2;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(
            combining_start_rectangles.?,
            &combining_start_width_index,
            &combining_start_width,
        ),
    );
    try std.testing.expectEqual(@as(f64, 20), combining_start_width);
    _ = com.SafeArrayDestroy(combining_start_rectangles);
}

test "range start anchors combining marks without shrinking wide end boundaries" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "界\u{0301}x",
        .metrics = .{
            .cell_width = 10,
            .cell_height = 20,
            .origin_x = 100,
            .origin_y = 200,
        },
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var wide = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 0, .end = 1 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&wide.base);
    var wide_rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&wide.base, &wide_rectangles),
    );
    var wide_width: f64 = 0;
    var width_index: i32 = 2;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(wide_rectangles.?, &width_index, &wide_width),
    );
    try std.testing.expectEqual(@as(f64, 20), wide_width);
    _ = com.SafeArrayDestroy(wide_rectangles);

    var combining_start = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 1, .end = 3 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&combining_start.base);
    var combining_rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(
            &combining_start.base,
            &combining_rectangles,
        ),
    );
    var combining_left: f64 = 0;
    var combining_width: f64 = 0;
    var left_index: i32 = 0;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(combining_rectangles.?, &left_index, &combining_left),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(combining_rectangles.?, &width_index, &combining_width),
    );
    try std.testing.expectEqual(@as(f64, 100), combining_left);
    try std.testing.expectEqual(@as(f64, 30), combining_width);
    _ = com.SafeArrayDestroy(combining_rectangles);
}

test "display-cell geometry covers wide Unicode outside the BMP" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "\u{1b000}x",
        .metrics = .{ .cell_width = 10, .cell_height = 20 },
    });
    defer _ = SurfaceProvider.Release(&provider.base);
    var range = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 0, .end = 3 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&range.base);
    var rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&range.base, &rectangles),
    );
    var width: f64 = 0;
    var index: i32 = 2;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(rectangles.?, &index, &width),
    );
    try std.testing.expectEqual(@as(f64, 30), width);
    _ = com.SafeArrayDestroy(rectangles);
}

test "RangeFromPoint uses display-cell positions for combining and wide text" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "e\u{0301}é界x",
        .metrics = .{ .cell_width = 10, .cell_height = 20 },
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.textRangeFromPoint(.{ .x = 10, .y = 5 }, &range),
    );
    const combining_value = SurfaceTextRangeProvider.fromBase(range.?);
    try std.testing.expectEqual(Range{ .start = 2, .end = 2 }, combining_value.range);
    _ = SurfaceTextRangeProvider.Release(range.?);

    range = null;
    try std.testing.expectEqual(
        com.S_OK,
        provider.textRangeFromPoint(.{ .x = 20, .y = 5 }, &range),
    );
    const wide_value = SurfaceTextRangeProvider.fromBase(range.?);
    try std.testing.expectEqual(Range{ .start = 3, .end = 3 }, wide_value.range);
    _ = SurfaceTextRangeProvider.Release(range.?);
}

const ProviderStress = struct {
    provider: *SurfaceProvider,
    stop: *std.atomic.Value(bool),
};

const CallbackStress = struct {
    callbacks: std.atomic.Value(usize),
    detached: std.atomic.Value(bool),
    after_detach: std.atomic.Value(usize),
};

fn stressSelectionCallback(ctx: *anyopaque, _: usize, _: usize) void {
    const state: *CallbackStress = @ptrCast(@alignCast(ctx));
    _ = state.callbacks.fetchAdd(1, .monotonic);
    if (state.detached.load(.acquire)) {
        _ = state.after_detach.fetchAdd(1, .monotonic);
    }
}

fn stressQueryProvider(stress: *ProviderStress) void {
    for (0..2000) |_| {
        if (stress.stop.load(.acquire)) break;
        var value = com.VARIANT.empty();
        const property_hr = SurfaceProvider.GetPropertyValue(
            &stress.provider.base,
            30005,
            &value,
        );
        if (property_hr == com.S_OK) _ = com.VariantClear(&value);

        var range: ?*com.ITextRangeProvider = null;
        _ = SurfaceProvider.TextGetDocumentRange(&stress.provider.text_iface, &range);
        if (range) |item| _ = SurfaceTextRangeProvider.Release(item);
        std.Thread.yield() catch {};
    }
}

fn stressUpdateProvider(stress: *ProviderStress) void {
    for (0..1000) |index| {
        if (stress.stop.load(.acquire)) break;
        stress.provider.updateText(
            if (index % 2 == 0) "e\u{0301}界x" else "replacement",
            .{ .start = 0, .end = 1 },
            .{ .start = 0, .end = 0 },
            0,
        ) catch break;
        stress.provider.updateName(if (index % 2 == 0) "one" else "two") catch break;
        stress.provider.updateSelection(.{ .start = 0, .end = 0 }, 0);
        std.Thread.yield() catch {};
    }
}

fn stressDetachProvider(stress: *ProviderStress) void {
    for (0..32) |_| std.Thread.yield() catch {};
    stress.provider.detach();
    stress.stop.store(true, .release);
}

test "provider synchronizes concurrent queries updates and detach" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "initial",
        .name = "initial",
        .screen_origin_query = testScreenOriginQuery,
    });
    defer _ = SurfaceProvider.Release(&provider.base);
    var stop = std.atomic.Value(bool).init(false);
    var stress = ProviderStress{
        .provider = provider,
        .stop = &stop,
    };
    const query_thread = try std.Thread.spawn(.{}, stressQueryProvider, .{&stress});
    const update_thread = try std.Thread.spawn(.{}, stressUpdateProvider, .{&stress});
    const detach_thread = try std.Thread.spawn(.{}, stressDetachProvider, .{&stress});
    query_thread.join();
    update_thread.join();
    detach_thread.join();
    try std.testing.expect(!provider.available());
}

test "selection callbacks are detached without post-teardown calls" {
    var callback_state = CallbackStress{
        .callbacks = std.atomic.Value(usize).init(0),
        .detached = std.atomic.Value(bool).init(false),
        .after_detach = std.atomic.Value(usize).init(0),
    };
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "initial",
        .callback_ctx = &callback_state,
        .on_selection = stressSelectionCallback,
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    try std.testing.expectEqual(com.S_OK, provider.setSelectedRange(.{ .start = 0, .end = 0 }));
    const update_thread = try std.Thread.spawn(.{}, struct {
        fn run(value: *SurfaceProvider) void {
            for (0..2000) |index| {
                _ = value.setSelectedRange(.{ .start = index % 4, .end = index % 4 });
            }
        }
    }.run, .{provider});
    for (0..32) |_| std.Thread.yield() catch {};
    provider.detach();
    callback_state.detached.store(true, .release);
    update_thread.join();

    try std.testing.expect(callback_state.callbacks.load(.acquire) > 0);
    try std.testing.expectEqual(@as(usize, 0), callback_state.after_detach.load(.acquire));
}

test "selection callback may detach and release its provider without deadlock" {
    const CallbackTeardown = struct {
        provider: *SurfaceProvider,
        calls: usize = 0,

        fn run(ctx: *anyopaque, _: usize, _: usize) void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.calls += 1;
            state.provider.detach();
            _ = SurfaceProvider.Release(&state.provider.base);
        }
    };
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "initial",
    });
    var state = CallbackTeardown{ .provider = provider };
    provider.callback_ctx = &state;
    provider.on_selection = CallbackTeardown.run;
    try std.testing.expectEqual(
        com.S_OK,
        provider.setSelectedRange(.{ .start = 0, .end = 1 }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

test "caret ranges expose empty bounding rectangles" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "abcdef",
        .caret = 3,
    });
    defer _ = SurfaceProvider.Release(&provider.base);

    var active: com.BOOL = 0;
    var caret_range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceProvider.Text2GetCaretRange(&provider.text2_iface, &active, &caret_range),
    );
    const value = SurfaceTextRangeProvider.fromBase(caret_range.?);
    try std.testing.expectEqual(Range{ .start = 3, .end = 3 }, value.range);
    var rectangles: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.GetBoundingRectangles(&value.base, &rectangles),
    );
    try std.testing.expectEqual(@as(u32, 1), com.SafeArrayGetDim(rectangles.?));
    _ = com.SafeArrayDestroy(rectangles);
    _ = SurfaceTextRangeProvider.Release(caret_range.?);
}

test "range creation cleans up allocation failure after provider allocation" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "text",
    });
    defer _ = SurfaceProvider.Release(&provider.base);
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        SurfaceTextRangeProvider.create(
            failing.allocator(),
            provider,
            .{ .start = 0, .end = 1 },
        ),
    );
}

test "document MoveEndpointByUnit zero count is a no-op" {
    var provider = try SurfaceProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .text = "text",
    });
    defer _ = SurfaceProvider.Release(&provider.base);
    var range = try SurfaceTextRangeProvider.create(
        std.testing.allocator,
        provider,
        .{ .start = 2, .end = 3 },
    );
    defer _ = SurfaceTextRangeProvider.Release(&range.base);
    var moved: i32 = -1;
    try std.testing.expectEqual(
        com.S_OK,
        SurfaceTextRangeProvider.MoveEndpointByUnit(
            &range.base,
            com.TextPatternRangeEndpoint_Start,
            com.TextUnit_Document,
            0,
            &moved,
        ),
    );
    try std.testing.expectEqual(@as(i32, 0), moved);
    try std.testing.expectEqual(Range{ .start = 2, .end = 3 }, range.range);
}

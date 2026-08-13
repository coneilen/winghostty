//! Standalone UI Automation provider for an embeddable terminal surface.
//!
//! This module deliberately depends only on the Win32 UIA ABI declarations.
//! It does not reach into the renderer, terminal, input, clipboard, or
//! product runtime. The host updates the provider with immutable UTF-8
//! snapshots and UTF-16 selection offsets.

const std = @import("std");
const com = @import("apprt/win32_uia/com.zig");

extern "user32" fn IsWindow(hwnd: com.HWND) callconv(.winapi) com.BOOL;

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
    callback_ctx: ?*anyopaque = null,
    on_selection: ?SelectionCallback = null,
};

fn boundingRectangle(metrics: Metrics, line_index: usize, line_width: usize) com.UiaRect {
    return .{
        .left = metrics.origin_x,
        .top = metrics.origin_y +
            metrics.cell_height * @as(f64, @floatFromInt(line_index)),
        .width = metrics.cell_width *
            @as(f64, @floatFromInt(@max(line_width, 1))),
        .height = metrics.cell_height,
    };
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

pub const SurfaceProvider = struct {
    base: com.IRawElementProviderSimple,
    value_iface: com.IValueProvider,
    text_iface: com.ITextProvider,
    text2_iface: com.ITextProvider2,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    name: []u8,
    snapshot: Snapshot,
    role: Role,
    focused: std.atomic.Value(bool),
    visible: std.atomic.Value(bool),
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),
    callback_ctx: ?*anyopaque,
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
            .name = name,
            .snapshot = snapshot,
            .role = config.role,
            .focused = std.atomic.Value(bool).init(config.focused),
            .visible = std.atomic.Value(bool).init(config.visible),
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
            .callback_ctx = config.callback_ctx,
            .on_selection = config.on_selection,
        };
        return self;
    }

    pub fn detach(self: *SurfaceProvider) void {
        self.on_selection = null;
        self.callback_ctx = null;
        self.detached.store(true, .release);
    }

    pub fn disconnect(self: *SurfaceProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        if (IsWindow(self.hwnd) == 0) {
            self.disconnected.store(true, .release);
            return com.S_OK;
        }
        const hr = com.UiaDisconnectProvider(&self.base);
        if (hr == com.S_OK) self.disconnected.store(true, .release);
        return hr;
    }

    pub fn updateName(self: *SurfaceProvider, name: []const u8) !void {
        if (!self.available()) return error.ElementNotAvailable;
        const owned = try self.alloc.dupe(u8, name);
        self.alloc.free(self.name);
        self.name = owned;
        raiseNameChanged(self);
    }

    pub fn updateText(
        self: *SurfaceProvider,
        text: []const u8,
        visible: Range,
        next_selection: Range,
        caret: usize,
    ) !void {
        if (!self.available()) return error.ElementNotAvailable;
        const next = try snapshotFromUtf8(
            self.alloc,
            text,
            visible,
            next_selection,
            caret,
            self.snapshot.metrics,
        );
        self.snapshot.deinit(self.alloc);
        self.snapshot = next;
        raiseAutomationEvent(self, 20015);
        raiseAutomationEvent(self, 20014);
    }

    pub fn updateSelection(self: *SurfaceProvider, next_selection: Range, caret: usize) void {
        if (!self.available()) return;
        const next = next_selection.normalized(self.snapshot.utf16_len);
        self.snapshot.selection = next;
        self.snapshot.caret = @min(caret, self.snapshot.utf16_len);
        raiseAutomationEvent(self, 20014);
    }

    pub fn updateFocus(self: *SurfaceProvider, focused: bool) void {
        if (!self.available()) return;
        self.focused.store(focused, .release);
        raiseAutomationEvent(self, 20005);
    }

    pub fn updateVisibility(self: *SurfaceProvider, visible: bool) void {
        if (!self.available()) return;
        self.visible.store(visible, .release);
    }

    pub fn updateRole(self: *SurfaceProvider, role: Role) void {
        if (!self.available()) return;
        const previous = self.role;
        if (previous == role) return;
        self.role = role;
        raiseRoleChanged(self, previous, role);
    }

    pub fn updateMetrics(self: *SurfaceProvider, metrics: Metrics) void {
        if (!self.available()) return;
        self.snapshot.metrics = metrics;
        raiseAutomationEvent(self, 20015);
    }

    pub fn textUtf8(self: *const SurfaceProvider) []const u8 {
        return self.snapshot.text;
    }

    pub fn selectionRange(self: *const SurfaceProvider) Range {
        return self.snapshot.selection;
    }

    pub fn copyRangeUtf8(
        self: *const SurfaceProvider,
        range: Range,
        alloc: std.mem.Allocator,
    ) ![]u8 {
        if (!self.available()) return error.ElementNotAvailable;
        const bytes = self.snapshot.utf16RangeToBytes(range);
        return alloc.dupe(u8, self.snapshot.text[bytes.start..bytes.end]);
    }

    pub fn available(self: *const SurfaceProvider) bool {
        return !self.detached.load(.acquire);
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
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
        } else if (iidEqual(iid, &com.IID_IValueProvider)) {
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
            self.snapshot.deinit(self.alloc);
            self.alloc.free(self.name);
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
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

    fn makeRange(self: *SurfaceProvider, range: Range) ?*SurfaceTextRangeProvider {
        return SurfaceTextRangeProvider.create(self.alloc, self, range) catch null;
    }

    fn setSelectedRange(self: *SurfaceProvider, range: Range) com.HRESULT {
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const next = range.normalized(self.snapshot.utf16_len);
        self.snapshot.selection = next;
        self.snapshot.caret = next.end;
        if (self.on_selection) |callback| {
            if (self.callback_ctx) |ctx| callback(ctx, next.start, next.end);
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
        out.* = com.ProviderOptions_ServerSideProvider;
        if (self.available()) return com.S_OK;
        return com.UIA_E_ELEMENTNOTAVAILABLE;
    }

    fn GetPatternProvider(
        value: *com.IRawElementProviderSimple,
        pattern: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        out.* = null;
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
        out.* = com.VARIANT.empty();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
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
            30046 => out.* = com.VARIANT.fromBool(self.role != .edit),
            else => {},
        }
        return com.S_OK;
    }

    fn getHostRawElementProvider(
        value: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
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
        _ = value;
        return com.UIA_E_INVALIDOPERATION;
    }
    fn ValueGetValue(
        value: *com.IValueProvider,
        out: *?[*:0]u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(value);
        out.* = null;
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
        out.* = if (self.role == .edit) 0 else 1;
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
        ranges: []const Range,
        out: *?*com.SAFEARRAY,
    ) com.HRESULT {
        out.* = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, @intCast(ranges.len));
        if (out.* == null) return com.E_OUTOFMEMORY;
        for (ranges, 0..) |range, index| {
            const item = self.makeRange(range) orelse {
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
        if (!self.available()) {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        }
        const range = self.selectedRange();
        return self.makeSafeArrayRange(&.{range}, out);
    }
    fn textGetVisibleRanges(
        self: *SurfaceProvider,
        out: *?*com.SAFEARRAY,
    ) com.HRESULT {
        if (!self.available()) {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        }
        return self.makeSafeArrayRange(&.{self.snapshot.visible}, out);
    }
    fn textRangeFromPoint(
        self: *SurfaceProvider,
        point: com.UiaPoint,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return com.S_OK;
        const cell_height = @max(self.snapshot.metrics.cell_height, 1);
        const cell_width = @max(self.snapshot.metrics.cell_width, 1);
        const row = @as(usize, @intFromFloat(@max(
            0,
            @floor((point.y - self.snapshot.metrics.origin_y) / cell_height),
        )));
        const column = @as(usize, @intFromFloat(@max(
            0,
            @floor((point.x - self.snapshot.metrics.origin_x) / cell_width),
        )));
        var current_row: usize = 0;
        var current_column: usize = 0;
        var utf16_start: usize = 0;
        var index: usize = 0;
        while (index < self.snapshot.text.len) {
            const byte = self.snapshot.text[index];
            if (byte == '\n') {
                if (current_row >= row) break;
                current_row += 1;
                current_column = 0;
                utf16_start = self.snapshot.utf16_for_byte[index + 1];
                index += 1;
                continue;
            }
            if (current_row == row and current_column >= column) break;
            const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            current_column += 1;
            index += sequence_len;
        }
        const offset = if (index <= self.snapshot.text.len)
            self.snapshot.utf16_for_byte[index]
        else
            utf16_start;
        const range = self.makeRange(.{ .start = offset, .end = offset }) orelse
            return com.E_OUTOFMEMORY;
        out.* = &range.base;
        return com.S_OK;
    }
    fn textGetDocumentRange(
        self: *SurfaceProvider,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const range = self.makeRange(.{ .start = 0, .end = self.snapshot.utf16_len }) orelse
            return com.E_OUTOFMEMORY;
        out.* = &range.base;
        return com.S_OK;
    }
    fn textGetSupported(
        self: *SurfaceProvider,
        out: *i32,
    ) com.HRESULT {
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
        out.* = null;
        return if (fromText(value).available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
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
        out.* = null;
        _ = child;
        return if (fromText2(value).available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
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
        out.* = null;
        return if (fromText2(value).available()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }
    fn Text2GetCaretRange(value: *com.ITextProvider2, active: *com.BOOL, out: *?*com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromText2(value);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        active.* = if (self.focused.load(.acquire)) 1 else 0;
        const range = self.makeRange(.{ .start = self.snapshot.caret, .end = self.snapshot.caret }) orelse
            return com.E_OUTOFMEMORY;
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
        const self = try alloc.create(SurfaceTextRangeProvider);
        _ = SurfaceProvider.AddRef(&parent.base);
        errdefer _ = SurfaceProvider.Release(&parent.base);
        const copy = try snapshotFromUtf8(
            alloc,
            parent.snapshot.text,
            parent.snapshot.visible,
            parent.snapshot.selection,
            parent.snapshot.caret,
            parent.snapshot.metrics,
        );
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .parent = parent,
            .snapshot = copy,
            .range = range.normalized(copy.utf16_len),
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
        return SurfaceTextRangeProvider.create(self.alloc, self.parent, self.range) catch null;
    }
    fn byteRange(self: *const SurfaceTextRangeProvider) Range {
        return self.snapshot.utf16RangeToBytes(self.range);
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
        out.* = if (std.mem.eql(u8, self.snapshot.text, other_range.snapshot.text) and
            self.range.start == other_range.range.start and
            self.range.end == other_range.range.end) 1 else 0;
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
        const lhs_value = if (endpoint == com.TextPatternRangeEndpoint_Start) self.range.start else self.range.end;
        const rhs_value = if (other_endpoint == com.TextPatternRangeEndpoint_Start) other_range.range.start else other_range.range.end;
        out.* = if (lhs_value < rhs_value) -1 else if (lhs_value > rhs_value) 1 else 0;
        return com.S_OK;
    }
    fn ExpandToEnclosingUnit(value: *com.ITextRangeProvider, unit: i32) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        switch (unit) {
            com.TextUnit_Document => self.range = .{ .start = 0, .end = self.snapshot.utf16_len },
            com.TextUnit_Line, com.TextUnit_Paragraph => self.range = self.lineBounds(),
            else => {},
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
        _: com.BOOL,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const needle_ptr = needle orelse return com.E_INVALIDARG;
        var length: usize = 0;
        while (needle_ptr[length] != 0) : (length += 1) {}
        const needle_utf8 = std.unicode.utf16LeToUtf8Alloc(self.alloc, needle_ptr[0..length]) catch
            return com.E_INVALIDARG;
        defer self.alloc.free(needle_utf8);
        const bytes = self.byteRange();
        const haystack = self.snapshot.text[bytes.start..bytes.end];
        const found = if (backward != 0)
            std.mem.lastIndexOf(u8, haystack, needle_utf8)
        else
            std.mem.indexOf(u8, haystack, needle_utf8);
        const at = found orelse return com.S_OK;
        const start_byte = bytes.start + at;
        const end_byte = start_byte + needle_utf8.len;
        const range = SurfaceTextRangeProvider.create(
            self.alloc,
            self.parent,
            .{
                .start = self.snapshot.utf16_for_byte[start_byte],
                .end = self.snapshot.utf16_for_byte[end_byte],
            },
        ) catch return com.E_OUTOFMEMORY;
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
        const bytes = self.byteRange();
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
            const line_width = @max(
                @as(usize, 1),
                line_end - line_start,
            );
            const rectangle = boundingRectangle(
                self.snapshot.metrics,
                line_index,
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
        const bstr = self.textForRange(max_length) orelse return com.E_OUTOFMEMORY;
        out.* = bstr;
        return com.S_OK;
    }
    fn Move(value: *com.ITextRangeProvider, unit: i32, count: i32, moved: *i32) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
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
        }
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
        moved.* = 0;
        if (unit == com.TextUnit_Document) {
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
        }
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
        const target = if (other_endpoint == com.TextPatternRangeEndpoint_Start)
            other_range.range.start
        else
            other_range.range.end;
        self.moveEndpoint(endpoint, target);
        return com.S_OK;
    }
    fn Select(value: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromBase(value);
        return self.parent.setSelectedRange(self.range);
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
    if (!self.available() or IsWindow(self.hwnd) == 0 or
        com.UiaClientsAreListening() == 0) return;
    _ = com.UiaRaiseAutomationEvent(&self.base, event_id);
}

fn raiseNameChanged(self: *SurfaceProvider) void {
    if (!self.available() or IsWindow(self.hwnd) == 0 or
        com.UiaClientsAreListening() == 0) return;
    const bstr = self.propertyBstr(self.name) orelse return;
    defer com.SysFreeString(bstr);
    _ = com.UiaRaiseAutomationPropertyChangedEvent(
        &self.base,
        30005,
        com.VARIANT.empty(),
        com.VARIANT.fromBstr(bstr),
    );
}

fn raiseRoleChanged(self: *SurfaceProvider, previous: Role, next: Role) void {
    if (!self.available() or IsWindow(self.hwnd) == 0 or
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
    return com.UiaReturnRawElementProvider(hwnd, wparam, lparam, &provider.base);
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

    try std.testing.expectEqualStrings("one", first.textUtf8());
    try std.testing.expectEqualStrings("two", second.textUtf8());
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

    const first_rect = boundingRectangle(first.snapshot.metrics, 0, 2);
    const second_rect = boundingRectangle(second.snapshot.metrics, 0, 2);
    try std.testing.expectEqual(@as(f64, 100), first_rect.left);
    try std.testing.expectEqual(@as(f64, 500), second_rect.left);
    try std.testing.expectEqual(@as(f64, 200), first_rect.top);
    try std.testing.expectEqual(@as(f64, 700), second_rect.top);
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

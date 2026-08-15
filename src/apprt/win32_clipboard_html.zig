//! CF_HTML clipboard format serialiser.
//!
//! Microsoft's CF_HTML clipboard format wraps an HTML fragment in a
//! fixed-width header whose byte offsets let consumers locate the
//! fragment without parsing. The four offset values are zero-padded
//! to exactly 10 decimal digits — this width is load-bearing because
//! consumers parse by fixed column position. Do not "optimise" the
//! padding away.
//!
//! Reference: https://learn.microsoft.com/en-us/windows/win32/dataxchg/html-clipboard-format

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Header template with 10-digit placeholder offsets.
/// Each line is terminated by \r\n. The header length is constant
/// regardless of the actual offset values because every field is
/// always exactly 10 digits wide.
const header_template =
    "Version:0.9\r\n" ++
    "StartHTML:0000000000\r\n" ++
    "EndHTML:0000000000\r\n" ++
    "StartFragment:0000000000\r\n" ++
    "EndFragment:0000000000\r\n";

const prefix = "<html><body>\r\n<!--StartFragment-->";
const suffix = "<!--EndFragment-->\r\n</body></html>";

pub const FragmentRange = struct {
    start: usize,
    end: usize,
};

/// Wrap an HTML fragment in the CF_HTML clipboard envelope.
///
/// Returns a freshly-allocated byte slice owned by `alloc` containing
/// the complete CF_HTML text ready for `SetClipboardData`. The caller
/// must free the returned slice with `alloc.free`.
pub fn wrapFragment(alloc: Allocator, html: []const u8) Allocator.Error![]u8 {
    const header_len = header_template.len;
    const start_html = header_len;
    const start_fragment = header_len + prefix.len;
    const end_fragment = start_fragment + html.len;
    const end_html = end_fragment + suffix.len;

    const total = end_html;
    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);

    // Write header with real offsets.
    var pos: usize = 0;
    pos += (std.fmt.bufPrint(buf[pos..], "Version:0.9\r\n" ++
        "StartHTML:{d:0>10}\r\n" ++
        "EndHTML:{d:0>10}\r\n" ++
        "StartFragment:{d:0>10}\r\n" ++
        "EndFragment:{d:0>10}\r\n", .{
        start_html,
        end_html,
        start_fragment,
        end_fragment,
    }) catch unreachable).len;

    // Sanity: header consumed exactly header_len bytes.
    std.debug.assert(pos == header_len);

    // Write body prefix.
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    // Write fragment.
    @memcpy(buf[pos..][0..html.len], html);
    pos += html.len;

    // Write body suffix.
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    std.debug.assert(pos == total);
    return buf;
}

fn headerRegionEnd(output: []const u8) usize {
    if (std.mem.indexOf(u8, output, "\r\n\r\n")) |idx| return idx;
    if (std.mem.indexOf(u8, output, "\n\n")) |idx| return idx;
    if (std.mem.indexOfScalar(u8, output, '<')) |idx| return idx;
    return output.len;
}

pub fn headerOffset(output: []const u8, comptime key: []const u8) ?usize {
    const needle = key ++ ":";
    const header = output[0..headerRegionEnd(output)];
    const start = std.mem.indexOf(u8, header, needle) orelse return null;
    var p: usize = start + needle.len;
    while (p < header.len and (header[p] == ' ' or header[p] == '\t')) : (p += 1) {}
    const digit_start = p;
    while (p < header.len and header[p] >= '0' and header[p] <= '9') : (p += 1) {}
    if (p == digit_start) return null;
    return std.fmt.parseInt(usize, header[digit_start..p], 10) catch null;
}

pub fn fragmentRange(output: []const u8) ?FragmentRange {
    const start = headerOffset(output, "StartFragment") orelse return null;
    const end = headerOffset(output, "EndFragment") orelse return null;
    if (start > end or end > output.len) return null;
    return .{ .start = start, .end = end };
}

pub fn extractFragment(alloc: Allocator, output: []const u8) Allocator.Error![]u8 {
    if (fragmentRange(output)) |range| {
        return alloc.dupe(u8, output[range.start..range.end]);
    }
    const start_marker = "<!--StartFragment-->";
    const end_marker = "<!--EndFragment-->";
    if (std.mem.indexOf(u8, output, start_marker)) |start| {
        const fragment_start = start + start_marker.len;
        const fragment_end = std.mem.indexOfPos(
            u8,
            output,
            fragment_start,
            end_marker,
        ) orelse output.len;
        return alloc.dupe(u8, output[fragment_start..fragment_end]);
    }
    return alloc.dupe(u8, output);
}

fn appendEntity(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    entity: []const u8,
) Allocator.Error!bool {
    const value: ?u21 = if (std.mem.eql(u8, entity, "amp"))
        '&'
    else if (std.mem.eql(u8, entity, "lt"))
        '<'
    else if (std.mem.eql(u8, entity, "gt"))
        '>'
    else if (std.mem.eql(u8, entity, "quot"))
        '"'
    else if (std.mem.eql(u8, entity, "apos") or
        std.mem.eql(u8, entity, "#39"))
        '\''
    else if (std.mem.eql(u8, entity, "nbsp"))
        ' '
    else if (std.mem.startsWith(u8, entity, "#x"))
        std.fmt.parseInt(u21, entity[2..], 16) catch null
    else if (std.mem.startsWith(u8, entity, "#X"))
        std.fmt.parseInt(u21, entity[2..], 16) catch null
    else if (std.mem.startsWith(u8, entity, "#"))
        std.fmt.parseInt(u21, entity[1..], 10) catch null
    else
        null;
    const codepoint = value orelse return false;
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &encoded) catch return false;
    try output.appendSlice(alloc, encoded[0..length]);
    return true;
}

fn isBlockTag(tag: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag, "br") or
        std.ascii.eqlIgnoreCase(tag, "div") or
        std.ascii.eqlIgnoreCase(tag, "li") or
        std.ascii.eqlIgnoreCase(tag, "p") or
        std.ascii.eqlIgnoreCase(tag, "pre") or
        std.ascii.eqlIgnoreCase(tag, "tr");
}

fn tagName(tag: []const u8) []const u8 {
    var start: usize = 0;
    while (start < tag.len and std.ascii.isWhitespace(tag[start])) : (start += 1) {}
    if (start < tag.len and tag[start] == '/') start += 1;
    while (start < tag.len and std.ascii.isWhitespace(tag[start])) : (start += 1) {}
    var end = start;
    while (end < tag.len and !std.ascii.isWhitespace(tag[end])) : (end += 1) {}
    if (end > start and tag[end - 1] == '/') end -= 1;
    return tag[start..end];
}

pub fn fragmentToPlainText(
    alloc: Allocator,
    fragment: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    var index: usize = 0;
    var no_future_tag_end = false;
    var no_future_entity_end = false;
    var entity_end: ?usize = null;
    while (index < fragment.len) {
        if (std.mem.startsWith(u8, fragment[index..], "<!--")) {
            const end = std.mem.indexOfPos(u8, fragment, index + 4, "-->") orelse {
                index = fragment.len;
                continue;
            };
            index = end + 3;
            continue;
        }
        if (fragment[index] == '<') {
            if (no_future_tag_end) {
                try output.append(alloc, fragment[index]);
                index += 1;
                continue;
            }
            var end = index + 1;
            while (end < fragment.len and fragment[end] != '>') : (end += 1) {}
            if (end == fragment.len) {
                no_future_tag_end = true;
                try output.append(alloc, fragment[index]);
                index += 1;
                continue;
            }
            const tag = tagName(fragment[index + 1 .. end]);
            const closing = std.mem.startsWith(u8, fragment[index + 1 .. end], "/");
            if (std.ascii.eqlIgnoreCase(tag, "br") or
                (closing and isBlockTag(tag)))
            {
                if (output.items.len == 0 or output.items[output.items.len - 1] != '\n') {
                    try output.append(alloc, '\n');
                }
            }
            index = end + 1;
            continue;
        }
        if (fragment[index] == '&') {
            if (entity_end) |known_end| {
                if (known_end <= index) entity_end = null;
            }
            if (entity_end == null and !no_future_entity_end) {
                var end = index + 1;
                while (end < fragment.len and fragment[end] != ';') : (end += 1) {}
                if (end == fragment.len) {
                    no_future_entity_end = true;
                } else {
                    entity_end = end;
                }
            }
            if (entity_end) |end| {
                if (try appendEntity(
                    &output,
                    alloc,
                    fragment[index + 1 .. end],
                )) {
                    index = end + 1;
                    entity_end = null;
                    continue;
                }
            }
        }
        try output.append(alloc, fragment[index]);
        index += 1;
    }
    while (output.items.len > 0 and
        (output.items[output.items.len - 1] == '\n' or
            output.items[output.items.len - 1] == '\r'))
    {
        _ = output.pop();
    }
    return output.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "wrapFragment emits a valid CF_HTML header" {
    const alloc = std.testing.allocator;
    const out = try wrapFragment(alloc, "<b>test</b>");
    defer alloc.free(out);

    // Each key must be present with a 10-digit value.
    inline for (.{ "StartHTML", "EndHTML", "StartFragment", "EndFragment" }) |key| {
        const needle = key ++ ":";
        const idx = std.mem.indexOf(u8, out, needle).?;
        const val_start = idx + needle.len;
        const val_end = std.mem.indexOfPos(u8, out, val_start, "\r\n").?;
        try std.testing.expectEqual(@as(usize, 10), val_end - val_start);
    }
}

test "wrapFragment offsets point at the correct byte positions" {
    const alloc = std.testing.allocator;
    const fragment = "<em>hi</em>";
    const out = try wrapFragment(alloc, fragment);
    defer alloc.free(out);

    const sh = headerOffset(out, "StartHTML").?;
    const eh = headerOffset(out, "EndHTML").?;
    const sf = headerOffset(out, "StartFragment").?;
    const ef = headerOffset(out, "EndFragment").?;

    // StartHTML -> "<html>"
    try std.testing.expect(std.mem.startsWith(u8, out[sh..], "<html>"));

    // EndHTML -> one past "</html>"
    try std.testing.expect(eh == out.len);
    try std.testing.expect(std.mem.endsWith(u8, out[0..eh], "</html>"));

    // StartFragment -> first byte of the fragment
    try std.testing.expectEqualStrings(fragment, out[sf..ef]);

    // EndFragment -> the '<' of <!--EndFragment-->
    try std.testing.expectEqual(@as(u8, '<'), out[ef]);
    try std.testing.expect(std.mem.startsWith(u8, out[ef..], "<!--EndFragment-->"));
}

test "wrapFragment preserves the fragment bytes verbatim" {
    const alloc = std.testing.allocator;
    const fragment = "<span style=\"color:red\">hello</span>";
    const out = try wrapFragment(alloc, fragment);
    defer alloc.free(out);

    const sf = headerOffset(out, "StartFragment").?;
    const ef = headerOffset(out, "EndFragment").?;
    try std.testing.expectEqualStrings(fragment, out[sf..ef]);
}

test "wrapFragment handles empty fragment" {
    const alloc = std.testing.allocator;
    const out = try wrapFragment(alloc, "");
    defer alloc.free(out);

    const sf = headerOffset(out, "StartFragment").?;
    const ef = headerOffset(out, "EndFragment").?;
    try std.testing.expectEqual(sf, ef);

    // Still valid structure.
    const sh = headerOffset(out, "StartHTML").?;
    const eh = headerOffset(out, "EndHTML").?;
    try std.testing.expect(std.mem.startsWith(u8, out[sh..], "<html>"));
    try std.testing.expect(eh == out.len);
}

test "wrapFragment handles unicode fragment" {
    const alloc = std.testing.allocator;
    const fragment = "\xc3\xa9\xe2\x80\x93\xf0\x9f\x91\x8b"; // e-acute, en-dash, wave emoji
    const out = try wrapFragment(alloc, fragment);
    defer alloc.free(out);

    const sf = headerOffset(out, "StartFragment").?;
    const ef = headerOffset(out, "EndFragment").?;
    try std.testing.expectEqualStrings(fragment, out[sf..ef]);
}

test "fragmentRange parses lenient CF_HTML fragment offsets" {
    const raw =
        "Version:0.9\r\n" ++
        "StartFragment:  5\r\n" ++
        "EndFragment:\t10\r\n" ++
        "hello world";
    const range = fragmentRange(raw).?;
    try std.testing.expectEqual(@as(usize, 5), range.start);
    try std.testing.expectEqual(@as(usize, 10), range.end);
}

test "fragmentRange rejects invalid CF_HTML fragment offsets" {
    const inverted =
        "StartFragment:10\r\n" ++
        "EndFragment:5\r\n" ++
        "hello world";
    try std.testing.expect(fragmentRange(inverted) == null);

    const out_of_bounds =
        "StartFragment:0\r\n" ++
        "EndFragment:99\r\n" ++
        "hello world";
    try std.testing.expect(fragmentRange(out_of_bounds) == null);
}

test "headerOffset ignores keys outside the CF_HTML header" {
    const raw =
        "Version:0.9\r\n" ++
        "StartFragment:0000000017\r\n" ++
        "\r\n" ++
        "<p>StartFragment:9999999999</p>";
    try std.testing.expectEqual(@as(?usize, 17), headerOffset(raw, "StartFragment"));
    try std.testing.expect(headerOffset(raw, "EndFragment") == null);
}

test "headerOffset treats any html tag as a fallback body boundary" {
    const raw =
        "Version:0.9\r\n" ++
        "StartFragment:0000000017\r\n" ++
        "<!DOCTYPE html><p>StartFragment:9999999999</p>";
    try std.testing.expectEqual(@as(?usize, 17), headerOffset(raw, "StartFragment"));
    try std.testing.expect(headerOffset(raw, "EndFragment") == null);
}

test "extractFragment returns only the CF_HTML fragment" {
    const alloc = std.testing.allocator;
    const wrapped = try wrapFragment(alloc, "<b>hello</b>");
    defer alloc.free(wrapped);
    const fragment = try extractFragment(alloc, wrapped);
    defer alloc.free(fragment);
    try std.testing.expectEqualStrings("<b>hello</b>", fragment);
}

test "extractFragment falls back to CF_HTML comment markers" {
    const alloc = std.testing.allocator;
    const raw = "Version:0.9\r\n<!--StartFragment--><i>hello</i><!--EndFragment-->";
    const fragment = try extractFragment(alloc, raw);
    defer alloc.free(fragment);
    try std.testing.expectEqualStrings("<i>hello</i>", fragment);
}

test "fragmentToPlainText removes markup and decodes entities" {
    const alloc = std.testing.allocator;
    const plain = try fragmentToPlainText(
        alloc,
        "<p>Hello &amp; <b>world</b></p><p>&#x1F680;</p>",
    );
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("Hello & world\n🚀", plain);
}

test "fragmentToPlainText bounds malformed delimiter scanning" {
    const alloc = std.testing.allocator;
    const repeated = 32 * 1024;
    const malformed = try alloc.alloc(u8, repeated * 2);
    defer alloc.free(malformed);
    @memset(malformed[0..repeated], '<');
    @memset(malformed[repeated..], '&');

    const started = std.time.nanoTimestamp();
    const plain = try fragmentToPlainText(alloc, malformed);
    defer alloc.free(plain);
    const elapsed = std.time.nanoTimestamp() - started;

    try std.testing.expectEqualSlices(u8, malformed, plain);
    try std.testing.expect(elapsed < 100 * std.time.ns_per_ms);
}

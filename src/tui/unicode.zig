/// UTF-8 and display-width utilities for the TUI.
const std = @import("std");
const vaxis = @import("vaxis");

/// Calculate the display width (in terminal columns) of a UTF-8 string.
///
/// NOTE: We intentionally return `usize` and accumulate per-codepoint widths.
/// `vaxis.gwidth.gwidth` returns `u16` and can overflow on very long strings.
pub fn displayWidth(str: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        const end = @min(i + cp_len, str.len);
        const cp_width: usize = vaxis.gwidth.gwidth(str[i..end], .unicode);
        cols += cp_width;
        i = end;
    }
    return cols;
}

/// Truncate a UTF-8 string so its display width fits within `max_cols` terminal columns.
/// Returns a slice that ends on a valid UTF-8 boundary and whose display width <= max_cols.
pub fn truncateToDisplayWidth(str: []const u8, max_cols: usize) []const u8 {
    if (max_cols == 0) return str[0..0];
    var cols: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        const end = @min(i + cp_len, str.len);
        const cp_width: usize = vaxis.gwidth.gwidth(str[i..end], .unicode);
        if (cols + cp_width > max_cols) break;
        cols += cp_width;
        i = end;
    }
    return str[0..i];
}

/// Find the byte offset of the start of the previous UTF-8 codepoint before `pos`.
/// If pos is 0, returns 0.
pub fn prevCodepointStart(buf: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    // Walk back over continuation bytes (10xxxxxx)
    while (p > 0 and (buf[p] & 0xC0) == 0x80) : (p -= 1) {}
    return p;
}

/// Find the byte offset just past the current UTF-8 codepoint at `pos`.
/// If pos >= len, returns len.
pub fn nextCodepointEnd(buf: []const u8, pos: usize) usize {
    if (pos >= buf.len) return buf.len;
    const cp_len = std.unicode.utf8ByteSequenceLength(buf[pos]) catch 1;
    return @min(pos + cp_len, buf.len);
}

/// Calculate display width of buf[0..byte_pos] (for cursor positioning).
pub fn displayWidthUpTo(buf: []const u8, byte_pos: usize) usize {
    const end = @min(byte_pos, buf.len);
    return displayWidth(buf[0..end]);
}

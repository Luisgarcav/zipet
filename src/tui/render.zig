/// TUI rendering functions for zipet.
const std = @import("std");
const config = @import("../config.zig");
const store = @import("../store.zig");
const t = @import("types.zig");

const Window = t.Window;
const State = t.State;
const Style = t.Style;

// ── Help lines ──
const HelpLine = struct { text: []const u8, is_header: bool, is_spacer: bool };
const help_lines = [_]HelpLine{
    .{ .text = " QUICK REFERENCE", .is_header = true, .is_spacer = false },
    .{ .text = "", .is_header = false, .is_spacer = true },
    .{ .text = " Navigation", .is_header = true, .is_spacer = false },
    .{ .text = "  j / k         Up / Down", .is_header = false, .is_spacer = false },
    .{ .text = "  gg / G        First / Last", .is_header = false, .is_spacer = false },
    .{ .text = "  Ctrl-D / U    Page Down / Up", .is_header = false, .is_spacer = false },
    .{ .text = "  /             Search", .is_header = false, .is_spacer = false },
    .{ .text = "  Esc           Clear / Back", .is_header = false, .is_spacer = false },
    .{ .text = "", .is_header = false, .is_spacer = true },
    .{ .text = " Actions", .is_header = true, .is_spacer = false },
    .{ .text = "  Enter         Run snippet", .is_header = false, .is_spacer = false },
    .{ .text = "  e             Edit snippet", .is_header = false, .is_spacer = false },
    .{ .text = "  d             Delete (confirm)", .is_header = false, .is_spacer = false },
    .{ .text = "  a             Add new snippet", .is_header = false, .is_spacer = false },
    .{ .text = "  w             Create workflow", .is_header = false, .is_spacer = false },
    .{ .text = "  y             Yank to clipboard", .is_header = false, .is_spacer = false },
    .{ .text = "  p             Paste from clipboard", .is_header = false, .is_spacer = false },
    .{ .text = "  o             Open TOML file", .is_header = false, .is_spacer = false },
    .{ .text = "  i             Full info panel", .is_header = false, .is_spacer = false },
    .{ .text = "  Space         Toggle preview", .is_header = false, .is_spacer = false },
    .{ .text = "  x             Toggle select", .is_header = false, .is_spacer = false },
    .{ .text = "  X             Select all / Clear", .is_header = false, .is_spacer = false },
    .{ .text = "  R             Run selected ∥", .is_header = false, .is_spacer = false },
    .{ .text = "  D             Delete selected", .is_header = false, .is_spacer = false },
    .{ .text = "  t             Filter by tag", .is_header = false, .is_spacer = false },
    .{ .text = "  W             Workspace picker", .is_header = false, .is_spacer = false },
    .{ .text = "  P             Pack browser", .is_header = false, .is_spacer = false },
    .{ .text = "", .is_header = false, .is_spacer = true },
    .{ .text = " Commands", .is_header = true, .is_spacer = false },
    .{ .text = "  :q            Quit", .is_header = false, .is_spacer = false },
    .{ .text = "  :w            Save all", .is_header = false, .is_spacer = false },
    .{ .text = "  :wq           Save & quit", .is_header = false, .is_spacer = false },
    .{ .text = "  :tags         Tag picker", .is_header = false, .is_spacer = false },
    .{ .text = "  :export       Export snippets", .is_header = false, .is_spacer = false },
    .{ .text = "  :ws           Workspace picker", .is_header = false, .is_spacer = false },
    .{ .text = "  :packs        Pack browser", .is_header = false, .is_spacer = false },
    .{ .text = "", .is_header = false, .is_spacer = true },
    .{ .text = "  ? to close", .is_header = false, .is_spacer = false },
};

const SIDEBAR_W: u16 = 33;

pub fn renderMainScreen(win: Window, state: *State, snip_store: *store.Store, cfg: config.Config) void {
    const show_sidebar = state.mode == .help and win.width > SIDEBAR_W + 30;
    const main_w: u16 = if (show_sidebar) win.width - SIDEBAR_W - 1 else win.width;
    const mw = win.child(.{ .width = main_w, .height = win.height });

    // Status bar
    {
        const bar = mw.child(.{ .height = 1 });
        bar.fill(.{ .style = t.reverse_style });
        _ = bar.print(&.{.{ .text = " zipet", .style = t.reverse_style }}, .{});

        if (state.active_workspace) |ws| {
            const ws_col: u16 = 7;
            _ = bar.print(&.{
                .{ .text = " 📂 ", .style = t.reverse_style },
                .{ .text = ws, .style = .{ .reverse = true, .bold = true } },
            }, .{ .col_offset = ws_col });
        }

        const sel_count = state.selectionCount();
        var wf_count: usize = 0;
        for (snip_store.snippets.items) |s| if (s.kind == .workflow) {
            wf_count += 1;
        };
        var rb: [96]u8 = undefined;
        const rt = if (sel_count > 0)
            std.fmt.bufPrint(&rb, " {d} selected  {d} snippets ", .{ sel_count, snip_store.snippets.items.len }) catch "?"
        else if (wf_count > 0)
            std.fmt.bufPrint(&rb, "{d} snippets  {d} wf ", .{ snip_store.snippets.items.len - wf_count, wf_count }) catch "?"
        else
            std.fmt.bufPrint(&rb, "{d} snippets ", .{snip_store.snippets.items.len}) catch "?";
        const rc: u16 = mw.width -| @as(u16, @intCast(@min(rt.len, mw.width)));
        const bar_style: t.Style = if (sel_count > 0) .{ .reverse = true, .fg = .{ .index = 3 } } else t.reverse_style;
        _ = bar.print(&.{.{ .text = rt, .style = bar_style }}, .{ .col_offset = rc });
    }

    // Search bar (row 1)
    if (state.mode == .search) {
        _ = mw.print(&.{
            .{ .text = " >", .style = t.accentBoldStyle(cfg.accent_color) },
            .{ .text = " ", .style = .{} },
            .{ .text = state.searchQuery(), .style = .{} },
        }, .{ .row_offset = 1 });
    } else if (state.mode == .command) {
        _ = mw.print(&.{ .{ .text = " :", .style = .{} }, .{ .text = state.commandStr(), .style = .{} } }, .{ .row_offset = 1 });
    } else {
        if (state.search_len > 0) {
            _ = mw.print(&.{ .{ .text = " / ", .style = t.dim_style }, .{ .text = state.searchQuery(), .style = .{} } }, .{ .row_offset = 1 });
        } else {
            _ = mw.print(&.{.{ .text = " type / to search", .style = t.dim_style }}, .{ .row_offset = 1 });
        }
    }

    // Separator (row 2)
    hline(mw, 2, main_w);

    // List
    const list_h = state.listHeight(win.height);
    renderList(mw, state, snip_store, cfg, list_h);

    // Preview
    if (state.preview_visible) {
        const py: u16 = @intCast(@min(3 + list_h, win.height -| 1));
        hline(mw, py, main_w);
        renderPreview(mw, state, snip_store, cfg, py + 1);
    }

    // Tag filter indicator
    if (state.active_tag_filter) |tf| {
        const ty: u16 = win.height -| 2;
        _ = mw.print(&.{
            .{ .text = " filter: [", .style = t.accentStyle(cfg.accent_color) },
            .{ .text = tf, .style = t.accentStyle(cfg.accent_color) },
            .{ .text = "]  (t change, Esc clear)", .style = t.dim_style },
        }, .{ .row_offset = ty });
    }

    // Tag picker overlay
    if (state.mode == .tag_picker) {
        renderTagPicker(mw, state, cfg);
        return;
    }

    // Info overlay
    if (state.mode == .info) {
        renderInfoOverlay(mw, state, snip_store, cfg);
        return;
    }

    // Bottom bar
    {
        const by: u16 = win.height -| 1;
        if (state.mode == .confirm_delete) {
            _ = mw.print(&.{.{ .text = " Delete this snippet? (y/N)", .style = t.del_style }}, .{ .row_offset = by });
        } else if (state.mode == .confirm_delete_multi) {
            var dbuf: [80]u8 = undefined;
            const dtxt = std.fmt.bufPrint(&dbuf, " Delete {d} selected snippets? (y/N)", .{state.selectionCount()}) catch " Delete selected? (y/N)";
            _ = mw.print(&.{.{ .text = dtxt, .style = t.del_style }}, .{ .row_offset = by });
        } else if (state.message) |msg| {
            _ = mw.print(&.{.{ .text = msg, .style = t.dim_style }}, .{ .row_offset = by });
            state.message = null;
        } else if (state.selectionCount() > 0) {
            _ = mw.print(&.{.{ .text = " x toggle  X clear  R run parallel  D delete  Enter run cursor", .style = .{ .fg = .{ .index = 3 } } }}, .{ .row_offset = by });
        } else {
            _ = mw.print(&.{.{ .text = " j/k move  Enter run  x select  a add  w workflow  e edit  d del  P packs  ? help", .style = t.dim_style }}, .{ .row_offset = by });
        }
    }

    // Help sidebar
    if (show_sidebar) {
        renderHelpSidebar(win, win.width, win.height, cfg);
    } else if (state.mode == .help) {
        const by = win.height -| 1;
        if (by >= 3) {
            _ = mw.print(&.{.{ .text = " j/k gg/G Ctrl-D/U / Enter e d a y p t o i :q :w ? — press ? to close", .style = t.dim_style }}, .{ .row_offset = by });
        }
    }
}

pub fn hline(win: Window, row: u16, cols: u16) void {
    var c: u16 = 0;
    while (c < cols) : (c += 1) {
        win.writeCell(c, row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = t.dim_style });
    }
}

fn renderList(win: Window, state: *State, snip_store: *store.Store, cfg: config.Config, list_h: usize) void {
    const total = state.filtered_indices.len;
    const ab = t.accentBoldStyle(cfg.accent_color);

    var i: usize = 0;
    while (i < list_h) : (i += 1) {
        const row: u16 = 3 + @as(u16, @intCast(i));
        if (row >= win.height) break;
        const idx = state.scroll_offset + i;
        if (idx >= total) break;

        const si = state.filtered_indices[idx];
        const snip = &snip_store.snippets.items[si];
        const sel = idx == state.cursor;

        const icon: []const u8 = switch (snip.kind) {
            .workflow => ">>",
            .snippet => " $",
            .chain => "<>",
        };
        const ks: Style = switch (snip.kind) {
            .workflow => t.wf_style,
            .snippet => t.snip_icon_style,
            .chain => t.chain_style,
        };

        const is_marked = state.isSelected(si);

        if (sel and is_marked) {
            _ = win.print(&.{.{ .text = " ▸●", .style = ab }}, .{ .row_offset = row });
        } else if (sel) {
            _ = win.print(&.{.{ .text = " ▸ ", .style = ab }}, .{ .row_offset = row });
        } else if (is_marked) {
            _ = win.print(&.{.{ .text = "  ●", .style = .{ .fg = .{ .index = 3 }, .bold = true } }}, .{ .row_offset = row });
        } else {
            _ = win.print(&.{.{ .text = "   ", .style = .{} }}, .{ .row_offset = row });
        }
        _ = win.print(&.{.{ .text = icon, .style = ks }}, .{ .row_offset = row, .col_offset = 3 });

        const name_col: u16 = 7;
        const name_style = if (sel) ab else t.bold_style;
        _ = win.print(&.{.{ .text = snip.name, .style = name_style }}, .{ .row_offset = row, .col_offset = name_col });

        const desc_col: u16 = 30;
        if (desc_col < win.width and snip.desc.len > 0) {
            const mx = win.width -| desc_col -| 15;
            const de = @min(snip.desc.len, mx);
            _ = win.print(&.{.{ .text = snip.desc[0..de], .style = t.dim_style }}, .{ .row_offset = row, .col_offset = desc_col });
        }

        if (snip.tags.len > 0 and win.width > 60) {
            var tc: u16 = win.width -| 15;
            _ = win.print(&.{.{ .text = "[", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = tc });
            tc += 1;
            for (snip.tags, 0..) |tag, ti| {
                if (ti > 0) {
                    _ = win.print(&.{.{ .text = ",", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = tc });
                    tc += 1;
                }
                if (tc + @as(u16, @intCast(tag.len)) >= win.width) break;
                _ = win.print(&.{.{ .text = tag, .style = t.dim_style }}, .{ .row_offset = row, .col_offset = tc });
                tc += @intCast(@min(tag.len, win.width - tc));
            }
            if (tc < win.width) _ = win.print(&.{.{ .text = "]", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = tc });
        }
    }
}

fn renderPreview(win: Window, state: *State, snip_store: *store.Store, cfg: config.Config, start_row: u16) void {
    const total = state.filtered_indices.len;
    if (total == 0 or state.cursor >= total) return;
    if (start_row >= win.height) return;

    const si = state.filtered_indices[state.cursor];
    const snip = &snip_store.snippets.items[si];
    const as = t.accentStyle(cfg.accent_color);

    if (snip.kind == .workflow) {
        _ = win.print(&.{
            .{ .text = " >> workflow ", .style = t.wf_style },
            .{ .text = snip.cmd, .style = t.dim_style },
        }, .{ .row_offset = start_row });
    } else {
        _ = win.print(&.{
            .{ .text = " $ ", .style = as },
            .{ .text = snip.cmd, .style = .{} },
        }, .{ .row_offset = start_row });
    }

    if (start_row + 1 < win.height and snip.params.len > 0) {
        _ = win.print(&.{.{ .text = " params: ", .style = t.dim_style }}, .{ .row_offset = start_row + 1 });
        var col: u16 = 10;
        for (snip.params, 0..) |p, pi| {
            if (pi > 0) {
                _ = win.print(&.{.{ .text = ", ", .style = t.dim_style }}, .{ .row_offset = start_row + 1, .col_offset = col });
                col += 2;
            }
            _ = win.print(&.{.{ .text = p.name, .style = t.dim_style }}, .{ .row_offset = start_row + 1, .col_offset = col });
            col += @intCast(@min(p.name.len, win.width -| col));
            if (p.default) |d| {
                _ = win.print(&.{.{ .text = "=", .style = t.dim_style }}, .{ .row_offset = start_row + 1, .col_offset = col });
                col += 1;
                _ = win.print(&.{.{ .text = d, .style = t.dim_style }}, .{ .row_offset = start_row + 1, .col_offset = col });
                col += @intCast(@min(d.len, win.width -| col));
            }
        }
    }
}

pub fn renderTagPicker(win: Window, state: *State, cfg: config.Config) void {
    const ab = t.accentBoldStyle(cfg.accent_color);
    var row: u16 = @intCast(@min(win.height / 2, win.height -| @as(u16, @intCast(state.tag_list.len)) -| 4));
    _ = win.print(&.{.{ .text = " ── Select Tag ──", .style = ab }}, .{ .row_offset = row });
    row += 1;
    const mx = @min(state.tag_list.len, if (win.height > 10) win.height - 10 else 5);
    for (state.tag_list[0..mx], 0..) |tag, ti| {
        if (row >= win.height) break;
        if (ti == state.tag_cursor)
            _ = win.print(&.{ .{ .text = " ▸ ", .style = ab }, .{ .text = tag, .style = ab } }, .{ .row_offset = row })
        else
            _ = win.print(&.{ .{ .text = "   ", .style = .{} }, .{ .text = tag, .style = .{} } }, .{ .row_offset = row });
        row += 1;
    }
    if (row < win.height)
        _ = win.print(&.{.{ .text = " j/k move  Enter select  x clear  Esc cancel", .style = t.dim_style }}, .{ .row_offset = row });
}

fn renderInfoOverlay(win: Window, state: *State, snip_store: *store.Store, cfg: config.Config) void {
    const total = state.filtered_indices.len;
    if (total == 0 or state.cursor >= total) return;
    const si = state.filtered_indices[state.cursor];
    const snip = &snip_store.snippets.items[si];
    const ab = t.accentBoldStyle(cfg.accent_color);
    const as = t.accentStyle(cfg.accent_color);
    var row: u16 = @intCast(@min(@as(u16, 4), win.height -| 12));

    _ = win.print(&.{.{ .text = " ── Snippet Info ──", .style = ab }}, .{ .row_offset = row });
    row += 1;
    _ = win.print(&.{ .{ .text = " Name:      ", .style = .{} }, .{ .text = snip.name, .style = t.bold_style } }, .{ .row_offset = row });
    row += 1;
    _ = win.print(&.{ .{ .text = " Desc:      ", .style = .{} }, .{ .text = snip.desc, .style = .{} } }, .{ .row_offset = row });
    row += 1;
    _ = win.print(&.{ .{ .text = " Namespace: ", .style = .{} }, .{ .text = snip.namespace, .style = .{} } }, .{ .row_offset = row });
    row += 1;
    _ = win.print(&.{ .{ .text = " Kind:      ", .style = .{} }, .{ .text = @tagName(snip.kind), .style = .{} } }, .{ .row_offset = row });
    row += 1;

    _ = win.print(&.{.{ .text = " Tags:      ", .style = .{} }}, .{ .row_offset = row });
    if (snip.tags.len > 0) {
        var col: u16 = 12;
        for (snip.tags, 0..) |tag, ti| {
            if (ti > 0) {
                _ = win.print(&.{.{ .text = ", ", .style = .{} }}, .{ .row_offset = row, .col_offset = col });
                col += 2;
            }
            _ = win.print(&.{.{ .text = tag, .style = .{} }}, .{ .row_offset = row, .col_offset = col });
            col += @intCast(@min(tag.len, win.width -| col));
        }
    } else {
        _ = win.print(&.{.{ .text = "(none)", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = 12 });
    }
    row += 1;

    _ = win.print(&.{.{ .text = " Command:", .style = .{} }}, .{ .row_offset = row });
    row += 1;
    _ = win.print(&.{ .{ .text = "   $ ", .style = as }, .{ .text = snip.cmd, .style = .{} } }, .{ .row_offset = row });
    row += 1;

    if (snip.params.len > 0 and row < win.height) {
        var pb: [32]u8 = undefined;
        const pt = std.fmt.bufPrint(&pb, " Parameters ({d}):", .{snip.params.len}) catch " Parameters:";
        _ = win.print(&.{.{ .text = pt, .style = .{} }}, .{ .row_offset = row });
        row += 1;
        for (snip.params) |p| {
            if (row >= win.height) break;
            _ = win.print(&.{ .{ .text = "   • ", .style = .{} }, .{ .text = p.name, .style = .{} } }, .{ .row_offset = row });
            if (p.default) |d| {
                const col: u16 = @intCast(5 + p.name.len);
                _ = win.print(&.{ .{ .text = " = ", .style = t.dim_style }, .{ .text = d, .style = t.dim_style } }, .{ .row_offset = row, .col_offset = col });
            }
            row += 1;
        }
    }
    if (row < win.height)
        _ = win.print(&.{.{ .text = " i/Esc/q close info", .style = t.dim_style }}, .{ .row_offset = row });
}

fn renderHelpSidebar(win: Window, full_w: u16, full_h: u16, cfg: config.Config) void {
    const sx: u16 = full_w - SIDEBAR_W;
    const sidebar = win.child(.{
        .x_off = @intCast(sx),
        .width = SIDEBAR_W,
        .height = full_h,
        .border = .{ .where = .all, .glyphs = .single_rounded, .style = t.dim_style },
    });
    const ab = t.accentBoldStyle(cfg.accent_color);
    const as = t.accentStyle(cfg.accent_color);
    var row: u16 = 0;
    for (help_lines) |line| {
        if (row >= sidebar.height) break;
        if (line.is_spacer) {
            row += 1;
            continue;
        }
        if (line.is_header) {
            _ = sidebar.print(&.{.{ .text = line.text, .style = ab }}, .{ .row_offset = row });
        } else {
            if (findKeySplit(line.text)) |sp| {
                _ = sidebar.print(&.{
                    .{ .text = line.text[0..sp], .style = as },
                    .{ .text = line.text[sp..], .style = t.dim_style },
                }, .{ .row_offset = row });
            } else {
                _ = sidebar.print(&.{.{ .text = line.text, .style = .{} }}, .{ .row_offset = row });
            }
        }
        row += 1;
    }
}

fn findKeySplit(text: []const u8) ?usize {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    while (i < text.len and text[i] != ' ') : (i += 1) {}
    var spaces: usize = 0;
    const gs = i;
    while (i < text.len and text[i] == ' ') : (i += 1) {
        spaces += 1;
    }
    if (spaces >= 2 and i < text.len) return gs;
    return null;
}

// ── Form rendering ──
pub fn renderForm(win: Window, state: *State, cfg: config.Config) void {
    const ab = t.accentBoldStyle(cfg.accent_color);
    const title: []const u8 = switch (state.form.purpose) {
        .add => "── Add Snippet ──",
        .edit => "── Edit Snippet ──",
        .paste => "── Paste as Snippet ──",
    };

    _ = win.print(&.{.{ .text = "", .style = .{} }}, .{ .row_offset = 1 });
    _ = win.print(&.{.{ .text = title, .style = ab }}, .{ .row_offset = 2, .col_offset = 2 });

    const field_x: u16 = 16;
    var row: u16 = 4;
    var fi: usize = 0;
    while (fi < state.form.field_count) : (fi += 1) {
        const label = state.form.labels[fi];
        const field = &state.form.fields[fi];
        const is_active = fi == state.form.active;
        const label_style = if (is_active) ab else t.dim_style;

        _ = win.print(&.{.{ .text = "  ", .style = .{} }}, .{ .row_offset = row });
        _ = win.print(&.{.{ .text = label, .style = label_style }}, .{ .row_offset = row, .col_offset = 2 });
        _ = win.print(&.{.{ .text = ":", .style = label_style }}, .{ .row_offset = row, .col_offset = @intCast(@min(2 + label.len, win.width -| 1)) });

        const content = field.text();
        const field_w = win.width -| field_x -| 2;
        const display_len = @min(content.len, field_w);

        if (is_active) {
            var c: u16 = field_x;
            while (c < field_x + field_w) : (c += 1) {
                win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 236 } } });
            }
            _ = win.print(&.{.{ .text = content[0..display_len], .style = .{ .bg = .{ .index = 236 } } }}, .{ .row_offset = row, .col_offset = field_x });
        } else {
            if (content.len > 0) {
                _ = win.print(&.{.{ .text = content[0..display_len], .style = .{} }}, .{ .row_offset = row, .col_offset = field_x });
            } else {
                _ = win.print(&.{.{ .text = "—", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = field_x });
            }
        }

        row += 2;
    }

    if (state.form.error_msg) |emsg| {
        _ = win.print(&.{.{ .text = emsg, .style = t.err_style }}, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }

    row += 1;
    _ = win.print(&.{.{ .text = "  Tab/↓: next field   Shift+Tab/↑: prev   Ctrl+S: save   Esc: cancel", .style = t.dim_style }}, .{ .row_offset = row });
}

// ── Param input rendering ──
pub fn renderParamInput(win: Window, state: *State, snip_store: *store.Store, cfg: config.Config) void {
    const ab = t.accentBoldStyle(cfg.accent_color);
    const as = t.accentStyle(cfg.accent_color);
    const pi = &state.param_input;

    var title_buf: [128]u8 = undefined;
    const snip = &snip_store.snippets.items[pi.snippet_idx];
    const title = std.fmt.bufPrint(&title_buf, "── Run: {s} ──", .{snip.name}) catch "── Run ──";

    _ = win.print(&.{.{ .text = title, .style = ab }}, .{ .row_offset = 1, .col_offset = 2 });
    _ = win.print(&.{.{ .text = snip.desc, .style = t.dim_style }}, .{ .row_offset = 2, .col_offset = 2 });

    _ = win.print(&.{
        .{ .text = "  $ ", .style = as },
        .{ .text = snip.cmd, .style = t.dim_style },
    }, .{ .row_offset = 4 });

    const field_x: u16 = 20;
    var row: u16 = 6;
    var fi: usize = 0;
    while (fi < pi.param_count) : (fi += 1) {
        const label = pi.labels[fi];
        const field = &pi.fields[fi];
        const is_active = fi == pi.active;
        const label_style = if (is_active) ab else t.dim_style;

        _ = win.print(&.{.{ .text = "  ", .style = .{} }}, .{ .row_offset = row });
        _ = win.print(&.{.{ .text = label, .style = label_style }}, .{ .row_offset = row, .col_offset = 2 });

        if (pi.defaults[fi]) |d| {
            var hint_buf: [64]u8 = undefined;
            const hint = std.fmt.bufPrint(&hint_buf, " [{s}]", .{d}) catch "";
            const hx: u16 = @intCast(@min(2 + label.len, win.width -| 1));
            _ = win.print(&.{.{ .text = hint, .style = t.dim_style }}, .{ .row_offset = row, .col_offset = hx });
        }

        _ = win.print(&.{.{ .text = ":", .style = label_style }}, .{ .row_offset = row, .col_offset = field_x - 2 });

        const content = field.text();
        const fw = win.width -| field_x -| 2;
        const dl = @min(content.len, fw);

        if (is_active) {
            var c: u16 = field_x;
            while (c < field_x + fw) : (c += 1) {
                win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 236 } } });
            }
            _ = win.print(&.{.{ .text = content[0..dl], .style = .{ .bg = .{ .index = 236 } } }}, .{ .row_offset = row, .col_offset = field_x });
        } else {
            if (content.len > 0) {
                _ = win.print(&.{.{ .text = content[0..dl], .style = .{} }}, .{ .row_offset = row, .col_offset = field_x });
            } else if (pi.defaults[fi] != null) {
                _ = win.print(&.{.{ .text = pi.defaults[fi].?, .style = t.dim_style }}, .{ .row_offset = row, .col_offset = field_x });
            }
        }
        row += 2;
    }

    row += 1;
    _ = win.print(&.{.{ .text = "  Tab/↓: next   Shift+Tab/↑: prev   Enter: run   Esc: cancel", .style = t.dim_style }}, .{ .row_offset = row });
}

// ── Output view rendering ──
pub fn renderOutputView(win: Window, state: *State, cfg: config.Config) void {
    const ab = t.accentBoldStyle(cfg.accent_color);

    // Title bar
    {
        const bar = win.child(.{ .height = 1 });
        bar.fill(.{ .style = t.reverse_style });
        _ = bar.print(&.{.{ .text = " Output", .style = t.reverse_style }}, .{});
        if (state.output_title.len > 0) {
            _ = bar.print(&.{
                .{ .text = " — ", .style = t.reverse_style },
                .{ .text = state.output_title, .style = t.reverse_style },
            }, .{ .col_offset = 8 });
        }
    }

    hline(win, 1, win.width);

    const content_h: usize = @intCast(win.height -| 3);
    const total = state.output.lines.items.len;
    const scroll = state.output_scroll;

    var i: usize = 0;
    while (i < content_h) : (i += 1) {
        const li = scroll + i;
        if (li >= total) break;
        const row: u16 = 2 + @as(u16, @intCast(i));
        const line = state.output.lines.items[li];
        const style: Style = switch (line.style) {
            .header => ab,
            .dim => t.dim_style,
            .success => t.success_style,
            .err => t.err_style,
            .cmd => t.accentStyle(cfg.accent_color),
            .normal => .{},
        };
        const max_len = @min(line.text.len, @as(usize, win.width -| 1));
        _ = win.print(&.{.{ .text = line.text[0..max_len], .style = style }}, .{ .row_offset = row, .col_offset = 1 });
    }

    if (total > content_h) {
        var sb: [32]u8 = undefined;
        const si = std.fmt.bufPrint(&sb, " [{d}/{d}]", .{ scroll + 1, total }) catch "";
        const sc: u16 = win.width -| @as(u16, @intCast(@min(si.len, win.width)));
        _ = win.print(&.{.{ .text = si, .style = t.dim_style }}, .{ .row_offset = 0, .col_offset = sc });
    }

    _ = win.print(&.{.{ .text = " j/k scroll  G end  gg top  q/Esc close", .style = t.dim_style }}, .{ .row_offset = win.height -| 1 });
}

// ── Workspace picker rendering ──
pub fn renderWorkspacePicker(win: Window, state: *State, allocator: std.mem.Allocator, cfg: config.Config) void {
    _ = allocator;
    const ab = t.accentBoldStyle(cfg.accent_color);
    _ = ab;
    const as = t.accentStyle(cfg.accent_color);
    _ = as;

    const total = state.ws_list.len + 1;
    const overlay_h: u16 = @intCast(@min(total + 4, win.height -| 4));
    const overlay_w: u16 = @min(50, win.width -| 4);
    const ox: u16 = (win.width -| overlay_w) / 2;
    const oy: u16 = @intCast(@min(@as(u16, 3), (win.height -| overlay_h) / 2));

    // Draw overlay background
    var r: u16 = oy;
    while (r < oy + overlay_h and r < win.height) : (r += 1) {
        var c: u16 = ox;
        while (c < ox + overlay_w and c < win.width) : (c += 1) {
            win.writeCell(c, r, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 235 } } });
        }
    }

    // Title
    _ = win.print(&.{.{ .text = " 📂 Workspaces", .style = .{ .fg = t.accentColor(cfg.accent_color), .bold = true, .bg = .{ .index = 235 } } }}, .{ .row_offset = oy, .col_offset = ox + 1 });

    // Separator
    var sc: u16 = ox;
    while (sc < ox + overlay_w and sc < win.width) : (sc += 1) {
        win.writeCell(sc, oy + 1, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = .{ .fg = .{ .index = 240 }, .bg = .{ .index = 235 } } });
    }

    // Global entry
    const global_row: u16 = oy + 2;
    const global_selected = state.ws_cursor == 0;
    const global_active = state.active_workspace == null;
    const g_style: Style = if (global_selected) .{ .bold = true, .fg = t.accentColor(cfg.accent_color), .bg = .{ .index = 237 } } else .{ .bg = .{ .index = 235 } };

    if (global_selected) {
        var hc: u16 = ox;
        while (hc < ox + overlay_w and hc < win.width) : (hc += 1) {
            win.writeCell(hc, global_row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 237 } } });
        }
    }

    if (global_selected) {
        _ = win.print(&.{.{ .text = " ▸ ", .style = .{ .fg = t.accentColor(cfg.accent_color), .bold = true, .bg = .{ .index = 237 } } }}, .{ .row_offset = global_row, .col_offset = ox + 1 });
    } else {
        _ = win.print(&.{.{ .text = "   ", .style = .{ .bg = .{ .index = 235 } } }}, .{ .row_offset = global_row, .col_offset = ox + 1 });
    }
    _ = win.print(&.{.{ .text = "global", .style = g_style }}, .{ .row_offset = global_row, .col_offset = ox + 4 });
    if (global_active) {
        _ = win.print(&.{.{ .text = " (active)", .style = .{ .fg = .{ .index = 2 }, .bg = if (global_selected) .{ .index = 237 } else .{ .index = 235 } } }}, .{ .row_offset = global_row, .col_offset = ox + 11 });
    }
    _ = win.print(&.{.{ .text = "default workspace", .style = .{ .dim = true, .bg = if (global_selected) .{ .index = 237 } else .{ .index = 235 } } }}, .{ .row_offset = global_row, .col_offset = ox + 25 });

    // Workspace entries
    for (state.ws_list, 0..) |ws, wi| {
        const row: u16 = global_row + 1 + @as(u16, @intCast(wi));
        if (row >= oy + overlay_h or row >= win.height) break;

        const selected = state.ws_cursor == wi + 1;
        const is_active = if (state.active_workspace) |aw| std.mem.eql(u8, aw, ws.name) else false;
        const bg_color: t.Color = if (selected) .{ .index = 237 } else .{ .index = 235 };

        if (selected) {
            var hc: u16 = ox;
            while (hc < ox + overlay_w and hc < win.width) : (hc += 1) {
                win.writeCell(hc, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 237 } } });
            }
        }

        if (selected) {
            _ = win.print(&.{.{ .text = " ▸ ", .style = .{ .fg = t.accentColor(cfg.accent_color), .bold = true, .bg = bg_color } }}, .{ .row_offset = row, .col_offset = ox + 1 });
        } else {
            _ = win.print(&.{.{ .text = "   ", .style = .{ .bg = bg_color } }}, .{ .row_offset = row, .col_offset = ox + 1 });
        }

        const name_style: Style = if (selected) .{ .bold = true, .fg = t.accentColor(cfg.accent_color), .bg = bg_color } else .{ .bg = bg_color };
        _ = win.print(&.{.{ .text = ws.name, .style = name_style }}, .{ .row_offset = row, .col_offset = ox + 4 });

        if (is_active) {
            const ac: u16 = @intCast(@min(ox + 4 + ws.name.len + 1, win.width -| 1));
            _ = win.print(&.{.{ .text = "(active)", .style = .{ .fg = .{ .index = 2 }, .bg = bg_color } }}, .{ .row_offset = row, .col_offset = ac });
        }

        if (ws.description.len > 0) {
            const desc_col: u16 = ox + 25;
            if (desc_col < ox + overlay_w) {
                const max_desc = @min(ws.description.len, overlay_w -| 26);
                _ = win.print(&.{.{ .text = ws.description[0..max_desc], .style = .{ .dim = true, .bg = bg_color } }}, .{ .row_offset = row, .col_offset = desc_col });
            }
        }
    }

    // Bottom hint
    const hint_row: u16 = oy + overlay_h - 1;
    if (hint_row < win.height) {
        _ = win.print(&.{.{ .text = " j/k move  Enter switch  Esc close", .style = .{ .dim = true, .bg = .{ .index = 235 } } }}, .{ .row_offset = hint_row, .col_offset = ox + 1 });
    }
}

// ── Pack browser rendering ──
pub fn renderPackBrowser(win: Window, state: *State, cfg: config.Config) void {
    const ab = t.accentBoldStyle(cfg.accent_color);

    // Title bar
    {
        const bar = win.child(.{ .height = 1 });
        bar.fill(.{ .style = t.reverse_style });
        _ = bar.print(&.{.{ .text = " 📦 Pack Browser", .style = t.reverse_style }}, .{});

        var rb: [32]u8 = undefined;
        const rt = std.fmt.bufPrint(&rb, "{d} packs ", .{state.pack_list.len}) catch "?";
        const rc: u16 = win.width -| @as(u16, @intCast(@min(rt.len, win.width)));
        _ = bar.print(&.{.{ .text = rt, .style = t.reverse_style }}, .{ .col_offset = rc });
    }

    hline(win, 1, win.width);

    if (state.pack_list.len == 0) {
        _ = win.print(&.{.{ .text = "  No packs found in registry.", .style = t.dim_style }}, .{ .row_offset = 3 });
        _ = win.print(&.{.{ .text = "  Run the install-packs script to populate the registry.", .style = t.dim_style }}, .{ .row_offset = 4 });
        _ = win.print(&.{.{ .text = "  q/Esc to close", .style = t.dim_style }}, .{ .row_offset = win.height -| 1 });
        return;
    }

    const content_h: usize = @intCast(win.height -| 4);
    const items_per_pack: usize = 3;
    const visible_packs = content_h / items_per_pack;

    if (state.pack_cursor < state.pack_scroll) {
        state.pack_scroll = state.pack_cursor;
    } else if (state.pack_cursor >= state.pack_scroll + visible_packs) {
        state.pack_scroll = state.pack_cursor -| (visible_packs -| 1);
    }

    var row: u16 = 2;
    var pi = state.pack_scroll;
    while (pi < state.pack_list.len and row + 2 < win.height -| 1) : (pi += 1) {
        const p = &state.pack_list[pi];
        const selected = pi == state.pack_cursor;

        if (selected) {
            _ = win.print(&.{.{ .text = " ▸ ", .style = ab }}, .{ .row_offset = row });
        } else {
            _ = win.print(&.{.{ .text = "   ", .style = .{} }}, .{ .row_offset = row });
        }

        if (p.installed) {
            _ = win.print(&.{.{ .text = "✓ ", .style = t.success_style }}, .{ .row_offset = row, .col_offset = 4 });
        } else {
            _ = win.print(&.{.{ .text = "  ", .style = .{} }}, .{ .row_offset = row, .col_offset = 4 });
        }

        const name_style = if (selected) ab else t.bold_style;
        _ = win.print(&.{.{ .text = p.name, .style = name_style }}, .{ .row_offset = row, .col_offset = 6 });

        const desc_col: u16 = 22;
        if (desc_col < win.width and p.description.len > 0) {
            const max_desc = @min(p.description.len, @as(usize, win.width -| desc_col -| 1));
            _ = win.print(&.{.{ .text = p.description[0..max_desc], .style = if (selected) .{} else t.dim_style }}, .{ .row_offset = row, .col_offset = desc_col });
        }

        row += 1;

        if (row < win.height -| 1) {
            var detail_buf: [128]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "     {s} • {s} • {d} snippets", .{ p.category, p.author, p.snippet_count }) catch "     ?";
            _ = win.print(&.{.{ .text = detail, .style = t.dim_style }}, .{ .row_offset = row });

            if (p.workflow_count > 0) {
                var wf_buf: [32]u8 = undefined;
                const wf_text = std.fmt.bufPrint(&wf_buf, " • {d} workflows", .{p.workflow_count}) catch "";
                const wf_col: u16 = @intCast(@min(5 + detail.len, win.width -| 1));
                _ = win.print(&.{.{ .text = wf_text, .style = t.dim_style }}, .{ .row_offset = row, .col_offset = wf_col });
            }
            row += 1;
        }

        row += 1;
    }

    // Preview panel for selected pack
    if (state.pack_cursor < state.pack_list.len and win.height > 8) {
        const p = &state.pack_list[state.pack_cursor];
        const preview_row: u16 = win.height -| 4;
        hline(win, preview_row, win.width);

        if (p.tags.len > 0 and preview_row + 1 < win.height) {
            _ = win.print(&.{.{ .text = " Tags: ", .style = t.dim_style }}, .{ .row_offset = preview_row + 1 });
            var tc: u16 = 8;
            for (p.tags, 0..) |tag, ti| {
                if (ti > 0 and tc + 2 < win.width) {
                    _ = win.print(&.{.{ .text = ", ", .style = t.dim_style }}, .{ .row_offset = preview_row + 1, .col_offset = tc });
                    tc += 2;
                }
                if (tc + @as(u16, @intCast(tag.len)) < win.width) {
                    _ = win.print(&.{.{ .text = tag, .style = t.accentStyle(cfg.accent_color) }}, .{ .row_offset = preview_row + 1, .col_offset = tc });
                    tc += @intCast(tag.len);
                }
            }
        }

        if (preview_row + 2 < win.height) {
            var ver_buf: [64]u8 = undefined;
            const ver_text = std.fmt.bufPrint(&ver_buf, " Version: {s}", .{p.version}) catch "";
            _ = win.print(&.{.{ .text = ver_text, .style = t.dim_style }}, .{ .row_offset = preview_row + 2 });
        }
    }

    _ = win.print(&.{.{ .text = " j/k move  Enter/Space preview  i install  u uninstall  q close", .style = t.dim_style }}, .{ .row_offset = win.height -| 1 });

    if (state.message) |msg| {
        const msg_col: u16 = win.width -| @as(u16, @intCast(@min(msg.len + 2, win.width)));
        _ = win.print(&.{.{ .text = msg, .style = t.success_style }}, .{ .row_offset = win.height -| 1, .col_offset = msg_col });
        state.message = null;
    }
}

// ── Pack preview rendering ──
pub fn renderPackPreview(win: Window, state: *State, cfg: config.Config) void {
    const ab = t.accentBoldStyle(cfg.accent_color);
    const as = t.accentStyle(cfg.accent_color);
    const pack_mod = @import("../pack.zig");
    _ = pack_mod;

    // Title bar
    {
        const bar = win.child(.{ .height = 1 });
        bar.fill(.{ .style = t.reverse_style });

        var title_buf: [128]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, " 📦 Pack: {s}", .{state.pack_preview_name}) catch " 📦 Pack Preview";
        _ = bar.print(&.{.{ .text = title, .style = t.reverse_style }}, .{});

        if (state.pack_preview_installed) {
            _ = bar.print(&.{.{ .text = " ✓ installed", .style = .{ .reverse = true, .fg = .{ .index = 2 } } }}, .{ .col_offset = @intCast(@min(title.len + 1, win.width -| 1)) });
        }

        var rb: [32]u8 = undefined;
        const rt = std.fmt.bufPrint(&rb, "{d} items ", .{state.pack_preview_items.len}) catch "?";
        const rc: u16 = win.width -| @as(u16, @intCast(@min(rt.len, win.width)));
        _ = bar.print(&.{.{ .text = rt, .style = t.reverse_style }}, .{ .col_offset = rc });
    }

    hline(win, 1, win.width);

    if (state.pack_preview_items.len == 0) {
        _ = win.print(&.{.{ .text = "  No snippets or workflows in this pack.", .style = t.dim_style }}, .{ .row_offset = 3 });
        _ = win.print(&.{.{ .text = " q/Esc back", .style = t.dim_style }}, .{ .row_offset = win.height -| 1 });
        return;
    }

    // Split: list on left, detail preview on right (or bottom if narrow)
    const use_side_preview = win.width > 80;
    const list_w: u16 = if (use_side_preview) @intCast(@min(win.width / 2, 45)) else win.width;
    const content_h: usize = @intCast(win.height -| 4);
    const items_per_entry: usize = 2;
    const visible_items = content_h / items_per_entry;

    // Adjust scroll
    if (state.pack_preview_cursor < state.pack_preview_scroll) {
        state.pack_preview_scroll = state.pack_preview_cursor;
    } else if (state.pack_preview_cursor >= state.pack_preview_scroll + visible_items) {
        state.pack_preview_scroll = state.pack_preview_cursor -| (visible_items -| 1);
    }

    // Render list
    var row: u16 = 2;
    var pi = state.pack_preview_scroll;
    while (pi < state.pack_preview_items.len and row + 1 < win.height -| 1) : (pi += 1) {
        const item = &state.pack_preview_items[pi];
        const selected = pi == state.pack_preview_cursor;

        // Icon and selection indicator
        if (selected) {
            _ = win.print(&.{.{ .text = " ▸ ", .style = ab }}, .{ .row_offset = row });
        } else {
            _ = win.print(&.{.{ .text = "   ", .style = .{} }}, .{ .row_offset = row });
        }

        const icon: []const u8 = switch (item.kind) {
            .workflow => ">>",
            .snippet => " $",
        };
        const ks: Style = switch (item.kind) {
            .workflow => t.wf_style,
            .snippet => t.snip_icon_style,
        };
        _ = win.print(&.{.{ .text = icon, .style = ks }}, .{ .row_offset = row, .col_offset = 3 });

        // Name
        const name_style = if (selected) ab else t.bold_style;
        _ = win.print(&.{.{ .text = item.name, .style = name_style }}, .{ .row_offset = row, .col_offset = 6 });

        // Description (truncated to list width)
        const desc_col: u16 = @min(list_w -| 2, 28);
        if (desc_col < list_w and item.desc.len > 0) {
            const max_desc = @min(item.desc.len, @as(usize, list_w -| desc_col -| 1));
            _ = win.print(&.{.{ .text = item.desc[0..max_desc], .style = if (selected) .{} else t.dim_style }}, .{ .row_offset = row, .col_offset = desc_col });
        }

        row += 1;

        // Tags line
        if (row < win.height -| 1 and item.tags.len > 0) {
            _ = win.print(&.{.{ .text = "      [", .style = t.dim_style }}, .{ .row_offset = row });
            var tc: u16 = 7;
            for (item.tags, 0..) |tag, ti| {
                if (ti > 0 and tc + 2 < list_w) {
                    _ = win.print(&.{.{ .text = ", ", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = tc });
                    tc += 2;
                }
                if (tc + @as(u16, @intCast(tag.len)) < list_w) {
                    _ = win.print(&.{.{ .text = tag, .style = t.dim_style }}, .{ .row_offset = row, .col_offset = tc });
                    tc += @intCast(tag.len);
                }
            }
            if (tc < list_w) _ = win.print(&.{.{ .text = "]", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = tc });
            row += 1;
        } else {
            row += 1;
        }
    }

    // Detail preview panel
    if (state.pack_preview_cursor < state.pack_preview_items.len) {
        const item = &state.pack_preview_items[state.pack_preview_cursor];

        if (use_side_preview) {
            // Side panel
            const panel_x: u16 = list_w;
            var pr: u16 = 2;

            // Vertical separator
            var sr: u16 = 2;
            while (sr < win.height -| 1) : (sr += 1) {
                win.writeCell(panel_x, sr, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = t.dim_style });
            }

            const px: u16 = panel_x + 2;

            _ = win.print(&.{.{ .text = "── Preview ──", .style = ab }}, .{ .row_offset = pr, .col_offset = px });
            pr += 1;

            _ = win.print(&.{
                .{ .text = "Name: ", .style = t.dim_style },
                .{ .text = item.name, .style = t.bold_style },
            }, .{ .row_offset = pr, .col_offset = px });
            pr += 1;

            if (item.desc.len > 0) {
                const max_d = @min(item.desc.len, @as(usize, win.width -| px -| 1));
                _ = win.print(&.{.{ .text = item.desc[0..max_d], .style = .{} }}, .{ .row_offset = pr, .col_offset = px });
                pr += 1;
            }
            pr += 1;

            if (item.kind == .snippet and item.cmd.len > 0) {
                _ = win.print(&.{.{ .text = "Command:", .style = t.dim_style }}, .{ .row_offset = pr, .col_offset = px });
                pr += 1;

                // Word-wrap command into available width
                const cmd_w = @as(usize, win.width -| px -| 3);
                var cmd_remaining = item.cmd;
                while (cmd_remaining.len > 0 and pr < win.height -| 2) {
                    const chunk = @min(cmd_remaining.len, cmd_w);
                    _ = win.print(&.{
                        .{ .text = "$ ", .style = as },
                        .{ .text = cmd_remaining[0..chunk], .style = .{} },
                    }, .{ .row_offset = pr, .col_offset = px });
                    cmd_remaining = cmd_remaining[chunk..];
                    pr += 1;
                }
            } else if (item.kind == .workflow) {
                _ = win.print(&.{.{ .text = "Type: workflow", .style = t.wf_style }}, .{ .row_offset = pr, .col_offset = px });
                pr += 1;
            }

            if (item.tags.len > 0 and pr + 1 < win.height -| 1) {
                pr += 1;
                _ = win.print(&.{.{ .text = "Tags: ", .style = t.dim_style }}, .{ .row_offset = pr, .col_offset = px });
                var tc: u16 = px + 6;
                for (item.tags, 0..) |tag, ti| {
                    if (ti > 0 and tc + 2 < win.width) {
                        _ = win.print(&.{.{ .text = ", ", .style = t.dim_style }}, .{ .row_offset = pr, .col_offset = tc });
                        tc += 2;
                    }
                    if (tc + @as(u16, @intCast(tag.len)) < win.width) {
                        _ = win.print(&.{.{ .text = tag, .style = as }}, .{ .row_offset = pr, .col_offset = tc });
                        tc += @intCast(tag.len);
                    }
                }
            }
        } else {
            // Bottom panel (narrow terminal)
            const preview_row: u16 = win.height -| 5;
            if (preview_row > row) {
                hline(win, preview_row, win.width);

                var pr = preview_row + 1;
                _ = win.print(&.{
                    .{ .text = " ", .style = .{} },
                    .{ .text = item.name, .style = t.bold_style },
                    .{ .text = " — ", .style = t.dim_style },
                    .{ .text = item.desc, .style = .{} },
                }, .{ .row_offset = pr });
                pr += 1;

                if (item.kind == .snippet and item.cmd.len > 0 and pr < win.height -| 1) {
                    const max_cmd = @min(item.cmd.len, @as(usize, win.width -| 5));
                    _ = win.print(&.{
                        .{ .text = " $ ", .style = as },
                        .{ .text = item.cmd[0..max_cmd], .style = .{} },
                    }, .{ .row_offset = pr });
                }
            }
        }
    }

    // Bottom bar
    const install_hint: []const u8 = if (state.pack_preview_installed) "already installed" else "Enter install";
    var hint_buf: [128]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, " j/k move  {s}  q/Esc back to browser", .{install_hint}) catch " j/k  Enter install  q back";
    _ = win.print(&.{.{ .text = hint, .style = t.dim_style }}, .{ .row_offset = win.height -| 1 });

    if (state.message) |msg| {
        const msg_col: u16 = win.width -| @as(u16, @intCast(@min(msg.len + 2, win.width)));
        _ = win.print(&.{.{ .text = msg, .style = t.success_style }}, .{ .row_offset = win.height -| 1, .col_offset = msg_col });
        state.message = null;
    }
}

// ── Workflow form rendering ──
pub fn renderWorkflowForm(win: Window, state: *State, snip_store: *store.Store, cfg: config.Config) void {
    const ab = t.accentBoldStyle(cfg.accent_color);
    const as = t.accentStyle(cfg.accent_color);
    const wf = &state.wf_form;

    switch (wf.phase) {
        .info => {
            _ = win.print(&.{.{ .text = "── Create Workflow ──", .style = ab }}, .{ .row_offset = 2, .col_offset = 2 });

            const field_x: u16 = 18;
            var row: u16 = 4;
            var fi: usize = 0;
            while (fi < 4) : (fi += 1) {
                const label = wf.info_labels[fi];
                const field = &wf.info_fields[fi];
                const is_active = fi == wf.info_active;
                const label_style = if (is_active) ab else t.dim_style;

                _ = win.print(&.{.{ .text = label, .style = label_style }}, .{ .row_offset = row, .col_offset = 2 });
                _ = win.print(&.{.{ .text = ":", .style = label_style }}, .{ .row_offset = row, .col_offset = @intCast(@min(2 + label.len, win.width -| 1)) });

                const content = field.text();
                const field_w = win.width -| field_x -| 2;
                const display_len = @min(content.len, field_w);

                if (is_active) {
                    var c: u16 = field_x;
                    while (c < field_x + field_w) : (c += 1) {
                        win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 236 } } });
                    }
                    _ = win.print(&.{.{ .text = content[0..display_len], .style = .{ .bg = .{ .index = 236 } } }}, .{ .row_offset = row, .col_offset = field_x });
                } else {
                    if (content.len > 0) {
                        _ = win.print(&.{.{ .text = content[0..display_len], .style = .{} }}, .{ .row_offset = row, .col_offset = field_x });
                    } else {
                        _ = win.print(&.{.{ .text = "—", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = field_x });
                    }
                }
                row += 2;
            }

            if (wf.error_msg) |emsg| {
                _ = win.print(&.{.{ .text = emsg, .style = t.err_style }}, .{ .row_offset = row, .col_offset = 2 });
                row += 1;
            }

            row += 1;
            _ = win.print(&.{.{ .text = "  Tab/↓: next   ↑: prev   Enter: add steps   Ctrl+S: next   Esc: cancel", .style = t.dim_style }}, .{ .row_offset = row });
        },
        .steps => {
            // Title
            var title_buf: [128]u8 = undefined;
            const wf_name = wf.info_fields[t.WorkflowFormState.F_NAME].text();
            const title = std.fmt.bufPrint(&title_buf, "── Workflow: {s} — Steps ──", .{wf_name}) catch "── Workflow Steps ──";
            _ = win.print(&.{.{ .text = title, .style = ab }}, .{ .row_offset = 1, .col_offset = 2 });

            // Step list
            var row: u16 = 3;
            if (wf.step_count == 0) {
                _ = win.print(&.{.{ .text = "  No steps yet. Add one below.", .style = t.dim_style }}, .{ .row_offset = row });
                row += 1;
            } else {
                const max_visible: usize = @intCast(@min(@as(u16, @intCast(wf.step_count)), win.height / 3));
                for (0..max_visible) |i| {
                    if (row + 1 >= win.height -| 10) break;
                    const se = &wf.steps[i];
                    const selected = !wf.editing_new_step and i == wf.step_cursor;

                    var num_buf: [8]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, " {d}.", .{i + 1}) catch "?";

                    if (selected) {
                        _ = win.print(&.{
                            .{ .text = " ▸", .style = ab },
                            .{ .text = num_str, .style = ab },
                        }, .{ .row_offset = row });
                    } else {
                        _ = win.print(&.{
                            .{ .text = "  ", .style = .{} },
                            .{ .text = num_str, .style = t.dim_style },
                        }, .{ .row_offset = row });
                    }

                    const name_col: u16 = 7;
                    const name_style = if (selected) ab else t.bold_style;
                    _ = win.print(&.{.{ .text = se.nameSlice(), .style = name_style }}, .{ .row_offset = row, .col_offset = name_col });

                    // Show type indicator
                    const type_col: u16 = 28;
                    if (se.is_snippet) {
                        _ = win.print(&.{.{ .text = "→ ", .style = t.wf_style }}, .{ .row_offset = row, .col_offset = type_col });
                    } else {
                        _ = win.print(&.{.{ .text = "$ ", .style = as }}, .{ .row_offset = row, .col_offset = type_col });
                    }
                    const cmd_col: u16 = type_col + 2;
                    const max_cmd = @min(se.cmdSlice().len, @as(usize, win.width -| cmd_col -| 1));
                    _ = win.print(&.{.{ .text = se.cmdSlice()[0..max_cmd], .style = if (selected) .{} else t.dim_style }}, .{ .row_offset = row, .col_offset = cmd_col });

                    row += 1;

                    // on_fail indicator
                    _ = win.print(&.{
                        .{ .text = "       on_fail: ", .style = t.dim_style },
                        .{ .text = se.on_fail.label(), .style = t.dim_style },
                    }, .{ .row_offset = row });
                    row += 1;
                }
            }

            // Separator
            row += 1;
            hline(win, row, win.width);
            row += 1;

            // New step form
            const form_active = wf.editing_new_step;
            _ = win.print(&.{.{ .text = "  ╭─ New Step ─", .style = if (form_active) as else t.dim_style }}, .{ .row_offset = row });
            row += 1;

            // Field 0: Step name
            {
                const is_active = form_active and wf.new_step_field == 0;
                const label_style = if (is_active) ab else t.dim_style;
                _ = win.print(&.{.{ .text = "  │ Name:", .style = label_style }}, .{ .row_offset = row });
                const fx: u16 = 14;
                const content = wf.new_step.name[0..wf.new_step.name_len];
                const fw = win.width -| fx -| 2;
                const dl = @min(content.len, fw);
                if (is_active) {
                    var c: u16 = fx;
                    while (c < fx + fw) : (c += 1) {
                        win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 236 } } });
                    }
                    _ = win.print(&.{.{ .text = content[0..dl], .style = .{ .bg = .{ .index = 236 } } }}, .{ .row_offset = row, .col_offset = fx });
                } else if (content.len > 0) {
                    _ = win.print(&.{.{ .text = content[0..dl], .style = .{} }}, .{ .row_offset = row, .col_offset = fx });
                }
                row += 1;
            }

            // Field 1: Type toggle
            {
                const is_active = form_active and wf.new_step_field == 1;
                const label_style = if (is_active) ab else t.dim_style;
                _ = win.print(&.{.{ .text = "  │ Type:", .style = label_style }}, .{ .row_offset = row });
                const type_label: []const u8 = if (wf.new_step.is_snippet) "snippet (Enter/Space to toggle)" else "command (Enter/Space to toggle)";
                const type_style = if (is_active) ab else t.dim_style;
                _ = win.print(&.{.{ .text = type_label, .style = type_style }}, .{ .row_offset = row, .col_offset = 14 });
                row += 1;
            }

            // Field 2: Command/Snippet ref
            {
                const is_active = form_active and wf.new_step_field == 2;
                const field_label: []const u8 = if (wf.new_step.is_snippet) "  │ Snippet:" else "  │ Command:";
                const label_style = if (is_active) ab else t.dim_style;
                _ = win.print(&.{.{ .text = field_label, .style = label_style }}, .{ .row_offset = row });
                const fx: u16 = 16;
                const content = wf.new_step.cmd[0..wf.new_step.cmd_len];
                const fw = win.width -| fx -| 2;
                const dl = @min(content.len, fw);
                if (is_active) {
                    var c: u16 = fx;
                    while (c < fx + fw) : (c += 1) {
                        win.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 236 } } });
                    }
                    _ = win.print(&.{.{ .text = content[0..dl], .style = .{ .bg = .{ .index = 236 } } }}, .{ .row_offset = row, .col_offset = fx });
                } else if (content.len > 0) {
                    _ = win.print(&.{.{ .text = content[0..dl], .style = .{} }}, .{ .row_offset = row, .col_offset = fx });
                }

                // Show available snippets hint when in snippet mode
                if (wf.new_step.is_snippet and is_active) {
                    row += 1;
                    _ = win.print(&.{.{ .text = "  │  Snippets: ", .style = t.dim_style }}, .{ .row_offset = row });
                    var sc: u16 = 17;
                    var shown: usize = 0;
                    for (snip_store.snippets.items) |snip| {
                        if (snip.kind == .snippet) {
                            if (shown > 0) {
                                if (sc + 2 >= win.width) break;
                                _ = win.print(&.{.{ .text = ", ", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = sc });
                                sc += 2;
                            }
                            if (sc + @as(u16, @intCast(snip.name.len)) >= win.width -| 1) break;
                            _ = win.print(&.{.{ .text = snip.name, .style = t.dim_style }}, .{ .row_offset = row, .col_offset = sc });
                            sc += @intCast(snip.name.len);
                            shown += 1;
                            if (shown >= 8) break;
                        }
                    }
                }
                row += 1;
            }

            // Field 3: on_fail toggle
            {
                const is_active = form_active and wf.new_step_field == 3;
                const label_style = if (is_active) ab else t.dim_style;
                _ = win.print(&.{.{ .text = "  │ On fail:", .style = label_style }}, .{ .row_offset = row });
                const fail_label = wf.new_step.on_fail.label();
                const fail_style = if (is_active) ab else t.dim_style;
                _ = win.print(&.{.{ .text = fail_label, .style = fail_style }}, .{ .row_offset = row, .col_offset = 16 });
                if (is_active) {
                    _ = win.print(&.{.{ .text = " (Enter/Space to cycle)", .style = t.dim_style }}, .{ .row_offset = row, .col_offset = 16 + @as(u16, @intCast(fail_label.len)) });
                }
                row += 1;
            }

            _ = win.print(&.{.{ .text = "  ╰──────────────", .style = if (form_active) as else t.dim_style }}, .{ .row_offset = row });
            row += 1;

            if (wf.error_msg) |emsg| {
                row += 1;
                _ = win.print(&.{.{ .text = emsg, .style = t.err_style }}, .{ .row_offset = row, .col_offset = 2 });
            }

            // Bottom bar
            var steps_buf: [16]u8 = undefined;
            const steps_str = std.fmt.bufPrint(&steps_buf, " {d} step(s)", .{wf.step_count}) catch "";
            _ = win.print(&.{.{ .text = steps_str, .style = t.dim_style }}, .{ .row_offset = win.height -| 2, .col_offset = 2 });

            if (wf.editing_new_step) {
                _ = win.print(&.{.{ .text = "  Tab: next field  Enter: add step  Ctrl+S: save workflow  Ctrl+L: browse steps  Esc: back", .style = t.dim_style }}, .{ .row_offset = win.height -| 1 });
            } else {
                _ = win.print(&.{.{ .text = "  j/k: move  d: delete step  Tab/i: edit new step  Ctrl+S: save workflow  Esc: back", .style = t.dim_style }}, .{ .row_offset = win.height -| 1 });
            }
        },
    }
}

// ── Cursor positioning ──
pub fn setCursor(win: Window, state: *State) void {
    switch (state.mode) {
        .search => {
            const col: u16 = @intCast(@min(state.search_len + 3, win.width -| 1));
            win.showCursor(col, 1);
        },
        .command => {
            const col: u16 = @intCast(@min(state.command_len + 2, win.width -| 1));
            win.showCursor(col, 1);
        },
        .form => {
            const f = &state.form;
            const field_x: u16 = 16;
            const cursor_col: u16 = field_x + @as(u16, @intCast(@min(f.activeField().cursor, win.width -| field_x -| 1)));
            const cursor_row: u16 = 4 + @as(u16, @intCast(f.active)) * 2;
            win.showCursor(cursor_col, cursor_row);
        },
        .param_input => {
            const p = &state.param_input;
            const field_x: u16 = 20;
            const cursor_col: u16 = field_x + @as(u16, @intCast(@min(p.activeField().cursor, win.width -| field_x -| 1)));
            const cursor_row: u16 = 6 + @as(u16, @intCast(p.active)) * 2;
            win.showCursor(cursor_col, cursor_row);
        },
        .workflow_form => {
            const wf = &state.wf_form;
            switch (wf.phase) {
                .info => {
                    const field_x: u16 = 18;
                    const cursor_col: u16 = field_x + @as(u16, @intCast(@min(wf.activeInfoField().cursor, win.width -| field_x -| 1)));
                    const cursor_row: u16 = 4 + @as(u16, @intCast(wf.info_active)) * 2;
                    win.showCursor(cursor_col, cursor_row);
                },
                .steps => {
                    if (wf.editing_new_step) {
                        // Calculate base row for new step form
                        const step_lines: u16 = @intCast(@min(wf.step_count * 2, win.height / 3));
                        const form_base: u16 = 3 + step_lines + 2; // list + separator + "New Step" header

                        if (wf.new_step_field == 0) {
                            // Name field
                            const fx: u16 = 14;
                            const cursor_col: u16 = fx + @as(u16, @intCast(@min(wf.new_step.name_len, win.width -| fx -| 1)));
                            win.showCursor(cursor_col, form_base + 1);
                        } else if (wf.new_step_field == 2) {
                            // Cmd field
                            const fx: u16 = 16;
                            const cursor_col: u16 = fx + @as(u16, @intCast(@min(wf.new_step.cmd_len, win.width -| fx -| 1)));
                            win.showCursor(cursor_col, form_base + 3);
                        } else {
                            win.hideCursor();
                        }
                    } else {
                        win.hideCursor();
                    }
                },
            }
        },
        else => win.hideCursor(),
    }
}

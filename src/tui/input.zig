/// TUI input/key handling for zipet.
const std = @import("std");
const config = @import("../config.zig");
const store = @import("../store.zig");
const template = @import("../template.zig");
const workspace_mod = @import("../workspace.zig");
const pack_mod = @import("../pack.zig");
const t = @import("types.zig");
const actions = @import("actions.zig");
const utils = @import("utils.zig");

const Key = t.Key;
const State = t.State;
const FormState = t.FormState;
const OutputBuf = t.OutputBuf;

pub fn handleKeyPress(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store, cfg: config.Config) !void {
    switch (state.mode) {
        .search => handleSearchKey(allocator, key, state, snip_store),
        .command => handleCommandKey(allocator, key, state, snip_store, cfg),
        .confirm_delete => handleConfirmDeleteKey(allocator, key, state, snip_store),
        .tag_picker => handleTagPickerKey(allocator, key, state, snip_store),
        .form => handleFormKey(allocator, key, state, snip_store),
        .param_input => try handleParamInputKey(allocator, key, state, snip_store, cfg),
        .output_view => handleOutputViewKey(key, state),
        .workspace_picker => try handleWorkspacePickerKey(allocator, key, state, snip_store, cfg),
        .pack_browser => try handlePackBrowserKey(allocator, key, state, snip_store, cfg),
        .info => {
            if (key.matches('i', .{}) or key.matches(Key.escape, .{}) or key.matches('q', .{}))
                state.mode = .normal;
        },
        .help => {
            if (key.matches('?', .{}) or key.matches(Key.escape, .{})) {
                state.mode = .normal;
            } else {
                state.mode = .normal;
                try handleNormalKey(allocator, key, state, snip_store, cfg);
                if (state.running and state.mode == .normal) state.mode = .help;
            }
        },
        .normal => try handleNormalKey(allocator, key, state, snip_store, cfg),
    }
}

fn handleNormalKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store, cfg: config.Config) !void {
    const total = state.filtered_indices.len;

    if (key.matches('j', .{}) or key.matches(Key.down, .{})) {
        if (total > 0 and state.cursor < total - 1) {
            state.cursor += 1;
            utils.adjustScroll(state, 24);
        }
        state.pending_g = false;
    } else if (key.matches('k', .{}) or key.matches(Key.up, .{})) {
        if (state.cursor > 0) {
            state.cursor -= 1;
            utils.adjustScroll(state, 24);
        }
        state.pending_g = false;
    } else if (key.matches('g', .{})) {
        if (state.pending_g) {
            state.cursor = 0;
            state.scroll_offset = 0;
            state.pending_g = false;
        } else state.pending_g = true;
    } else if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
        if (total > 0) {
            state.cursor = total - 1;
            utils.adjustScroll(state, 24);
        }
        state.pending_g = false;
    } else if (key.matches('/', .{})) {
        state.mode = .search;
        state.pending_g = false;
    } else if (key.matches(':', .{}) or key.matches(':', .{ .shift = true })) {
        state.mode = .command;
        state.command_len = 0;
        state.pending_g = false;
    } else if (key.matches('?', .{}) or key.matches('?', .{ .shift = true })) {
        state.mode = .help;
        state.pending_g = false;
    } else if (key.matches('q', .{})) {
        state.running = false;
    } else if (key.matches(' ', .{})) {
        state.preview_visible = !state.preview_visible;
        state.pending_g = false;
    } else if (key.matches('d', .{ .ctrl = true })) {
        const half = state.listHeight(24) / 2;
        if (total > 0) {
            state.cursor = @min(state.cursor + half, total - 1);
            utils.adjustScroll(state, 24);
        }
        state.pending_g = false;
    } else if (key.matches('u', .{ .ctrl = true })) {
        state.cursor -|= state.listHeight(24) / 2;
        utils.adjustScroll(state, 24);
        state.pending_g = false;
    } else if (key.matches(Key.escape, .{})) {
        if (state.search_len > 0 or state.active_tag_filter != null) {
            state.search_len = 0;
            state.active_tag_filter = null;
            state.cursor = 0;
            state.scroll_offset = 0;
            allocator.free(state.filtered_indices);
            state.filtered_indices = utils.updateFilter(allocator, snip_store, "") catch &.{};
        }
        state.pending_g = false;
    } else if (key.matches(Key.enter, .{})) {
        if (total > 0 and state.cursor < total) {
            const si = state.filtered_indices[state.cursor];
            const snip = &snip_store.snippets.items[si];
            if (snip.params.len > 0) {
                actions.initParamInput(state, si, snip);
                state.mode = .param_input;
            } else {
                try actions.executeSnippetDirect(allocator, state, snip, cfg, snip_store);
            }
        }
        state.pending_g = false;
    } else if (key.matches('a', .{})) {
        state.form = FormState.init(.add);
        state.mode = .form;
        state.pending_g = false;
    } else if (key.matches('e', .{})) {
        if (total > 0 and state.cursor < total) {
            const si = state.filtered_indices[state.cursor];
            const snip = &snip_store.snippets.items[si];
            state.form = FormState.init(.edit);
            state.form.editing_snip_idx = si;
            state.form.fields[FormState.F_NAME].setText(snip.name);
            state.form.fields[FormState.F_DESC].setText(snip.desc);
            state.form.fields[FormState.F_CMD].setText(snip.cmd);
            var tags_joined: [512]u8 = undefined;
            var tl: usize = 0;
            for (snip.tags, 0..) |tag, ti| {
                if (ti > 0 and tl < 510) {
                    tags_joined[tl] = ',';
                    tl += 1;
                }
                const copy_len = @min(tag.len, 512 - tl);
                @memcpy(tags_joined[tl .. tl + copy_len], tag[0..copy_len]);
                tl += copy_len;
            }
            state.form.fields[FormState.F_TAGS].setText(tags_joined[0..tl]);
            state.form.fields[FormState.F_NS].setText(snip.namespace);
            state.mode = .form;
        }
        state.pending_g = false;
    } else if (key.matches('o', .{})) {
        if (total > 0 and state.cursor < total) {
            const si = state.filtered_indices[state.cursor];
            const snip = &snip_store.snippets.items[si];
            actions.openExternalEditor(allocator, snip, cfg);
            utils.reloadStore(allocator, state, snip_store);
            state.message = "✓ Reloaded after edit";
        }
        state.pending_g = false;
    } else if (key.matches('d', .{})) {
        if (total > 0 and state.cursor < total) state.mode = .confirm_delete;
        state.pending_g = false;
    } else if (key.matches('y', .{})) {
        if (total > 0 and state.cursor < total) {
            const si = state.filtered_indices[state.cursor];
            const snip = &snip_store.snippets.items[si];
            state.message = if (utils.yankToClipboard(allocator, snip.cmd)) "✓ Copied to clipboard" else "✗ No clipboard tool found";
        }
        state.pending_g = false;
    } else if (key.matches('p', .{})) {
        const clip = template.readClipboard(allocator) catch null;
        if (clip) |clip_text| {
            state.form = FormState.init(.paste);
            state.form.fields[FormState.F_CMD].setText(clip_text);
            allocator.free(clip_text);
            state.mode = .form;
        } else {
            state.message = "✗ No clipboard content";
        }
        state.pending_g = false;
    } else if (key.matches('t', .{})) {
        const all_tags = snip_store.allTags(allocator) catch &.{};
        if (all_tags.len > 0) {
            if (state.tag_list.len > 0) allocator.free(state.tag_list);
            state.tag_list = all_tags;
            state.tag_cursor = 0;
            state.mode = .tag_picker;
        } else state.message = "No tags found";
        state.pending_g = false;
    } else if (key.matches('i', .{})) {
        if (total > 0 and state.cursor < total) state.mode = .info;
        state.pending_g = false;
    } else if (key.matches('W', .{}) or key.matches('w', .{ .shift = true })) {
        try actions.openWorkspacePicker(allocator, state, cfg);
        state.pending_g = false;
    } else if (key.matches('P', .{}) or key.matches('p', .{ .shift = true })) {
        try actions.openPackBrowser(allocator, state, cfg);
        state.pending_g = false;
    } else {
        state.pending_g = false;
    }
}

fn handleSearchKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store) void {
    if (key.matches(Key.escape, .{})) {
        state.mode = .normal;
    } else if (key.matches(Key.enter, .{})) {
        state.mode = .normal;
    } else if (key.matches(Key.backspace, .{})) {
        if (state.search_len > 0) {
            state.search_len -= 1;
            utils.refilter(allocator, state, snip_store);
        }
    } else {
        if (utils.insertKeyChar(&state.search_buf, &state.search_len, state.search_buf.len - 1, key))
            utils.refilter(allocator, state, snip_store);
    }
}

fn handleCommandKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store, cfg: config.Config) void {
    if (key.matches(Key.escape, .{})) {
        state.mode = .normal;
        state.command_len = 0;
    } else if (key.matches(Key.enter, .{})) {
        const cmd = state.commandStr();
        if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
            state.running = false;
        } else if (std.mem.eql(u8, cmd, "help")) {
            state.mode = .help;
        } else if (std.mem.eql(u8, cmd, "tags")) {
            const all_tags = snip_store.allTags(allocator) catch &.{};
            if (all_tags.len > 0) {
                if (state.tag_list.len > 0) allocator.free(state.tag_list);
                state.tag_list = all_tags;
                state.tag_cursor = 0;
                state.mode = .tag_picker;
            } else {
                state.message = "No tags found";
                state.mode = .normal;
            }
        } else if (std.mem.eql(u8, cmd, "export")) {
            actions.buildExportOutput(allocator, state, snip_store);
            state.mode = .output_view;
        } else if (std.mem.eql(u8, cmd, "ws") or std.mem.eql(u8, cmd, "workspace") or std.mem.eql(u8, cmd, "workspaces")) {
            actions.openWorkspacePicker(allocator, state, cfg) catch {};
        } else if (std.mem.eql(u8, cmd, "packs") or std.mem.eql(u8, cmd, "pack")) {
            actions.openPackBrowser(allocator, state, cfg) catch {};
        } else if (std.mem.eql(u8, cmd, "w")) {
            actions.saveAll(allocator, snip_store);
            state.message = "✓ Saved";
            state.mode = .normal;
        } else if (std.mem.eql(u8, cmd, "wq")) {
            actions.saveAll(allocator, snip_store);
            state.running = false;
        } else {
            state.message = "Unknown command";
            state.mode = .normal;
        }
        state.command_len = 0;
        if (state.running and state.mode == .command) state.mode = .normal;
    } else if (key.matches(Key.backspace, .{})) {
        if (state.command_len > 0) state.command_len -= 1;
    } else {
        _ = utils.insertKeyChar(&state.command_buf, &state.command_len, state.command_buf.len - 1, key);
    }
}

fn handleConfirmDeleteKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store) void {
    if (key.matches('y', .{}) or key.matches('Y', .{}) or key.matches('y', .{ .shift = true })) {
        const total = state.filtered_indices.len;
        if (state.cursor < total) {
            const si = state.filtered_indices[state.cursor];
            const name = snip_store.snippets.items[si].name;
            snip_store.remove(name) catch {};
            allocator.free(state.filtered_indices);
            state.filtered_indices = utils.updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};
            if (state.filtered_indices.len == 0) {
                state.cursor = 0;
                state.scroll_offset = 0;
            } else if (state.cursor >= state.filtered_indices.len) state.cursor = state.filtered_indices.len - 1;
            utils.adjustScroll(state, 24);
            state.message = "✓ Deleted";
        }
        state.mode = .normal;
    } else {
        state.mode = .normal;
        state.message = "Delete cancelled";
    }
}

fn handleTagPickerKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store) void {
    if (key.matches(Key.escape, .{})) {
        state.active_tag_filter = null;
        state.cursor = 0;
        state.scroll_offset = 0;
        allocator.free(state.filtered_indices);
        state.filtered_indices = utils.updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};
        state.mode = .normal;
    } else if (key.matches('j', .{}) or key.matches(Key.down, .{})) {
        if (state.tag_cursor < state.tag_list.len - 1) state.tag_cursor += 1;
    } else if (key.matches('k', .{}) or key.matches(Key.up, .{})) {
        if (state.tag_cursor > 0) state.tag_cursor -= 1;
    } else if (key.matches(Key.enter, .{})) {
        if (state.tag_list.len > 0 and state.tag_cursor < state.tag_list.len) {
            state.active_tag_filter = state.tag_list[state.tag_cursor];
            state.cursor = 0;
            state.scroll_offset = 0;
            allocator.free(state.filtered_indices);
            state.filtered_indices = utils.updateFilterWithTag(allocator, snip_store, state.searchQuery(), state.active_tag_filter) catch &.{};
            state.mode = .normal;
        }
    } else if (key.matches('q', .{})) {
        state.mode = .normal;
    } else if (key.matches('x', .{})) {
        state.active_tag_filter = null;
        state.cursor = 0;
        state.scroll_offset = 0;
        allocator.free(state.filtered_indices);
        state.filtered_indices = utils.updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};
        state.mode = .normal;
        state.message = "Tag filter cleared";
    }
}

fn handleFormKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store) void {
    const f = &state.form;

    if (key.matches(Key.escape, .{})) {
        state.mode = .normal;
        return;
    }

    if (key.matches('s', .{ .ctrl = true })) {
        actions.submitForm(allocator, state, snip_store);
        return;
    }

    if (key.matches(Key.tab, .{}) or key.matches(Key.down, .{})) {
        if (f.active + 1 < f.field_count) f.active += 1 else f.active = 0;
        return;
    }

    if (key.matches(Key.tab, .{ .shift = true }) or key.matches(Key.up, .{})) {
        if (f.active > 0) f.active -= 1 else f.active = f.field_count - 1;
        return;
    }

    if (key.matches(Key.enter, .{})) {
        actions.submitForm(allocator, state, snip_store);
        return;
    }

    utils.handleTextFieldKey(f.activeField(), key);
}

fn handleParamInputKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store, cfg: config.Config) !void {
    const pi = &state.param_input;

    if (key.matches(Key.escape, .{})) {
        state.mode = .normal;
        return;
    }

    if (key.matches(Key.tab, .{}) or key.matches(Key.down, .{})) {
        if (pi.active + 1 < pi.param_count) pi.active += 1 else pi.active = 0;
        return;
    }
    if (key.matches(Key.tab, .{ .shift = true }) or key.matches(Key.up, .{})) {
        if (pi.active > 0) pi.active -= 1 else pi.active = pi.param_count - 1;
        return;
    }

    if (key.matches(Key.enter, .{})) {
        try actions.submitParamInput(allocator, state, snip_store, cfg);
        return;
    }

    utils.handleTextFieldKey(pi.activeField(), key);
}

fn handleOutputViewKey(key: Key, state: *State) void {
    if (key.matches('q', .{}) or key.matches(Key.escape, .{})) {
        state.output.deinit();
        state.output = OutputBuf.init(state.output.alloc);
        state.output_scroll = 0;
        state.output_title = "";
        state.mode = .normal;
        return;
    }
    const total = state.output.lines.items.len;
    if (key.matches('j', .{}) or key.matches(Key.down, .{})) {
        if (state.output_scroll + 1 < total) state.output_scroll += 1;
    } else if (key.matches('k', .{}) or key.matches(Key.up, .{})) {
        if (state.output_scroll > 0) state.output_scroll -= 1;
    } else if (key.matches('d', .{ .ctrl = true })) {
        state.output_scroll = @min(state.output_scroll + 10, if (total > 0) total - 1 else 0);
    } else if (key.matches('u', .{ .ctrl = true })) {
        state.output_scroll -|= 10;
    } else if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
        if (total > 0) state.output_scroll = total - 1;
    } else if (key.matches('g', .{})) {
        state.output_scroll = 0;
    }
}

fn handleWorkspacePickerKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store, cfg: config.Config) !void {
    const total = state.ws_list.len + 1;

    if (key.matches(Key.escape, .{}) or key.matches('q', .{})) {
        state.mode = .normal;
        return;
    }

    if (key.matches('j', .{}) or key.matches(Key.down, .{})) {
        if (state.ws_cursor + 1 < total) state.ws_cursor += 1;
    } else if (key.matches('k', .{}) or key.matches(Key.up, .{})) {
        if (state.ws_cursor > 0) state.ws_cursor -= 1;
    } else if (key.matches(Key.enter, .{})) {
        if (state.ws_cursor == 0) {
            try workspace_mod.setActiveWorkspace(allocator, cfg, null);
            if (state.active_workspace) |aw| {
                allocator.free(aw);
            }
            state.active_workspace = null;
            state.message = "✓ Switched to global";
        } else {
            const ws = state.ws_list[state.ws_cursor - 1];
            try workspace_mod.setActiveWorkspace(allocator, cfg, ws.name);
            if (state.active_workspace) |aw| {
                allocator.free(aw);
            }
            state.active_workspace = try allocator.dupe(u8, ws.name);
            state.message = "✓ Switched workspace";
        }
        utils.reloadStore(allocator, state, snip_store);
        state.mode = .normal;
    }
}

fn handlePackBrowserKey(allocator: std.mem.Allocator, key: Key, state: *State, snip_store: *store.Store, cfg: config.Config) !void {
    const total = state.pack_list.len;

    if (key.matches(Key.escape, .{}) or key.matches('q', .{})) {
        state.mode = .normal;
        return;
    }

    if (key.matches('j', .{}) or key.matches(Key.down, .{})) {
        if (total > 0 and state.pack_cursor + 1 < total) state.pack_cursor += 1;
    } else if (key.matches('k', .{}) or key.matches(Key.up, .{})) {
        if (state.pack_cursor > 0) state.pack_cursor -= 1;
    } else if (key.matches('g', .{})) {
        state.pack_cursor = 0;
    } else if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
        if (total > 0) state.pack_cursor = total - 1;
    } else if (key.matches(Key.enter, .{}) or key.matches('i', .{})) {
        if (total > 0 and state.pack_cursor < total) {
            const p = &state.pack_list[state.pack_cursor];
            if (p.installed) {
                state.message = "Pack already installed";
            } else {
                const result = pack_mod.install(allocator, cfg, p.name, null, snip_store) catch {
                    state.message = "✗ Failed to install pack";
                    return;
                };
                defer pack_mod.freeInstallResult(allocator, result);

                if (result.err_msg) |_| {
                    state.message = "✗ Failed to install pack";
                } else {
                    p.installed = true;
                    allocator.free(state.filtered_indices);
                    state.filtered_indices = utils.updateFilter(allocator, snip_store, "") catch &.{};
                    state.message = "✓ Pack installed!";
                }
            }
        }
    } else if (key.matches('u', .{})) {
        if (total > 0 and state.pack_cursor < total) {
            const p = &state.pack_list[state.pack_cursor];
            if (!p.installed) {
                state.message = "Pack not installed";
            } else {
                const removed = pack_mod.uninstall(allocator, cfg, p.name, snip_store) catch {
                    state.message = "✗ Failed to uninstall";
                    return;
                };
                _ = removed;
                p.installed = false;
                allocator.free(state.filtered_indices);
                state.filtered_indices = utils.updateFilter(allocator, snip_store, "") catch &.{};
                state.message = "✓ Pack uninstalled";
            }
        }
    }
}

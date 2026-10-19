const std = @import("std");
const builtin = @import("builtin");

const core = @import("zodo");

const platform = @import("platform.zig");
const sdl = platform.sdl;
const Color = platform.Color;
const Point = platform.Point;
const Rect = platform.Rect;

// SDL stores the task list in this per-user directory, such as ~/.local/share/zodo/ on Linux.
const pref_org = "";
const pref_app = "zodo";
const save_file = "tasks.md";

const bg = color(13, 17, 27);
const panel = color(21, 28, 42);
const panel_hover = color(27, 36, 53);
const border = color(41, 53, 72);
const muted = color(126, 145, 168);
const ink = color(232, 240, 248);
const accent = color(75, 218, 205);
const selection_bg = color(36, 92, 96);
const match_bg = color(92, 79, 36);
const danger = color(240, 105, 119);

const pad = 32;
const row_h = 44;
const field_h = 44;
const tab_w = 76;
const blink_ms = 530;
const menu_w = 252;
const menu_row_h = 38;

const MenuAction = enum { import_tasks, export_tasks, quit };
const menu_actions = std.enums.values(MenuAction);
const menu_labels = [_][]const u8{ "Import Markdown…", "Export Markdown…", "Quit" };

fn color(r: u8, g: u8, b: u8) Color {
    return .{
        .r = r,
        .g = g,
        .b = b,
    };
}

const Layout = struct {
    add: Rect,
    search: Rect,
    tabs: [3]Rect,
    list: Rect,
    clear_done: Rect,
    footer_y: f32,
    menu_button: Rect,
    menu: Rect,

    fn compute(size: Point) Layout {
        const w = size.x - 2 * pad;
        const search_w = w - 3 * tab_w - 12;
        const footer_y = size.y - 44;
        const clear_w = platform.textWidth(.strong, "Clear done") + 24;
        const header_center = 36 + platform.lineHeight(.small) / 2;
        var tabs: [3]Rect = undefined;
        for (&tabs, 0..) |*tab, i| tab.* = .{
            .x = pad + search_w + 12 + @as(f32, @floatFromInt(i)) * tab_w,
            .y = 144,
            .w = tab_w,
            .h = 40,
        };
        return .{
            .menu_button = .{
                .x = size.x - pad - 32,
                .y = header_center - 16,
                .w = 32,
                .h = 32,
            },
            .menu = .{
                .x = size.x - pad - menu_w,
                .y = header_center + 24,
                .w = menu_w,
                .h = menu_row_h * menu_actions.len + 8,
            },
            .add = .{
                .x = pad,
                .y = 84,
                .w = w,
                .h = field_h,
            },
            .search = .{
                .x = pad,
                .y = 144,
                .w = search_w,
                .h = 40,
            },
            .list = .{
                .x = pad,
                .y = 200,
                .w = w,
                .h = @max(0, footer_y - 212),
            },
            .clear_done = .{
                .x = pad + w - clear_w,
                .y = footer_y - 2,
                .w = clear_w,
                .h = 28,
            },
            .footer_y = footer_y,
            .tabs = tabs,
        };
    }
};

/// Fields that take text input, with per-field view state.
const FieldView = struct {
    /// Horizontal scroll that keeps the cursor visible.
    scroll: f32 = 0,
    /// Logical x of the text's first character, for mouse hit tests.
    origin: f32 = 0,
    rect: Rect = .{
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
    },
    caret_x: f32 = 0,
};

const Ui = struct {
    gpa: std.mem.Allocator,
    app: *core.App,
    save_path: ?[:0]u8,
    layout: Layout = undefined,
    mouse: Point = .{ .x = -1, .y = -1 },
    scroll: f32 = 0,
    /// Scroll the selected row into view on the next frame.
    reveal: bool = false,
    views: std.enums.EnumArray(core.Focus, FieldView) = .initFill(.{}),
    dragging: ?core.Focus = null,
    caret_epoch: u64 = 0,
    menu_open: bool = false,
    menu_selected: usize = 0,
    dialog_pending: bool = false,

    fn menuRow(ui: *const Ui, index: usize) Rect {
        const r = ui.layout.menu;
        return .{
            .x = r.x + 4,
            .y = r.y + 4 + @as(f32, @floatFromInt(index)) * menu_row_h,
            .w = r.w - 8,
            .h = menu_row_h,
        };
    }

    fn toggleMenu(ui: *Ui) void {
        ui.menu_open = !ui.menu_open;
        ui.menu_selected = 0;
        ui.dragging = null;
        ui.app.setComposition("");
    }

    /// Menu items and shortcuts share the same actions.
    fn action(ui: *Ui, selected: MenuAction) !bool {
        ui.menu_open = false;
        if (selected != .quit and ui.dialog_pending) return true;

        // Include any task currently being renamed in saved/exported data.
        if (ui.app.focus == .edit) try ui.app.focusOn(.list);
        switch (selected) {
            .import_tasks, .export_tasks => {
                ui.dialog_pending = true;
                platform.showFileDialog(if (selected == .import_tasks) .open else .save);
            },
            .quit => return false,
        }

        return true;
    }

    fn view(ui: *Ui, focus: core.Focus) *FieldView {
        return ui.views.getPtr(focus);
    }

    fn fieldFor(ui: *Ui, focus: core.Focus) *core.TextField {
        return switch (focus) {
            .add => &ui.app.add_field,
            .search => &ui.app.search_field,
            .edit => &ui.app.edit_field,
            .list => unreachable,
        };
    }

    fn rowRect(ui: *const Ui, row: usize) Rect {
        const l = ui.layout.list;
        return .{
            .x = l.x,
            .y = l.y + @as(f32, @floatFromInt(row)) * row_h - ui.scroll,
            .w = l.w,
            .h = row_h,
        };
    }

    fn rowAt(ui: *const Ui, p: Point) ?usize {
        if (!ui.layout.list.contains(p)) return null;
        const row: usize = @intFromFloat((p.y - ui.layout.list.y + ui.scroll) / row_h);
        return if (row < ui.app.visible.items.len) row else null;
    }

    fn checkboxRect(r: Rect) Rect {
        return .{
            .x = r.x,
            .y = r.y,
            .w = 44,
            .h = r.h,
        };
    }

    fn deleteRect(r: Rect) Rect {
        return .{
            .x = r.x + r.w - 40,
            .y = r.y,
            .w = 40,
            .h = r.h,
        };
    }

    fn editRect(r: Rect) Rect {
        return .{
            .x = r.x + 40,
            .y = r.y + 5,
            .w = r.w - 84,
            .h = r.h - 10,
        };
    }

    fn save(ui: *Ui) void {
        ui.app.dirty = false;
        const path = ui.save_path orelse return;
        const data = ui.app.tasks.serialize(ui.gpa) catch return;
        defer ui.gpa.free(data);
        platform.saveFile(ui.gpa, path, data) catch {};
    }

    /// Handles one event. Returns false to quit.
    fn handle(ui: *Ui, event: sdl.SDL_Event) !bool {
        const app = ui.app;
        if (platform.fileDialogResult(event)) |result| {
            defer result.deinit();
            ui.dialog_pending = false;
            if (result.failure) |message| {
                platform.showError("File dialog failed", message);
            } else if (result.path) |path| switch (result.kind) {
                .open => {
                    if (platform.loadFile(path)) |data| {
                        defer platform.free(data);
                        _ = try app.import(data);
                        ui.reveal = true;
                    } else platform.showError("Import failed", sdl.SDL_GetError());
                },
                .save => {
                    const data = try app.tasks.serialize(ui.gpa);
                    defer ui.gpa.free(data);
                    platform.saveFile(ui.gpa, path, data) catch {
                        platform.showError("Export failed", "Could not write the selected file.");
                    };
                },
            };
            return true;
        }

        switch (event.type) {
            sdl.SDL_EVENT_QUIT, sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => return false,
            sdl.SDL_EVENT_TEXT_INPUT => {
                if (ui.menu_open) return true;
                try app.insertText(std.mem.span(event.text.text));
                ui.caret_epoch = platform.getTicks();
            },
            sdl.SDL_EVENT_TEXT_EDITING => if (!ui.menu_open) app.setComposition(
                std.mem.span(event.edit.text),
            ),
            sdl.SDL_EVENT_KEY_DOWN => return ui.key(event.key.key, event.key.mod),
            sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => if (event.button.button == sdl.SDL_BUTTON_LEFT) {
                ui.mouse = platform.toLogical(event.button.x, event.button.y);
                if (ui.layout.menu_button.contains(ui.mouse)) {
                    ui.toggleMenu();
                    return true;
                }
                if (ui.menu_open) {
                    for (menu_actions, 0..) |selected, i| if (ui.menuRow(i).contains(ui.mouse)) {
                        return ui.action(selected);
                    };
                    // Dismiss without passing the click to controls underneath.
                    ui.menu_open = false;
                    return true;
                }
                try ui.click(event.button.clicks, platform.modState() & sdl.SDL_KMOD_SHIFT != 0);
            },
            sdl.SDL_EVENT_MOUSE_BUTTON_UP => ui.dragging = null,
            sdl.SDL_EVENT_MOUSE_MOTION => {
                ui.mouse = platform.toLogical(event.motion.x, event.motion.y);
                if (ui.menu_open) {
                    for (menu_actions, 0..) |_, i| if (ui.menuRow(i).contains(ui.mouse)) {
                        ui.menu_selected = i;
                    };
                    return true;
                }
                if (ui.dragging) |focus| {
                    if (app.focus == focus) {
                        const f = ui.fieldFor(focus);
                        f.setCursor(
                            platform.hitText(.body, f.text(), ui.mouse.x - ui.view(focus).origin),
                            true,
                        );
                    } else ui.dragging = null;
                }
            },
            sdl.SDL_EVENT_WINDOW_MOUSE_LEAVE => ui.mouse = .{ .x = -1, .y = -1 },
            sdl.SDL_EVENT_WINDOW_FOCUS_LOST => {
                ui.menu_open = false;
                ui.dragging = null;
            },
            sdl.SDL_EVENT_MOUSE_WHEEL => if (!ui.menu_open and ui.layout.list.contains(ui.mouse)) {
                ui.scroll -= event.wheel.y * row_h;
            },
            sdl.SDL_EVENT_DROP_TEXT => {
                const added = try app.import(std.mem.span(event.drop.data));
                std.log.info("ZODO: imported {d} dropped lines", .{added});
            },
            sdl.SDL_EVENT_DROP_FILE => {
                const path = std.mem.span(event.drop.data);
                if (platform.loadFile(path)) |data| {
                    defer platform.free(data);
                    const added = try app.import(data);
                    std.log.info("ZODO: imported {d} tasks from {s}", .{ added, path });
                } else std.log.err("ZODO: can't read {s}: {s}", .{ path, sdl.SDL_GetError() });
            },
            else => {},
        }

        return true;
    }

    fn key(ui: *Ui, keycode: sdl.SDL_Keycode, mod: sdl.SDL_Keymod) !bool {
        const app = ui.app;
        const primary = platform.primaryMod(mod);
        const shift = mod & sdl.SDL_KMOD_SHIFT != 0;
        ui.caret_epoch = platform.getTicks();

        if (primary) switch (keycode) {
            sdl.SDLK_Q => return ui.action(.quit),
            sdl.SDLK_O => return ui.action(.import_tasks),
            sdl.SDLK_E => return ui.action(.export_tasks),
            else => {},
        };
        if (keycode == sdl.SDLK_F10) {
            ui.toggleMenu();
            return true;
        }
        if (ui.menu_open) {
            switch (keycode) {
                sdl.SDLK_ESCAPE, sdl.SDLK_TAB => ui.menu_open = false,
                sdl.SDLK_UP => ui.menu_selected = (ui.menu_selected + menu_actions.len - 1) % menu_actions.len,
                sdl.SDLK_DOWN => ui.menu_selected = (ui.menu_selected + 1) % menu_actions.len,
                sdl.SDLK_HOME => ui.menu_selected = 0,
                sdl.SDLK_END => ui.menu_selected = menu_actions.len - 1,
                sdl.SDLK_RETURN, sdl.SDLK_KP_ENTER, sdl.SDLK_SPACE => return ui.action(
                    menu_actions[ui.menu_selected],
                ),
                else => {},
            }
            return true;
        }
        if (primary and keycode == sdl.SDLK_V) {
            if (platform.getClipboard()) |text| {
                defer platform.free(text);
                try app.insertText(text);
            }
            return true;
        }

        const cmd = keyCommand(keycode, mod) orelse return true;
        if (try app.command(cmd, shift)) |copied| try platform.setClipboard(ui.gpa, copied);

        ui.reveal = true;
        return true;
    }

    fn click(ui: *Ui, clicks: u8, shift: bool) !void {
        const app = ui.app;
        const p = ui.mouse;
        const l = ui.layout;
        ui.caret_epoch = platform.getTicks();

        // Clicking anywhere else commits an edit in progress.
        if (app.focus == .edit and !ui.view(.edit).rect.contains(p)) try app.focusOn(.list);

        for ([_]core.Focus{ .add, .search }) |focus| if (ui.view(focus).rect.contains(p)) {
            try app.focusOn(focus);
            ui.pointField(focus, clicks, shift);
            return;
        };
        for (l.tabs, [_]core.Filter{ .all, .active, .done }) |tab, filter| if (tab.contains(p)) {
            return app.setFilter(filter);
        };

        if (l.clear_done.contains(p) and app.tasks.countDone() > 0) return app.clearDone();
        if (ui.rowAt(p)) |row| {
            const r = ui.rowRect(row);
            const id = app.visibleTask(row).id;
            if (app.editing == id and editRect(r).contains(p)) {
                ui.pointField(.edit, clicks, shift);
            } else if (checkboxRect(r).contains(p)) {
                try app.toggle(id);
            } else if (deleteRect(r).contains(p)) {
                try app.remove(id);
            } else if (clicks >= 2) {
                try app.startEdit(id);
                ui.view(.edit).scroll = 0;
            } else try app.select(id);
        }
    }

    /// Places the cursor where the mouse points.
    /// Double-clicking selects a word and triple-clicking selects everything.
    fn pointField(ui: *Ui, focus: core.Focus, clicks: u8, shift: bool) void {
        const f = ui.fieldFor(focus);
        const pos = platform.hitText(.body, f.text(), ui.mouse.x - ui.view(focus).origin);
        if (clicks >= 3) {
            f.selectAll();
        } else if (clicks == 2) {
            f.selectWord(pos);
        } else {
            f.setCursor(pos, shift);
            ui.dragging = focus;
        }
    }

    fn render(ui: *Ui) void {
        const app = ui.app;
        const size = platform.size();
        ui.layout = .compute(size);
        const l = ui.layout;
        platform.clear(bg);
        platform.drawText(.title, "Zodo", pad, 24, ink);

        var buf: [96]u8 = undefined;
        const done = app.tasks.countDone();
        const open = app.tasks.items.items.len - done;
        platform.drawText(
            .small,
            std.fmt.bufPrint(&buf, "{d} open · {d} done", .{ open, done }) catch "",
            pad + platform.textWidth(.title, "Zodo") + 14,
            36,
            muted,
        );

        ui.drawField(.add, l.add, .plus, "Add a task and press Enter");
        ui.drawField(.search, l.search, .search, "Filter tasks");

        for (l.tabs, [_]core.Filter{ .all, .active, .done }, [_][]const u8{ "All", "Active", "Done" }) |tab, filter, label| {
            const active = app.filter == filter;
            const hover = tab.contains(ui.mouse);
            platform.fillRect(tab, if (active) selection_bg else if (hover) panel_hover else panel);
            platform.strokeRect(tab, if (active) accent else border);
            platform.drawText(
                .strong,
                label,
                tab.x + (tab.w - platform.textWidth(.strong, label)) / 2,
                tab.y + (tab.h - platform.lineHeight(.strong)) / 2,
                if (active) ink else muted,
            );
        }

        ui.drawList();

        const shown = app.visible.items.len;
        const total = app.tasks.items.items.len;
        const summary = if (shown == total)
            std.fmt.bufPrint(
                &buf,
                "{d} {s}",
                .{ total, if (total == 1) "task" else "tasks" },
            ) catch ""
        else
            std.fmt.bufPrint(&buf, "Showing {d} of {d}", .{ shown, total }) catch "";
        platform.drawText(.small, summary, pad, l.footer_y + 4, muted);

        const can_clear = done > 0;
        const clear_hover = can_clear and l.clear_done.contains(ui.mouse);
        platform.fillRect(l.clear_done, if (clear_hover) panel_hover else bg);
        platform.strokeRect(l.clear_done, if (can_clear) border else panel);
        platform.drawText(
            .strong,
            "Clear done",
            l.clear_done.x + 12,
            l.clear_done.y + (l.clear_done.h - platform.lineHeight(.strong)) / 2,
            if (!can_clear) border else if (clear_hover) danger else muted,
        );

        ui.drawMenu();
        platform.present();

        ui.updateCursor();
        if (!ui.menu_open and app.field() != null) {
            const v = ui.view(app.focus);
            platform.startTextInput(v.rect, v.caret_x - v.rect.x);
        } else platform.stopTextInput();
    }

    fn drawMenu(ui: *Ui) void {
        const button = ui.layout.menu_button;
        const hover = button.contains(ui.mouse);
        if (ui.menu_open or hover) platform.fillRect(button, panel_hover);

        // Three crisp strokes, centered on the header count's line.
        for (0..3) |i| platform.fillRect(.{
            .x = button.x + 7,
            .y = button.y + 9 + @as(f32, @floatFromInt(i)) * 6,
            .w = 18,
            .h = 2,
        }, if (ui.menu_open or hover) accent else muted);
        if (!ui.menu_open) return;

        const r = ui.layout.menu;
        platform.fillRect(.{ .x = r.x + 3, .y = r.y + 4, .w = r.w, .h = r.h }, bg);
        platform.fillRect(r, panel);
        platform.strokeRect(r, border);

        const shortcuts = if (builtin.os.tag == .macos)
            [_][]const u8{ "⌘O", "⌘E", "⌘Q" }
        else
            [_][]const u8{ "Ctrl+O", "Ctrl+E", "Ctrl+Q" };
        for (menu_labels, shortcuts, 0..) |label, shortcut, i| {
            const row = ui.menuRow(i);
            const disabled = ui.dialog_pending and menu_actions[i] != .quit;
            if (i == ui.menu_selected and !disabled) platform.fillRect(row, selection_bg);
            const y = row.y + (row.h - platform.lineHeight(.small)) / 2;
            platform.drawText(.small, label, row.x + 10, y, if (disabled) muted else ink);
            platform.drawText(
                .small,
                shortcut,
                row.x + row.w - 10 - platform.textWidth(.small, shortcut),
                y,
                muted,
            );
        }
    }

    fn drawList(ui: *Ui) void {
        const app = ui.app;
        const l = ui.layout.list;
        const rows = app.visible.items.len;
        const max_scroll = @max(0, @as(f32, @floatFromInt(rows)) * row_h - l.h);

        if (ui.reveal) if (app.selectedRow()) |row| {
            const top = @as(f32, @floatFromInt(row)) * row_h;
            if (top < ui.scroll) ui.scroll = top;
            if (top + row_h > ui.scroll + l.h) ui.scroll = top + row_h - l.h;
        };

        ui.reveal = false;
        ui.scroll = std.math.clamp(ui.scroll, 0, max_scroll);

        if (rows == 0) {
            const empty = app.tasks.items.items.len == 0;
            const s = platform.iconSize(.empty);
            const y = l.y + @max(0, (l.h - s - 60) / 3);
            platform.drawIcon(.empty, l.x + (l.w - s) / 2, y, .{ .r = 255, .g = 255, .b = 255 });

            const title: []const u8 = if (empty) "Nothing to do yet" else "No matching tasks";
            const hint: []const u8 = if (empty) "Add a task above, or drop a text file here" else "Try another filter or search";
            platform.drawText(
                .body,
                title,
                l.x + (l.w - platform.textWidth(.body, title)) / 2,
                y + s + 16,
                ink,
            );
            platform.drawText(
                .small,
                hint,
                l.x + (l.w - platform.textWidth(.small, hint)) / 2,
                y + s + 42,
                muted,
            );

            return;
        }

        platform.clip(l);
        defer platform.clip(null);
        const first: usize = @intFromFloat(ui.scroll / row_h);
        var row = first;
        while (row < rows) : (row += 1) {
            const r = ui.rowRect(row);
            if (r.y >= l.y + l.h) break;
            ui.drawRow(row, r);
        }
    }

    fn drawRow(ui: *Ui, row: usize, r: Rect) void {
        const app = ui.app;
        const task = app.visibleTask(row);
        const selected = app.selected == task.id;
        const hover = r.contains(ui.mouse) and ui.layout.list.contains(ui.mouse);

        if (selected or hover) platform.fillRect(r, if (selected) panel else panel_hover);
        if (selected and (app.focus == .list or app.focus == .edit)) platform.fillRect(
            .{ .x = r.x, .y = r.y, .w = 3, .h = r.h },
            accent,
        );
        platform.fillRect(
            .{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 },
            panel,
        );

        const box = platform.iconSize(.box);
        const bx = r.x + 12;
        const by = r.y + (r.h - box) / 2;

        if (task.done) {
            platform.drawIcon(.box_checked, bx, by, accent);
            platform.drawIcon(.check, bx, by, bg);
        } else platform.drawIcon(
            .box,
            bx,
            by,
            if (checkboxRect(r).contains(ui.mouse)) accent else muted,
        );

        if (app.editing == task.id) {
            ui.drawField(.edit, editRect(r), null, "");
        } else {
            const x = r.x + 48;
            const y = r.y + (r.h - platform.lineHeight(.body)) / 2;
            const max_w = r.w - 48 - 44;
            const title = task.title;
            var shown = title;
            var ellipsis = false;

            if (platform.textWidth(.body, title) > max_w) {
                shown = title[0..platform.fitText(
                    .body,
                    title,
                    max_w - platform.textWidth(.body, "…"),
                )];
                ellipsis = true;
            }

            // Highlight each search term's first match in the visible text.
            var it = core.terms(app.query());
            while (it.next()) |term| if (core.findIgnoreCase(shown, term)) |at| {
                const end = @min(at + term.len, shown.len);
                const mx = x + platform.textWidth(.body, shown[0..at]);
                platform.fillRect(
                    .{
                        .x = mx - 1,
                        .y = y,
                        .w = platform.textWidth(.body, shown[at..end]) + 2,
                        .h = platform.lineHeight(.body),
                    },
                    match_bg,
                );
            };
            const tint = if (task.done) muted else ink;
            platform.drawText(.body, shown, x, y, tint);
            var w = platform.textWidth(.body, shown);

            if (ellipsis) {
                platform.drawText(.body, "…", x + w, y, tint);
                w += platform.textWidth(.body, "…");
            }
            if (task.done) platform.fillRect(
                .{ .x = x, .y = y + platform.lineHeight(.body) / 2, .w = w, .h = 1 },
                muted,
            );
        }

        if (hover or selected) {
            const d = deleteRect(r);
            const s = platform.iconSize(.delete);
            platform.drawIcon(
                .delete,
                d.x + (d.w - s) / 2,
                d.y + (d.h - s) / 2,
                if (d.contains(ui.mouse)) danger else muted,
            );
        }
    }

    /// Draws a text field with its selection, input method composition, and
    /// blinking cursor, scrolled to keep the cursor visible.
    fn drawField(ui: *Ui, focus: core.Focus, r: Rect, icon: ?platform.Icon, placeholder: []const u8) void {
        const app = ui.app;
        const f = ui.fieldFor(focus);
        const v = ui.view(focus);
        const focused = app.focus == focus and !ui.menu_open;

        v.rect = r;
        platform.fillRect(r, if (focus == .edit) bg else panel);
        platform.strokeRect(r, if (focused) accent else border);

        var inner = r.inset(12, 0);
        if (icon) |i| {
            const s = platform.iconSize(i);
            platform.drawIcon(i, r.x + 12, r.y + (r.h - s) / 2, if (focused) accent else muted);
            inner.x += s + 8;
            inner.w -= s + 8;
        }

        // Show composition text at the cursor without changing the field.
        const text = f.text();
        const comp = if (focused) f.composition() else "";
        var display_buf: [2 * core.max_text]u8 = undefined;
        const display = std.fmt.bufPrint(
            &display_buf,
            "{s}{s}{s}",
            .{ text[0..f.cursor], comp, text[f.cursor..] },
        ) catch text;
        const comp_x = platform.textWidth(.body, text[0..f.cursor]);
        const caret = comp_x + platform.textWidth(.body, comp);
        const room = @max(1, inner.w - 2);

        if (caret - v.scroll > room) v.scroll = caret - room;
        if (caret < v.scroll) v.scroll = caret;
        v.scroll = std.math.clamp(v.scroll, 0, @max(0, platform.textWidth(.body, display) - room));
        v.origin = inner.x - v.scroll;
        v.caret_x = v.origin + caret;

        const lh = platform.lineHeight(.body);
        const y = r.y + (r.h - lh) / 2;
        platform.clip(.{ .x = inner.x - 1, .y = r.y, .w = inner.w + 2, .h = r.h });
        defer platform.clip(null);

        if (focused and f.hasSelection() and comp.len == 0) {
            const sel = f.selection();
            const sx = v.origin + platform.textWidth(.body, text[0..sel.start]);
            platform.fillRect(
                .{
                    .x = sx,
                    .y = y,
                    .w = platform.textWidth(.body, text[sel.start..sel.end]),
                    .h = lh,
                },
                selection_bg,
            );
        }
        if (display.len == 0) {
            platform.drawText(.body, placeholder, inner.x, y, muted);
        } else platform.drawText(.body, display, v.origin, y, ink);
        if (comp.len > 0) platform.fillRect(
            .{ .x = v.origin + comp_x, .y = y + lh - 2, .w = caret - comp_x, .h = 1 },
            accent,
        );
        const blink_on = (platform.getTicks() - ui.caret_epoch) / blink_ms % 2 == 0;
        if (focused and blink_on) platform.fillRect(
            .{ .x = v.caret_x, .y = y + 1, .w = 2, .h = lh - 2 },
            accent,
        );
    }

    fn updateCursor(ui: *Ui) void {
        const p = ui.mouse;
        const app = ui.app;
        if (ui.layout.menu_button.contains(p) or ui.menu_open) {
            var over_item = false;
            for (menu_actions, 0..) |selected, i| if (ui.menuRow(i).contains(p) and (!ui.dialog_pending or selected == .quit)) {
                over_item = true;
            };
            platform.setCursor(if (ui.layout.menu_button.contains(p) or over_item) .pointer else .default);
            return;
        }
        var cursor: platform.Cursor = .default;
        if (ui.view(.add).rect.contains(p) or ui.view(.search).rect.contains(p)) cursor = .text;
        for (ui.layout.tabs) |tab| if (tab.contains(p)) {
            cursor = .pointer;
        };
        if (ui.layout.clear_done.contains(p) and app.tasks.countDone() > 0) cursor = .pointer;
        if (ui.rowAt(p)) |row| {
            const r = ui.rowRect(row);
            if (app.editing == app.visibleTask(row).id and editRect(r).contains(p)) {
                cursor = .text;
            } else if (checkboxRect(r).contains(p) or deleteRect(r).contains(p)) cursor = .pointer;
        }
        platform.setCursor(cursor);
    }

    /// Milliseconds until the cursor blinks, or null to sleep until input.
    fn timeout(ui: *const Ui) ?i32 {
        if (ui.menu_open or ui.app.field() == null) return null;
        const elapsed = platform.getTicks() - ui.caret_epoch;
        return @intCast(blink_ms - elapsed % blink_ms);
    }
};

fn keyCommand(keycode: sdl.SDL_Keycode, mod: sdl.SDL_Keymod) ?core.Command {
    const primary = platform.primaryMod(mod);
    const word = platform.wordMod(mod);
    const mac = builtin.os.tag == .macos;
    return switch (keycode) {
        sdl.SDLK_LEFT => if (mac and primary) .home else if (word) .word_left else .left,
        sdl.SDLK_RIGHT => if (mac and primary) .end else if (word) .word_right else .right,
        sdl.SDLK_UP => .up,
        sdl.SDLK_DOWN => .down,
        sdl.SDLK_HOME => .home,
        sdl.SDLK_END => .end,
        sdl.SDLK_BACKSPACE => if (word) .word_backspace else .backspace,
        sdl.SDLK_DELETE => if (word) .word_delete else .delete,
        sdl.SDLK_RETURN, sdl.SDLK_KP_ENTER => .submit,
        sdl.SDLK_ESCAPE => .cancel,
        sdl.SDLK_TAB => if (mod & sdl.SDL_KMOD_SHIFT != 0) .prev_focus else .next_focus,
        sdl.SDLK_SPACE => .toggle,
        sdl.SDLK_F2 => .rename,
        else => if (!primary) null else switch (keycode) {
            sdl.SDLK_A => .select_all,
            sdl.SDLK_C => .copy,
            sdl.SDLK_X => .cut,
            sdl.SDLK_F => .focus_search,
            sdl.SDLK_N => .focus_add,
            sdl.SDLK_1 => .filter_all,
            sdl.SDLK_2 => .filter_active,
            sdl.SDLK_3 => .filter_done,
            else => null,
        },
    };
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    platform.init("Zodo", 640, 720, 460, 420);
    defer platform.deinit();

    var app: core.App = .init(gpa);
    defer app.deinit();

    const save_path = platform.prefPath(gpa, pref_org, pref_app, save_file) catch |err| blk: {
        std.log.err("ZODO: no data directory ({s}); tasks won't be saved", .{@errorName(err)});
        break :blk null;
    };
    defer if (save_path) |path| gpa.free(path);

    if (save_path) |path| {
        if (platform.loadFile(path)) |data| {
            defer platform.free(data);
            _ = try app.import(data);
            app.dirty = false;
            std.log.info("ZODO: loaded {d} tasks from {s}", .{ app.tasks.items.items.len, path });
        } else {
            try app.seed();
            std.log.info("ZODO: starting a new list at {s}", .{path});
        }
    }

    var ui: Ui = .{
        .gpa = gpa,
        .app = &app,
        .save_path = save_path,
        .caret_epoch = platform.getTicks(),
    };
    defer if (app.dirty) ui.save();
    ui.render();

    // Sleep until input arrives, waking only to blink the text cursor.
    while (true) {
        if (platform.waitEvent(ui.timeout())) |first| {
            var event = first;
            while (true) {
                if (!try ui.handle(event)) return;
                event = platform.pollEvent() orelse break;
            }
        }
        if (app.dirty) ui.save();
        ui.render();
    }
}

//! Task-list and text-editing logic, independent of the window and rendering.
//! The UI turns SDL events into the commands and text insertions here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Maximum bytes in a text field, and so in a task title.
pub const max_text = 256;

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Motion = enum {
    left,
    right,
    word_left,
    word_right,
    home,
    end,
};

fn isWordByte(c: u8) bool {
    // Non-ASCII bytes count as word characters so accented and CJK words move as a unit.
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn prevBoundary(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (s[j] & 0xc0 != 0x80) break;
    }
    return j;
}

fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + 1;
    while (j < s.len and s[j] & 0xc0 == 0x80) j += 1;
    return j;
}

/// Moves `i` back to the start of the codepoint containing it.
fn floorBoundary(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j > 0 and j < s.len and s[j] & 0xc0 == 0x80) j -= 1;
    return j;
}

fn prevWord(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and !isWordByte(s[j - 1])) j = prevBoundary(s, j);
    while (j > 0 and isWordByte(s[j - 1])) j = prevBoundary(s, j);
    return j;
}

fn nextWord(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and !isWordByte(s[j])) j = nextBoundary(s, j);
    while (j < s.len and isWordByte(s[j])) j = nextBoundary(s, j);
    return j;
}

/// Single-line UTF-8 text with a cursor, a selection, and the uncommitted text an input method is composing.
pub const TextField = struct {
    buf: [max_text]u8 = undefined,
    len: usize = 0,

    /// Byte offsets. The selection spans the anchor and the cursor.
    cursor: usize = 0,
    anchor: usize = 0,
    composition_buf: [max_text]u8 = undefined,
    composition_len: usize = 0,

    pub fn text(f: *const TextField) []const u8 {
        return f.buf[0..f.len];
    }

    pub fn composition(f: *const TextField) []const u8 {
        return f.composition_buf[0..f.composition_len];
    }

    pub fn selection(f: *const TextField) Range {
        return .{
            .start = @min(f.anchor, f.cursor),
            .end = @max(f.anchor, f.cursor),
        };
    }

    pub fn hasSelection(f: *const TextField) bool {
        return f.anchor != f.cursor;
    }

    pub fn selectedText(f: *const TextField) []const u8 {
        const r = f.selection();
        return f.buf[r.start..r.end];
    }

    pub fn set(f: *TextField, s: []const u8) void {
        f.len = 0;
        f.cursor = 0;
        f.anchor = 0;
        f.composition_len = 0;
        _ = f.insert(s);
    }

    pub fn clear(f: *TextField) void {
        f.set("");
    }

    pub fn selectAll(f: *TextField) void {
        f.anchor = 0;
        f.cursor = f.len;
    }

    /// Places the cursor at the codepoint boundary at or before `pos`.
    pub fn setCursor(f: *TextField, pos: usize, extend: bool) void {
        f.cursor = floorBoundary(f.text(), pos);
        if (!extend) f.anchor = f.cursor;
    }

    /// Selects the word at `pos`, as a double-click does.
    pub fn selectWord(f: *TextField, pos: usize) void {
        const s = f.text();
        const at = floorBoundary(s, pos);
        var start = at;
        var end = at;

        if (at < s.len and isWordByte(s[at])) {
            while (start > 0 and isWordByte(s[start - 1])) start = prevBoundary(s, start);
            while (end < s.len and isWordByte(s[end])) end = nextBoundary(s, end);
        } else {
            end = nextBoundary(s, at);
        }

        f.anchor = start;
        f.cursor = end;
    }

    pub fn move(f: *TextField, motion: Motion, extend: bool) void {
        const s = f.text();

        // Without Shift, Left and Right collapse a selection to its edge.
        if (!extend and f.hasSelection() and (motion == .left or motion == .right)) {
            const r = f.selection();
            f.setCursor(if (motion == .left) r.start else r.end, false);
            return;
        }

        const target = switch (motion) {
            .left => prevBoundary(s, f.cursor),
            .right => nextBoundary(s, f.cursor),
            .word_left => prevWord(s, f.cursor),
            .word_right => nextWord(s, f.cursor),
            .home => 0,
            .end => s.len,
        };

        f.setCursor(target, extend);
    }

    pub fn deleteSelection(f: *TextField) bool {
        if (!f.hasSelection()) return false;
        const r = f.selection();
        std.mem.copyForwards(u8, f.buf[r.start..], f.buf[r.end..f.len]);
        f.len -= r.end - r.start;
        f.setCursor(r.start, false);
        return true;
    }

    /// Replaces the selection with `s`. Line breaks and tabs become spaces, other control
    /// characters and invalid UTF-8 are dropped, and text past `max_text` is cut at a codepoint
    /// boundary. Returns whether the text changed.
    pub fn insert(f: *TextField, s: []const u8) bool {
        var changed = f.deleteSelection();
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                i += 1;
                continue;
            };
            if (i + n > s.len) break;
            const seq = s[i .. i + n];
            i += n;
            if (n > 1 and !std.unicode.utf8ValidateSlice(seq)) continue;
            var c = seq;
            if (n == 1) {
                if (seq[0] == '\n' or seq[0] == '\r' or seq[0] == '\t') {
                    c = " ";
                } else if (seq[0] < 0x20 or seq[0] == 0x7f) {
                    continue;
                }
            }
            if (f.len + c.len > max_text) break;
            std.mem.copyBackwards(
                u8,
                f.buf[f.cursor + c.len .. f.len + c.len],
                f.buf[f.cursor..f.len],
            );
            @memcpy(f.buf[f.cursor..][0..c.len], c);
            f.len += c.len;
            f.cursor += c.len;
            changed = true;
        }
        f.anchor = f.cursor;
        return changed;
    }

    /// Deletes the selection, or the codepoint or word before the cursor.
    pub fn backspace(f: *TextField, word: bool) bool {
        if (f.deleteSelection()) return true;
        if (f.cursor == 0) return false;
        f.anchor = if (word) prevWord(f.text(), f.cursor) else prevBoundary(f.text(), f.cursor);
        return f.deleteSelection();
    }

    /// Deletes the selection, or the codepoint or word after the cursor.
    pub fn delete(f: *TextField, word: bool) bool {
        if (f.deleteSelection()) return true;
        if (f.cursor == f.len) return false;
        f.anchor = if (word) nextWord(f.text(), f.cursor) else nextBoundary(f.text(), f.cursor);
        return f.deleteSelection();
    }

    /// Stores in-progress input method text, shown at the cursor until the input method commits it.
    pub fn setComposition(f: *TextField, s: []const u8) void {
        const n = floorBoundary(s, @min(s.len, max_text));
        @memcpy(f.composition_buf[0..n], s[0..n]);
        f.composition_len = n;
    }
};

pub const Task = struct {
    id: u32,
    title: []u8,
    done: bool = false,
};

/// Returns the byte offset of `needle` in `haystack`, ignoring ASCII case.
pub fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Iterates over the whitespace-separated terms of a search query.
pub fn terms(query: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, query, " ");
}

/// A title matches when it contains every query term, ignoring ASCII case.
pub fn matchesQuery(title: []const u8, query: []const u8) bool {
    var it = terms(query);
    while (it.next()) |term| if (findIgnoreCase(title, term) == null) return false;
    return true;
}

pub const Filter = enum {
    all,
    active,
    done,

    pub fn accepts(filter: Filter, task: Task) bool {
        return switch (filter) {
            .all => true,
            .active => !task.done,
            .done => task.done,
        };
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " ");
}

pub const Tasks = struct {
    gpa: Allocator,
    items: std.ArrayList(Task) = .empty,
    next_id: u32 = 1,

    pub fn init(gpa: Allocator) Tasks {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *Tasks) void {
        for (t.items.items) |task| t.gpa.free(task.title);
        t.items.deinit(t.gpa);
    }

    /// Appends a task. Returns its id, or null when the title is blank.
    pub fn add(t: *Tasks, title: []const u8, done: bool) Allocator.Error!?u32 {
        const trimmed = trim(title);
        if (trimmed.len == 0) return null;
        const owned = try t.gpa.dupe(u8, trimmed);
        errdefer t.gpa.free(owned);
        try t.items.append(t.gpa, .{ .id = t.next_id, .title = owned, .done = done });
        t.next_id += 1;
        return t.items.items[t.items.items.len - 1].id;
    }

    pub fn index(t: *const Tasks, id: u32) ?usize {
        for (t.items.items, 0..) |task, i| if (task.id == id) return i;
        return null;
    }

    pub fn get(t: *const Tasks, id: u32) ?*Task {
        return &t.items.items[t.index(id) orelse return null];
    }

    pub fn toggle(t: *Tasks, id: u32) bool {
        const task = t.get(id) orelse return false;
        task.done = !task.done;
        return true;
    }

    pub fn remove(t: *Tasks, id: u32) bool {
        const i = t.index(id) orelse return false;
        t.gpa.free(t.items.orderedRemove(i).title);
        return true;
    }

    /// Renames a task. A blank title leaves it unchanged.
    pub fn rename(t: *Tasks, id: u32, title: []const u8) Allocator.Error!bool {
        const task = t.get(id) orelse return false;
        const trimmed = trim(title);
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, task.title)) return false;
        const owned = try t.gpa.dupe(u8, trimmed);
        t.gpa.free(task.title);
        task.title = owned;
        return true;
    }

    pub fn clearDone(t: *Tasks) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < t.items.items.len) {
            if (t.items.items[i].done) {
                t.gpa.free(t.items.orderedRemove(i).title);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    pub fn countDone(t: *const Tasks) usize {
        var n: usize = 0;
        for (t.items.items) |task| n += @intFromBool(task.done);
        return n;
    }

    /// Writes the tasks as a Markdown task list.
    pub fn serialize(t: *const Tasks, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (t.items.items) |task| {
            try out.print(gpa, "- [{s}] {s}\n", .{ if (task.done) "x" else " ", task.title });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Adds a task for each non-blank line.
    /// Markdown list markers and task checkboxes are recognized; other lines become open tasks.
    /// Titles are cleaned up as text input is. Returns the number of tasks added.
    pub fn import(t: *Tasks, data: []const u8) Allocator.Error!usize {
        var added: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            for ([_][]const u8{ "- ", "* ", "+ " }) |marker| {
                if (std.mem.startsWith(u8, line, marker)) line = line[marker.len..];
            }
            var done = false;
            if (line.len >= 3 and line[0] == '[' and line[2] == ']') {
                if (line[1] == 'x' or line[1] == 'X') {
                    done = true;
                    line = line[3..];
                } else if (line[1] == ' ') {
                    line = line[3..];
                }
            }
            var clean: TextField = .{};
            _ = clean.insert(line);
            if (try t.add(clean.text(), done) != null) added += 1;
        }
        return added;
    }
};

pub const Focus = enum { add, search, list, edit };

/// Keyboard commands. The UI maps platform shortcuts, such as Ctrl or Cmd with a letter, to these.
pub const Command = enum {
    left,
    right,
    word_left,
    word_right,
    home,
    end,
    up,
    down,
    backspace,
    word_backspace,
    delete,
    word_delete,
    select_all,
    copy,
    cut,
    submit,
    cancel,
    next_focus,
    prev_focus,
    toggle,
    rename,
    focus_add,
    focus_search,
    filter_all,
    filter_active,
    filter_done,
};

pub const App = struct {
    tasks: Tasks,
    add_field: TextField = .{},
    search_field: TextField = .{},
    edit_field: TextField = .{},
    focus: Focus = .add,
    filter: Filter = .all,
    /// Task ids, so selection survives reordering and filtering.
    selected: ?u32 = null,
    editing: ?u32 = null,
    /// Indexes into `tasks.items` that pass the filter and search.
    visible: std.ArrayList(usize) = .empty,
    /// Set when tasks change; the UI clears it after saving.
    dirty: bool = false,
    clipboard: [max_text]u8 = undefined,

    pub fn init(gpa: Allocator) App {
        return .{ .tasks = .init(gpa) };
    }

    pub fn deinit(app: *App) void {
        app.visible.deinit(app.tasks.gpa);
        app.tasks.deinit();
    }

    /// Adds the starter tasks shown on first launch.
    pub fn seed(app: *App) Allocator.Error!void {
        _ = try app.tasks.import(
            \\- [x] Open Zodo
            \\- [ ] Type in the filter box to search tasks
            \\- [ ] Double-click a task to rename it
            \\- [ ] Press Tab to move between fields and the list
            \\- [ ] Drop a text or Markdown file to import its lines
        );
        app.dirty = true;
        try app.refresh();
    }

    /// The text field with keyboard focus, if any.
    pub fn field(app: *App) ?*TextField {
        return switch (app.focus) {
            .add => &app.add_field,
            .search => &app.search_field,
            .edit => &app.edit_field,
            .list => null,
        };
    }

    pub fn query(app: *const App) []const u8 {
        return app.search_field.text();
    }

    pub fn visibleTask(app: *const App, row: usize) *Task {
        return &app.tasks.items.items[app.visible.items[row]];
    }

    pub fn selectedRow(app: *const App) ?usize {
        const id = app.selected orelse return null;
        for (app.visible.items, 0..) |i, row| if (app.tasks.items.items[i].id == id) return row;
        return null;
    }

    /// Recomputes the visible rows and keeps the selection on one of them.
    pub fn refresh(app: *App) Allocator.Error!void {
        app.visible.clearRetainingCapacity();
        for (app.tasks.items.items, 0..) |task, i| {
            if (app.filter.accepts(task) and matchesQuery(task.title, app.query()))
                try app.visible.append(app.tasks.gpa, i);
        }
        if (app.editing) |id| if (app.tasks.get(id) == null) app.cancelEdit();
        if (app.selectedRow() == null) app.selected = null;
        if (app.selected == null and app.focus == .list) app.selectRow(0);
    }

    fn selectRow(app: *App, row: usize) void {
        if (app.visible.items.len == 0) {
            app.selected = null;
            return;
        }
        app.selected = app.visibleTask(@min(row, app.visible.items.len - 1)).id;
    }

    /// Inserts typed, pasted, or input-method text into the focused field.
    pub fn insertText(app: *App, s: []const u8) Allocator.Error!void {
        const f = app.field() orelse return;
        f.composition_len = 0;
        if (f.insert(s)) try app.refresh();
    }

    pub fn setComposition(app: *App, s: []const u8) void {
        if (app.field()) |f| f.setComposition(s);
    }

    /// Moves keyboard focus, committing an edit in progress.
    pub fn focusOn(app: *App, focus: Focus) Allocator.Error!void {
        if (app.focus == .edit and focus != .edit) try app.commitEdit();
        if (app.field()) |f| f.composition_len = 0;
        app.focus = focus;
        try app.refresh();
    }

    pub fn select(app: *App, id: u32) Allocator.Error!void {
        try app.focusOn(.list);
        if (app.tasks.get(id) != null) app.selected = id;
    }

    pub fn setFilter(app: *App, filter: Filter) Allocator.Error!void {
        // The edited task might not pass the new filter.
        try app.commitEdit();
        app.filter = filter;
        try app.refresh();
    }

    pub fn toggle(app: *App, id: u32) Allocator.Error!void {
        if (app.tasks.toggle(id)) app.dirty = true;
        try app.refresh();
    }

    pub fn remove(app: *App, id: u32) Allocator.Error!void {
        // Keep the selection at the same position in the list.
        const row = app.selectedRow();
        const was_selected = app.selected == id;
        if (app.tasks.remove(id)) app.dirty = true;
        try app.refresh();
        if (was_selected) if (row) |r| app.selectRow(r);
    }

    pub fn clearDone(app: *App) Allocator.Error!void {
        if (app.tasks.clearDone() > 0) app.dirty = true;
        try app.refresh();
    }

    pub fn import(app: *App, data: []const u8) Allocator.Error!usize {
        const added = try app.tasks.import(data);
        if (added > 0) app.dirty = true;
        try app.refresh();
        return added;
    }

    pub fn startEdit(app: *App, id: u32) Allocator.Error!void {
        const task = app.tasks.get(id) orelse return;
        try app.focusOn(.list);
        app.selected = id;
        app.editing = id;
        app.edit_field.set(task.title);
        app.focus = .edit;
    }

    fn commitEdit(app: *App) Allocator.Error!void {
        const id = app.editing orelse return;
        if (try app.tasks.rename(id, app.edit_field.text())) app.dirty = true;
        app.cancelEdit();
        try app.refresh();
    }

    fn cancelEdit(app: *App) void {
        app.editing = null;
        app.edit_field.clear();
        if (app.focus == .edit) app.focus = .list;
    }

    /// Runs a command for the focused element. `extend` is Shift for selection.
    /// Copy and cut return the text for the system clipboard.
    pub fn command(app: *App, cmd: Command, extend: bool) Allocator.Error!?[]const u8 {
        switch (cmd) {
            .focus_add => try app.focusOn(.add),
            .focus_search => {
                try app.focusOn(.search);
                app.search_field.selectAll();
            },
            .filter_all => try app.setFilter(.all),
            .filter_active => try app.setFilter(.active),
            .filter_done => try app.setFilter(.done),
            .next_focus, .prev_focus => {
                const order = [_]Focus{ .add, .search, .list };
                const current: usize = switch (app.focus) {
                    .add => 0,
                    .search => 1,
                    .list, .edit => 2,
                };
                const step: usize = if (cmd == .next_focus) 1 else order.len - 1;
                try app.focusOn(order[(current + step) % order.len]);
            },
            else => if (app.focus == .list) try app.listCommand(cmd) else return app.fieldCommand(cmd, extend),
        }
        return null;
    }

    fn listCommand(app: *App, cmd: Command) Allocator.Error!void {
        const row = app.selectedRow();
        const id = app.selected;
        switch (cmd) {
            .up => if (row == null or row.? == 0) try app.focusOn(.search) else app.selectRow(row.? - 1),
            .down => app.selectRow(if (row) |r| r + 1 else 0),
            .home => app.selectRow(0),
            .end => app.selectRow(app.visible.items.len),
            .toggle => if (id) |i| try app.toggle(i),
            .submit, .rename => if (id) |i| try app.startEdit(i),
            .delete, .backspace => if (id) |i| try app.remove(i),
            .cancel => app.selected = null,
            else => {},
        }
    }

    fn fieldCommand(app: *App, cmd: Command, extend: bool) Allocator.Error!?[]const u8 {
        const f = app.field().?;
        var changed = false;
        switch (cmd) {
            .left => f.move(.left, extend),
            .right => f.move(.right, extend),
            .word_left => f.move(.word_left, extend),
            .word_right => f.move(.word_right, extend),
            .home => f.move(.home, extend),
            .end => f.move(.end, extend),
            .backspace => changed = f.backspace(false),
            .word_backspace => changed = f.backspace(true),
            .delete => changed = f.delete(false),
            .word_delete => changed = f.delete(true),
            .select_all => f.selectAll(),
            .copy, .cut => {
                if (!f.hasSelection()) return null;
                const s = f.selectedText();
                @memcpy(app.clipboard[0..s.len], s);
                if (cmd == .cut) {
                    _ = f.deleteSelection();
                    try app.refresh();
                }
                return app.clipboard[0..s.len];
            },
            .down => if (app.focus != .edit) try app.focusOn(.list),
            .up => if (app.focus == .search) try app.focusOn(.add),
            .submit => switch (app.focus) {
                .add => if (try app.tasks.add(f.text(), false)) |id| {
                    f.clear();
                    app.dirty = true;
                    // Select the new task so the list can scroll to it.
                    // The refresh drops the selection if a filter hides it.
                    app.selected = id;
                    try app.refresh();
                },
                .search => try app.focusOn(.list),
                .edit => try app.focusOn(.list),
                .list => unreachable,
            },
            .cancel => switch (app.focus) {
                .edit => app.cancelEdit(),
                else => if (f.len > 0) {
                    f.clear();
                    changed = true;
                } else try app.focusOn(.list),
            },
            else => {},
        }
        if (changed) try app.refresh();
        return null;
    }
};

test "text field inserts and deletes whole codepoints" {
    var f: TextField = .{};
    _ = f.insert("café 東京");
    try testing.expectEqualStrings("café 東京", f.text());
    _ = f.backspace(false);
    try testing.expectEqualStrings("café 東", f.text());
    f.move(.home, false);
    f.move(.right, false);
    f.move(.right, false);
    f.move(.right, false);
    try testing.expectEqual(@as(usize, 3), f.cursor);
    _ = f.delete(false);
    try testing.expectEqualStrings("caf 東", f.text());
    f.setCursor(6, false); // Inside the three-byte 東 sequence.
    try testing.expectEqual(@as(usize, 4), f.cursor);
}

test "text field moves and deletes by word" {
    var f: TextField = .{};
    _ = f.insert("buy oat milk");
    f.move(.word_left, false);
    try testing.expectEqual(@as(usize, 8), f.cursor);
    f.move(.word_left, true);
    try testing.expectEqualStrings("oat ", f.selectedText());
    f.move(.end, false);
    _ = f.backspace(true);
    try testing.expectEqualStrings("buy oat ", f.text());
    f.move(.home, false);
    _ = f.delete(true);
    try testing.expectEqualStrings(" oat ", f.text());
}

test "text field replaces selections and collapses them on arrows" {
    var f: TextField = .{};
    _ = f.insert("hello world");
    f.selectWord(8);
    try testing.expectEqualStrings("world", f.selectedText());
    _ = f.insert("there");
    try testing.expectEqualStrings("hello there", f.text());
    f.selectAll();
    f.move(.left, false);
    try testing.expectEqual(@as(usize, 0), f.cursor);
    try testing.expect(!f.hasSelection());
}

test "text field cleans up pasted text and respects its capacity" {
    var f: TextField = .{};
    _ = f.insert("one\ntwo\tthree\x07\xff!");
    try testing.expectEqualStrings("one two three!", f.text());
    f.clear();
    var long: [max_text + 2]u8 = @splat('a');
    long[max_text - 1] = 0xc3; // A two-byte é that won't fit.
    long[max_text] = 0xa9;
    _ = f.insert(&long);
    try testing.expectEqual(@as(usize, max_text - 1), f.len);
    try testing.expect(std.unicode.utf8ValidateSlice(f.text()));
}

test "tasks trim titles and ignore blank ones" {
    var t: Tasks = .init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(?u32, null), try t.add("   ", false));
    const id = (try t.add("  water plants ", false)).?;
    try testing.expectEqualStrings("water plants", t.get(id).?.title);
    try testing.expect(try t.rename(id, " repot cactus"));
    try testing.expect(!try t.rename(id, "  "));
    try testing.expectEqualStrings("repot cactus", t.get(id).?.title);
    try testing.expect(t.toggle(id));
    try testing.expectEqual(@as(usize, 1), t.clearDone());
    try testing.expectEqual(@as(usize, 0), t.items.items.len);
}

test "tasks round-trip through Markdown" {
    var t: Tasks = .init(testing.allocator);
    defer t.deinit();
    _ = try t.add("ship it", true);
    _ = try t.add("write notes — 下書き", false);
    const data = try t.serialize(testing.allocator);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("- [x] ship it\n- [ ] write notes — 下書き\n", data);

    var loaded: Tasks = .init(testing.allocator);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), try loaded.import(data));
    try testing.expectEqual(@as(usize, 2), try loaded.import("\r\n* plain bullet\r\nloose line\n\n"));
    try testing.expect(loaded.items.items[0].done);
    try testing.expectEqualStrings("write notes — 下書き", loaded.items.items[1].title);
    try testing.expectEqualStrings("plain bullet", loaded.items.items[2].title);
    try testing.expectEqualStrings("loose line", loaded.items.items[3].title);
}

test "queries match every term ignoring case" {
    try testing.expect(matchesQuery("Buy Oat Milk", "milk oat"));
    try testing.expect(matchesQuery("anything", "  "));
    try testing.expect(!matchesQuery("Buy Oat Milk", "milk soy"));
    try testing.expectEqual(@as(?usize, 4), findIgnoreCase("Buy Oat Milk", "oAT"));
}

fn typeText(app: *App, s: []const u8) !void {
    try app.insertText(s);
}

test "typing in the search field filters the list" {
    var app: App = .init(testing.allocator);
    defer app.deinit();
    for ([_][]const u8{ "Buy milk", "Call mom", "Buy stamps" }) |title| {
        try typeText(&app, title);
        _ = try app.command(.submit, false);
    }
    try testing.expectEqual(@as(usize, 3), app.visible.items.len);
    try testing.expectEqual(@as(usize, 0), app.add_field.len);

    _ = try app.command(.focus_search, false);
    try typeText(&app, "buy");
    try testing.expectEqual(@as(usize, 2), app.visible.items.len);
    try typeText(&app, " st");
    try testing.expectEqual(@as(usize, 1), app.visible.items.len);
    try testing.expectEqualStrings("Buy stamps", app.visibleTask(0).title);
    _ = try app.command(.word_backspace, false);
    _ = try app.command(.word_backspace, false);
    try testing.expectEqual(@as(usize, 3), app.visible.items.len);
}

test "filters and the list keep a visible selection" {
    var app: App = .init(testing.allocator);
    defer app.deinit();
    _ = try app.import("- [ ] one\n- [x] two\n- [ ] three\n");
    _ = try app.command(.next_focus, false);
    _ = try app.command(.next_focus, false);
    try testing.expectEqual(Focus.list, app.focus);
    try testing.expectEqualStrings("one", app.tasks.get(app.selected.?).?.title);
    _ = try app.command(.down, false);
    _ = try app.command(.toggle, false);
    try testing.expect(!app.tasks.items.items[1].done);
    _ = try app.command(.filter_done, false);
    try testing.expectEqual(@as(usize, 0), app.visible.items.len);
    try testing.expectEqual(@as(?u32, null), app.selected);
    _ = try app.command(.filter_active, false);
    try testing.expectEqual(@as(usize, 3), app.visible.items.len);
    _ = try app.command(.end, false);
    _ = try app.command(.delete, false);
    try testing.expectEqualStrings("two", app.tasks.get(app.selected.?).?.title);
    try testing.expect(app.dirty);
}

test "renaming commits on Enter and focus changes, and Escape cancels" {
    var app: App = .init(testing.allocator);
    defer app.deinit();
    _ = try app.import("draft");
    const id = app.tasks.items.items[0].id;
    try app.startEdit(id);
    _ = try app.command(.select_all, false);
    try typeText(&app, "final");
    _ = try app.command(.cancel, false);
    try testing.expectEqualStrings("draft", app.tasks.get(id).?.title);
    try testing.expectEqual(Focus.list, app.focus);

    try app.startEdit(id);
    try typeText(&app, " v2");
    _ = try app.command(.submit, false);
    try testing.expectEqualStrings("draft v2", app.tasks.get(id).?.title);

    try app.startEdit(id);
    _ = try app.command(.home, false);
    try typeText(&app, "new ");
    try app.focusOn(.add);
    try testing.expectEqualStrings("new draft v2", app.tasks.get(id).?.title);
    try testing.expectEqual(@as(?u32, null), app.editing);

    // A filter that hides the task still keeps the edit.
    try app.startEdit(id);
    try typeText(&app, "!");
    _ = try app.command(.filter_done, false);
    try testing.expectEqualStrings("new draft v2!", app.tasks.get(id).?.title);
    try testing.expectEqual(@as(?u32, null), app.editing);
    try testing.expectEqual(Focus.list, app.focus);
}

test "cut returns the selection for the clipboard" {
    var app: App = .init(testing.allocator);
    defer app.deinit();
    try typeText(&app, "copy me");
    try testing.expectEqual(@as(?[]const u8, null), try app.command(.copy, false));
    _ = try app.command(.word_left, true);
    try testing.expectEqualStrings("me", (try app.command(.copy, false)).?);
    try testing.expectEqualStrings("me", (try app.command(.cut, false)).?);
    try testing.expectEqualStrings("copy ", app.add_field.text());
}

test "composition text clears when the input method commits" {
    var app: App = .init(testing.allocator);
    defer app.deinit();
    app.setComposition("とう");
    try testing.expectEqualStrings("とう", app.add_field.composition());
    try typeText(&app, "東");
    try testing.expectEqualStrings("", app.add_field.composition());
    try testing.expectEqualStrings("東", app.add_field.text());
}

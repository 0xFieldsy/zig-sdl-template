//! The demo's window, event, drawing, text, image, clipboard, and file helpers on top of SDL3,
//! SDL_ttf, and SDL_image. Native APIs remain available as `sdl` for features these helpers omit.
//!
//! Positions and sizes are logical units: render pixels divided by the window's display scale.
//! The UI keeps its physical size on high-DPI displays, and fonts and icons are rasterized at the
//! full resolution.
const std = @import("std");
const builtin = @import("builtin");

const assets = @import("assets");
pub const sdl = @import("sdl");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h;
    }

    pub fn inset(r: Rect, dx: f32, dy: f32) Rect {
        return .{
            .x = r.x + dx,
            .y = r.y + dy,
            .w = @max(0, r.w - 2 * dx),
            .h = @max(0, r.h - 2 * dy),
        };
    }
};

// FreeType encodes a variable font's named instance in the upper 16 bits of the face index.
// Instance 6 is SemiBold (600) in the pinned Inter font; face 0 uses its default Regular (400) weight.
pub const Font = enum { title, body, small, strong };
const font_specs = std.enums.EnumArray(Font, struct { size: f32, face_index: i64 = 0 }).init(.{
    .title = .{ .size = 26, .face_index = 6 << 16 },
    .body = .{ .size = 16 },
    .small = .{ .size = 13 },
    .strong = .{ .size = 13, .face_index = 6 << 16 },
});

pub const Icon = enum { search, plus, box, box_checked, check, delete, empty };
const icon_specs = std.enums.EnumArray(Icon, struct { data: []const u8, size: f32 }).init(.{
    .search = .{ .data = assets.search, .size = 20 },
    .plus = .{ .data = assets.plus, .size = 20 },
    .box = .{ .data = assets.box, .size = 22 },
    .box_checked = .{ .data = assets.box_checked, .size = 22 },
    .check = .{ .data = assets.check, .size = 22 },
    .delete = .{ .data = assets.delete, .size = 18 },
    .empty = .{ .data = assets.empty, .size = 96 },
});

pub const Cursor = enum { default, text, pointer };
var window: ?*sdl.SDL_Window = null;
var renderer: ?*sdl.SDL_Renderer = null;
var engine: ?*sdl.TTF_TextEngine = null;
var fonts: std.enums.EnumArray(Font, ?*sdl.TTF_Font) = .initFill(null);
var icons: std.enums.EnumArray(Icon, ?*sdl.SDL_Texture) = .initFill(null);
var cursors: std.enums.EnumArray(Cursor, ?*sdl.SDL_Cursor) = .initFill(null);
var current_cursor: Cursor = .default;
var scale: f32 = 1;
var input_area: sdl.SDL_Rect = .{};
var input_cursor: c_int = 0;
var dialog_event: u32 = 0;

pub const FileDialogKind = enum { open, save };
const dialog_kinds = [_]FileDialogKind{ .open, .save };
const dialog_filters = [_]sdl.SDL_DialogFileFilter{
    .{ .name = "Markdown and text", .pattern = "md;txt;markdown" },
    .{ .name = "All files", .pattern = "*" },
};

pub const FileDialogResult = struct {
    kind: FileDialogKind,
    path: ?[:0]u8,
    failure: ?[:0]u8,

    pub fn deinit(result: FileDialogResult) void {
        if (result.path) |path| free(path);
        if (result.failure) |failure| free(failure);
    }
};

fn check(ok: bool) void {
    if (!ok) std.debug.panic("SDL: {s}", .{sdl.SDL_GetError()});
}

fn constIo(data: []const u8) *sdl.SDL_IOStream {
    return sdl.SDL_IOFromConstMem(data.ptr, data.len) orelse std.debug.panic("SDL: {s}", .{sdl.SDL_GetError()});
}

/// Opens a resizable window of the given logical size.
pub fn init(title: [:0]const u8, width: f32, height: f32, min_width: f32, min_height: f32) void {
    sdl.SDL_SetMainReady();

    // The UI draws input method composition text itself.
    _ = sdl.SDL_SetHint(sdl.SDL_HINT_IME_IMPLEMENTED_UI, "composition");
    check(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    dialog_event = sdl.SDL_RegisterEvents(1);
    check(dialog_event != 0);
    check(sdl.TTF_Init());

    // Size the window for the primary display's scale before it exists;
    // later scale changes arrive as events.
    const initial = @max(sdl.SDL_GetDisplayContentScale(sdl.SDL_GetPrimaryDisplay()), 1);

    // Renderer setup can recreate the native window. Publish it only once the renderer is ready,
    // so startup tools can't find a temporary X11 window ID.
    window = sdl.SDL_CreateWindow(
        title,
        @intFromFloat(width * initial),
        @intFromFloat(height * initial),
        sdl.SDL_WINDOW_HIDDEN | sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse std.debug.panic("SDL window: {s}", .{sdl.SDL_GetError()});
    renderer = sdl.SDL_CreateRenderer(window, null) orelse std.debug.panic(
        "SDL renderer: {s}",
        .{sdl.SDL_GetError()},
    );
    check(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BLENDMODE_BLEND));

    // VSync is optional; the event-driven loop only redraws after input.
    _ = sdl.SDL_SetRenderVSync(renderer, 1);
    engine = sdl.TTF_CreateRendererTextEngine(renderer) orelse std.debug.panic(
        "SDL_ttf: {s}",
        .{sdl.SDL_GetError()},
    );

    for (std.enums.values(Font)) |font| {
        const spec = font_specs.get(font);
        const props = sdl.SDL_CreateProperties();
        check(props != 0);
        defer sdl.SDL_DestroyProperties(props);
        check(
            sdl.SDL_SetPointerProperty(props, sdl.TTF_PROP_FONT_CREATE_IOSTREAM_POINTER, constIo(assets.font)),
        );
        check(
            sdl.SDL_SetBooleanProperty(props, sdl.TTF_PROP_FONT_CREATE_IOSTREAM_AUTOCLOSE_BOOLEAN, true),
        );
        check(
            sdl.SDL_SetFloatProperty(props, sdl.TTF_PROP_FONT_CREATE_SIZE_FLOAT, spec.size),
        );
        check(
            sdl.SDL_SetNumberProperty(props, sdl.TTF_PROP_FONT_CREATE_FACE_NUMBER, spec.face_index),
        );
        fonts.set(
            font,
            sdl.TTF_OpenFontWithProperties(props) orelse std.debug.panic("SDL_ttf: {s}", .{sdl.SDL_GetError()}),
        );
    }

    cursors.set(.default, sdl.SDL_CreateSystemCursor(sdl.SDL_SYSTEM_CURSOR_DEFAULT));
    cursors.set(.text, sdl.SDL_CreateSystemCursor(sdl.SDL_SYSTEM_CURSOR_TEXT));
    cursors.set(.pointer, sdl.SDL_CreateSystemCursor(sdl.SDL_SYSTEM_CURSOR_POINTER));

    if (sdl.IMG_LoadSizedSVG_IO(constIo(assets.icon), 64, 64)) |surface| {
        _ = sdl.SDL_SetWindowIcon(window, surface);
        sdl.SDL_DestroySurface(surface);
    }

    updateScale();
    check(
        sdl.SDL_SetWindowMinimumSize(window, @intFromFloat(min_width * scale), @intFromFloat(min_height * scale)),
    );
    check(
        sdl.SDL_ShowWindow(window),
    );

    std.log.info("PLATFORM: SDL {d}.{d}.{d}, SDL_ttf {d}.{d}.{d}, SDL_image {d}.{d}.{d}, scale {d}", .{
        sdl.SDL_MAJOR_VERSION,       sdl.SDL_MINOR_VERSION,       sdl.SDL_MICRO_VERSION,
        sdl.SDL_TTF_MAJOR_VERSION,   sdl.SDL_TTF_MINOR_VERSION,   sdl.SDL_TTF_MICRO_VERSION,
        sdl.SDL_IMAGE_MAJOR_VERSION, sdl.SDL_IMAGE_MINOR_VERSION, sdl.SDL_IMAGE_MICRO_VERSION,
        scale,
    });
}

pub fn deinit() void {
    // Release any dialog result queued just before shutdown.
    var event: sdl.SDL_Event = undefined;

    while (sdl.SDL_PeepEvents(&event, 1, sdl.SDL_GETEVENT, dialog_event, dialog_event) > 0) {
        if (fileDialogResult(event)) |result| result.deinit();
    }

    _ = sdl.SDL_StopTextInput(window);

    for (&icons.values) |*icon| if (icon.*) |t| {
        sdl.SDL_DestroyTexture(t);
        icon.* = null;
    };
    for (&fonts.values) |*font| if (font.*) |f| {
        sdl.TTF_CloseFont(f);
        font.* = null;
    };
    for (&cursors.values) |*cursor| if (cursor.*) |c| {
        sdl.SDL_DestroyCursor(c);
        cursor.* = null;
    };

    sdl.TTF_DestroyRendererTextEngine(engine);
    sdl.SDL_DestroyRenderer(renderer);
    sdl.SDL_DestroyWindow(window);
    engine = null;
    renderer = null;
    window = null;

    sdl.TTF_Quit();
    sdl.SDL_Quit();
}

/// Resizes fonts and rerasterizes icons for the window's display scale.
fn updateScale() void {
    const new_scale = sdl.SDL_GetWindowDisplayScale(window);
    if (new_scale <= 0) return;
    scale = new_scale;

    for (std.enums.values(Font)) |font| check(
        sdl.TTF_SetFontSize(fonts.get(font), font_specs.get(font).size * scale),
    );
    for (std.enums.values(Icon)) |icon| {
        if (icons.get(icon)) |t| sdl.SDL_DestroyTexture(t);
        const px: c_int = @intFromFloat(@round(icon_specs.get(icon).size * scale));
        const surface = sdl.IMG_LoadSizedSVG_IO(constIo(icon_specs.get(icon).data), px, px) orelse std.debug.panic(
            "SDL_image: {s}",
            .{sdl.SDL_GetError()},
        );
        defer sdl.SDL_DestroySurface(surface);
        icons.set(
            icon,
            sdl.SDL_CreateTextureFromSurface(renderer, surface) orelse std.debug.panic("SDL: {s}", .{sdl.SDL_GetError()}),
        );
    }
}

/// Waits for the next event, up to `timeout_ms` when given. Display scale
/// changes are applied before the event is returned.
pub fn waitEvent(timeout_ms: ?i32) ?sdl.SDL_Event {
    var event: sdl.SDL_Event = undefined;
    const got = if (timeout_ms) |ms| sdl.SDL_WaitEventTimeout(&event, ms) else sdl.SDL_WaitEvent(&event);
    return if (got) filtered(event) else null;
}

/// Returns the next pending event without waiting.
pub fn pollEvent() ?sdl.SDL_Event {
    var event: sdl.SDL_Event = undefined;
    return if (sdl.SDL_PollEvent(&event)) filtered(event) else null;
}

fn filtered(event: sdl.SDL_Event) sdl.SDL_Event {
    if (event.type == sdl.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED) updateScale();
    return event;
}

/// Converts mouse event window coordinates to logical units.
pub fn toLogical(x: f32, y: f32) Point {
    const density = sdl.SDL_GetWindowPixelDensity(window);
    return .{ .x = x * density / scale, .y = y * density / scale };
}

pub fn size() Point {
    var w: c_int = 0;
    var h: c_int = 0;
    check(sdl.SDL_GetRenderOutputSize(renderer, &w, &h));
    return .{ .x = @as(f32, @floatFromInt(w)) / scale, .y = @as(f32, @floatFromInt(h)) / scale };
}

pub fn getTicks() u64 {
    return sdl.SDL_GetTicks();
}

pub fn setCursor(cursor: Cursor) void {
    if (cursor == current_cursor) return;
    current_cursor = cursor;
    if (cursors.get(cursor)) |c| _ = sdl.SDL_SetCursor(c);
}

pub fn modState() sdl.SDL_Keymod {
    return sdl.SDL_GetModState();
}

/// Primary shortcut modifier: Command on macOS, Control elsewhere.
pub fn primaryMod(mod: sdl.SDL_Keymod) bool {
    return mod & @as(
        sdl.SDL_Keymod,
        if (builtin.os.tag == .macos) sdl.SDL_KMOD_GUI else sdl.SDL_KMOD_CTRL,
    ) != 0;
}

/// Word-movement modifier: Option on macOS, Control elsewhere.
pub fn wordMod(mod: sdl.SDL_Keymod) bool {
    return mod & @as(
        sdl.SDL_Keymod,
        if (builtin.os.tag == .macos) sdl.SDL_KMOD_ALT else sdl.SDL_KMOD_CTRL,
    ) != 0;
}

/// Enables text input events and tells the input method where the text field and its cursor are,
/// so candidate windows appear beside them.
pub fn startTextInput(area: Rect, cursor_x: f32) void {
    const density = sdl.SDL_GetWindowPixelDensity(window);
    const to_window = scale / density;
    const rect: sdl.SDL_Rect = .{
        .x = @intFromFloat(area.x * to_window),
        .y = @intFromFloat(area.y * to_window),
        .w = @intFromFloat(area.w * to_window),
        .h = @intFromFloat(area.h * to_window),
    };
    const cursor: c_int = @intFromFloat(cursor_x * to_window);

    // Some input method backends do work for each update, so skip repeats.
    if (!sdl.SDL_TextInputActive(window) or !std.meta.eql(rect, input_area) or cursor != input_cursor) {
        _ = sdl.SDL_SetTextInputArea(window, &rect, cursor);
        input_area = rect;
        input_cursor = cursor;
    }
    if (!sdl.SDL_TextInputActive(window)) _ = sdl.SDL_StartTextInput(window);
}

pub fn stopTextInput() void {
    if (sdl.SDL_TextInputActive(window)) _ = sdl.SDL_StopTextInput(window);
}

pub fn setClipboard(gpa: std.mem.Allocator, text: []const u8) !void {
    const z = try gpa.dupeZ(u8, text);
    defer gpa.free(z);
    if (!sdl.SDL_SetClipboardText(z)) std.log.err("CLIPBOARD: {s}", .{sdl.SDL_GetError()});
}

/// Returns clipboard text; release it with `free`.
pub fn getClipboard() ?[:0]u8 {
    const text: [*:0]u8 = sdl.SDL_GetClipboardText() orelse return null;
    return std.mem.span(text);
}

/// Opens a native asynchronous dialog. Results arrive through the event
/// queue, so callbacks never touch the application's allocator or state.
pub fn showFileDialog(kind: FileDialogKind) void {
    const userdata = @constCast(&dialog_kinds[@intFromEnum(kind)]);
    switch (kind) {
        .open => sdl.SDL_ShowOpenFileDialog(
            dialogCallback,
            userdata,
            window,
            &dialog_filters,
            dialog_filters.len,
            null,
            false,
        ),
        .save => sdl.SDL_ShowSaveFileDialog(
            dialogCallback,
            userdata,
            window,
            &dialog_filters,
            dialog_filters.len,
            "tasks.md",
        ),
    }
}

fn dialogCallback(
    userdata: ?*anyopaque,
    files: [*c]const [*c]const u8,
    _: c_int,
) callconv(.c) void {
    const kind: *const FileDialogKind = @ptrCast(@alignCast(userdata.?));
    var event: sdl.SDL_Event = .{
        .user = .{ .type = dialog_event, .code = @intFromEnum(kind.*) },
    };

    if (files == null) {
        event.user.data2 = sdl.SDL_strdup(sdl.SDL_GetError());
    } else if (files[0] != null and files[0][0] != 0) {
        event.user.data1 = sdl.SDL_strdup(files[0]);
        if (event.user.data1 == null) event.user.data2 = sdl.SDL_strdup(
            "Not enough memory for the selected path.",
        );
    }
    if (!sdl.SDL_PushEvent(&event)) {
        sdl.SDL_free(event.user.data1);
        sdl.SDL_free(event.user.data2);
        sdl.SDL_Log("Could not queue file dialog result: %s", sdl.SDL_GetError());
    }
}

/// The caller owns this result and must call `deinit`, including on cancel.
pub fn fileDialogResult(event: sdl.SDL_Event) ?FileDialogResult {
    if (event.type != dialog_event) return null;
    return .{
        .kind = @enumFromInt(event.user.code),
        .path = if (event.user.data1) |ptr| std.mem.span(@as([*:0]u8, @ptrCast(ptr))) else null,
        .failure = if (event.user.data2) |ptr| std.mem.span(@as([*:0]u8, @ptrCast(ptr))) else null,
    };
}

pub fn showError(title: [:0]const u8, message: [*:0]const u8) void {
    _ = sdl.SDL_ShowSimpleMessageBox(sdl.SDL_MESSAGEBOX_ERROR, title, message, window);
}

/// Releases memory SDL allocated for clipboard text or file contents.
pub fn free(memory: []u8) void {
    sdl.SDL_free(memory.ptr);
}

/// Returns the path of `file` in the per-user data directory, which SDL creates if needed.
pub fn prefPath(
    gpa: std.mem.Allocator,
    org: [:0]const u8,
    app: [:0]const u8,
    file: []const u8,
) ![:0]u8 {
    const dir: [*:0]u8 = sdl.SDL_GetPrefPath(org, app) orelse return error.NoPrefPath;
    defer sdl.SDL_free(dir);
    return std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ std.mem.span(dir), file }, 0);
}

/// Reads a whole file; release it with `free`. Returns null if it can't be read.
pub fn loadFile(path: [:0]const u8) ?[]u8 {
    var len: usize = 0;
    const data: [*]u8 = @ptrCast(sdl.SDL_LoadFile(path, &len) orelse return null);
    return data[0..len];
}

/// Writes a file through a temporary file, so a failed save keeps the previous contents.
pub fn saveFile(gpa: std.mem.Allocator, path: [:0]const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrintSentinel(gpa, "{s}.tmp", .{path}, 0);
    defer gpa.free(tmp);
    if (!sdl.SDL_SaveFile(tmp, data.ptr, data.len) or !sdl.SDL_RenamePath(tmp, path)) {
        std.log.err("SAVE: {s}: {s}", .{ path, sdl.SDL_GetError() });
        return error.SaveFailed;
    }
}

pub fn clear(color: Color) void {
    tint(color);
    check(sdl.SDL_RenderClear(renderer));
}

pub fn present() void {
    check(sdl.SDL_RenderPresent(renderer));
}

fn tint(color: Color) void {
    check(sdl.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a));
}

fn physical(r: Rect) sdl.SDL_FRect {
    return .{
        .x = @round(r.x * scale),
        .y = @round(r.y * scale),
        .w = @round(r.w * scale),
        .h = @round(r.h * scale),
    };
}

pub fn fillRect(r: Rect, color: Color) void {
    tint(color);
    const area = physical(r);
    check(sdl.SDL_RenderFillRect(renderer, &area));
}

/// Draws a border one logical unit wide inside `r`.
pub fn strokeRect(r: Rect, color: Color) void {
    fillRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, color);
    fillRect(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, color);
    fillRect(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, color);
    fillRect(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, color);
}

/// Restricts drawing to `r`, or removes the restriction.
pub fn clip(r: ?Rect) void {
    if (r) |area| {
        const p = physical(area);
        const rect: sdl.SDL_Rect = .{
            .x = @intFromFloat(p.x),
            .y = @intFromFloat(p.y),
            .w = @intFromFloat(p.w),
            .h = @intFromFloat(p.h),
        };
        check(sdl.SDL_SetRenderClipRect(renderer, &rect));
    } else check(sdl.SDL_SetRenderClipRect(renderer, null));
}

pub fn drawIcon(icon: Icon, x: f32, y: f32, color: Color) void {
    const texture = icons.get(icon) orelse return;
    const s = icon_specs.get(icon).size;
    check(sdl.SDL_SetTextureColorMod(texture, color.r, color.g, color.b));
    check(sdl.SDL_SetTextureAlphaMod(texture, color.a));
    const dst = physical(.{ .x = x, .y = y, .w = s, .h = s });
    check(sdl.SDL_RenderTexture(renderer, texture, null, &dst));
}

pub fn iconSize(icon: Icon) f32 {
    return icon_specs.get(icon).size;
}

pub fn lineHeight(font: Font) f32 {
    return @as(f32, @floatFromInt(sdl.TTF_GetFontHeight(fonts.get(font)))) / scale;
}

/// Draws a single line of text with its top-left corner at `x`, `y`.
pub fn drawText(font: Font, text: []const u8, x: f32, y: f32, color: Color) void {
    if (text.len == 0) return;
    const t = sdl.TTF_CreateText(engine, fonts.get(font), text.ptr, text.len) orelse return;
    defer sdl.TTF_DestroyText(t);
    check(sdl.TTF_SetTextColor(t, color.r, color.g, color.b, color.a));
    check(sdl.TTF_DrawRendererText(t, @round(x * scale), @round(y * scale)));
}

pub fn textWidth(font: Font, text: []const u8) f32 {
    if (text.len == 0) return 0;
    var w: c_int = 0;
    check(sdl.TTF_GetStringSize(fonts.get(font), text.ptr, text.len, &w, null));
    return @as(f32, @floatFromInt(w)) / scale;
}

/// Returns how many bytes of `text` fit in `max_width`.
pub fn fitText(font: Font, text: []const u8, max_width: f32) usize {
    if (text.len == 0) return 0;
    var fit: usize = 0;
    check(
        sdl.TTF_MeasureString(
            fonts.get(font),
            text.ptr,
            text.len,
            @intFromFloat(@max(1, max_width * scale)),
            null,
            &fit,
        ),
    );
    return fit;
}

/// Returns the byte offset of the character boundary nearest `x`, measured from the start of the text,
/// for placing a cursor with the mouse.
pub fn hitText(font: Font, text: []const u8, x: f32) usize {
    if (text.len == 0) return 0;
    const t = sdl.TTF_CreateText(engine, fonts.get(font), text.ptr, text.len) orelse return 0;
    defer sdl.TTF_DestroyText(t);

    const px: c_int = @intFromFloat(x * scale);
    var sub: sdl.TTF_SubString = undefined;
    if (!sdl.TTF_GetTextSubStringForPoint(t, px, 0, &sub)) return 0;
    const offset: usize = @intCast(sub.offset);

    // Past the middle of a character, the cursor goes after it.
    return if (px * 2 >= sub.rect.x * 2 + sub.rect.w) offset + @as(usize, @intCast(sub.length)) else offset;
}

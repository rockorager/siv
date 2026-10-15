//! siv-webview for Zig: the C API (include/siv-webview.h) with siv's Zig
//! types, and idiomatic wrappers in the style of siv's generated module:
//! slices for strings, errors for results, methods on the handle.
//!
//!     const siv = @import("siv");
//!     const webview = @import("siv_webview");
//!
//!     const wv = try webview.create(window, .{ .on_event = onEvent });
//!     const page = wv.view(txn, root);
//!     try wv.loadUri("https://example.com");
//!
//! Build it with the `siv` module (share/siv/siv.zig of an installed siv)
//! as its import and link libsiv-webview.

const std = @import("std");
const siv = @import("siv");

pub const Error = siv.Error;
const check = siv.check;

pub const Engine = enum(i32) { auto = 0, wpe = 1, _ };

pub const Flags = packed struct(u32) {
    /// Keep nothing on disk (a private window).
    ephemeral: bool = false,
    /// Inspect Element and the remote inspector (Desc.inspector_port).
    developer_extras: bool = false,
    /// Do not pass the window's theme on as prefers-color-scheme.
    no_theme: bool = false,
    /// Do not show the engine's context menu.
    no_context_menu: bool = false,
    _bit4: u28 = 0,
};

pub const EventType = enum(i32) {
    load = 0,
    progress = 1,
    title = 2,
    uri = 3,
    history = 4,
    message = 5,
    navigate = 6,
    new_window = 7,
    permission = 8,
    download = 9,
    notification = 10,
    close = 11,
    crashed = 12,
    load_failed = 13,
    _,
};

pub const LoadState = enum(i32) { started = 0, redirected = 1, committed = 2, finished = 3, _ };
pub const Permission = enum(i32) { other = 0, geolocation = 1, notifications = 2, media = 3, clipboard = 4, pointer_lock = 5, _ };
pub const DownloadPhase = enum(i32) { started = 0, progress = 1, finished = 2, failed = 3, _ };

pub const EventFlags = packed struct(u32) {
    main_frame: bool = false,
    user_gesture: bool = false,
    redirect: bool = false,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    loading: bool = false,
    _bit6: u26 = 0,
};

/// A web view's event (siv_webview_event); strings live during the call.
pub const Event = extern struct {
    size: usize = @sizeOf(Event),
    type: EventType,
    load_state: LoadState,
    flags: EventFlags,
    permission: Permission,
    download_phase: DownloadPhase,
    reserved0: u32 = 0,
    uri_ptr: ?[*]const u8,
    uri_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
    name_ptr: ?[*]const u8,
    name_len: usize,
    path_ptr: ?[*]const u8,
    path_len: usize,
    progress: f64,
    id: u64,

    fn slice(p: ?[*]const u8, len: usize) []const u8 {
        return if (p) |q| q[0..len] else "";
    }
    pub fn uri(e: *const Event) []const u8 {
        return slice(e.uri_ptr, e.uri_len);
    }
    pub fn text(e: *const Event) []const u8 {
        return slice(e.text_ptr, e.text_len);
    }
    pub fn name(e: *const Event) []const u8 {
        return slice(e.name_ptr, e.name_len);
    }
    pub fn path(e: *const Event) []const u8 {
        return slice(e.path_ptr, e.path_len);
    }
};

pub const EventFn = *const fn (user_data: ?*anyopaque, webview: Webview, event: *const Event) callconv(.c) bool;
pub const ScriptFn = *const fn (user_data: ?*anyopaque, result: siv.Result, json: ?[*]const u8, json_len: usize) callconv(.c) void;
pub const SchemeFn = *const fn (user_data: ?*anyopaque, request: Request, uri: [*]const u8, uri_len: usize, method: [*]const u8, method_len: usize) callconv(.c) void;

/// siv_webview_desc.
pub const Desc = extern struct {
    size: usize = @sizeOf(Desc),
    user_data: ?*anyopaque = null,
    on_event: ?EventFn = null,
    destroy: ?siv.DestroyFn = null,
    flags: Flags = .{},
    engine: Engine = .auto,
    data_dir: ?[*]const u8 = null,
    data_dir_len: usize = 0,
    cache_dir: ?[*]const u8 = null,
    cache_dir_len: usize = 0,
    user_agent: ?[*]const u8 = null,
    user_agent_len: usize = 0,
    zoom: f64 = 0,
    inspector_port: u16 = 0,
    background: siv.Color = .{},

    /// Desc with slices.
    pub const Options = struct {
        user_data: ?*anyopaque = null,
        on_event: ?EventFn = null,
        destroy: ?siv.DestroyFn = null,
        flags: Flags = .{},
        engine: Engine = .auto,
        data_dir: []const u8 = "",
        cache_dir: []const u8 = "",
        user_agent: []const u8 = "",
        zoom: f64 = 0,
        inspector_port: u16 = 0,
        background: siv.Color = .{},
    };

    pub fn fromOptions(o: Options) Desc {
        return .{
            .user_data = o.user_data,
            .on_event = o.on_event,
            .destroy = o.destroy,
            .flags = o.flags,
            .engine = o.engine,
            .data_dir = o.data_dir.ptr,
            .data_dir_len = o.data_dir.len,
            .cache_dir = o.cache_dir.ptr,
            .cache_dir_len = o.cache_dir.len,
            .user_agent = o.user_agent.ptr,
            .user_agent_len = o.user_agent.len,
            .zoom = o.zoom,
            .inspector_port = o.inspector_port,
            .background = o.background,
        };
    }
};

/// siv_webview_state.
pub const State = extern struct {
    size: usize = @sizeOf(State),
    flags: EventFlags = .{},
    reserved0: u32 = 0,
    progress: f64 = 0,
    zoom: f64 = 0,
};

/// The C functions.
pub const c = struct {
    pub extern fn siv_webview_version() u32;
    pub extern fn siv_webview_engine_available(engine: Engine) siv.Result;
    pub extern fn siv_webview_create(window: siv.Window, desc: ?*const Desc, webview: *Webview) siv.Result;
    pub extern fn siv_webview_destroy(webview: Webview) void;
    pub extern fn siv_webview_view(txn: siv.Txn, parent: siv.Node, webview: Webview) siv.Node;
    pub extern fn siv_webview_get_node(webview: Webview) siv.Node;
    pub extern fn siv_webview_load_uri(webview: Webview, uri: [*]const u8, len: usize) siv.Result;
    pub extern fn siv_webview_load_html(webview: Webview, html: [*]const u8, len: usize, base: ?[*]const u8, base_len: usize) siv.Result;
    pub extern fn siv_webview_go_back(webview: Webview) siv.Result;
    pub extern fn siv_webview_go_forward(webview: Webview) siv.Result;
    pub extern fn siv_webview_reload(webview: Webview) siv.Result;
    pub extern fn siv_webview_stop(webview: Webview) siv.Result;
    pub extern fn siv_webview_get_uri(webview: Webview, text: ?[*]u8, cap: usize, len: *usize) siv.Result;
    pub extern fn siv_webview_get_title(webview: Webview, text: ?[*]u8, cap: usize, len: *usize) siv.Result;
    pub extern fn siv_webview_get_state(webview: Webview, state: *State) siv.Result;
    pub extern fn siv_webview_set_zoom(webview: Webview, zoom: f64) siv.Result;
    pub extern fn siv_webview_set_color_scheme(webview: Webview, scheme: siv.ColorScheme) siv.Result;
    pub extern fn siv_webview_run_script(webview: Webview, script: [*]const u8, len: usize, callback: ?ScriptFn, destroy: ?siv.DestroyFn, user_data: ?*anyopaque) siv.Result;
    pub extern fn siv_webview_add_message_handler(webview: Webview, name: [*]const u8, len: usize) siv.Result;
    pub extern fn siv_webview_post_message(webview: Webview, json: [*]const u8, len: usize) siv.Result;
    pub extern fn siv_webview_register_scheme(app: siv.App, scheme: [*]const u8, len: usize, callback: SchemeFn, destroy: ?siv.DestroyFn, user_data: ?*anyopaque) siv.Result;
    pub extern fn siv_webview_request_finish(request: Request, status: u32, content_type: [*]const u8, content_type_len: usize, data: [*]const u8, len: usize) siv.Result;
    pub extern fn siv_webview_request_fail(request: Request) siv.Result;
    pub extern fn siv_webview_permission_reply(webview: Webview, id: u64, allow: bool) siv.Result;
    pub extern fn siv_webview_download_cancel(webview: Webview, id: u64) siv.Result;
};

pub fn version() std.SemanticVersion {
    const v = c.siv_webview_version();
    return .{ .major = v >> 16, .minor = (v >> 8) & 0xff, .patch = v & 0xff };
}

pub fn engineAvailable(engine: Engine) bool {
    return c.siv_webview_engine_available(engine) == .ok;
}

pub fn create(window: siv.Window, options: Desc.Options) Error!Webview {
    const desc = Desc.fromOptions(options);
    var wv: Webview = .null;
    try check(c.siv_webview_create(window, &desc, &wv));
    return wv;
}

/// Serves URLs of `scheme` for every web view of the application.
pub fn registerScheme(app: siv.App, scheme: []const u8, callback: SchemeFn, destroy: ?siv.DestroyFn, user_data: ?*anyopaque) Error!void {
    try check(c.siv_webview_register_scheme(app, scheme.ptr, scheme.len, callback, destroy, user_data));
}

/// A request for a URL of a registered scheme.
pub const Request = enum(u64) {
    null = 0,
    _,

    pub fn finish(r: Request, status: u32, content_type: []const u8, body: []const u8) Error!void {
        try check(c.siv_webview_request_finish(r, status, content_type.ptr, content_type.len, body.ptr, body.len));
    }
    pub fn fail(r: Request) Error!void {
        try check(c.siv_webview_request_fail(r));
    }
};

/// A web view (siv_webview).
pub const Webview = enum(u64) {
    null = 0,
    _,

    pub fn destroy(wv: Webview) void {
        c.siv_webview_destroy(wv);
    }
    /// The node showing the page, created in `txn` under `parent`; .null
    /// if the transaction failed.
    pub fn view(wv: Webview, txn: siv.Txn, parent: siv.Node) siv.Node {
        return c.siv_webview_view(txn, parent, wv);
    }
    pub fn node(wv: Webview) siv.Node {
        return c.siv_webview_get_node(wv);
    }
    pub fn loadUri(wv: Webview, url: []const u8) Error!void {
        try check(c.siv_webview_load_uri(wv, url.ptr, url.len));
    }
    pub fn loadHtml(wv: Webview, html: []const u8, base_uri: []const u8) Error!void {
        try check(c.siv_webview_load_html(wv, html.ptr, html.len, base_uri.ptr, base_uri.len));
    }
    /// error.Busy with nowhere to go.
    pub fn goBack(wv: Webview) Error!void {
        try check(c.siv_webview_go_back(wv));
    }
    pub fn goForward(wv: Webview) Error!void {
        try check(c.siv_webview_go_forward(wv));
    }
    pub fn reload(wv: Webview) Error!void {
        try check(c.siv_webview_reload(wv));
    }
    pub fn stop(wv: Webview) Error!void {
        try check(c.siv_webview_stop(wv));
    }
    /// The page's URL, cut to `buf`.
    pub fn uri(wv: Webview, buf: []u8) Error![]u8 {
        var len: usize = 0;
        try check(c.siv_webview_get_uri(wv, buf.ptr, buf.len, &len));
        return buf[0..@min(len, buf.len)];
    }
    /// The page's title, cut to `buf`.
    pub fn title(wv: Webview, buf: []u8) Error![]u8 {
        var len: usize = 0;
        try check(c.siv_webview_get_title(wv, buf.ptr, buf.len, &len));
        return buf[0..@min(len, buf.len)];
    }
    pub fn state(wv: Webview) Error!State {
        var st: State = .{};
        try check(c.siv_webview_get_state(wv, &st));
        return st;
    }
    pub fn setZoom(wv: Webview, zoom: f64) Error!void {
        try check(c.siv_webview_set_zoom(wv, zoom));
    }
    pub fn setColorScheme(wv: Webview, scheme: siv.ColorScheme) Error!void {
        try check(c.siv_webview_set_color_scheme(wv, scheme));
    }
    pub fn runScript(wv: Webview, script: []const u8, callback: ?ScriptFn, destroy_fn: ?siv.DestroyFn, user_data: ?*anyopaque) Error!void {
        try check(c.siv_webview_run_script(wv, script.ptr, script.len, callback, destroy_fn, user_data));
    }
    pub fn addMessageHandler(wv: Webview, name: []const u8) Error!void {
        try check(c.siv_webview_add_message_handler(wv, name.ptr, name.len));
    }
    /// error.InvalidArgument if `json` is not JSON.
    pub fn postMessage(wv: Webview, json: []const u8) Error!void {
        try check(c.siv_webview_post_message(wv, json.ptr, json.len));
    }
    pub fn permissionReply(wv: Webview, id: u64, allow: bool) Error!void {
        try check(c.siv_webview_permission_reply(wv, id, allow));
    }
    pub fn downloadCancel(wv: Webview, id: u64) Error!void {
        try check(c.siv_webview_download_cancel(wv, id));
    }
};

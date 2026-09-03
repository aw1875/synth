const std = @import("std");
const builtin = @import("builtin");

const pkg = @import("pkg");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const Database = @import("../core/database.zig");
const Conversation = @import("../core/conversation.zig");
const Role = Conversation.Role;
const AgentLoop = @import("../agent/loop.zig");
const Subagent = @import("../agent/subagent.zig");
const mention = @import("../core/mention.zig");
const Auth = @import("../core/auth.zig");
const Config = @import("../core/config.zig");
const Project = @import("../core/project.zig");
const mcp_tools = @import("../tools/mcp.zig");
const catalog = @import("../provider/catalog.zig");
const Backend = @import("../provider/backend.zig");
const Provider = @import("../provider/provider.zig");
const Registry = @import("../tools/registry.zig");
const image = @import("../core/image.zig");
const skill = @import("../core/skill.zig");
const tool = @import("../tools/tool.zig");
const Approval = @import("approval.zig");
const AttachmentCard = @import("attachment_card.zig");
const Attachments = @import("attachments.zig");
const Connect = @import("connect.zig");
const diff = @import("diff.zig");
const Input = @import("input.zig");
const markdown = @import("markdown.zig");
const MentionPopup = @import("mention_popup.zig");
const ModelPicker = @import("model_picker.zig");
const Notification = @import("notification.zig");
const Rename = @import("rename.zig");
const Selection = @import("selection.zig");
const SessionPicker = @import("session_picker.zig");
const Slash = @import("slash.zig");
const theme = @import("theme.zig");
const ThemePicker = @import("theme_picker.zig");
const McpPicker = @import("mcp_picker.zig");
const agents = @import("../agent/agent.zig");
const themes = @import("themes.zig");
const ThoughtView = @import("thought_view.zig");
const ToolCard = @import("tool_card.zig");
const w = @import("widgets.zig");

const Model = @This();

/// Width of the right-hand sidebar, including its own left inset.
pub const sidebar_width: u16 = 48;
/// Sidebar is dropped entirely below this terminal width.
pub const sidebar_min_term_width: u16 = 80;
/// Horizontal inset of the main column's content.
pub const gutter: u16 = 2;
/// Blank rows between message blocks.
pub const block_gap: u16 = 1;
/// Blank rows above the first message when the transcript hugs the top.
pub const transcript_top: u16 = 1;
/// Rows moved per PageUp/PageDown.
/// Measured block heights kept before the lot is dropped. Well past what
/// `max_messages` can produce, so it only trips on a transcript that has been
/// paged through for a long time.
pub const max_measured_blocks: u32 = 4096;
pub const page_scroll_rows: i32 = 10;
/// Most rows the prompt box will grow to before it scrolls internally.
pub const max_input_rows: u16 = 6;
/// Cap on in-memory transcript messages. Older ones are trimmed and paged back
/// in from the database when the user scrolls to the top.
const max_transcript_messages: usize = 200;
/// How many older messages to page in per scroll-to-top.
const history_page_size: usize = 50;
/// How long a ctrl+c stays armed. Miss the window and the next ctrl+c arms it
/// again rather than quitting, so a stray keypress cannot end a running turn.
const quit_confirm_ms: i64 = 2_000;

/// A two-press confirmation that lapses on its own.
const Confirm = struct {
    window_ms: i64,
    armed_at: ?std.Io.Timestamp = null,

    pub fn arm(self: *Confirm, io: std.Io) void {
        self.armed_at = .now(io, .awake);
    }

    pub fn reset(self: *Confirm) void {
        self.armed_at = null;
    }

    /// Whether the confirming press is still expected. Clearing lapsed arming
    /// here means the caller never has to poll for the expiry.
    pub fn armed(self: *Confirm, io: std.Io) bool {
        const armed_at = self.armed_at orelse return false;
        const now: std.Io.Timestamp = .now(io, .awake);
        if (armed_at.durationTo(now).nanoseconds > self.window_ms * std.time.ns_per_ms) {
            self.armed_at = null;
            return false;
        }
        return true;
    }
};
/// Queued prompts shown under the transcript before the rest are summarised.
pub const max_steering_shown: usize = 3;

/// Prompts kept for up-arrow recall.
const max_history: usize = 200;

/// A paste this long is held back and shown as a token instead of filling the
/// prompt box with something nobody is going to read there.
const paste_minify_lines: usize = 4;
const paste_minify_bytes: usize = 400;
/// Messages loaded into memory when a session is resumed or switched. Older
/// ones page in from the database when the transcript is scrolled to the top.
pub const resume_messages: usize = 50;

/// Attachment-card slot for a message's compaction summary. Its own index, so
/// it cannot collide with a mentioned file on the same message.
pub const summary_card_key: usize = std.math.maxInt(u32);

/// Ceiling on a file read to place a diff's line numbers.
pub const max_diff_file_bytes: std.Io.Limit = .limited(4 << 20);

io: std.Io,
allocator: std.mem.Allocator,

conversation: Conversation,
provider: Provider,
input: Input,

/// Absolute path of the working directory, owned by the model.
cwd: []const u8 = "",
/// `cwd` with $HOME collapsed to `~`, owned by the model.
cwd_display: []const u8 = "",

/// Cursor position within the prompt box, in prompt-box coordinates. Set
/// during draw; the root surface owns the real cursor because the root widget
/// is the focused one.
input_cursor: ?vxfw.CursorState = null,

/// The agent loop. Owns the conversation's mutations, the in-flight request,
/// and any running tools.
loop: AgentLoop = undefined,
/// Rows the plan occupied in the last frame, so a click can find it. Both zero
/// when there is no plan on screen.
plan_top: u16 = 0,
plan_bottom: u16 = 0,
/// Whether the pointer is over the plan, which is the only thing that says it
/// can be clicked at all.
plan_hover: bool = false,
/// Every skill found at startup, for `/skills`. Borrowed, and null where
/// nothing looked.
skills: ?*const skill.Set = null,
/// What `/prune` is allowed to throw away, as config.json set it.
prune_policy: Database.Policy = .{},
/// Tool registry, and the read log the tools share. Owned.
registry: Registry = undefined,
reads: tool.ReadLog = undefined,
/// The clickable loading indicator. Lives on the model so its expanded state
/// survives the requests coming and going.
thinking: ThoughtView.View = .{},

/// One settled "Thought: ..." row per message, keyed by the message's stable
/// `seq` so trimming older messages does not shift the mapping. Heap-allocated
/// individually because each is a widget whose address is baked into
/// `userdata`, so a growing map must not move them.
thought_rows: std.AutoHashMapUnmanaged(u64, *ThoughtView.View) = .empty,

/// One card per tool call, keyed by message `seq` and call index so expansion
/// state survives redraws and trimming. Individually allocated: each is a
/// widget whose address is baked into its `userdata`.
tool_cards: std.AutoHashMapUnmanaged(u64, *ToolCard) = .empty,
/// Which tool calls left a subagent transcript, keyed like `tool_cards`. Looked
/// up once per call rather than once per frame.
subagent_sessions: std.AutoHashMapUnmanaged(u64, i64) = .empty,
/// A subagent's transcript, shown in place of this session's own.
viewing: ?Viewing = null,
/// The nested runs, which this model drives on its own tick. Null where
/// subagents are not available at all.
subagents: ?*Subagent.Runner = null,
/// Expandable cards for the files an `@path` mention pulled in, keyed by
/// `(message seq << 32) | attachment index`.
attachment_cards: std.AutoHashMapUnmanaged(u64, *AttachmentCard) = .empty,
/// Per-message toggles for messages carrying a held-back paste, keyed by the
/// message's `seq`.
paste_toggles: std.AutoHashMapUnmanaged(u64, *PasteToggle) = .empty,
/// The widget the runtime drives, and the same one without handlers, both
/// filled in by `app.wire`. Kept as values rather than built here so the Model
/// never has to know which module routes its events or draws it.
vtable: vxfw.Widget = undefined,
plain_vtable: vxfw.Widget = undefined,
/// Where each `edit` call's hunk starts in its file, keyed like `tool_cards`.
/// Resolved once, from the file on disk, and kept: after the edit has run the
/// old text is no longer there to search for.
diff_starts: std.AutoHashMapUnmanaged(u64, usize) = .empty,

/// Mouse text selection over the composited frame.
selection: Selection = undefined,

/// The `@` file picker. Indexes lazily on first use.
mentions: MentionPopup = undefined,
/// The permission panel, shown in place of the prompt while a tool call waits
/// on a decision.
approval: Approval = .{},
/// Prompts sent this session, oldest first, for up/down recall. Owned.
history: std.ArrayList([]const u8) = .empty,
/// Where recall currently sits. Null means the draft is the user's own, which
/// is what down-arrow returns to.
history_index: ?usize = null,
/// The draft that was in the box when recall started, so it can be given back.
/// Owned.
history_draft: ?[]const u8 = null,
/// The rename dialog. Closed unless ctrl+r opened it.
rename: Rename = undefined,
/// The session switcher. Closed unless ctrl+p opened it.
sessions: SessionPicker = undefined,
/// The model switcher. Closed unless ctrl+o or `/model` opened it.
models: ModelPicker = undefined,
/// The provider connect flow. Closed unless `/providers` opened it.
connect: Connect = undefined,
/// The theme switcher. Closed unless `/theme` opened it.
theme_picker: ThemePicker = undefined,
mcp_picker: McpPicker = undefined,
/// The toast in the top-right corner.
notification: Notification = undefined,
/// Where credentials are stored, so connecting a provider can write one.
/// Borrowed; it outlives the model.
auth: ?*Auth = null,
/// The client behind `provider`. Borrowed; it outlives the model. Needed
/// because connecting a provider of another protocol replaces the client, which
/// the erased `Provider` has no way to do.
backend: ?*Backend = null,
/// The `/` command picker, open while one is being typed.
slash: Slash = undefined,
/// Where the left button went down, so a drag can anchor there. The first
/// `.drag` event arrives a cell or two away, and anchoring on it loses whatever
/// was under the press.
press_point: ?Selection.Point = null,
/// Column the sidebar starts at, or the screen width when there is none.
/// Selection is confined to one side of it.
sidebar_col: u16 = std.math.maxInt(u16),

/// Whether a spinner tick is already scheduled. Every place that starts work
/// wants the spinner running, and vxfw has no way to ask whether a timer is
/// pending - without this each one adds its own chain and the spinner advances
/// once per chain per interval.
tick_pending: bool = false,
/// Pasted text and images, standing in the draft as tokens.
held: Attachments = undefined,
/// Bracketed paste arrives as ordinary key events between `paste_start` and
/// `paste_end`, so they are collected here rather than typed into the draft one
/// character at a time.
paste_buffer: std.ArrayList(u8) = .empty,
pasting: bool = false,
/// Where the harness is running, for resolving mentions. Borrowed.
project: ?*const Project = null,
/// The MCP servers, connected on a worker while the first frame draws.
/// Borrowed. Their tools are registered once the worker lands, which is also
/// when a server that did not come up is reported.
mcp: ?*mcp_tools.Host = null,
/// Whether the configured model still needs checking against what the provider
/// actually has. Done after the first frame rather than before it: the check is
/// a round trip, and a model that has gone missing fails the first turn with a
/// message saying so anyway.
pending_model_check: bool = false,

/// Tracks the ctrl+c pressed during a running turn. A second press inside
/// `quit_confirm_ms` quits; otherwise the arming lapses.
quit_confirm: Confirm = .{ .window_ms = quit_confirm_ms },

/// The vxfw app, borrowed from main. Only needed to hand the terminal back on
/// ctrl+z: raw mode swallows the suspend key, so the app has to do it itself.
app: ?*vxfw.App = null,
/// The process environment, for the editor `ctrl+e` shells out to.
environ: ?*std.process.Environ.Map = null,
/// When a finished turn is worth a noise, as config.json set it.
bell: Config.Bell = .unfocused,
/// What the terminal last said about focus, or null if it has said nothing.
focused: ?bool = null,
/// Turns already announced, so a finished one rings once and a compaction
/// settling back to idle rings not at all.
rung_for: usize = 0,

/// Rows the transcript is scrolled back from the newest message. Zero pins the
/// view to the bottom, which is where it returns whenever a message arrives.
scroll: u16 = 0,
/// How far `scroll` can go, recomputed during each draw once block heights are
/// known. Approximate while history remains unbuilt: it reports at least as
/// far as the last draw reached, which is always further than the user can see.
max_scroll: u16 = 0,
/// Measured block heights, so a scrolled-back transcript does not rebuild
/// every block between the newest and the viewport on every frame just to
/// learn how tall they are.
block_heights: std.AutoHashMapUnmanaged(u64, u16) = .empty,
/// The width those heights were measured at. A resize invalidates all of them.
heights_width: u16 = 0,
/// Whether the last draw built every block, rather than stopping once it had
/// covered the viewport. Only then does hitting `max_scroll` mean the top.
transcript_exhausted: bool = true,
/// Height of the live tail - the spinner, the streaming reply, the queue - as
/// of the last draw. Growth there moves everything above it up, so a reader
/// who has scrolled back needs the offset grown to match.
tail_height: u16 = 0,

/// A widget for decorative surfaces: no handlers, so hit testing ignores it.
/// A message with a held-back paste keeps its own expanded flag.
pub const PasteToggle = struct {
    expanded: bool = false,

    pub fn widget(self: *PasteToggle) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = PasteToggle.handleEvent,
            .drawFn = PasteToggle.drawFn,
        };
    }

    /// Never called: the surface is built by the transcript, not by drawing
    /// this widget.
    fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        return error.OutOfMemory;
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *PasteToggle = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                switch (mouse.button) {
                    .wheel_up, .wheel_down, .wheel_left, .wheel_right => return,
                    .left => {},
                    else => return ctx.consumeEvent(),
                }
                if (mouse.type == .press) {
                    self.expanded = !self.expanded;
                    return ctx.consumeAndRedraw();
                }
            },
            .mouse_enter => {
                try ctx.setMouseShape(.pointer);
                return ctx.consumeAndRedraw();
            },
            .mouse_leave => {
                try ctx.setMouseShape(.default);
                ctx.redraw = true;
            },
            else => {},
        }
    }
};

/// Modes read at a glance, the way a branch name does.
pub fn agentColor(id: []const u8) theme.Color {
    if (std.mem.eql(u8, id, "plan")) return theme.accent_alt;
    if (std.mem.eql(u8, id, "review")) return theme.warning;
    return theme.accent;
}

pub fn widget(self: *Model) vxfw.Widget {
    return self.vtable;
}

pub fn plainWidget(self: *Model) vxfw.Widget {
    return self.plain_vtable;
}

pub fn clearToolCards(self: *Model) void {
    var cards = self.tool_cards.valueIterator();
    while (cards.next()) |card| self.allocator.destroy(card.*);
    self.tool_cards.clearRetainingCapacity();
    var attachment_cards = self.attachment_cards.valueIterator();
    while (attachment_cards.next()) |card| self.allocator.destroy(card.*);
    self.attachment_cards.clearRetainingCapacity();
    var toggles = self.paste_toggles.valueIterator();
    while (toggles.next()) |toggle| self.allocator.destroy(toggle.*);
    self.paste_toggles.clearRetainingCapacity();
    self.diff_starts.clearRetainingCapacity();
}
pub fn clearThoughtRows(self: *Model) void {
    var it = self.thought_rows.valueIterator();
    while (it.next()) |row| self.allocator.destroy(row.*);
    self.thought_rows.clearRetainingCapacity();
}

/// A subagent's transcript, loaded from the database and shown in place of the
/// session's own. Read-only: the run it records is over.
pub const Viewing = struct {
    /// Where a shown transcript comes from.
    pub const Source = union(enum) {
        /// Looked up by call index every time rather than held: the run it
        /// belongs to is freed the moment its tool call collects the answer.
        live,
        stored: Conversation,
    };

    /// Where the transcript comes from. A running subagent's is borrowed and
    /// grows while it is read; a finished one is a copy from the database.
    source: Source,
    /// The call this belongs to, for finding it again once it is written down.
    key: u64,
    seq: u64,
    index: usize,
    title: []u8,
    /// Owned by the model rather than a frame's arena: the prompt reads it on
    /// every draw, and an arena string would be gone by the second one.
    hint: []u8,

    fn deinit(self: *Viewing, allocator: std.mem.Allocator) void {
        switch (self.source) {
            .stored => |*convo| convo.deinit(),
            .live => {},
        }
        allocator.free(self.title);
        allocator.free(self.hint);
    }
};

/// Whether this call left a subagent transcript. Looked up once and then
/// remembered, including the answer that there is none.
pub fn hasSubagent(self: *Model, key: u64, msg: *Conversation.Message, call_index: usize) bool {
    if (self.viewing != null) return false;

    // A run still going is in memory, not the database, so it is asked every time.
    if (self.subagents) |runner| {
        if (self.loop.pending_seq) |pending| {
            if (msg.seq == pending and runner.viewable(call_index) != null) return true;
        }
    }

    if (self.subagent_sessions.get(key)) |id| return id != 0;

    // A "no" cached before the call settles would outlive the transcript landing.
    const call = msg.tool_calls[call_index];
    if (call.status != .ok and call.status != .failed) return false;

    const session = self.resolveSubagent(msg.seq, call_index);
    self.subagent_sessions.put(self.allocator, key, session orelse 0) catch return false;
    return session != null;
}

/// The stored transcript a call left, straight from the database.
///
/// Asked rather than cached wherever the answer has to be right now: nothing
/// populates the cache while a view is open, since `hasSubagent` returns early.
fn resolveSubagent(self: *Model, seq: u64, call_index: usize) ?i64 {
    const db = self.loop.db orelse return null;
    const message_id = self.loop.message_ids.get(seq) orelse return null;
    const found = db.toolCallId(message_id, @intCast(call_index)) catch return null;
    const call_row = found orelse return null;
    return db.subagentSession(call_row) catch null;
}

/// The transcript on screen, which is a subagent's while one is open.
pub fn shown(self: *Model) *Conversation {
    if (self.viewing) |*view| {
        switch (view.source) {
            .stored => |*convo| return convo,
            .live => {
                if (self.subagents) |runner| {
                    if (runner.viewable(view.index)) |child| return &child.convo;
                }
            },
        }
    }
    return &self.conversation;
}

/// The loop whose progress belongs on screen: a subagent's while its transcript
/// is open, the session's own otherwise.
pub fn shownLoop(self: *Model) *AgentLoop {
    if (self.viewing) |*view| {
        if (view.source == .live) {
            if (self.subagents) |runner| {
                if (runner.viewable(view.index)) |child| {
                    if (child.started) return &child.loop;
                }
            }
        }
    }
    return &self.loop;
}

/// Follow a subagent past the end of its run.
///
/// Its transcript lives in memory only until the tool call collects the answer,
/// and is in the database from that moment, so the view swaps sources rather
/// than emptying out under whoever is reading it.
pub fn refreshViewing(self: *Model) void {
    const view = if (self.viewing) |*v| v else return;
    if (view.source != .live) return;

    const runner = self.subagents orelse return;
    if (runner.viewable(view.index) != null) return;

    const key = view.key;
    const seq = view.seq;
    const index = view.index;
    const title = self.allocator.dupe(u8, view.title) catch return;
    defer self.allocator.free(title);

    const opened = self.openSubagent(key, seq, index, title) catch false;
    if (!opened) self.closeSubagent();
}

/// Whether a subagent's transcript is what the person is reading.
pub fn inSubagent(self: *const Model) bool {
    return self.viewing != null;
}

/// Which view a widget belongs to, so a subagent's `seq 0` and the session's
/// own do not share a cached card.
pub fn viewTag(self: *const Model) u64 {
    return if (self.viewing != null) 1 << 63 else 0;
}

/// The cache key for one widget of a message.
pub fn widgetKey(self: *const Model, seq: u64, index: usize) u64 {
    return self.viewTag() | (seq << 32) | @as(u64, index);
}

/// The cache key for a whole message, for the widgets there is one of.
pub fn viewKey(self: *const Model, seq: u64) u64 {
    return self.viewTag() | seq;
}

/// A card was clicked. Errors are swallowed: a transcript that will not load is
/// a card that does nothing, which is what it did before it could be opened.
pub fn openFromCard(ptr: *anyopaque, key: u64, seq: u64, index: usize, name: []const u8) void {
    const self: *Model = @ptrCast(@alignCast(ptr));
    _ = self.openSubagent(key, seq, index, name) catch return;
}

/// Show the transcript a tool call left behind. Silent when it left none.
pub fn openSubagent(self: *Model, key: u64, seq: u64, index: usize, title: []const u8) !bool {
    const source: Viewing.Source = live: {
        if (self.subagents) |runner| {
            if (runner.viewable(index) != null) break :live .live;
        }

        const db = self.loop.db orelse return false;
        const session = self.subagent_sessions.get(key) orelse
            self.resolveSubagent(seq, index) orelse return false;

        var convo: Conversation = .init(self.allocator);
        errdefer convo.deinit();
        try loadInto(db, session, &convo);
        break :live .{ .stored = convo };
    };
    errdefer if (source == .stored) {
        var owned_convo = source.stored;
        owned_convo.deinit();
    };

    const owned = try self.allocator.dupe(u8, title);
    errdefer self.allocator.free(owned);

    const hint = try std.fmt.allocPrint(
        self.allocator,
        "reading the {s} subagent \u{b7} ctrl+b to go back",
        .{owned},
    );
    errdefer self.allocator.free(hint);

    self.closeSubagent();
    self.viewing = .{
        .source = source,
        .key = key,
        .seq = seq,
        .index = index,
        .title = owned,
        .hint = hint,
    };
    return true;
}

/// Back to the session's own transcript.
pub fn closeSubagent(self: *Model) void {
    if (self.viewing) |*view| view.deinit(self.allocator);
    self.viewing = null;
    forgetWidgets(self);
}

/// Drop every cached widget and measurement.
///
/// Called whenever the transcript on screen changes. The view tag separates a
/// subagent's widgets from the session's, but one bit cannot separate two
/// subagents, and a tagged key outlives the view that made it: `pruneWidgets`
/// evicts by seq, and every tagged key is larger than any seq.
fn forgetWidgets(self: *Model) void {
    clearToolCards(self);
    clearThoughtRows(self);
    self.block_heights.clearRetainingCapacity();
}

fn loadInto(db: *Database, session: i64, convo: *Conversation) !void {
    const loaded = try db.loadMessages(convo.allocator, session, std.math.maxInt(i64), max_transcript_messages);
    defer convo.allocator.free(loaded);

    for (loaded) |message| try convo.messages.append(convo.allocator, message);
    std.mem.reverse(Conversation.Message, convo.messages.items);
}

pub fn deinit(self: *Model) void {
    self.closeSubagent();
    self.subagent_sessions.deinit(self.allocator);
    self.loop.deinit();
    self.registry.deinit();
    self.reads.deinit();
    self.thinking.stream = null;
    clearThoughtRows(self);
    self.thought_rows.deinit(self.allocator);
    self.mentions.deinit();
    self.held.deinit();
    self.rename.deinit();
    self.sessions.deinit();
    self.models.deinit();
    self.connect.deinit();
    self.theme_picker.deinit();
    self.mcp_picker.deinit();
    self.block_heights.deinit(self.allocator);
    self.notification.deinit();
    self.slash.deinit();
    self.clearHistory();
    self.history.deinit(self.allocator);
    self.paste_buffer.deinit(self.allocator);
    self.selection.deinit();
    var cards = self.tool_cards.valueIterator();
    while (cards.next()) |card| self.allocator.destroy(card.*);
    self.tool_cards.deinit(self.allocator);
    var attachment_cards = self.attachment_cards.valueIterator();
    while (attachment_cards.next()) |card| self.allocator.destroy(card.*);
    self.attachment_cards.deinit(self.allocator);
    var toggles = self.paste_toggles.valueIterator();
    while (toggles.next()) |toggle| self.allocator.destroy(toggle.*);
    self.paste_toggles.deinit(self.allocator);
    self.diff_starts.deinit(self.allocator);
    self.input.deinit();
    self.conversation.deinit();
    self.allocator.free(self.cwd);
    self.allocator.free(self.cwd_display);
}

/// Wire the input's submit callback back to the model. Call after the
/// model's fields are initialized.
/// Build the pieces that need the model's final address, then hook up input.
pub fn wire(self: *Model) !void {
    self.mentions = .init(self.allocator);
    self.held = .init(self.allocator);
    self.rename = .init(self.allocator);
    self.sessions = .init(self.allocator);
    self.models = .init(self.allocator);
    self.connect = .init(self.allocator);
    self.theme_picker = .init(self.allocator);
    self.mcp_picker = .init(self.allocator);
    self.notification = .init(self.allocator, self.io);
    self.slash = .init(self.allocator);
    self.selection = .init(self.allocator);
    self.reads = .init(self.allocator);
    self.registry = try Registry.init(self.allocator);
    self.conversation.max_messages = max_transcript_messages;
    self.loop = .init(
        self.allocator,
        self.io,
        self.provider,
        &self.registry,
        &self.conversation,
        &self.reads,
        if (self.project) |project| project.root else self.cwd,
    );
}

/// Replace the half-typed command with the highlighted one.
pub fn acceptCommand(self: *Model) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();

    const completion = try self.slash.completion(arena_state.allocator()) orelse return;
    self.input.clear();
    try self.input.insertText(completion);
    self.slash.close();
}

/// Keep a selection inside the pane it started in. The transcript and the
/// sidebar are separate documents that happen to share a screen, and a linear
/// selection spanning two rows would otherwise swallow both.
pub fn confineToPane(self: *Model, start: Selection.Point) void {
    if (start.col >= self.sidebar_col) {
        self.selection.confine(self.sidebar_col, std.math.maxInt(u16));
    } else {
        self.selection.confine(0, self.sidebar_col -| 1);
    }
}

/// Ask for one spinner tick, unless one is already on its way.
pub fn scheduleTick(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.tick_pending) return;
    self.tick_pending = true;
    try ctx.tick(ThoughtView.spinner_interval_ms, self.widget());
}

/// Ask the model to summarise the transcript so far.
pub fn startCompaction(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.loop.isBusy()) return;
    try self.loop.compact();
    self.thinking.stream = self.loop.thoughts();
    self.thinking.frame = 0;
    self.thinking.expanded = false;
    self.scroll = 0;
    try self.scheduleTick(ctx);
    ctx.redraw = true;
}

pub fn startTurn(self: *Model, ctx: *vxfw.EventContext, prompt: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try self.beginTurn(ctx, prompt, .{
        .attachments = try self.held.textAttachments(arena, prompt),
        .images = try self.held.images(arena, prompt),
    });
    self.held.consume(prompt);
}

/// Everything starting a turn involves besides the prompt itself.
///
/// The tick is the part that must not be missed: a turn runs on a worker, and
/// without a scheduled tick nothing polls it, so the spinner sits still and the
/// reply never lands until some other event wakes the loop.
pub fn beginTurn(self: *Model, ctx: *vxfw.EventContext, prompt: []const u8, extras: AgentLoop.Extras) !void {
    try self.remember(prompt);
    try self.loop.submit(prompt, extras);

    self.thinking.stream = self.loop.thoughts();
    self.thinking.frame = 0;
    self.thinking.expanded = true;
    self.scroll = 0;

    try self.scheduleTick(ctx);
    ctx.redraw = true;
}

/// Start a turn with whatever was typed mid-turn but never handed over, once
/// the loop has gone idle. A cancelled turn leaves its steering behind, and
/// what was a correction is now simply the next thing to do.
pub fn drainSteering(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.loop.isBusy()) return;
    const prompt = self.loop.takeSteering() orelse return;
    defer self.allocator.free(prompt);
    try self.startTurn(ctx, prompt);
}

/// Terminals send a carriage return for each pasted newline, so the buffer is
/// rewritten to plain `\n` before anything counts lines in it.
pub fn normalizePaste(self: *Model) void {
    const items = self.paste_buffer.items;
    var out: usize = 0;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        if (items[i] == '\r') {
            if (i + 1 < items.len and items[i + 1] == '\n') i += 1;
            items[out] = '\n';
        } else {
            items[out] = items[i];
        }
        out += 1;
    }
    self.paste_buffer.shrinkRetainingCapacity(out);
}

/// A one-line field a dialog has the keyboard in, with the ceiling that dialog
/// puts on it - the same one its own key handling enforces, since a paste is
/// not a way around a limit.
const Focus = struct { field: *Input, max: usize };

/// Where a paste should land, or null when the composer owns the keyboard. A
/// dialog is modal for keys, so it has to be modal for pastes too - otherwise
/// an API key typed by the clipboard lands in the draft behind it.
fn focusedField(self: *Model) ?Focus {
    if (self.connect.isOpen()) {
        const field = self.connect.focus() orelse return null;
        return .{ .field = field, .max = Connect.max_value_bytes };
    }
    if (self.models.open) return .{ .field = &self.models.search, .max = 256 };
    if (self.rename.open) return .{ .field = &self.rename.field, .max = Rename.max_title_bytes };
    return null;
}

/// Flatten a paste for a one-line field. A key copied out of a web page brings
/// its line wrapping with it, and a URL copied from a terminal brings a
/// trailing newline; neither belongs in the value.
fn flattenPaste(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, text.len);
    for (text) |byte| {
        switch (byte) {
            '\n', '\r', '\t' => {},
            else => out.appendAssumeCapacity(byte),
        }
    }
    return std.mem.trim(u8, out.items, " ");
}

/// Route a paste: a dialog's field, a dropped image file, an image on the
/// clipboard, a block big enough to be worth holding back, or just text.
pub fn handlePaste(self: *Model, text: []const u8) !void {
    if (self.loop.state == .awaiting_approval) return;

    if (self.focusedField()) |focus| {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();

        const value = try flattenPaste(arena_state.allocator(), text);
        const room = focus.max -| focus.field.text.items.len;
        if (value.len == 0 or room == 0) return;
        try focus.field.insertText(value[0..@min(value.len, room)]);
        return;
    }

    const trimmed = trimPastedPath(text);
    if (image.hasImageExtension(trimmed) and self.attachImageFile(trimmed)) return;

    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        self.attachClipboardImage();
        return;
    }

    const lines = std.mem.count(u8, text, "\n") + 1;
    if (lines >= paste_minify_lines or text.len >= paste_minify_bytes) {
        const token = try self.held.addText(text);
        try self.input.insertText(token);
        return;
    }
    try self.input.insertText(text);
}

/// A path dropped on the terminal arrives quoted, escaped, or as a file URI.
fn trimPastedPath(text: []const u8) []const u8 {
    var path = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    if (path.len >= 2) {
        const first = path[0];
        if ((first == '\'' or first == '"') and path[path.len - 1] == first) {
            path = path[1 .. path.len - 1];
        }
    }
    return path;
}

/// Hold an image file, returning whether it was one. Failures are silent: a
/// paste that turns out not to be an image falls through to the text path.
fn attachImageFile(self: *Model, path: []const u8) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        self.io,
        path,
        self.allocator,
        .limited(Attachments.max_image_bytes),
    ) catch return false;
    defer self.allocator.free(bytes);

    if (!image.isImage(bytes)) return false;
    self.holdImage(bytes, std.fs.path.basename(path));
    return true;
}

/// Ask the system clipboard for an image. Terminals do not forward image
/// pastes, so this shells out to whichever helper is installed.
pub fn attachClipboardImage(self: *Model) void {
    const candidates: []const []const []const u8 = &.{
        &.{ "wl-paste", "--no-newline", "--type", "image/png" },
        &.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" },
        &.{ "pngpaste", "-" },
    };

    for (candidates) |argv| {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(Attachments.max_image_bytes),
            .stderr_limit = .limited(4096),
        }) catch continue;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (!image.isImage(result.stdout)) continue;
        self.holdImage(result.stdout, "");
        return;
    }
}

fn holdImage(self: *Model, bytes: []const u8, label: []const u8) void {
    const encoded = image.encode(self.allocator, bytes) catch return;
    defer self.allocator.free(encoded);

    const token = self.held.addImage(encoded, label) catch return;
    self.input.insertText(token) catch {};
}

/// Swap the transcript for another session's, without leaving.
pub fn switchSession(self: *Model, session_id: i64) !void {
    if (self.loop.session_id) |current| {
        if (current == session_id) return;
    }
    if (self.loop.isBusy()) try self.loop.cancel();

    try self.loop.resumeSession(session_id, resume_messages);

    clearToolCards(self);
    clearThoughtRows(self);
    self.closeSubagent();
    self.subagent_sessions.clearRetainingCapacity();
    self.thinking.stream = null;
    self.loop.dropSteering();
    try self.seedHistory();
    self.input.clear();
    self.held.clear();
    self.scroll = 0;
}

/// Keep a sent prompt for up-arrow recall. Consecutive duplicates are not worth
/// two entries.
fn remember(self: *Model, prompt: []const u8) !void {
    self.endRecall();
    if (prompt.len == 0) return;
    if (self.history.items.len > 0) {
        const last = self.history.items[self.history.items.len - 1];
        if (std.mem.eql(u8, last, prompt)) return;
    }

    while (self.history.items.len >= max_history) {
        self.allocator.free(self.history.orderedRemove(0));
    }
    try self.history.append(self.allocator, try self.allocator.dupe(u8, prompt));
}

/// Fill the up-arrow history from a resumed transcript. Without this,
/// continuing a session gives you its messages on screen but an empty recall
/// list, so up-arrow does nothing.
pub fn seedHistory(self: *Model) !void {
    self.clearHistory();
    for (self.conversation.messages.items) |msg| {
        if (msg.role != .user) continue;
        try self.remember(msg.text);
    }
}

fn clearHistory(self: *Model) void {
    for (self.history.items) |prompt| self.allocator.free(prompt);
    self.history.clearRetainingCapacity();
    self.endRecall();
}

/// Stop walking history, forgetting the stashed draft.
fn endRecall(self: *Model) void {
    if (self.history_draft) |draft| self.allocator.free(draft);
    self.history_draft = null;
    self.history_index = null;
}

/// Up on the first line walks back through what was sent; down walks forward,
/// ending at whatever was being typed when recall started. Returns whether the
/// key was used, so an ordinary cursor move still happens when it was not.
pub fn recall(self: *Model, direction: enum { back, forward }) !bool {
    switch (direction) {
        .back => {
            if (!self.input.onFirstLine()) return false;
            if (self.history.items.len == 0) return false;

            if (self.history_index) |index| {
                if (index == 0) return true;
                self.history_index = index - 1;
            } else {
                self.history_draft = try self.allocator.dupe(u8, self.input.text.items);
                self.history_index = self.history.items.len - 1;
            }
            self.showRecalled(self.history.items[self.history_index.?]);
            return true;
        },
        .forward => {
            if (!self.input.onLastLine()) return false;
            const index = self.history_index orelse return false;

            if (index + 1 < self.history.items.len) {
                self.history_index = index + 1;
                self.showRecalled(self.history.items[index + 1]);
                return true;
            }

            const draft = self.history_draft orelse "";
            self.showRecalled(draft);
            self.endRecall();
            return true;
        },
    }
}

fn showRecalled(self: *Model, text: []const u8) void {
    self.input.clear();
    self.input.insertText(text) catch {};
}

/// ctrl+c is overloaded, in order of least destructive: discard the draft,
/// then ask before abandoning a running turn, then quit.
pub fn handleInterrupt(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.quit_confirm.armed(self.io)) {
        self.loop.requestStop();
        ctx.quit = true;
        return;
    }
    if (self.input.text.items.len > 0) {
        self.input.clear();
        self.mentions.close();
        self.endRecall();
        if (self.loop.pendingSteering().len == 0) self.held.clear();
        return ctx.consumeAndRedraw();
    }
    if (self.loop.isBusy()) {
        self.quit_confirm.arm(self.io);
        return ctx.consumeAndRedraw();
    }
    self.loop.requestStop();
    ctx.quit = true;
}

/// The capture phase reaches the root first, and only there are mouse
/// coordinates still screen-relative - once an event bubbles back up they have
/// been translated into whatever widget was hit. Selection needs screen
/// coordinates, so it is handled here rather than in the event handler.
/// Put the selection on the system clipboard. Uses OSC 52, so it works over
/// ssh where a local clipboard tool would not.
pub fn copySelection(self: *Model, ctx: *vxfw.EventContext) !void {
    const copied = try self.selection.text(self.allocator) orelse return;
    defer self.allocator.free(copied);
    if (copied.len == 0) return;
    try ctx.copyToClipboard(copied);
    try self.notification.show(ctx, .info, "Copied to clipboard");
}

/// A decision may have started tools running, which needs the tick loop back.
pub fn afterDecision(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.loop.isBusy()) try self.scheduleTick(ctx);
    self.scroll = 0;
    return ctx.consumeAndRedraw();
}

/// Recompute the file picker from the current input. Cheap enough to run on
/// every keystroke: the index is built once and the filter is a substring scan
/// capped at the number of visible rows.
pub fn refreshMentions(self: *Model) !void {
    const project = self.project orelse return;
    self.mentions.update(
        self.io,
        project.root,
        self.input.text.items,
        self.input.cursor,
    ) catch {};
}

/// The picker's index is built on a worker, so the first `@` in a session needs
/// the tick loop running to notice the scan land.
pub fn awaitMentions(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.mentions.isScanning()) try self.scheduleTick(ctx);
}

/// Replace the partial `@token` under the cursor with the selected path.
pub fn acceptMention(self: *Model) !void {
    const anchor = self.mentions.anchor orelse return;
    const path = self.mentions.selectedPath() orelse return;

    const completed = if (mention.needsQuoting(path))
        try std.fmt.allocPrint(self.allocator, "@\"{s}\" ", .{path})
    else
        try std.fmt.allocPrint(self.allocator, "@{s} ", .{path});
    defer self.allocator.free(completed);

    try self.input.replaceRange(anchor, self.input.cursor, completed);
    self.mentions.close();
}

/// Positive scrolls back through history, negative returns toward the newest
/// message. Clamped against the previous frame's extent; the next draw
/// re-clamps once the real one is known.
pub fn scrollBy(self: *Model, ctx: *vxfw.EventContext, delta: i32) void {
    const target = @as(i32, self.scroll) + delta;
    const clamped = std.math.clamp(target, 0, @as(i32, self.max_scroll));
    const next: u16 = @intCast(clamped);
    if (next == self.scroll) return;
    self.scroll = next;
    ctx.redraw = true;
}

/// When the user has scrolled to the very top and older messages were trimmed
/// from memory, page a batch back in from the database. The scroll offset is
/// left alone: the newly prepended messages appear above the current view, so
/// the user keeps scrolling up to see them.
pub fn pageHistoryIfNeeded(self: *Model) !void {
    if (!self.transcript_exhausted) return;
    if (self.scroll < self.max_scroll) return;
    if (self.conversation.dropped == 0) return;
    _ = try self.loop.pageHistory(history_page_size);
}

test "a running subagent can be read before it has finished" {
    const testing = std.testing;

    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = undefined,
        .input = .init(testing.allocator),
    };
    defer model.conversation.deinit();
    defer model.input.deinit();
    defer model.subagent_sessions.deinit(testing.allocator);
    defer model.closeSubagent();

    model.loop.db = null;
    model.loop.pending_seq = null;

    var child: Subagent.Child = .{
        .agent = "task",
        .prompt = "where is it",
        .label = "find it",
        .index = 2,
        .cancelled = null,
        .progress = null,
        .convo = .init(testing.allocator),
        .reads = .init(testing.allocator),
    };
    defer child.convo.deinit();
    defer child.reads.deinit();
    _ = try child.convo.addUser("where is it", &.{}, &.{});

    var runner: Subagent.Runner = .{ .parent = &model.loop };
    defer runner.active.deinit(testing.allocator);
    try runner.active.append(testing.allocator, &child);
    model.subagents = &runner;

    // Borrowed, not copied: what the run writes next is what the reader sees.
    try testing.expect(try model.openSubagent(0, 0, 2, "task"));
    try testing.expectEqual(&child.convo, model.shown());
    try testing.expectEqual(@as(usize, 1), model.shown().messages.items.len);

    _ = try child.convo.addAssistant("still looking", null, null);
    try testing.expectEqual(@as(usize, 2), model.shown().messages.items.len);

    // Its progress, not the parent's, which is stuck on "running tools".
    try testing.expectEqual(&model.loop, model.shownLoop());
    child.started = true;
    child.loop = model.loop;
    try testing.expectEqual(&child.loop, model.shownLoop());

    // Once the run is gone and nothing was written down, the view lets go.
    _ = runner.active.orderedRemove(0);
    model.refreshViewing();
    try testing.expect(!model.inSubagent());
    try testing.expectEqual(&model.conversation, model.shown());
}

test "a finishing subagent hands its reader over to the stored transcript" {
    const testing = std.testing;

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();

    const project = try db.resolveProject("/repo", "git", "repo");
    const parent = try db.createSession(project, "/repo", "model");

    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = undefined,
        .input = .init(testing.allocator),
    };
    defer model.conversation.deinit();
    defer model.input.deinit();
    defer model.subagent_sessions.deinit(testing.allocator);
    defer model.closeSubagent();

    model.loop.db = &db;
    model.loop.message_ids = .empty;
    defer model.loop.message_ids.deinit(testing.allocator);

    var calls = [_]Conversation.ToolCall{.{
        .id = "call_0",
        .name = "task",
        .arguments = "{}",
        .status = .running,
    }};
    _ = try model.conversation.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    const msg = &model.conversation.messages.items[model.conversation.messages.items.len - 1];

    const message_id = try db.appendMessage(parent, @intCast(msg.seq), "assistant", "", null, 0);
    try model.loop.message_ids.put(testing.allocator, msg.seq, message_id);
    const call_row = try db.appendToolCall(message_id, 0, "call_0", "task", "{}", "ok", "done", 4);

    var child: Subagent.Child = .{
        .agent = "task",
        .prompt = "where is it",
        .label = "find it",
        .index = 0,
        .cancelled = null,
        .progress = null,
        .convo = .init(testing.allocator),
        .reads = .init(testing.allocator),
    };
    defer child.convo.deinit();
    defer child.reads.deinit();
    _ = try child.convo.addUser("where is it", &.{}, &.{});

    var runner: Subagent.Runner = .{ .parent = &model.loop };
    defer runner.active.deinit(testing.allocator);
    try runner.active.append(testing.allocator, &child);
    model.subagents = &runner;

    const key = model.widgetKey(msg.seq, 0);
    try testing.expect(try model.openSubagent(key, msg.seq, 0, "task"));
    try testing.expectEqual(&child.convo, model.shown());

    // What the tick does when the call settles: store it, then drop the child.
    const stored = try db.createSubagentSession(project, "/repo", "model", parent, call_row);
    _ = try db.appendMessage(stored, 0, "user", "where is it", null, 0);
    _ = try db.appendMessage(stored, 1, "assistant", "found it", null, 0);
    _ = runner.active.orderedRemove(0);

    // The reader stays put, on the copy rather than the borrowed convo.
    model.refreshViewing();
    try testing.expect(model.inSubagent());
    try testing.expect(model.viewing.?.source == .stored);
    try testing.expectEqual(@as(usize, 2), model.shown().messages.items.len);
    try testing.expectEqualStrings("found it", model.shown().messages.items[1].text);
}

test "a task card only offers its transcript once the call has settled" {
    const testing = std.testing;

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();

    const project = try db.resolveProject("/repo", "git", "repo");
    const parent = try db.createSession(project, "/repo", "model");

    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = undefined,
        .input = .init(testing.allocator),
    };
    defer model.conversation.deinit();
    defer model.input.deinit();
    defer model.subagent_sessions.deinit(testing.allocator);
    defer model.closeSubagent();

    // Only the fields this path reads; the loop itself needs no wiring here.
    model.loop.db = &db;
    model.loop.message_ids = .empty;
    defer model.loop.message_ids.deinit(testing.allocator);

    var calls = [_]Conversation.ToolCall{.{
        .id = "call_0",
        .name = "task",
        .arguments = "{}",
        .status = .running,
    }};
    _ = try model.conversation.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });

    const msg = &model.conversation.messages.items[model.conversation.messages.items.len - 1];
    const message_id = try db.appendMessage(parent, @intCast(msg.seq), "assistant", "", null, 0);
    try model.loop.message_ids.put(testing.allocator, msg.seq, message_id);
    const call_row = try db.appendToolCall(message_id, 0, "call_0", "task", "{}", "running", null, 0);

    const key = model.widgetKey(msg.seq, 0);

    // Still running, so nothing is looked up and nothing is remembered.
    try testing.expect(!model.hasSubagent(key, msg, 0));
    try testing.expect(model.subagent_sessions.get(key) == null);

    _ = try db.createSubagentSession(project, "/repo", "model", parent, call_row);
    msg.tool_calls[0].status = .ok;

    try testing.expect(model.hasSubagent(key, msg, 0));
}

test "a subagent transcript takes over the view, and ctrl+b gives it back" {
    const testing = std.testing;

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();

    const project = try db.resolveProject("/repo", "git", "repo");
    const parent = try db.createSession(project, "/repo", "model");
    const message = try db.appendMessage(parent, 0, "assistant", "", null, 0);
    const call = try db.appendToolCall(message, 0, "call_0", "task", "{}", "ok", "found it", 8);
    const child = try db.createSubagentSession(project, "/repo", "model", parent, call);
    _ = try db.appendMessage(child, 0, "user", "where is the parser", null, 0);
    _ = try db.appendMessage(child, 1, "assistant", "src/parse.zig:40", null, 0);

    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = undefined,
        .input = .init(testing.allocator),
    };
    defer model.conversation.deinit();
    defer model.input.deinit();
    defer model.subagent_sessions.deinit(testing.allocator);
    defer model.closeSubagent();

    model.loop.db = &db;
    _ = try model.conversation.addUser("go", &.{}, &.{});

    const key: u64 = 0;
    try model.subagent_sessions.put(testing.allocator, key, child);

    try testing.expect(!model.inSubagent());
    try testing.expectEqual(&model.conversation, model.shown());

    try testing.expect(try model.openSubagent(key, 0, 0, "task"));
    try testing.expect(model.inSubagent());
    try testing.expectEqual(@as(usize, 2), model.shown().messages.items.len);
    try testing.expectEqualStrings("where is the parser", model.shown().messages.items[0].text);
    try testing.expect(std.mem.indexOf(u8, model.viewing.?.hint, "ctrl+b") != null);

    model.closeSubagent();
    try testing.expect(!model.inSubagent());
    try testing.expectEqual(&model.conversation, model.shown());

    // A call that left nothing behind stays where it is.
    try testing.expect(!try model.openSubagent(99, 5, 7, "task"));
}

test "a confirmation lapses if the second press never comes" {
    const io = std.testing.io;
    var confirm: Confirm = .{ .window_ms = 20 };

    try std.testing.expect(!confirm.armed(io));

    confirm.arm(io);
    try std.testing.expect(confirm.armed(io));

    try std.Io.sleep(io, .fromMilliseconds(40), .real);
    try std.testing.expect(!confirm.armed(io));
    try std.testing.expect(confirm.armed_at == null);
}

test "up walks back through sent prompts, down returns the draft" {
    var model: Model = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .conversation = .init(std.testing.allocator),
        .provider = undefined,
        .input = .init(std.testing.allocator),
    };
    defer model.conversation.deinit();
    defer model.input.deinit();
    defer {
        model.clearHistory();
        model.history.deinit(std.testing.allocator);
    }

    try model.remember("first");
    try model.remember("second");

    try model.input.insertText("half typed");
    try std.testing.expect(try model.recall(.back));
    try std.testing.expectEqualStrings("second", model.input.text.items);

    try std.testing.expect(try model.recall(.back));
    try std.testing.expectEqualStrings("first", model.input.text.items);

    try std.testing.expect(try model.recall(.back));
    try std.testing.expectEqualStrings("first", model.input.text.items);

    try std.testing.expect(try model.recall(.forward));
    try std.testing.expectEqualStrings("second", model.input.text.items);

    try std.testing.expect(try model.recall(.forward));
    try std.testing.expectEqualStrings("half typed", model.input.text.items);
    try std.testing.expect(model.history_index == null);

    try std.testing.expect(!try model.recall(.forward));
}

test "recall stays out of the way inside a multi-line draft" {
    var model: Model = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .conversation = .init(std.testing.allocator),
        .provider = undefined,
        .input = .init(std.testing.allocator),
    };
    defer model.conversation.deinit();
    defer model.input.deinit();
    defer {
        model.clearHistory();
        model.history.deinit(std.testing.allocator);
    }

    try model.remember("first");
    try model.input.insertText("one\ntwo");

    try std.testing.expect(!try model.recall(.back));
    try std.testing.expectEqualStrings("one\ntwo", model.input.text.items);
}

test "a resumed session fills the recall list" {
    var model: Model = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .conversation = .init(std.testing.allocator),
        .provider = undefined,
        .input = .init(std.testing.allocator),
    };
    defer model.conversation.deinit();
    defer model.input.deinit();
    defer {
        model.clearHistory();
        model.history.deinit(std.testing.allocator);
    }

    _ = try model.conversation.addUser("older prompt", &.{}, &.{});
    _ = try model.conversation.addAssistant("an answer", null, null);
    _ = try model.conversation.addUser("newer prompt", &.{}, &.{});

    try model.seedHistory();

    try std.testing.expectEqual(@as(usize, 2), model.history.items.len);
    try std.testing.expect(try model.recall(.back));
    try std.testing.expectEqualStrings("newer prompt", model.input.text.items);
    try std.testing.expect(try model.recall(.back));
    try std.testing.expectEqualStrings("older prompt", model.input.text.items);
}

test "recall stops growing once it is full" {
    var model: Model = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .conversation = .init(std.testing.allocator),
        .provider = undefined,
        .input = .init(std.testing.allocator),
    };
    defer model.conversation.deinit();
    defer model.input.deinit();
    defer {
        model.clearHistory();
        model.history.deinit(std.testing.allocator);
    }

    var buffer: [16]u8 = undefined;
    for (0..max_history + 10) |i| {
        try model.remember(try std.fmt.bufPrint(&buffer, "prompt {d}", .{i}));
    }

    try std.testing.expectEqual(max_history, model.history.items.len);
    try std.testing.expectEqualStrings("prompt 209", model.history.items[max_history - 1]);
}

test "a paste for a one-line field arrives as one line" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        "sk-0123456789abcdef",
        try flattenPaste(arena, "sk-0123456789\nabcdef\n"),
    );
    try testing.expectEqualStrings(
        "http://localhost:11434",
        try flattenPaste(arena, "  http://localhost:11434\r\n"),
    );
    try testing.expectEqualStrings("", try flattenPaste(arena, "\n\t  \r\n"));
}

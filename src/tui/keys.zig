//! Keys and mouse: which input does what.
//!
//! Everything here reads an event and calls a verb - on the Model for state, on
//! `commands` for the app's commands. Routing is where every feature meets, so
//! it lives apart from the state it drives rather than in the middle of it.

const builtin = @import("builtin");
const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agents = @import("../agent/agent.zig");
const commands = @import("commands.zig");
const Model = @import("model.zig");
const Selection = @import("selection.zig");
const widget_pool = @import("widget_pool.zig");
const themes = @import("themes.zig");

pub fn handleSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr.?));
    if (value.len == 0) return;

    if (try commands.runCommand(self, ctx, value)) return;

    if (self.loop.state == .awaiting_answer) {
        try self.loop.answer(value);
        self.input.clear();
        self.scroll = 0;
        try self.scheduleTick(ctx);
        ctx.redraw = true;
        return;
    }

    if (self.loop.isBusy()) {
        try self.queued.append(self.allocator, try self.allocator.dupe(u8, value));
        self.scroll = 0;
        ctx.redraw = true;
        return;
    }

    try self.startTurn(ctx, value);
}

pub fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr));
    switch (event) {
        .mouse => |mouse| try trackSelection(self, ctx, mouse),
        else => {},
    }
}

/// Mouse selection, driven from whichever phase reaches the root.
pub fn trackSelection(self: *Model, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) !void {
    if (mouse.button != .left) return;

    const point: Selection.Point = .{
        .row = @intCast(@max(mouse.row, 0)),
        .col = @intCast(@max(mouse.col, 0)),
    };

    switch (mouse.type) {
        .press => {
            if (self.selection.isActive()) ctx.redraw = true;
            self.selection.clear();
            self.press_point = point;
        },
        .drag => {
            const start = self.press_point orelse point;
            if (!self.selection.dragging) self.selection.begin(start);
            self.confineToPane(start);
            self.selection.extend(point);
            return ctx.consumeAndRedraw();
        },
        .release => {
            if (self.selection.dragging) {
                self.selection.end();
                try self.copySelection(ctx);
                self.selection.clear();
                return ctx.consumeAndRedraw();
            }
            if (self.press_point) |start| {
                if (start.row == point.row and start.col == point.col) openLink(self, point);
            }
        },
        else => {},
    }
}

/// Hand a clicked link to the desktop's opener.
pub fn openLink(self: *Model, point: Selection.Point) void {
    if (builtin.is_test) return;
    const uri = self.selection.linkAt(point.row, point.col) orelse return;
    if (!std.mem.startsWith(u8, uri, "http://") and !std.mem.startsWith(u8, uri, "https://")) return;

    const opener = switch (builtin.os.tag) {
        .macos => "open",
        .windows => return,
        else => "xdg-open",
    };

    const script = std.fmt.allocPrint(
        self.allocator,
        "{s} \"$1\" >/dev/null 2>&1 &",
        .{opener},
    ) catch return;
    defer self.allocator.free(script);

    const uri_z = self.allocator.dupe(u8, uri) catch return;
    defer self.allocator.free(uri_z);

    const result = std.process.run(self.allocator, self.io, .{
        .argv = &.{ "sh", "-c", script, "sh", uri_z },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return;
    self.allocator.free(result.stdout);
    self.allocator.free(result.stderr);
}

pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr));
    switch (event) {
        .init => {
            try commands.applyMcp(self, ctx);
            if (self.pending_model_check) try self.scheduleTick(ctx);
            if (self.mcp) |host| {
                if (host.connecting()) try self.scheduleTick(ctx);
            }
        },
        .paste_start => {
            self.pasting = true;
            self.paste_buffer.clearRetainingCapacity();
            return ctx.consumeEvent();
        },
        .paste_end => {
            self.pasting = false;
            self.normalizePaste();
            try self.handlePaste(self.paste_buffer.items);
            self.paste_buffer.clearRetainingCapacity();
            return ctx.consumeAndRedraw();
        },
        .paste => |text| {
            defer self.allocator.free(text);
            try self.handlePaste(text);
            return ctx.consumeAndRedraw();
        },
        .mouse => |mouse| {
            try trackSelection(self, ctx, mouse);
            if (ctx.consume_event) return;

            if (mouse.button == .wheel_up) {
                self.scrollBy(ctx, 3);
                try self.pageHistoryIfNeeded();
                return ctx.consumeEvent();
            }
            if (mouse.button == .wheel_down) {
                self.scrollBy(ctx, -3);
                return ctx.consumeEvent();
            }
        },
        .tick => {
            self.tick_pending = false;
            commands.checkModel(self, ctx);
            try commands.applyMcp(self, ctx);
            if (self.mcp) |host| {
                if (host.connecting()) try self.scheduleTick(ctx);
            }
            if (self.mentions.poll()) {
                try self.refreshMentions();
                ctx.redraw = true;
            }
            if (self.mentions.isScanning()) try self.scheduleTick(ctx);
            const changed = try self.loop.poll();
            if (changed) {
                widget_pool.pruneWidgets(self);
                commands.syncProvider(self);
                self.mentions.invalidate();
            }
            if (!self.loop.isBusy() and self.loop.shouldCompact()) {
                try self.startCompaction(ctx);
            }
            try self.drainQueue(ctx);
            if (!self.loop.isBusy()) self.quit_confirm.reset();
            if (self.loop.isBusy()) {
                self.thinking.stream = self.loop.thoughts();
                self.thinking.label = self.loop.label();
                self.thinking.frame +%= 1;
                try self.scheduleTick(ctx);
            } else {
                self.thinking.stream = null;
            }
            if (changed) self.scroll = 0;
            ctx.redraw = true;
        },
        .key_press => |key| {
            if (self.pasting) {
                if (key.text) |text| {
                    try self.paste_buffer.appendSlice(self.allocator, text);
                } else if (key.matches(vaxis.Key.enter, .{}) or
                    key.matches('j', .{ .ctrl = true }))
                {
                    try self.paste_buffer.append(self.allocator, '\n');
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    try self.paste_buffer.append(self.allocator, '\t');
                }
                return ctx.consumeEvent();
            }

            if (self.sessions.open) {
                switch (self.sessions.handleKey(key)) {
                    .none => {},
                    .cancel => self.sessions.close(),
                    .choose => {
                        if (self.sessions.selectedId()) |id| try self.switchSession(id);
                        self.sessions.close();
                    },
                }
                return ctx.consumeAndRedraw();
            }

            if (self.mcp_picker.isOpen()) {
                switch (try self.mcp_picker.handleKey(ctx, key)) {
                    .none => {},
                    .cancel => self.mcp_picker.close(),
                    .toggle => try commands.toggleMcpServer(self, ctx),
                }
                return ctx.consumeAndRedraw();
            }

            if (self.theme_picker.open) {
                switch (try self.theme_picker.handleKey(ctx, key)) {
                    .none => {},
                    .cancel => self.theme_picker.close(),
                    .choose => {
                        if (self.theme_picker.selected()) |entry| commands.keepTheme(self, entry.id);
                        self.theme_picker.close();
                    },
                }
                return ctx.consumeAndRedraw();
            }

            if (self.connect.isOpen()) {
                switch (try self.connect.handleKey(ctx, key)) {
                    .none => {},
                    .cancel => self.connect.close(),
                    .connect => |result| {
                        try commands.connectProvider(self, result);
                        self.connect.close();
                    },
                }
                return ctx.consumeAndRedraw();
            }

            if (self.models.open) {
                switch (try self.models.handleKey(ctx, key)) {
                    .none => {},
                    .cancel => self.models.close(),
                    .choose => {
                        if (self.models.selected()) |entry| try commands.switchTo(self, entry);
                        self.models.close();
                    },
                }
                return ctx.consumeAndRedraw();
            }

            if (self.rename.open) {
                switch (try self.rename.handleKey(ctx, key)) {
                    .none => {},
                    .cancel => self.rename.close(),
                    .submit => {
                        self.loop.rename(self.rename.value()) catch {};
                        self.rename.close();
                    },
                }
                return ctx.consumeAndRedraw();
            }

            if (key.matches('c', .{ .ctrl = true })) {
                return self.handleInterrupt(ctx);
            }

            if (key.matches('r', .{ .ctrl = true })) {
                try self.rename.show(self.loop.title());
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.tab, .{})) {
                try commands.switchAgent(self, ctx, agents.next(self.loop.agent.id).id);
                return ctx.consumeAndRedraw();
            }

            // Not ctrl+m: in the legacy encoding that is carriage return.
            if (key.matches('o', .{ .ctrl = true })) {
                try commands.showModels(self);
                return ctx.consumeAndRedraw();
            }

            if (key.matches('s', .{ .ctrl = true })) {
                if (self.loop.database()) |db| {
                    if (self.loop.project_id) |project_id| {
                        try self.sessions.show(db, project_id, self.loop.session_id);
                    }
                }
                return ctx.consumeAndRedraw();
            }

            if (key.matches('p', .{ .ctrl = true })) {
                try commands.showProviders(self);
                return ctx.consumeAndRedraw();
            }

            if (key.matches('v', .{ .ctrl = true })) {
                self.attachClipboardImage();
                return ctx.consumeAndRedraw();
            }

            if (key.matches('z', .{ .ctrl = true })) {
                suspendToShell(self);
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.page_up, .{})) {
                self.scrollBy(ctx, Model.page_scroll_rows);
                try self.pageHistoryIfNeeded();
                return ctx.consumeEvent();
            }
            if (key.matches(vaxis.Key.page_down, .{})) {
                self.scrollBy(ctx, -Model.page_scroll_rows);
                return ctx.consumeEvent();
            }

            if (key.matches(vaxis.Key.escape, .{}) and self.selection.isActive()) {
                self.selection.clear();
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.escape, .{}) and
                self.loop.isBusy() and
                self.loop.state != .awaiting_approval)
            {
                try self.loop.cancel();
                self.thinking.stream = null;
                try self.scheduleTick(ctx);
                return ctx.consumeAndRedraw();
            }

            if (self.loop.state == .awaiting_approval) {
                if (key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    self.approval.move(-1);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.right, .{}) or key.matches(vaxis.Key.tab, .{})) {
                    self.approval.move(1);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    try self.loop.decide(switch (self.approval.selected) {
                        .once => .once,
                        .always => .always,
                        .reject => .deny,
                    });
                    return self.afterDecision(ctx);
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    try self.loop.decide(.deny);
                    return self.afterDecision(ctx);
                }
                return ctx.consumeEvent();
            }

            if (self.slash.isOpen()) {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.slash.close();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.up, .{})) {
                    self.slash.moveSelection(-1);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.slash.moveSelection(1);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.tab, .{})) {
                    try self.acceptCommand();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    const command = self.slash.selectedCommand().?;
                    try self.acceptCommand();
                    if (command.argument.len == 0) {
                        const line = try self.allocator.dupe(u8, self.input.text.items);
                        defer self.allocator.free(line);
                        self.input.clear();
                        _ = try commands.runCommand(self, ctx, line);
                    }
                    return ctx.consumeAndRedraw();
                }
            }

            if (self.mentions.isOpen()) {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.mentions.close();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.up, .{})) {
                    self.mentions.moveSelection(-1);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.mentions.moveSelection(1);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.enter, .{})) {
                    try self.acceptMention();
                    return ctx.consumeAndRedraw();
                }
            }

            if (key.matches(vaxis.Key.up, .{})) {
                if (try self.recall(.back)) return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.down, .{})) {
                if (try self.recall(.forward)) return ctx.consumeAndRedraw();
            }

            if (self.selection.isActive() and key.text != null) {
                self.selection.clear();
                ctx.redraw = true;
            }

            _ = try self.input.handleEvent(ctx, event);
            try self.refreshMentions();
            try self.awaitMentions(ctx);
            try self.slash.update(self.input.text.items, self.input.cursor);
            if (ctx.consume_event) return;
        },
        else => {},
    }
}

/// Hand the terminal back and stop the process, the way ctrl+z does for any
/// other program.
pub fn suspendToShell(self: *Model) void {
    if (builtin.os.tag == .windows or builtin.is_test) return;
    const app = self.app orelse return;
    const writer = app.tty.writer();

    const in_band_resize = app.vx.state.in_band_resize;

    app.vx.resetState(writer) catch {};
    std.posix.tcsetattr(app.tty.fd.handle, .FLUSH, app.tty.termios) catch {};

    std.posix.raise(std.posix.SIG.TSTP) catch {};

    _ = vaxis.Tty.makeRaw(app.tty.fd.handle) catch {};
    app.vx.enterAltScreen(writer) catch {};
    app.vx.enableDetectedFeatures(writer) catch {};
    app.vx.setMouseMode(writer, true) catch {};
    app.vx.setBracketedPaste(writer, true) catch {};
    app.vx.subscribeToColorSchemeUpdates(writer) catch {};
    if (in_band_resize) {
        writer.writeAll(vaxis.ctlseqs.in_band_resize_set) catch {};
        app.vx.state.in_band_resize = true;
    }
    writer.flush() catch {};

    app.vx.queueRefresh();
}

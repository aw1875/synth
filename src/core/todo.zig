//! The steps a turn is working through.
//!
//! Kept as a list the model rewrites whole rather than one it patches. A model
//! that miscounts an index cannot corrupt state it always replaces, and the
//! alternative - add, update, remove - is three tools and a shared numbering
//! scheme that both sides have to agree on.

const std = @import("std");

/// Steps held for one session. Past this the rest are dropped: a plan longer
/// than this is not a plan.
pub const max_items: usize = 32;

/// Longest step text kept. One line in a narrow sidebar, so anything longer is
/// not going to be read anyway.
pub const max_text_bytes: usize = 120;

pub const Status = enum {
    pending,
    /// The one being worked on. At most one, so the sidebar has something to
    /// show when it is collapsed.
    active,
    done,

    pub fn parse(text: []const u8) ?Status {
        if (std.mem.eql(u8, text, "pending")) return .pending;
        if (std.mem.eql(u8, text, "active")) return .active;
        if (std.mem.eql(u8, text, "in_progress")) return .active;
        if (std.mem.eql(u8, text, "done")) return .done;
        if (std.mem.eql(u8, text, "completed")) return .done;
        return null;
    }

    /// What marks the step in the sidebar.
    pub fn mark(self: Status) []const u8 {
        return switch (self) {
            .pending => "○",
            .active => "◐",
            .done => "●",
        };
    }
};

pub const Item = struct {
    text: []const u8,
    status: Status = .pending,
};

pub const List = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    /// Whether the sidebar shows the whole list or only the step in hand.
    expanded: bool = true,

    pub fn init(allocator: std.mem.Allocator) List {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *List) void {
        self.clear();
        self.items.deinit(self.allocator);
    }

    pub fn clear(self: *List) void {
        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.clearRetainingCapacity();
    }

    /// Take a new list, copying every string. The old one is freed, so what the
    /// model last said is all there is.
    ///
    /// Only the first `active` survives as active: the sidebar collapses to one
    /// step, and a model that marks three at once has told us nothing about
    /// which it is on.
    pub fn replace(self: *List, items: []const Item) !void {
        var next: std.ArrayList(Item) = .empty;
        errdefer {
            for (next.items) |item| self.allocator.free(item.text);
            next.deinit(self.allocator);
        }

        var seen_active = false;
        for (items) |item| {
            if (next.items.len >= max_items) break;

            const trimmed = std.mem.trim(u8, item.text, " \t\r\n");
            if (trimmed.len == 0) continue;

            var status = item.status;
            if (status == .active) {
                if (seen_active) status = .pending;
                seen_active = true;
            }

            const kept = trimmed[0..@min(trimmed.len, max_text_bytes)];
            try next.append(self.allocator, .{
                .text = try self.allocator.dupe(u8, kept),
                .status = status,
            });
        }

        self.clear();
        self.items.deinit(self.allocator);
        self.items = next;
    }

    pub fn any(self: *const List) bool {
        return self.items.items.len > 0;
    }

    /// The step being worked on. Falls back to the first unfinished one, so a
    /// model that never marks anything active still shows progress.
    pub fn current(self: *const List) ?Item {
        for (self.items.items) |item| {
            if (item.status == .active) return item;
        }
        for (self.items.items) |item| {
            if (item.status != .done) return item;
        }
        return null;
    }

    pub fn done(self: *const List) usize {
        var n: usize = 0;
        for (self.items.items) |item| {
            if (item.status == .done) n += 1;
        }
        return n;
    }

    /// Whether every step is finished. What decides if the list is worth any
    /// room at all once a turn ends.
    pub fn finished(self: *const List) bool {
        return self.any() and self.done() == self.items.items.len;
    }
};

const testing = std.testing;

test "a list is replaced whole, and strings are its own" {
    var list: List = .init(testing.allocator);
    defer list.deinit();

    var buffer: [16]u8 = undefined;
    @memcpy(buffer[0..5], "first");

    try list.replace(&.{
        .{ .text = buffer[0..5], .status = .done },
        .{ .text = "second", .status = .active },
        .{ .text = "third" },
    });
    @memset(&buffer, 'x');

    try testing.expectEqual(@as(usize, 3), list.items.items.len);
    try testing.expectEqualStrings("first", list.items.items[0].text);
    try testing.expectEqual(@as(usize, 1), list.done());
    try testing.expectEqualStrings("second", list.current().?.text);

    try list.replace(&.{.{ .text = "only this now", .status = .done }});
    try testing.expectEqual(@as(usize, 1), list.items.items.len);
    try testing.expect(list.finished());
    try testing.expect(list.current() == null);
}

test "only one step can be the one in hand" {
    var list: List = .init(testing.allocator);
    defer list.deinit();

    try list.replace(&.{
        .{ .text = "a", .status = .active },
        .{ .text = "b", .status = .active },
        .{ .text = "c", .status = .active },
    });

    try testing.expectEqual(Status.active, list.items.items[0].status);
    try testing.expectEqual(Status.pending, list.items.items[1].status);
    try testing.expectEqual(Status.pending, list.items.items[2].status);
    try testing.expectEqualStrings("a", list.current().?.text);
}

test "with nothing marked, the first unfinished step is the one in hand" {
    var list: List = .init(testing.allocator);
    defer list.deinit();

    try list.replace(&.{
        .{ .text = "done one", .status = .done },
        .{ .text = "next one" },
        .{ .text = "later one" },
    });

    try testing.expectEqualStrings("next one", list.current().?.text);
    try testing.expect(!list.finished());
}

test "blank steps are dropped and long ones are cut" {
    var list: List = .init(testing.allocator);
    defer list.deinit();

    const long = "x" ** (max_text_bytes * 2);
    try list.replace(&.{
        .{ .text = "  spaced  " },
        .{ .text = "   " },
        .{ .text = long },
    });

    try testing.expectEqual(@as(usize, 2), list.items.items.len);
    try testing.expectEqualStrings("spaced", list.items.items[0].text);
    try testing.expectEqual(max_text_bytes, list.items.items[1].text.len);
}

test "a plan longer than the cap is cut to it" {
    var list: List = .init(testing.allocator);
    defer list.deinit();

    var many: [max_items + 5]Item = undefined;
    for (&many, 0..) |*item, i| {
        _ = i;
        item.* = .{ .text = "step" };
    }

    try list.replace(&many);
    try testing.expectEqual(max_items, list.items.items.len);
}

test "the words a model actually uses for a status are understood" {
    try testing.expectEqual(Status.active, Status.parse("in_progress").?);
    try testing.expectEqual(Status.active, Status.parse("active").?);
    try testing.expectEqual(Status.done, Status.parse("completed").?);
    try testing.expectEqual(Status.done, Status.parse("done").?);
    try testing.expectEqual(Status.pending, Status.parse("pending").?);
    try testing.expect(Status.parse("nope") == null);
}

//! A bounded conversation history for one agent session. The system message is
//! pinned; user/assistant/tool turns accumulate up to a cap, and the oldest
//! non-system turn is dropped (and freed) when the cap is exceeded, so a long
//! chat cannot grow the kernel heap without bound. Content is duplicated on
//! push and owned by the history.

const std = @import("std");
const openrouter = @import("openrouter.zig");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn text(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

const Turn = struct { role: Role, content: []u8 };

pub const History = struct {
    alloc: std.mem.Allocator,
    system: ?[]u8 = null,
    turns: std.array_list.Managed(Turn),
    /// Maximum number of non-system turns retained.
    cap: usize,

    pub fn init(alloc: std.mem.Allocator, cap: usize) History {
        return .{ .alloc = alloc, .turns = std.array_list.Managed(Turn).init(alloc), .cap = cap };
    }

    pub fn deinit(self: *History) void {
        if (self.system) |s| self.alloc.free(s);
        for (self.turns.items) |t| self.alloc.free(t.content);
        self.turns.deinit();
    }

    /// Set (or replace) the pinned system message.
    pub fn setSystem(self: *History, content: []const u8) !void {
        if (self.system) |s| self.alloc.free(s);
        self.system = try self.alloc.dupe(u8, content);
    }

    /// Append a turn, evicting the oldest turn if over cap.
    pub fn push(self: *History, role: Role, content: []const u8) !void {
        const dup = try self.alloc.dupe(u8, content);
        errdefer self.alloc.free(dup);
        try self.turns.append(.{ .role = role, .content = dup });
        while (self.turns.items.len > self.cap) {
            const evicted = self.turns.orderedRemove(0);
            self.alloc.free(evicted.content);
        }
    }

    /// Build the message array for a request: the system message (if set)
    /// followed by every retained turn. Allocated in `arena`.
    pub fn toMessages(self: *const History, arena: std.mem.Allocator) ![]openrouter.Msg {
        const n = self.turns.items.len + @as(usize, if (self.system != null) 1 else 0);
        var msgs = try arena.alloc(openrouter.Msg, n);
        var i: usize = 0;
        if (self.system) |s| {
            msgs[i] = .{ .role = "system", .content = s };
            i += 1;
        }
        for (self.turns.items) |t| {
            msgs[i] = .{ .role = t.role.text(), .content = t.content };
            i += 1;
        }
        return msgs;
    }
};

//! The agent's action budget (spec AGT-012): the stated bound on what one
//! request may spend. Four currencies — model turns, tool invocations, service
//! tokens, and wall-clock time — each charged as it is spent and checked before
//! more is spent. Pure bookkeeping over caller-supplied clock readings, so the
//! kernel (timer.millis) and the host test (a scripted clock) run identical
//! logic. The budget is STATED, not silent: `statement` renders limits and
//! spend in one line, and the loop shows it whenever a bound ends a request.

const std = @import("std");

/// Default per-request bounds. Named so the statement the user reads and the
/// enforcement that stops the loop share one home.
pub const DEFAULT_MAX_TURNS: usize = 8;
pub const DEFAULT_MAX_TOOL_CALLS: usize = 16;
pub const DEFAULT_MAX_TOKENS: usize = 100_000;
pub const DEFAULT_MAX_MS: u64 = 120_000;

/// The stated bounds for one request. A zero is a zero — it forbids that
/// spend — never "unlimited"; there is deliberately no way to run unbounded.
pub const Limits = struct {
    max_turns: usize = DEFAULT_MAX_TURNS,
    max_tool_calls: usize = DEFAULT_MAX_TOOL_CALLS,
    max_tokens: usize = DEFAULT_MAX_TOKENS,
    max_ms: u64 = DEFAULT_MAX_MS,
};

/// A self-improvement run (`ai /improve`) surveys, writes, compiles-with-retry,
/// loads, and exercises — more turns and tools than a chat request, so it gets
/// its own STATED bound rather than silently widening the default one.
pub const IMPROVE_LIMITS = Limits{
    .max_turns = 24,
    .max_tool_calls = 48,
    .max_tokens = 400_000,
    .max_ms = 600_000,
};

/// Which bound ran out.
pub const Exhausted = enum {
    turns,
    tool_calls,
    tokens,
    time,

    pub fn label(self: Exhausted) []const u8 {
        return switch (self) {
            .turns => "model turns",
            .tool_calls => "tool calls",
            .tokens => "tokens",
            .time => "time",
        };
    }
};

pub const Budget = struct {
    limits: Limits,
    started_ms: u64,
    turns: usize = 0,
    tool_calls: usize = 0,
    tokens: usize = 0,

    pub fn init(limits: Limits, now_ms: u64) Budget {
        return .{ .limits = limits, .started_ms = now_ms };
    }

    /// Charge one model round-trip; the exhausted bound instead when none is left.
    pub fn chargeTurn(self: *Budget) ?Exhausted {
        if (self.turns >= self.limits.max_turns) return .turns;
        self.turns += 1;
        return null;
    }

    /// Charge one tool invocation; the exhausted bound instead when none is left.
    pub fn chargeToolCall(self: *Budget) ?Exhausted {
        if (self.tool_calls >= self.limits.max_tool_calls) return .tool_calls;
        self.tool_calls += 1;
        return null;
    }

    /// Record tokens the service reported for a completed turn (usage.total_tokens).
    pub fn chargeTokens(self: *Budget, n: usize) void {
        self.tokens += n;
    }

    /// The bound already exceeded by past spend, or null while within budget.
    /// Checked before every turn, so token/time overruns stop the NEXT spend —
    /// an in-flight turn is never aborted mid-response.
    pub fn over(self: *const Budget, now_ms: u64) ?Exhausted {
        if (self.tokens >= self.limits.max_tokens) return .tokens;
        if (now_ms - self.started_ms >= self.limits.max_ms) return .time;
        return null;
    }

    /// One line stating the budget and the spend against it.
    pub fn statement(self: *const Budget, now_ms: u64, buf: []u8) []const u8 {
        return std.fmt.bufPrint(
            buf,
            "turns {d}/{d}, tools {d}/{d}, tokens {d}/{d}, time {d}/{d} s",
            .{
                self.turns,                                     self.limits.max_turns,
                self.tool_calls,                                self.limits.max_tool_calls,
                self.tokens,                                    self.limits.max_tokens,
                (now_ms - self.started_ms) / std.time.ms_per_s, self.limits.max_ms / std.time.ms_per_s,
            },
        ) catch buf[0..0];
    }
};

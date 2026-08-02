//! Host tests of src/agent/budget.zig — the agent's stated action budget
//! (spec AGT-012): charging order, each bound's exhaustion, and the statement
//! line that makes an exhaustion loud.

const std = @import("std");
const budget = @import("budget");

test "turns and tool calls charge until their bound, then refuse" {
    var b = budget.Budget.init(.{ .max_turns = 2, .max_tool_calls = 1 }, 0);
    try std.testing.expect(b.chargeTurn() == null);
    try std.testing.expect(b.chargeTurn() == null);
    try std.testing.expectEqual(budget.Exhausted.turns, b.chargeTurn().?);
    // A refused charge spends nothing.
    try std.testing.expectEqual(@as(usize, 2), b.turns);

    try std.testing.expect(b.chargeToolCall() == null);
    try std.testing.expectEqual(budget.Exhausted.tool_calls, b.chargeToolCall().?);
    try std.testing.expectEqual(@as(usize, 1), b.tool_calls);
}

test "token and time bounds trip `over`, in that order" {
    var b = budget.Budget.init(.{ .max_tokens = 100, .max_ms = 1_000 }, 500);
    try std.testing.expect(b.over(500) == null);

    // Time measures from the start reading, not from zero.
    try std.testing.expect(b.over(1_499) == null);
    try std.testing.expectEqual(budget.Exhausted.time, b.over(1_500).?);

    // Tokens at the bound exhaust it; tokens outrank time in the report.
    b.chargeTokens(60);
    try std.testing.expect(b.over(600) == null);
    b.chargeTokens(40);
    try std.testing.expectEqual(budget.Exhausted.tokens, b.over(600).?);
    try std.testing.expectEqual(budget.Exhausted.tokens, b.over(2_000).?);
}

test "a zero limit forbids the spend — there is no unlimited" {
    var b = budget.Budget.init(.{ .max_turns = 0, .max_tokens = 0 }, 0);
    try std.testing.expectEqual(budget.Exhausted.turns, b.chargeTurn().?);
    try std.testing.expectEqual(budget.Exhausted.tokens, b.over(0).?);
}

test "the statement states limits and spend in one line" {
    var b = budget.Budget.init(.{ .max_turns = 8, .max_tool_calls = 16, .max_tokens = 100_000, .max_ms = 120_000 }, 1_000);
    _ = b.chargeTurn();
    _ = b.chargeToolCall();
    _ = b.chargeToolCall();
    b.chargeTokens(1_234);
    var buf: [128]u8 = undefined;
    const s = b.statement(9_000, &buf);
    try std.testing.expectEqualStrings("turns 1/8, tools 2/16, tokens 1234/100000, time 8/120 s", s);
}

test "exhaustion labels name the bound in user language" {
    try std.testing.expectEqualStrings("model turns", budget.Exhausted.turns.label());
    try std.testing.expectEqualStrings("tool calls", budget.Exhausted.tool_calls.label());
    try std.testing.expectEqualStrings("tokens", budget.Exhausted.tokens.label());
    try std.testing.expectEqualStrings("time", budget.Exhausted.time.label());
}

test "improve limits are stated, bounded, and wider than a chat request" {
    const chat = budget.Limits{};
    const imp = budget.IMPROVE_LIMITS;
    // Wider on every currency — an improve run does more than a chat turn.
    try std.testing.expect(imp.max_turns > chat.max_turns);
    try std.testing.expect(imp.max_tool_calls > chat.max_tool_calls);
    try std.testing.expect(imp.max_tokens > chat.max_tokens);
    try std.testing.expect(imp.max_ms > chat.max_ms);
    // Still bounded — no currency is unlimited (a zero would forbid; none is 0).
    try std.testing.expect(imp.max_turns != 0 and imp.max_tool_calls != 0);
    try std.testing.expect(imp.max_tokens != 0 and imp.max_ms != 0);
}

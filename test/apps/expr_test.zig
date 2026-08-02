//! The TI-82-style calculator evaluator (spec APP-015). Host tests of src/apps/expr.zig — parse + eval of calculator expressions.

const std = @import("std");
const expr = @import("expr");
const expect = std.testing.expect;

fn evalStr(src: []const u8, x: f64) !f64 {
    switch (expr.parse(src)) {
        .ok => |prog| return expr.eval(&prog, x),
        .err => return error.ParseFailed,
    }
}

fn approx(a: f64, b: f64) bool {
    return @abs(a - b) < 1e-9;
}

test "precedence: mul binds tighter than add, pow tighter than mul" {
    try expect(approx(try evalStr("2+3*4", 0), 14));
    try expect(approx(try evalStr("2*3^2", 0), 18));
    try expect(approx(try evalStr("(2+3)*4", 0), 20));
}

test "power is right-associative" {
    try expect(approx(try evalStr("2^3^2", 0), 512));
}

test "unary minus and subtraction" {
    try expect(approx(try evalStr("-3+5", 0), 2));
    try expect(approx(try evalStr("2--3", 0), 5));
    try expect(approx(try evalStr("-2^2", 0), -4)); // -(2^2): pow binds tighter than unary minus
}

test "variable x and constants" {
    try expect(approx(try evalStr("2*x+1", 3), 7));
    try expect(approx(try evalStr("cos(pi)", 0), -1));
    try expect(approx(try evalStr("ln(e)", 0), 1));
    switch (expr.parse("x*x")) {
        .ok => |p| try expect(p.uses_x),
        .err => return error.ParseFailed,
    }
    switch (expr.parse("1+2")) {
        .ok => |p| try expect(!p.uses_x),
        .err => return error.ParseFailed,
    }
}

// APP-016: the calculator evaluates scientific functions and constants.
test "functions" {
    try expect(approx(try evalStr("sqrt(16)", 0), 4));
    try expect(approx(try evalStr("abs(-7)", 0), 7));
    try expect(approx(try evalStr("log(1000)", 0), 3));
    try expect(approx(try evalStr("sin(0)", 0), 0));
}

test "domain errors evaluate to NaN/inf, not a crash" {
    try expect(std.math.isNan(try evalStr("sqrt(-1)", 0)));
    try expect(std.math.isInf(try evalStr("1/0", 0)));
}

test "parse errors carry a position and reject trailing garbage" {
    switch (expr.parse("2+*3")) {
        .ok => return error.ShouldHaveFailed,
        .err => |e| try expect(e.pos == 2),
    }
    switch (expr.parse("1+2 junk")) {
        .ok => return error.ShouldHaveFailed,
        .err => |e| try expect(e.pos >= 4),
    }
    switch (expr.parse("")) {
        .ok => return error.ShouldHaveFailed,
        .err => {},
    }
    switch (expr.parse("nope(3)")) {
        .ok => return error.ShouldHaveFailed,
        .err => {},
    }
    switch (expr.parse("sin 3")) {
        .ok => return error.ShouldHaveFailed,
        .err => {},
    }
}

//! Expression engine — the calculator's pure half (imports only std). Parses
//! one arithmetic expression into a fixed-size postfix program and evaluates
//! it for a given `x`. No allocation: the program is a bounded array, parse
//! errors are VALUES carrying the offending position, and domain errors
//! evaluate to NaN (the plot treats NaN as a gap).
//!
//! Grammar (precedence climbing, tightest last):
//!   expr    := term (('+'|'-') term)*
//!   term    := unary (('*'|'/') unary)*
//!   unary   := '-' unary | power
//!   power   := atom ('^' unary)?          (right-associative)
//!   atom    := NUMBER | 'x' | 'pi' | 'e' | FN '(' expr ')' | '(' expr ')'
//!   FN      := sin cos tan sqrt log ln abs

const std = @import("std");

/// Upper bound on postfix ops per expression. An op is at most a few source
/// characters, so this covers any line a terminal-width entry field can hold.
pub const MAX_OPS: usize = 96;

pub const Fn = enum { sin, cos, tan, sqrt, log, ln, abs };

pub const Op = union(enum) {
    push: f64,
    x,
    add,
    sub,
    mul,
    div,
    pow,
    neg,
    call: Fn,
};

pub const Program = struct {
    code: [MAX_OPS]Op = undefined,
    len: usize = 0,
    /// Whether the expression references the variable `x` (a plottable function).
    uses_x: bool = false,
};

/// A parse failure: where, and a short fixed message.
pub const ParseError = struct { pos: usize, msg: []const u8 };

pub const ParseResult = union(enum) { ok: Program, err: ParseError };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    prog: Program = .{},
    err: ?ParseError = null,

    fn fail(self: *Parser, pos: usize, msg: []const u8) void {
        if (self.err == null) self.err = .{ .pos = pos, .msg = msg };
    }

    fn emit(self: *Parser, op: Op) void {
        if (self.prog.len >= MAX_OPS) {
            self.fail(self.pos, "expression too long");
            return;
        }
        self.prog.code[self.prog.len] = op;
        self.prog.len += 1;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] == ' ') self.pos += 1;
    }

    fn peek(self: *Parser) ?u8 {
        self.skipSpaces();
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn eat(self: *Parser, ch: u8) bool {
        if (self.peek() == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn isIdentChar(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    }

    fn isDigit(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }

    fn parseExpr(self: *Parser) void {
        self.parseTerm();
        while (self.err == null) {
            if (self.eat('+')) {
                self.parseTerm();
                self.emit(.add);
            } else if (self.eat('-')) {
                self.parseTerm();
                self.emit(.sub);
            } else break;
        }
    }

    fn parseTerm(self: *Parser) void {
        self.parseUnary();
        while (self.err == null) {
            if (self.eat('*')) {
                self.parseUnary();
                self.emit(.mul);
            } else if (self.eat('/')) {
                self.parseUnary();
                self.emit(.div);
            } else break;
        }
    }

    fn parseUnary(self: *Parser) void {
        if (self.eat('-')) {
            self.parseUnary();
            self.emit(.neg);
            return;
        }
        self.parsePower();
    }

    fn parsePower(self: *Parser) void {
        self.parseAtom();
        if (self.err != null) return;
        if (self.eat('^')) {
            // Right-associative: 2^3^2 = 2^(3^2).
            self.parseUnary();
            self.emit(.pow);
        }
    }

    fn parseNumber(self: *Parser) void {
        const start = self.pos;
        while (self.pos < self.src.len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '.')) self.pos += 1;
        const v = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch {
            self.fail(start, "bad number");
            return;
        };
        self.emit(.{ .push = v });
    }

    fn parseIdent(self: *Parser) void {
        const start = self.pos;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
        const name = self.src[start..self.pos];

        if (std.mem.eql(u8, name, "x")) {
            self.prog.uses_x = true;
            self.emit(.x);
            return;
        }
        if (std.mem.eql(u8, name, "pi")) {
            self.emit(.{ .push = std.math.pi });
            return;
        }
        if (std.mem.eql(u8, name, "e")) {
            self.emit(.{ .push = std.math.e });
            return;
        }
        const f: Fn = inline for (@typeInfo(Fn).@"enum".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) break @field(Fn, field.name);
        } else {
            self.fail(start, "unknown name");
            return;
        };
        if (!self.eat('(')) {
            self.fail(self.pos, "expected ( after function");
            return;
        }
        self.parseExpr();
        if (!self.eat(')')) {
            self.fail(self.pos, "expected )");
            return;
        }
        self.emit(.{ .call = f });
    }

    fn parseAtom(self: *Parser) void {
        const ch = self.peek() orelse {
            self.fail(self.pos, "unexpected end");
            return;
        };
        if (isDigit(ch) or ch == '.') {
            self.parseNumber();
        } else if (isIdentChar(ch)) {
            self.parseIdent();
        } else if (self.eat('(')) {
            self.parseExpr();
            if (!self.eat(')')) self.fail(self.pos, "expected )");
        } else {
            self.fail(self.pos, "unexpected character");
        }
    }
};

/// Parse one expression. The whole input must be consumed — trailing garbage
/// is an error, not silently ignored.
pub fn parse(src: []const u8) ParseResult {
    var p = Parser{ .src = src };
    p.parseExpr();
    if (p.err == null) {
        p.skipSpaces();
        if (p.pos != p.src.len) p.fail(p.pos, "unexpected character");
    }
    if (p.err) |e| return .{ .err = e };
    if (p.prog.len == 0) return .{ .err = .{ .pos = 0, .msg = "empty expression" } };
    return .{ .ok = p.prog };
}

/// Evaluate a parsed program at `x`. Domain errors (log of a negative, 0/0)
/// follow IEEE semantics into NaN/inf — the caller renders those as gaps.
pub fn eval(prog: *const Program, x: f64) f64 {
    var stack: [MAX_OPS]f64 = undefined;
    var sp: usize = 0;
    for (prog.code[0..prog.len]) |op| {
        switch (op) {
            .push => |v| {
                stack[sp] = v;
                sp += 1;
            },
            .x => {
                stack[sp] = x;
                sp += 1;
            },
            .neg => stack[sp - 1] = -stack[sp - 1],
            .call => |f| stack[sp - 1] = switch (f) {
                .sin => @sin(stack[sp - 1]),
                .cos => @cos(stack[sp - 1]),
                .tan => @tan(stack[sp - 1]),
                .sqrt => @sqrt(stack[sp - 1]),
                .log => @log10(stack[sp - 1]),
                .ln => @log(stack[sp - 1]),
                .abs => @abs(stack[sp - 1]),
            },
            .add, .sub, .mul, .div, .pow => {
                const b = stack[sp - 1];
                const a = stack[sp - 2];
                sp -= 1;
                stack[sp - 1] = switch (op) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => a / b,
                    .pow => std.math.pow(f64, a, b),
                    else => unreachable,
                };
            },
        }
    }
    return stack[0];
}

//! `echo [-n] TEXT` — print TEXT (with `-n`, no trailing newline). TEXT prints
//! VERBATIM, spacing included — this is the command that types source code into
//! files, and a bash-faithful word split would collapse the indentation it is
//! preserving. One whole-argument quote pair strips, and only that: the hatch
//! that lets a line CARRYING `;`/`|`/`>` be typed at all
//! (`echo 'const a = 1;' >> f.zig` — see redirect.zig's grammar).

const std = @import("std");
const console = @import("../console.zig");

pub fn run(c: console.Console, args: []const u8) void {
    var text = args;
    var newline = true;
    if (std.mem.eql(u8, text, "-n")) {
        newline = false;
        text = "";
    } else if (std.mem.startsWith(u8, text, "-n ")) {
        newline = false;
        text = std.mem.trimStart(u8, text[3..], " \t");
    }
    if (text.len >= 2 and (text[0] == '\'' or text[0] == '"')) {
        // Strip the pair only when the opening quote's CLOSE is the final
        // character — `echo 'a' 'b'` is not one quoted argument.
        if (std.mem.indexOfScalarPos(u8, text, 1, text[0])) |close| {
            if (close == text.len - 1) text = text[1 .. text.len - 1];
        }
    }
    c.write(text);
    if (newline) c.put('\n');
}

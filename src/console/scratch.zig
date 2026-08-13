//! The working space one command LINE needs while it runs: the bounce buffers a
//! piped stage's output passes through, the capture a redirection fills before
//! it writes its file, and the expansion of a globbing stage's arguments.
//!
//! One block PER TERMINAL, because terminals run their commands at the same time
//! (spec APP-031). A single shared set would let one terminal's stage overwrite
//! the bytes another terminal's stage is still reading — two windows quietly
//! producing each other's output, with nothing in either one to show it
//! happened.
//!
//! The block is the TERMINAL's (apps/terminal.zig allocates one per window), not
//! the command's, and that is what makes it safe to hand to a command that
//! outlives its invocation: a backgrounded transfer's late write lands in the
//! terminal it belongs to, whose lifetime the Console contract already states
//! (console.zig), rather than on a stack frame that has since been reused.

const redirect = @import("redirect.zig");

/// Most bytes one stage's glob expansion may produce. A line that expands past
/// it is refused rather than truncated: running a command on a silently
/// shortened file list is how a glob deletes the wrong files.
pub const EXPAND_BYTES: usize = 4096;

/// One terminal's command-line working space.
pub const Scratch = struct {
    /// A redirected stage's whole output, held until it is written to the file
    /// the line named (APP-028).
    capture: [redirect.MAX_BYTES]u8 = undefined,
    /// The pipe bounce buffers. Two, used alternately, so a stage's input stays
    /// intact while its output fills the other.
    pipe: [2][redirect.MAX_BYTES]u8 = undefined,
    /// The glob expansion of one stage's arguments.
    expand: [EXPAND_BYTES]u8 = undefined,
};

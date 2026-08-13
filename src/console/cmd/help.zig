//! `help` — the built-in command list.

const console = @import("../console.zig");

const HELP =
    \\commands:
    \\  help            this list
    \\  clear           clear the screen
    \\  echo TEXT       print TEXT
    \\  pwd             print the working directory
    \\  cd [PATH]       change directory (no arg: print it); / holds the mounts
    \\  ls [PATH...]    list a directory (default: the current one)
    \\  cat FILE...     print files
    \\  head [-n N] [F] first N lines (default 10) of a file or the pipe
    \\  grep PAT [F...] lines containing PAT, from files or the pipe (fixed string)
    \\  wc [FILE...]    line, word and byte counts
    \\  touch FILE...   create empty files
    \\  cp SRC... DEST  copy files
    \\  mv SRC... DEST  move files
    \\  rm FILE...      delete files
    \\  mkdir DIR...    create directories
    \\  rmdir DIR...    remove empty directories
    \\  ip [addr|route] the leased address configuration
    \\  ping HOST       four ICMP echo requests
    \\  host NAME       resolve a hostname
    \\  curl [-o F] URL HTTP GET; print the body, or save it with -o
    \\  free            physical RAM, and what the sessions hold
    \\  ps              list cores, their CPU %, and the tasks on each
    \\  lspci           list pci devices
    \\  uname [-a]      what this machine runs
    \\  uptime          time since boot
    \\  kudos SUB       everything kudos-specific: ai, compile, run, vm, caps,
    \\                  feature, show, stats, flipstat, background, term, system,
    \\                  clock, calc, prime, rt  (`kudos` alone lists them)
    \\  shutdown        power the machine off
    \\  reboot          restart the machine
    \\  exit            close this terminal window
    \\
    \\pipes and files (any command above):
    \\  CMD | CMD       the left command's output is the right one's input
    \\  CMD > FILE      write the output to FILE instead of the screen
    \\  CMD >> FILE     add the output to the end of FILE
    \\                  so a program can be typed and then compiled:
    \\                  echo const abi = @import("abi.zig"); > app.zig
    \\                  echo pub fn main(api: *const abi.Api) i32 { >> app.zig
    \\  *  ?            glob in file arguments (ls *.zig); text elsewhere
    \\
    \\shortcuts (work anywhere):
    \\  F12             open a new terminal
    \\  F10             open the AI agent window
    \\
;

/// `help` — print the built-in command list.
pub fn run(c: console.Console, _: []const u8) void {
    c.write(HELP);
}

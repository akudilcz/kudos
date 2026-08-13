//! `help` — the built-in command list.

const console = @import("../console.zig");

const HELP =
    \\commands:
    \\  help            this list
    \\  clear           clear the screen
    \\  echo [-n] TEXT  print TEXT
    \\  pwd             print the working directory
    \\  cd [PATH]       change directory (no arg: print it); / holds the mounts
    \\  ls [-alh] [PATH...]     list a directory (default: the current one)
    \\  cat [-n] FILE...        print files
    \\  head [-n N|-c N] [F]    first lines (default 10) of a file or the pipe
    \\  tail [-n N|-c N] [F...] last lines (default 10) of a file or the pipe
    \\  more|less [FILE...]     print files (the window keeps the scrollback)
    \\  nl [-b a|t] [FILE...]   number the lines
    \\  grep [-ivnc] PAT [F...] lines containing PAT (fixed string)
    \\  wc [-lwc] [FILE...]     line, word and byte counts
    \\  sort [-rnuf] [-k N] [-t C] [FILE]       order the lines
    \\  uniq [-cdui] [FILE]     collapse ADJACENT repeated lines
    \\  cut -f LIST [-d C] | -c LIST [FILE]     the named fields or characters
    \\  tee [-a] FILE...        write the pipe to files AND on to the terminal
    \\  diff [-q] FILE1 FILE2   the lines that differ
    \\  xxd [-l N] [-s N] [-p] [F]      hex dump
    \\  history [-c]    the commands Up-arrow can recall; -c forgets them
    \\  touch FILE...   create empty files
    \\  cp [-r] SRC... DEST     copy files (and directories with -r)
    \\  mv SRC... DEST  move files and directories
    \\  rm [-rf] FILE...        delete files (and directories with -r)
    \\  mkdir [-p] DIR...       create directories (-p: parents too)
    \\  rmdir DIR...    remove empty directories
    \\  find [PATH] [-name|-iname PAT] [-type f|d] [-maxdepth N]  paths in a tree
    \\  stat [-c FMT] FILE...   what a name is, its size and line count
    \\  du [-hsac] [PATH...]    bytes a tree holds
    \\  df [-h]         what each mounted store holds
    \\  basename [-a] [-s SUF] PATH... / dirname PATH...  the halves of a path
    \\  seq [-s SEP] [FIRST [STEP]] LAST        a run of integers
    \\  sleep N[ms|s|m|h]       wait (this terminal only; ^C ends it)
    \\  ip [addr|route] the leased address configuration
    \\  ping [-c N] [-i S] HOST ICMP echo requests (default 4)
    \\  host NAME       resolve a hostname
    \\  curl [-s] [-o F] URL    HTTP GET; print the body, or save it with -o
    \\  free [-h]       physical RAM, and what the sessions hold
    \\  ps              list cores, their CPU %, and the tasks on each
    \\  lspci           list pci devices
    \\  uname [-asnrvm] what this machine runs
    \\  uptime          time since boot
    \\  kudos SUB       everything kudos-specific: ai, compile, run, vm, caps,
    \\                  feature, show, stats, flipstat, background, term, system,
    \\                  clock, calc, prime, rt  (`kudos` alone lists them)
    \\  shutdown        power the machine off
    \\  reboot          restart the machine
    \\  exit            close this terminal window
    \\
    \\pipes `a | b`, lists `a; b`, redirects `> >>`, globs `* ?` and quotes '…'
    \\work everywhere; F12 new terminal, F10 the agent; Shift-PgUp scrolls back.
    \\
;

/// `help` — print the built-in command list.
pub fn run(c: console.Console, _: []const u8) void {
    c.write(HELP);
}

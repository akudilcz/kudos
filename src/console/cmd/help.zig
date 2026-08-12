//! `help` — the built-in command list.

const console = @import("../console.zig");

const HELP =
    \\commands:
    \\  help            this list
    \\  clear           clear the screen
    \\  echo TEXT       print TEXT
    \\  cd [PATH]       change directory (no arg: print it); / holds the mounts
    \\  ls [PATH]       list a directory (default: the current one; alias: dir)
    \\  cat PATH        print a file
    \\  rm PATH         delete a file
    \\  lspci           list pci devices
    \\  net SUBCOMMAND  network: ip | dns NAME | ping HOST | fetch URL [NAME]
    \\  mem             free / total RAM
    \\  ps              list cores, their CPU %, and the tasks on each
    \\  prime N         load THIS core: find primes until one >= N (bigger N = longer)
    \\  rt N            real-time task on THIS core: N periods at 10 Hz, reports jitter/drift
    \\  term            open a new terminal app
    \\  system          open the system monitor app
    \\  clock           open the analog clock app
    \\  calc            open the graphing calculator app
    \\  background PATH change the desktop background (.png, e.g. from /usbdisk)
    \\  show PATH [max] open a spinning 3D model window (.glb; max: maximised)
    \\  vm [N]          guest VMs: N boots image N | list | status | stop ID
    \\  ai [PROMPT]     talk to the AI agent (or /help inside for its commands)
    \\  compile SRC [N] compile a .zig file into a .kudos app named N
    \\  run NAME        run a loaded .kudos application module
    \\  caps            what a .kudos module may bind: the published capabilities
    \\  feature SUB     manage loaded .kudos feature modules (feature help)
    \\  flipstat        re-arm the present-cadence sample (-Dflip-sample builds):
    \\                  measures the CURRENT scene, verdict over netdebug in ~13 s
    \\  stats [PREFIX]  diagnostics counters (all, or only keys starting with PREFIX)
    \\  exit            close this terminal window
    \\  shutdown        power the machine off
    \\  reboot          restart the machine
    \\
    \\redirection (any command above):
    \\  CMD > FILE      write the output to FILE instead of the screen
    \\  CMD >> FILE     add the output to the end of FILE
    \\                  so a program can be typed and then compiled:
    \\                  echo const abi = @import("abi.zig"); > app.zig
    \\                  echo pub fn main(api: *const abi.Api) i32 { >> app.zig
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

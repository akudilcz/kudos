//! `flipstat` — re-arm the present-cadence sample (-Dflip-sample builds).

const iaccel = @import("iaccel"); // the GPU-acceleration seam (flipstat re-arms a measurement)
const console = @import("../console.zig");

/// `flipstat` — start a fresh measurement of how steadily frames are reaching the
/// monitor, so it measures the scene AS IT IS NOW (say, after `show`-ing five spinning
/// models) rather than the empty boot-time desktop. The verdict arrives over the trace
/// bus about 13 seconds later.
///
/// Only measurement builds carry the sampling code. On any other build the command says
/// so rather than printing a reassuring message and doing nothing.
pub fn run(c: console.Console, _: []const u8) void {
    const rearm = iaccel.accel.rearm_flip_sample orelse {
        c.write("error: no GPU present path is running\n");
        return;
    };
    if (rearm()) {
        c.write("flipstat: sampling re-armed; FLIPSTAT verdict over netdebug in ~13 s\n");
    } else {
        c.write("error: not a measurement build (rebuild with -Dflip-sample=true)\n");
    }
}

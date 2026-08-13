---
name: hardware-run
description: Run kudos on the real RTX 4090 (lemon) — netboot flow, rigging for passthrough, driving it over netdebug, and recovering a wedged box.
---

# Running on real hardware

**The dev laptop has no RTX 4090 and no reference USB stick.** Passthrough and `make rig` can
never run locally; the 4090 lives in lemon. Anything that needs real pixels, real HID timing,
real igc, or 32 cores goes to lemon, and it is the last rung of the ladder, not the first.

## Find lemon first

Its address has moved more than once, so verify rather than trust a number:

    ssh lemon 'hostname -I'

`~/.ssh/config` carries the HostName. Scripts that pin an address take a `LEMON_IP` override.

## Netboot: the normal path

lemon fetches the build from the laptop; nothing is staged on lemon, and any reset falls back
to Ubuntu on its own — so a bad build cannot strand it permanently.

    make netboot                       # stage build/netboot/
    make netboot-serve                 # proxyDHCP + TFTP + HTTP
    make lemon DO=boot                 # one-shot netboot into the current build
    make lemon DO=status               # is it up?
    make netboot-log                   # the DHCP/TFTP/HTTP conversation

`scripts/netboot/mknetboot.sh` takes the kernel variant: `kudos` is the single-core image,
`kudos-smp` the SMP one. Staging the wrong one is a classic false negative — a single-core
image's native-GPU boot never pumps the VM, so guests look dead when the kernel is simply not
the one under test.

Drive the running machine with the `kudos-netdebug` MCP tools (`netdebug_tail`,
`netdebug_screenshot`, `netdebug_inject_key`, `netdebug_select_window`), then
`netdebug_kudos_reboot` to end. Injected keys reach kudos terminal windows only — a guest VM
window swallows them, so anything typed inside a guest needs a real keyboard.

## Passthrough: when you need the desktop under QEMU on lemon

    ssh lemon
    scripts/gpu/rig.sh --take-display   # non-interactive consent flag; `make rig` refuses from a script
    …run the suite…
    sudo make stop                      # restore the desktop, release the 4090

Sync lemon's checkout first, and `git checkout -- BUILD_NUMBER` before pulling — it is a
generated counter and will always conflict.

## The gates that need hardware

`make check-hw` demands the native tracks (boot-1/2/3-native) on the tree making the claim.
`make test-models` sweeps every `.glb` on the stick through a live kudos. A K1 claim is not
"met" until the hardware rung ran — QEMU green is not the same statement.

## Recovery

A CPU fault reboots itself (the crash-hold path), and the one-shot boot lands back in Ubuntu.
A **hang** is different: no netdebug, no KMR1 request/response, and no remote reset — only a
physical power cycle recovers it. Symptom to recognise: heartbeats normal, then abrupt silence
with no panic in the trace.

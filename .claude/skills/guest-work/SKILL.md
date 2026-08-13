---
name: guest-work
description: Build, bake and run the Linux guests kudos hosts — one builder script, the acceptance gate, and the traps that cost the most time.
---

# Guest work

kudos runs Linux guests under its own hypervisor. The catalog is
`src/kernel/virt/guestlist.zig`; entry 1 is the staged busybox guest that `make test-guest-qemu`
boots, and the rest are self-built images.

## One builder, subcommands

    scripts/virt/build_guest.sh <staged|firefox|zigserver|ubuntu>
    scripts/virt/test_guest.sh  <image>      # acceptance: boots the pair under plain QEMU

For `zigserver` the acceptance gate also compiles a sample through the guest's factory and
checks the answer is a KDOS blob — that is the real proof, not "it booted".

All networked images share **one** proven kernel fragment (`write_net_fragment` in the builder).
It keeps `CONFIG_PCI`/`VIRTIO_PCI` — not for kudos, which has no PCI bus for guests, but because
the host acceptance test rides q35 + virtio-net-pci.

## Baking into the image

    zig build ... -Dbake=<csv|all>

Baked pairs start with no download and `vm list` says "(in this image)". They are published at
`/ramdisk/virt/<id>/` by borrowing the `.rodata` bytes rather than copying hundreds of MB.
Sizes are large: `-Dbake=zigserver` takes the ISO to ~183 MB.

## Running one

`vm boot <n>` is a **local** command — `#1> vm boot 3` runs the guest dedicated on that
terminal's core. `make test-guest-qemu` is the laptop-friendly nested path and needs no GPU, no
stick and no lemon.

## Traps already paid for

- **`make clean` drops the staged guest.** It deletes `assets/virt/bzImage` and
  `initramfs.cpio.gz`, so `vm boot 1` then answers "no guest image staged in this build". The
  catalog guests live in their own directories and survive.
- **The guest carries its own copy of the factory harness.** Patching a live guest takes effect
  on the next compile because the factory re-reads it, but it does **not** survive the guest's
  reboot — the image needs rebuilding. Any `abi.zig` change requires a guest rebuild.
- **Build `-Dtest-hooks` to see anything.** That mirrors the guest serial console onto the kudos
  trace bus as `vm0:` lines, readable over netdebug. Without it the guest console exists only
  inside a small VM window that does not scroll.
- **First compile after boot is slow by design.** The zigserver guest warms its build cache in
  `/init` (~180 s) and prints "build cache warm at Ns"; every compile after is under a second.
  Its per-compile budget is 180 s in the guest against 30 s on the host.
- **Memory matters**: 2048 MB made the guest reset connections under a concurrent compile;
  3072 MB is the size.
- **Injected keys never reach a guest window** — only a real keyboard does.

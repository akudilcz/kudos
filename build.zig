const std = @import("std");

pub fn build(b: *std.Build) void {
    // build/ is the single output tree. Sanctioned callers (Makefile, scripts/)
    // pass `-p build --cache-dir build/.zig-cache`; a caller on the defaults —
    // a bare `zig build`, or ZLS introspecting this script — is redirected
    // rather than refused: the zig-out/ install prefix becomes build/ here, and
    // the default .zig-cache/ path is a symlink to build/.zig-cache kept by
    // `make setup`/`make clean` (the CLI creates its cache dir before this
    // script runs, so a symlink is the only way to redirect the default cache).
    if (std.mem.eql(u8, std.fs.path.basename(b.install_prefix), "zig-out")) {
        const prefix = b.build_root.join(b.allocator, &.{"build"}) catch @panic("OOM");
        b.resolveInstallPrefix(prefix, .{});
    }

    // ReleaseFast ALWAYS unless -Ddebug=true: the per-frame full-screen
    // recomposite + MMIO present is far too slow under Debug's per-pixel safety
    // checks (visible cursor lag on real HW; 15+ second glass-composite stalls
    // in the integration suite — found 2026-07-11 when the suite timed out on a
    // "silent" kernel that was just compositing at Debug speed).
    // NOT standardOptimizeOption: on this Zig it registers `-Drelease=[bool]`
    // and silently defaults to DEBUG when the flag is absent — the
    // `.preferred_optimize_mode = .ReleaseFast` only applies once the user opts
    // into --release. Every default `make start`/`make test` image was Debug.
    // An explicit boolean keeps the real configuration visible (no implicit
    // defaults): plain builds are ReleaseFast, `-Ddebug=true` builds Debug.
    const debug_build = b.option(bool, "debug", "Build Debug (slow; per-pixel safety checks) instead of ReleaseFast") orelse false;
    const optimize: std.builtin.OptimizeMode = if (debug_build) .Debug else .ReleaseFast;

    // Freestanding x86_64 kernel target: SSE2 enabled (x86-64 baseline) so the
    // pixel-copy loops vectorize into xmm stores; FPU/SSE state is saved across
    // interrupts (fxsave in src/kernel/boot/isr.asm). AVX/AVX2/MMX stay off so a 512-byte
    // fxsave is a complete state save.
    const Feature = std.Target.x86.Feature;
    var sub = std.Target.Cpu.Feature.Set.empty;
    sub.addFeature(@intFromEnum(Feature.mmx));
    sub.addFeature(@intFromEnum(Feature.avx));
    sub.addFeature(@intFromEnum(Feature.avx2));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = sub,
    });

    // Build identity: bump BUILD_NUMBER and capture the git
    // commit at configure time. b.run executes the script now (not as a graph
    // step) so its stdout — "<number> <githash>" — is available as comptime
    // values. Bumped ONCE per `zig build` and shared by both kernel variants so
    // kudos and kudos-smp from the same invocation carry the same build number.
    const stamp = std.mem.trim(u8, b.run(&.{"scripts/build/bump-build.sh"}), " \r\n");
    var stamp_it = std.mem.tokenizeScalar(u8, stamp, ' ');
    const build_number = std.fmt.parseInt(u32, stamp_it.next() orelse "0", 10) catch
        @panic("bump-build.sh did not print a build number");
    const git_hash = b.dupe(stamp_it.next() orelse "unknown");
    const build_time = b.dupe(stamp_it.next() orelse @panic("bump-build.sh did not print a build timestamp"));

    // The Linux guest staged for the VM subsystem (scripts/virt/build_guest.sh →
    // assets/virt/, git-ignored and optional). When both artifacts are present
    // they are embedded (gueststage.zig); when absent — a tree that never ran the
    // guest build — empty blobs are wired instead so the kernel still compiles and
    // `vm boot` reports no guest is staged. A generated empty file is the stand-in
    // (b.path of a missing file would fail the embed at compile time).
    // WHICH guest is staged: `-Dguest=<name>` picks assets/virt/<name>/ (what
    // `build_guest.sh <name>` produces), and the default is the busybox pair
    // `build_guest.sh staged` drops at the top of assets/virt/. Staging is
    // how a guest boots with NO download: the image is in memory the moment
    // kudos is, which for a browser-sized initramfs is the difference between
    // booting and spending half an hour pulling 236 MiB through the TCP stack.
    const guest_name = b.option([]const u8, "guest", "stage assets/virt/<name>/ as the built-in guest (default: assets/virt/)");
    const guest_dir = if (guest_name) |n| b.fmt("assets/virt/{s}", .{n}) else "assets/virt";
    // What the `vm boot` list calls entry 1: the staged image's own name, so the
    // menu cannot drift from what -Dguest actually staged.
    const staged_guest_name = guest_name orelse "busybox";
    // Extra words on the staged guest's kernel command line. The command line
    // is how a caller tells a guest what to do without typing at its console:
    // the guest images carry a `kudos.run=<base64>` hook that runs a script and
    // states its exit code on the serial line, so an experiment inside a guest
    // becomes a build flag and a boot rather than a person driving a keyboard
    // into whichever window has focus. Empty by default — a guest given nothing
    // extra boots exactly as it always did.
    const guest_cmdline = b.option([]const u8, "guest-cmdline", "extra words appended to the staged guest's kernel command line") orelse "";

    // The agent's sealed service credential (spec AGT-017) and the passphrase
    // that opens it. Reading the credential from the USB stick (AGT-004) leaves
    // the agent dead on every machine without one — the emulator, this laptop —
    // so the image can carry it instead, as CIPHERTEXT.
    //
    // The default source is secrets/agent-key.b64, which is NOT tracked: sealing
    // once survives every later rebuild without the operator holding a base64
    // blob, and the repository never contains the credential in any form. Absent,
    // the option is empty and the agent falls back to the stick exactly as before.
    const agent_key = b.option([]const u8, "agent-key", "base64 sealed agent credential (default: secrets/agent-key.b64)") orelse blk: {
        const io = b.graph.io;
        const text = std.Io.Dir.cwd().readFileAlloc(io, b.pathFromRoot("secrets/agent-key.b64"), b.allocator, .limited(8 * 1024)) catch break :blk "";
        break :blk std.mem.trim(u8, text, " \t\r\n");
    };
    const agent_password = b.option([]const u8, "agent-password", "bake in the passphrase that opens the sealed credential (unattended rigs only; default: ask)") orelse "";
    const guest_bzimage_rel = b.fmt("{s}/bzImage", .{guest_dir});
    const guest_initramfs_rel = b.fmt("{s}/initramfs.cpio.gz", .{guest_dir});
    const guest_present = blk: {
        const io = b.graph.io;
        std.Io.Dir.cwd().access(io, b.pathFromRoot(guest_bzimage_rel), .{}) catch break :blk false;
        std.Io.Dir.cwd().access(io, b.pathFromRoot(guest_initramfs_rel), .{}) catch break :blk false;
        break :blk true;
    };
    // An explicitly named guest that is not there is a mistake, not a tree that
    // never ran the guest build: fail rather than silently staging nothing and
    // leaving `vm boot 1` to report the absence three steps later.
    if (guest_name != null and !guest_present)
        std.debug.panic("-Dguest={s}: no bzImage + initramfs.cpio.gz in {s}/", .{ guest_name.?, guest_dir });
    const empty_guest = b.addWriteFiles();
    const guest_bzimage_path: std.Build.LazyPath = if (guest_present)
        b.path(guest_bzimage_rel)
    else
        empty_guest.add("guest_bzimage.absent", "");
    const guest_initramfs_path: std.Build.LazyPath = if (guest_present)
        b.path(guest_initramfs_rel)
    else
        empty_guest.add("guest_initramfs.absent", "");

    // `-Dbake=<csv|all>`: carry catalog guests INSIDE the image instead of
    // fetching them. `vm boot` then reaches a baked guest with no network at
    // all and no wait — for the browser image that is the difference between
    // booting and pulling 256 MiB through the TCP stack first — at the cost of
    // exactly those bytes in the kernel's .rodata and therefore in RAM.
    // Default: bake nothing, so an ordinary build stays the size it was.
    //
    // The bakeable names are the catalog's own ids (kernel/virt/guestlist.zig)
    // and the build_guest.sh subcommands that produce them; a host test asserts
    // this list and the catalog agree, because nothing else can — the build
    // script cannot read the kernel's source.
    const bakeable = [_][]const u8{ "firefox", "zigserver", "ubuntu", "desktop" };
    const bake_opt = b.option([]const u8, "bake", "carry these catalog guests in the image: csv of firefox|zigserver|ubuntu|desktop, or all") orelse "";
    var baked_paths: [bakeable.len][2]std.Build.LazyPath = undefined;
    for (bakeable, 0..) |id, i| {
        const wanted = std.mem.eql(u8, bake_opt, "all") or blk: {
            var it = std.mem.splitScalar(u8, bake_opt, ',');
            while (it.next()) |w| if (std.mem.eql(u8, std.mem.trim(u8, w, " "), id)) break :blk true;
            break :blk false;
        };
        const bz_rel = b.fmt("assets/virt/{s}/bzImage", .{id});
        const initrd_rel = b.fmt("assets/virt/{s}/initramfs.cpio.gz", .{id});
        const present = blk: {
            const io = b.graph.io;
            std.Io.Dir.cwd().access(io, b.pathFromRoot(bz_rel), .{}) catch break :blk false;
            std.Io.Dir.cwd().access(io, b.pathFromRoot(initrd_rel), .{}) catch break :blk false;
            break :blk true;
        };
        // A guest named for baking that was never built is a mistake, not an
        // absence to work around: the image would silently ship without it and
        // fall back to fetching, which is exactly what the flag was asking to
        // avoid.
        if (wanted and !present)
            std.debug.panic("-Dbake={s}: no bzImage + initramfs.cpio.gz in assets/virt/{s}/ (build it: scripts/virt/build_guest.sh {s})", .{ bake_opt, id, id });
        baked_paths[i] = if (wanted)
            .{ b.path(bz_rel), b.path(initrd_rel) }
        else
            .{
                empty_guest.add(b.fmt("baked_{s}_bzimage.absent", .{id}), ""),
                empty_guest.add(b.fmt("baked_{s}_initramfs.absent", .{id}), ""),
            };
    }

    // Two kernel variants from one shared source tree:
    //   kudos       — single-core, BSP only (root src/main_root.zig)
    //   kudos-smp   — multi-core, brings APs online (root src/main_smp.zig)
    // The comptime `smp` flag in buildinfo gates AP startup and per-core terminal
    // pinning, so a module can branch on it without a separate copy. Both share
    // every other module, the wallpaper, the NASM objects, and the build number.
    // `-Dsmp-minimal`: build the SMP kernel down to a bare serial-only bring-up
    // (cores online + a per-core heartbeat, NO screen/USB/net/terminals). A
    // scaffold for isolating the scheduler over serial. Declared once; off by
    // default. (Inert in the single-core kudos build.)
    const smp_minimal = b.option(bool, "smp-minimal", "SMP: minimal serial-only heartbeat bring-up (no devices)") orelse false;

    // `-Dverify-script`: inject a fixed keystroke stream (spawn AP terminal →
    // `prime` → `ps`) so the headless screenshot/serial path shows per-core CPU%
    // (the pegged core at ~100%). Verification only; off by default, inert in
    // normal boots.
    const verify_script = b.option(bool, "verify-script", "Inject scripted prime+ps input for headless CPU% verification") orelse false;

    // `-Dflip-sample`: the steady-60Hz measurement build. present.zig records one
    // low-perturbation window of per-frame present intervals (FLIP_SAMPLE ring),
    // judges it against the panel refresh (flip_stats.zig, host-tested criteria)
    // and emits a one-line FLIPSTAT verdict over netdebug under the `.gpu` gate —
    // the pass/fail answer of a passthrough performance run. Off by default:
    // the per-frame ring store is cheap but the dump burst is measurement noise
    // a normal session shouldn't carry.
    const flip_sample = b.option(bool, "flip-sample", "Record + judge one steady-state present-cadence window (FLIPSTAT verdict over netdebug)") orelse false;

    // `-Dtest-hooks`: compile in the integration-test instrumentation — the
    // terminal-output mirror (terminal.zig `putChar` emits every committed grid
    // line as a `dbg: term.<core> = …` record so the test harness can read back
    // command output over serial/netdebug; see the mirror comment there). OFF by
    // default and comptime-gated, so a shipping `make start` image carries no
    // accumulator, no emit, and no `.term` gate. scripts/tests/*.sh pass
    // -Dtest-hooks; main.zig adds `.term` to the enabled gate set only under this
    // flag (mirrors how -Dflip-sample force-enables `.gpu`).
    const test_hooks = b.option(bool, "test-hooks", "Compile in integration-test instrumentation (terminal-output mirror); off by default") orelse false;

    // `-Dno-gl`: bring the GPU up (GSP, display, present) but do NOT publish the
    // windowed-GL device. The BISECT FLAG for lemon's native hang (2026-07-12):
    // the machine wedges the CPU dead — no netdebug, no IRQ0, no dead-man — in
    // the FIRST compositor render after `framebuffer.opengl` is published, i.e.
    // the first render that drives GL windows on the GR channel. A GR submit that
    // wedges the card makes the next CPU MMIO read to it never complete, which is
    // exactly that signature. gpu.zig already treats a failed GL init as
    // non-fatal (model windows stay 2D, desktop runs), so this is a supported
    // configuration, not a crippled one: it splits "the GPU present path hangs"
    // from "the GL/GR path hangs" in a single boot.
    const no_gl = b.option(bool, "no-gl", "Bring up the GPU but skip the windowed-GL device (bisect: desktop without GR)") orelse false;

    // `-Dgr-backend`: compile in the RTX 4090 GR-engine IDraw backend (drivers/gl/opengl.zig).
    // ON by default now that the backend is ported to the idraw seam and exercised on the
    // 4090 (boot-2 renders the GL windows in its cases at the 60 Hz cadence it asserts).
    // On a machine with
    // no 4090 the GR bring-up simply never runs. Pass `-Dgr-backend=false` to compile it out.
    const gr_backend = b.option(bool, "gr-backend", "Compile the 4090 GR-engine gles backend (opengl.zig)") orelse true;

    // `-Dsoft-display`: compile in the CPU rasteriser (drivers/gl/soft.zig) as a
    // draw device, published at boot only when no GPU is coming. kudos renders on
    // the 4090 — that is the product, and this flag is OFF by default, so the
    // default image does not compile in the software draw device. It exists for the
    // EMULATOR, where there is no GPU and the desktop would otherwise be a blank
    // screen: it is what makes a guest VM's window (and everything else) visible
    // and screenshottable on a development machine. A software frame costs orders
    // of magnitude more than a flip and meets none of the 60 Hz present
    // requirements, so it is a development instrument, not a fallback the
    // default build carries.
    const soft_display = b.option(bool, "soft-display", "Emulator only: render the desktop on the CPU when no GPU is present") orelse false;

    // `-Dusb-max-gb`: the largest USB mass-storage device the kernel will open
    // (GB = 10^9 bytes, the size printed on the packaging). USB storage is the
    // ONLY storage kudos can reach — there is no NVMe or AHCI driver — so this
    // ceiling is what keeps an external drive that happens to be plugged in from
    // being treated as the kudos stick. The default admits any ordinary stick;
    // lower it below the size of any USB drive you own to be stricter.
    const usb_max_gb = b.option(u32, "usb-max-gb", "Largest USB storage device the kernel will use, in GB (10^9 bytes)") orelse 2000;

    // `-Dheartbeat`: the BRING-UP image. Boot, take a DHCP lease, then sit in a
    // bounded request/response heartbeat loop (KMR1 OP_PING at ~1 Hz) and reboot
    // when the run is up. No USB, no desktop, no GPU — that code is all still
    // compiled in, just never reached (main.zig returns into heartbeatMode before
    // it). Two things this buys, both learned the hard way on lemon:
    //
    //   1. The run is BOUNDED: the image is built to end on its own rather than
    //      to be watched. Every watchdog we tried failed because its clock (IRQ0)
    //      was the thing dying; a fixed-duration run has nothing to detect.
    //   2. A reply PROVES liveness. A silent netdebug stream is ambiguous (wedge?
    //      link down? gated log?) and that ambiguity cost four physical power
    //      cycles. A ping that stops answering is not ambiguous.
    //
    // It is also the only test of power.reboot() on this silicon: the machine
    // resets itself at the end, or it does not, and either way we learn.
    const heartbeat = b.option(bool, "heartbeat", "Bring-up image: network + 1 Hz KMR1 heartbeat only, then self-reboot (no USB/desktop/GPU)") orelse false;

    // Cross-layer interface contracts (src/iface/) are imported by NAME, not by a
    // fragile relative path (a module root cannot import a file above its own
    // directory, which broke host tests). One module each, shared by both kernel
    // variants and the host test targets. They are pure vtable-type leaves.
    // Naming convention (CLAUDE.md): interface module = i<name> (idisplay, ilog,
    // ipresent); type = I<Name> (IDisplay, ...); real impl keeps its home name;
    // fake = <name>_sim in test/. surface.zig is the shared pure pixel type
    // imported by many files across groups (and by idisplay). It is a named module
    // so it belongs to ONE module regardless of which root imports it.
    const surface_mod = b.createModule(.{ .root_source_file = b.path("src/ui/screen/surface.zig") });
    const idisplay_mod = b.createModule(.{ .root_source_file = b.path("src/iface/idisplay.zig") });
    idisplay_mod.addImport("surface", surface_mod);
    const ilog_mod = b.createModule(.{ .root_source_file = b.path("src/iface/ilog.zig") });
    const ipresent_mod = b.createModule(.{ .root_source_file = b.path("src/iface/ipresent.zig") });
    // The SPSC ring is a shared named module so the iface `imouse` leaf can hold
    // one (it cannot relative-import above its own dir). The kernel still imports
    // ring.zig relatively for its per-core mailboxes — same file, and Ring is a
    // generic type so there is no shared-state identity concern.
    const ring_mod = b.createModule(.{ .root_source_file = b.path("src/kernel/sync/ring.zig") });
    // `algn` — power-of-two alignment, the ONE home (CLAUDE.md "Duplication"). A named
    // module because a host-test root's module path is its own directory: a pure module in
    // drivers/gpu/ cannot relatively import kernel/memory/, so without this every corner of
    // the tree re-spells `(x + a - 1) & ~(a - 1)` to stay testable. Named `algn`, not
    // `align`, because `align` is a Zig keyword and cannot be bound to a const.
    const algn_mod = b.createModule(.{ .root_source_file = b.path("src/kernel/memory/align.zig") });
    // imouse: the cross-layer pointer-event contract (MouseEvent + coalescing
    // queue). Pure data+logic leaf; depends on the ring + the log seam by name.
    const imouse_mod = b.createModule(.{ .root_source_file = b.path("src/iface/imouse.zig") });
    imouse_mod.addImport("ring", ring_mod);
    imouse_mod.addImport("ilog", ilog_mod);
    // ivirt: the hypervisor ↔ VM-console-app cross-core mailbox (serial rings,
    // guest lifecycle state, scanout publish, bridged Ethernet frames). Depends
    // on the ring and (for the frame ceiling) the inet contract, wired below
    // once inet_mod exists.
    const ivirt_mod = b.createModule(.{ .root_source_file = b.path("src/iface/ivirt.zig") });
    ivirt_mod.addImport("ring", ring_mod);
    // overlay_plane.zig: pure overlay-plane arm/blank state machine (the transition
    // logic that had two ghost bugs before it was extracted + tested). Shared module.
    const overlay_plane_shared = b.createModule(.{ .root_source_file = b.path("src/drivers/gpu/present/overlay_plane.zig") });
    // hostpush.zig: pure GPFIFO method encoder (imports nothing) — shared named
    // module so the gpu driver, the gl 3D layer, and the gl method-stream host
    // tests all use ONE instance (HostPush stays type-identical across the seam).
    const hostpush_shared = b.createModule(.{ .root_source_file = b.path("src/drivers/gpu/base/hostpush.zig") });
    // iramdisk: the file-system contract (real: storage/ramdisk.zig; fake:
    // test/support/ramdisk_sim.zig). idraw: the 3D-device seam the GL layer lowers onto (impl in
    // src/drivers/gl/). fileproto: netdebug wire codec + server
    // logic, pure over iramdisk — named so the
    // test/ root and the kernel share ONE instance.
    const iramdisk_mod = b.createModule(.{ .root_source_file = b.path("src/iface/iramdisk.zig") });
    // The pure half of the keyboard driver: scancode/HID tables and the key codes the
    // line editors compare against. No hardware, so the UI can name it without naming
    // a driver.
    const keymap_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/input/keymap.zig") });

    // The network as an application sees it: online?, resolve, ping, fetch. Everything
    // below it (Ethernet, IP, TCP, DHCP, DNS) stays inside the net group.
    const inet_mod = b.createModule(.{ .root_source_file = b.path("src/iface/inet.zig") });
    // The guest NIC bridge's frame rings size their slots from the network
    // contract's frame ceiling (inet.ETHER_FRAME_MAX): one fact, one home.
    ivirt_mod.addImport("inet", inet_mod);

    // The hardware inventory as a list of facts. Not a vtable: a diagnostic that prints
    // the device list wants to NAME each device, not talk to it.
    const ipci_mod = b.createModule(.{ .root_source_file = b.path("src/iface/ipci.zig") });

    const idraw_mod = b.createModule(.{ .root_source_file = b.path("src/iface/idraw.zig") });

    // Shared test fixtures (test/support/): suites in DIFFERENT test dirs
    // compose these, and a test root may not relatively import above its own
    // directory — so the shared ones are named modules, like any other
    // cross-group contract. A fixture used by one dir only stays a sibling
    // file there (percept_test's relative import of percept.zig).
    const draw_sim_mod = b.createModule(.{ .root_source_file = b.path("test/support/draw_sim.zig") });
    draw_sim_mod.addImport("idraw", idraw_mod);
    const ramdisk_sim_mod = b.createModule(.{ .root_source_file = b.path("test/support/ramdisk_sim.zig") });
    ramdisk_sim_mod.addImport("iramdisk", iramdisk_mod);
    const percept_mod = b.createModule(.{ .root_source_file = b.path("test/support/percept.zig") });

    // gles: OpenGL ES 1.1, Common profile — the pure half of the GL driver. Apps import
    // it BY NAME (like keymap, the pure half of the keyboard driver) and never see the
    // device seam underneath: gles.createContext is the whole of what they need, and
    // scripts/tests/layering.sh fails the build if ui/ reaches past it into idraw.
    const gles_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/gl/es/gl.zig") });
    gles_mod.addImport("idraw", idraw_mod);

    // soft: the CPU IDraw backend (src/drivers/gl/soft.zig). Host tests drive it as the
    // device the same way the kernel does when there is no GPU. Named so test/ files can
    // reach it without escaping their directory.
    const soft_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/gl/soft.zig") });
    soft_mod.addImport("idraw", idraw_mod);

    // kgl: the 2D rendering library (src/ui/screen/kgl.zig) — a formal layer over gles that
    // the window manager draws through. Named so the WM imports `kgl`, not gles, and the
    // boundary is explicit. It owns geom.zig/gltext.zig as internals (relative imports).
    // The any-size text path (spec RND-009..011): outlines in, packed coverage
    // sheet out. Named modules rather than relative imports because the sheet is
    // baked by whoever owns the GL context and read by every surface that draws
    // text at a size of its own — the kernel, the host screenshot fixture and the
    // tests must all see ONE rasteriser and ONE glyph-box contract.
    const truetype_mod = b.createModule(.{ .root_source_file = b.path("src/ui/screen/truetype.zig") });
    const gltext_mod = b.createModule(.{ .root_source_file = b.path("src/ui/screen/gltext.zig") });
    const glyphcache_mod = b.createModule(.{ .root_source_file = b.path("src/ui/screen/glyphcache.zig") });
    glyphcache_mod.addImport("truetype", truetype_mod);
    glyphcache_mod.addImport("gltext", gltext_mod);
    // typeface: the one baked instance of the shipped face. It carries the font
    // file itself, so the outlines are embedded exactly once no matter how many
    // surfaces draw text.
    const typeface_mod = b.createModule(.{ .root_source_file = b.path("src/ui/screen/typeface.zig") });
    typeface_mod.addImport("truetype", truetype_mod);
    typeface_mod.addImport("glyphcache", glyphcache_mod);
    typeface_mod.addImport("gltext", gltext_mod);
    typeface_mod.addAnonymousImport("font_ttf", .{ .root_source_file = b.path("src/ui/assets/RobotoMono-Regular.ttf") });

    // The widget toolkit's shared vocabulary: the rectangle algebra every widget
    // lays itself out with, and the sample ring every trace reads. Named modules
    // so a Rect built by the HUD is the same type the widgets take.
    const theme_mod = b.createModule(.{ .root_source_file = b.path("src/ui/screen/theme.zig") });
    theme_mod.addImport("surface", surface_mod);
    const rects_mod = b.createModule(.{ .root_source_file = b.path("src/widgets/rects.zig") });
    const sampler_mod = b.createModule(.{ .root_source_file = b.path("src/widgets/sampler.zig") });
    const kgl_mod = b.createModule(.{ .root_source_file = b.path("src/ui/screen/kgl.zig") });
    kgl_mod.addImport("gles", gles_mod);
    kgl_mod.addImport("gltext", gltext_mod);

    const barfill_mod = b.createModule(.{ .root_source_file = b.path("src/widgets/barfill.zig") });

    // The drawing widgets the HUD is composed of. Named modules, like kgl: they
    // are imported by the kernel AND compiled as host-test roots, so one instance
    // of each must serve both or a Rect built by one would not be the Rect the
    // other takes.
    const widget_names = [_][]const u8{ "panel", "meter", "stackbar", "sparkline", "statile", "hudview" };
    var widget_mods: [widget_names.len]*std.Build.Module = undefined;
    for (widget_names, 0..) |wn, wi| {
        const m = b.createModule(.{ .root_source_file = b.path(b.fmt("src/widgets/{s}.zig", .{wn})) });
        m.addImport("kgl", kgl_mod);
        m.addImport("rects", rects_mod);
        m.addImport("theme", theme_mod);
        m.addImport("typeface", typeface_mod);
        m.addImport("barfill", barfill_mod);
        m.addImport("sampler", sampler_mod);
        widget_mods[wi] = m;
    }
    // hudview draws WITH the other widgets, so it takes them as imports — the
    // same instances the kernel and the tests use.
    for ([_]usize{ 0, 1, 2, 3, 4 }) |wi| {
        widget_mods[widget_names.len - 1].addImport(widget_names[wi], widget_mods[wi]);
    }

    // input_latency: the PERF-008 receipt→present latency latch + budget judgement
    // (pure, imports nothing). Named because the latch instance lives in iaccel
    // (the compositor↔GPU seam) while the judgement runs in the GPU present path —
    // both sides must see ONE Latch type.
    const input_latency_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/gpu/present/input_latency.zig") });
    // The seam between the software compositor and a GPU that accelerates it. Both sides
    // publish their hooks here and read the other's; neither group imports the other.
    // The peripheral-presence seam: drivers publish, the interface reads.
    const idevices_mod = b.createModule(.{ .root_source_file = b.path("src/iface/idevices.zig") });
    const iaccel_mod = b.createModule(.{ .root_source_file = b.path("src/iface/iaccel.zig") });
    iaccel_mod.addImport("surface", surface_mod);
    iaccel_mod.addImport("idisplay", idisplay_mod);
    iaccel_mod.addImport("input_latency", input_latency_mod);
    // ifilesys: the VFS mount contract (vfs.zig; real: storage/ramdisk.zig
    // fileSys() + storage/fat.zig; the vfs host tests fake it inline).
    // iblockdev: the 512-byte-sector block seam (real: usb/msc.zig ONLY —
    // the storage-safety contract; fat.zig consumes it, tests fake it).
    // idesk: the desktop-control seam (AGT-023/AGT-024) — the agent and the
    // shell park window requests here and read what the desktop published;
    // ui/desktop is the only thing that applies or publishes.
    const idesk_mod = b.createModule(.{ .root_source_file = b.path("src/iface/idesk.zig") });
    const ifilesys_mod = b.createModule(.{ .root_source_file = b.path("src/iface/ifilesys.zig") });
    const iblockdev_mod = b.createModule(.{ .root_source_file = b.path("src/iface/iblockdev.zig") });
    // vfs: the / namespace (mount table = GLOBAL state) — a named module so
    // the kernel and the modelcache host tests share ONE instance; mixing a
    // relative import anywhere would silently fork the mount table.
    const vfs_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/storage/vfs.zig") });
    vfs_mod.addImport("ifilesys", ifilesys_mod);
    const fileproto_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/net/debug/fileproto.zig") });
    fileproto_mod.addImport("iramdisk", iramdisk_mod);
    // The asset pipeline (ui/assets/): glTF/PNG/JPEG decode + the model cache. Pure over
    // the `vfs` and `idraw` seams; the UI imports it by name, not by reaching into another
    // group's folder.
    const kernel_modelcache_mod = b.createModule(.{ .root_source_file = b.path("src/ui/assets/modelcache.zig") });
    kernel_modelcache_mod.addImport("vfs", vfs_mod);
    kernel_modelcache_mod.addImport("gles", gles_mod);
    kernel_modelcache_mod.addImport("kgl", kgl_mod); // GL image upload lives in kgl
    kernel_modelcache_mod.addImport("ilog", ilog_mod);

    // The .kudos loadable-binary ABI: a core contract compiled by the kernel
    // loader, the host compile factory, and every generated binary. Named (not a
    // relative import) so the kernel and the host tests share one definition.
    const abi_mod = b.createModule(.{ .root_source_file = b.path("src/kernel/loader/abi.zig") });
    // The module-fetch mailbox's bounds are the ABI's (NET_URL_MAX): one home.
    inet_mod.addImport("abi", abi_mod);

    // The module-window slot table and the per-window scene mailboxes. Named
    // contracts, not files: console publishes them as capabilities, ui composites
    // them, and neither may import the other.
    const iwindow_mod = b.createModule(.{ .root_source_file = b.path("src/iface/iwindow.zig") });
    iwindow_mod.addImport("abi", abi_mod);
    iwindow_mod.addImport("ring", ring_mod);
    const iscene_mod = b.createModule(.{ .root_source_file = b.path("src/iface/iscene.zig") });
    iscene_mod.addImport("abi", abi_mod);

    const IfaceMod = struct { name: []const u8, mod: *std.Build.Module };
    // The cooperative long-task runner (job.zig): named so jobs.zig and
    // fetchjob.zig share ONE instance across the kernel — a job.Job made by one
    // must be the type the other's runner accepts.
    const job_mod = b.createModule(.{ .root_source_file = b.path("src/kernel/sched/job.zig") });

    const hudcontrol_mod = b.createModule(.{ .root_source_file = b.path("src/widgets/hudcontrol.zig") });
    const iface_mods = [_]IfaceMod{
        .{ .name = "hudcontrol", .mod = hudcontrol_mod },
        .{ .name = "job", .mod = job_mod },
        .{ .name = "surface", .mod = surface_mod },
        .{ .name = "idisplay", .mod = idisplay_mod },
        .{ .name = "ilog", .mod = ilog_mod },
        .{ .name = "ipresent", .mod = ipresent_mod },
        .{ .name = "imouse", .mod = imouse_mod },
        .{ .name = "ivirt", .mod = ivirt_mod },
        .{ .name = "idesk", .mod = idesk_mod },
        .{ .name = "iwindow", .mod = iwindow_mod },
        .{ .name = "iscene", .mod = iscene_mod },
        .{ .name = "ring", .mod = ring_mod },
        .{ .name = "algn", .mod = algn_mod },
        .{ .name = "overlay_plane", .mod = overlay_plane_shared },
        .{ .name = "hostpush", .mod = hostpush_shared },
        .{ .name = "iramdisk", .mod = iramdisk_mod },
        .{ .name = "abi", .mod = abi_mod },
        // The scalable-type path and the widget toolkit the HUD draws with.
        .{ .name = "idevices", .mod = idevices_mod },
        .{ .name = "theme", .mod = theme_mod },
        .{ .name = "rects", .mod = rects_mod },
        .{ .name = "sampler", .mod = sampler_mod },
        .{ .name = "barfill", .mod = barfill_mod },
        .{ .name = "truetype", .mod = truetype_mod },
        .{ .name = "gltext", .mod = gltext_mod },
        .{ .name = "glyphcache", .mod = glyphcache_mod },
        .{ .name = "typeface", .mod = typeface_mod },
        .{ .name = "panel", .mod = widget_mods[0] },
        .{ .name = "meter", .mod = widget_mods[1] },
        .{ .name = "stackbar", .mod = widget_mods[2] },
        .{ .name = "sparkline", .mod = widget_mods[3] },
        .{ .name = "statile", .mod = widget_mods[4] },
        .{ .name = "hudview", .mod = widget_mods[5] },
        .{ .name = "idraw", .mod = idraw_mod },
        // The CPU rasteriser as a named module. It is in the kernel's import set
        // unconditionally so the wiring is one shape, but nothing reaches it
        // unless `-Dsoft-display` publishes it (main.publishSoftDisplay).
        .{ .name = "soft", .mod = soft_mod },
        .{ .name = "gles", .mod = gles_mod },
        .{ .name = "kgl", .mod = kgl_mod },
        // The generated shader manifest, by name: the GR backend (opengl.zig) reaches it
        // through ada/variant.zig's key->name lookup, which imports "manifest". Kept as a
        // named module (not a relative import) so it is the SAME set of blob names the
        // host test in variant.zig checks against — one manifest, one source of truth.
        .{ .name = "manifest", .mod = b.createModule(.{ .root_source_file = b.path("src/drivers/gl/shaders/manifest.zig") }) },
        .{ .name = "iaccel", .mod = iaccel_mod },
        .{ .name = "input_latency", .mod = input_latency_mod },
        .{ .name = "keymap", .mod = keymap_mod },
        .{ .name = "inet", .mod = inet_mod },
        .{ .name = "ipci", .mod = ipci_mod },
        .{ .name = "ifilesys", .mod = ifilesys_mod },
        .{ .name = "iblockdev", .mod = iblockdev_mod },
        .{ .name = "vfs", .mod = vfs_mod },
        .{ .name = "fileproto", .mod = fileproto_mod },
        // The asset pipeline: model/texture decoding (ui/assets/). Pure over the vfs and
        // idraw seams — no driver code — so the model-viewer app reaches it by NAME rather
        // than by a relative path into another group.
        .{ .name = "modelcache", .mod = kernel_modelcache_mod },
    };

    const Variant = struct {
        name: []const u8,
        root: []const u8,
        smp: bool,
    };
    for ([_]Variant{
        .{ .name = "kudos", .root = "src/main_root.zig", .smp = false },
        .{ .name = "kudos-smp", .root = "src/main_smp_root.zig", .smp = true },
    }) |v| {
        const kernel = b.addExecutable(.{ .name = v.name, .root_module = b.createModule(.{
            .root_source_file = b.path(v.root),
            .target = target,
            .optimize = optimize,
        }) });
        kernel.root_module.red_zone = false;
        kernel.root_module.stack_protector = false;
        // Keep the RBP frame-pointer chain intact (default ReleaseFast omits it) so
        // the panic / CPU-fault handler can walk it for a call-stack backtrace over
        // netdebug. The cost is one register
        // and a push/pop per frame — negligible against the diagnostic value on a
        // headless native boot where a hang is otherwise a silent black screen.
        kernel.root_module.omit_frame_pointer = false;
        kernel.setLinkerScript(b.path("linker.ld"));
        for (iface_mods) |im| kernel.root_module.addImport(im.name, im.mod);

        // Per-variant buildinfo: same identity, distinct comptime `smp` flag.
        const buildinfo = b.addOptions();
        buildinfo.addOption(u32, "build_number", build_number);
        buildinfo.addOption([]const u8, "git_hash", git_hash);
        buildinfo.addOption([]const u8, "build_time", build_time);
        buildinfo.addOption(bool, "smp", v.smp);
        buildinfo.addOption(bool, "smp_minimal", smp_minimal);
        buildinfo.addOption(bool, "flip_sample", flip_sample);
        buildinfo.addOption(bool, "test_hooks", test_hooks);
        buildinfo.addOption(bool, "no_gl", no_gl);
        buildinfo.addOption(bool, "gr_backend", gr_backend);
        buildinfo.addOption(bool, "soft_display", soft_display);
        buildinfo.addOption(u32, "usb_max_gb", usb_max_gb);
        buildinfo.addOption(bool, "heartbeat", heartbeat);
        buildinfo.addOption([]const u8, "staged_guest", staged_guest_name);
        buildinfo.addOption([]const u8, "guest_cmdline", guest_cmdline);
        buildinfo.addOption([]const u8, "agent_key", agent_key);
        buildinfo.addOption([]const u8, "agent_password", agent_password);
        // verify-script is SMP-only: verifyscript.spawn creates a scheduler task
        // (sched.spawn/enqueue), and only the SMP image runs the per-core
        // scheduler. Injecting it into the single-core image would silently
        // enqueue a task nothing ever runs — scope it here, at the flag's one
        // definition site, so the single-core image ignores it by construction.
        buildinfo.addOption(bool, "verify_script", v.smp and verify_script);
        kernel.root_module.addOptions("buildinfo", buildinfo);

        // Assemble the NASM sources (boot trampoline + interrupt stubs) and link.
        for ([_][]const u8{ "src/kernel/boot/boot.asm", "src/kernel/boot/isr.asm", "src/kernel/virt/vmentry.asm" }) |src| {
            const nasm = b.addSystemCommand(&.{ "nasm", "-f", "elf64" });
            nasm.addFileArg(b.path(src));
            nasm.addArg("-o");
            const obj = nasm.addOutputFileArg("out.o");
            kernel.root_module.addObjectFile(obj);
        }

        // The AP startup trampoline is assembled to a FLAT binary (nasm -f bin):
        // it runs in real mode at a fixed low address, so it cannot be an ELF
        // object. smp.zig @embedFile's the blob and copies it to low memory at
        // runtime. The SMP variant copies it via @embedFile, but it is harmless
        // (a few KiB of .rodata) in the single-core kernel too, so both build the
        // same way and the file is the single source of truth.
        const tramp = b.addSystemCommand(&.{ "nasm", "-f", "bin", "-w-implicit-abs-deprecated" });
        tramp.addFileArg(b.path("src/kernel/smp/trampoline.asm"));
        tramp.addArg("-o");
        const tramp_bin = tramp.addOutputFileArg("trampoline.bin");
        kernel.root_module.addAnonymousImport("trampoline_bin", .{
            .root_source_file = tramp_bin,
        });

        // The default desktop background (spec R23): the canonical asset at
        // assets/media/background.png, embedded and seeded into the ramdisk by
        // main.seedRamdisk so the desktop and the `background` command load it
        // through the same VFS path as any user-chosen image.
        kernel.root_module.addAnonymousImport("background_png", .{
            .root_source_file = b.path("assets/media/background.png"),
        });

        // The trusted certificate-authority set (spec NET-011): the canonical
        // PEM bundle at assets/net/cacert.pem, embedded so the TLS client can
        // verify every HTTPS chain with no filesystem. Regenerate from a
        // maintained host: cp /etc/ssl/certs/ca-certificates.crt assets/net/cacert.pem
        // The agent's configuration (spec AGT-017), seeded onto the ramdisk at
        // boot. Baked in because the alternative home is a USB stick, and no
        // emulator run has one — so the agent had no configuration at all on
        // the machine it is developed on.
        kernel.root_module.addAnonymousImport("ai_cfg", .{
            .root_source_file = b.path("assets/agent/AI.CFG"),
        });

        kernel.root_module.addAnonymousImport("cacert_pem", .{
            .root_source_file = b.path("assets/net/cacert.pem"),
        });

        // The staged Linux guest (spec VIRT): bzImage + initramfs embedded so the
        // `vm boot` run path can reach a real image with no filesystem. Empty when
        // no guest was staged (see guest_present above). ~2 MiB, in the kernel's
        // .rodata — it grows the image, not the ramdisk heap (gueststage.zig).
        kernel.root_module.addAnonymousImport("guest_bzimage", .{
            .root_source_file = guest_bzimage_path,
        });
        kernel.root_module.addAnonymousImport("guest_initramfs", .{
            .root_source_file = guest_initramfs_path,
        });

        // The baked catalog guests (-Dbake), by the same real-or-empty rule.
        for (bakeable, 0..) |id, i| {
            kernel.root_module.addAnonymousImport(b.fmt("baked_{s}_bzimage", .{id}), .{
                .root_source_file = baked_paths[i][0],
            });
            kernel.root_module.addAnonymousImport(b.fmt("baked_{s}_initramfs", .{id}), .{
                .root_source_file = baked_paths[i][1],
            });
        }

        b.installArtifact(kernel);
    }

    // `zig build iso`  -> bootable build/kudos.iso       (single-core)
    // `zig build iso-smp` -> bootable build/kudos-smp.iso (multi-core)
    // mkiso.sh takes the variant name; it stages $BUILD_DIR/bin/<name> (zig's
    // install prefix, set to build/ by every caller) and emits build/<name>.iso.
    // All generated artifacts live under build/.
    const iso = b.addSystemCommand(&.{ "scripts/build/mkiso.sh", "kudos" });
    iso.step.dependOn(b.getInstallStep());
    b.step("iso", "Build bootable kudos.iso (single-core)").dependOn(&iso.step);

    const iso_smp = b.addSystemCommand(&.{ "scripts/build/mkiso.sh", "kudos-smp" });
    iso_smp.step.dependOn(b.getInstallStep());
    b.step("iso-smp", "Build bootable kudos-smp.iso (multi-core)").dependOn(&iso_smp.step);

    // Host unit tests for device-independent logic that cannot run in the
    // freestanding kernel or be exercised in QEMU (the emulator has no 4090).
    // Built for the host so std.testing is available.
    // `zig build test` runs them; `zig build coverage` runs them under kcov.
    const test_step = b.step("test", "Run host unit tests (pure logic, no hardware)");
    // `-Dtest-only=SUBSTR`: wire only the test roots whose source path contains
    // SUBSTR — the iteration loop for one subsystem pays for that subsystem
    // alone. CI runs the bare step, which wires everything.
    const test_only = b.option([]const u8, "test-only", "Run only test roots whose path contains this substring") orelse "";
    // Coverage binaries accumulate here (both steps share the same test artifacts).
    var cov_bins: std.ArrayList(*std.Build.Step.Compile) = .empty;

    // glbcheck — host model-corpus validator (src/ui/assets/glbcheck.zig): runs
    // every .glb through the REAL glb.parse + png.decode and prints a verdict
    // table. `zig build glbcheck` installs build/bin/glbcheck; point it at the
    // mounted USB stick's models/ + scenes/ directories.
    {
        const exe = b.addExecutable(.{ .name = "glbcheck", .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/assets/glbcheck.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }) });
        // glbcheck.zig imports glb/png/jpeg RELATIVELY (they sit next to it), so
        // no named-module wiring is needed and png.zig stays a single instance
        // (jpeg.zig re-exports png.Image via a relative import; a file can't be
        // both a named module and a relative import — CLAUDE.md).
        const inst = b.addInstallArtifact(exe, .{});
        b.step("glbcheck", "Build the host .glb corpus validator (build/bin/glbcheck)").dependOn(&inst.step);
    }

    // The shader manifest the build loop generated, as a module — variant.zig maps a
    // key to a NAME; the manifest is the set of names that actually got compiled.
    const manifest_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/gl/shaders/manifest.zig") });

    // HOST-TEST SUITES. One row per pure module: `.s` is the module — the src file
    // itself, or a *_testroot.zig module-root shim where its relative imports demand
    // one — and the tests live in test/<stem>_test.zig (`.t` overrides where several
    // suites share one shim module). Test code never lives in the production file
    // (CLAUDE.md Tests): the test file imports the module by the `.n` name and
    // reaches everything through it. Add a row here and it is covered by both
    // `test` and `coverage`.
    const HostSuite = struct { n: []const u8, s: []const u8, t: ?[]const u8 = null };
    // The host shape of `buildinfo` for pure modules that read comptime flags
    // (e.g. linuxload's test-hooks guest-serial mirror): identity as built,
    // hardware-shaped flags off — the host analyses the flag'd code, never runs it.
    const pure_buildinfo = b.addOptions();
    pure_buildinfo.addOption(u32, "build_number", build_number);
    pure_buildinfo.addOption([]const u8, "git_hash", git_hash);
    pure_buildinfo.addOption([]const u8, "build_time", build_time);
    pure_buildinfo.addOption(bool, "smp", false);
    pure_buildinfo.addOption(bool, "smp_minimal", false);
    pure_buildinfo.addOption(bool, "flip_sample", flip_sample);
    pure_buildinfo.addOption(bool, "test_hooks", test_hooks);
    pure_buildinfo.addOption(bool, "no_gl", no_gl);
    pure_buildinfo.addOption(bool, "gr_backend", gr_backend);
    pure_buildinfo.addOption(bool, "soft_display", soft_display);
    pure_buildinfo.addOption(u32, "usb_max_gb", usb_max_gb);
    pure_buildinfo.addOption(bool, "heartbeat", heartbeat);
    pure_buildinfo.addOption([]const u8, "staged_guest", staged_guest_name);
    pure_buildinfo.addOption([]const u8, "guest_cmdline", guest_cmdline);
    pure_buildinfo.addOption([]const u8, "agent_key", agent_key);
    pure_buildinfo.addOption([]const u8, "agent_password", agent_password);
    pure_buildinfo.addOption(bool, "verify_script", false);
    for ([_]HostSuite{
        .{ .n = "calc", .s = "src/drivers/gpu/base/calc.zig" }, // GPU MSI/MTRR + pitch math
        .{ .n = "cpustat", .s = "src/kernel/sched/cpustat.zig" }, // busy/idle TSC-delta → percent
        .{ .n = "dispatch", .s = "src/kernel/sched/dispatch.zig" }, // which core a runnable task goes to (KRN-009/010/011)
        .{ .n = "runqueue", .s = "src/kernel/sched/runqueue.zig" }, // the run queue's FIFO order + the sleeper list's deadline order
        .{ .n = "algn", .s = "src/kernel/memory/align.zig" }, // power-of-two alignment (module name `algn` — `align` is a keyword)
        .{ .n = "ring", .s = "src/kernel/sync/ring.zig" }, // SPSC ring buffer
        .{ .n = "wire", .s = "src/drivers/net/stack/wire.zig" }, // big-endian field access, Internet checksum, parseIp
        .{ .n = "dhcp_wire", .s = "src/drivers/net/stack/dhcp_wire.zig" }, // DHCP option parse + "the lease is the address" acceptance rule
        .{ .n = "dns_wire", .s = "src/drivers/net/stack/dns_wire.zig" }, // DNS A-query build + answer parse (attacker-controlled input)
        .{ .n = "tlskeys", .s = "src/drivers/net/stack/tlskeys.zig" }, // TLS 1.3 handshake key schedule vs the RFC 8448 vectors
        .{ .n = "tlsstream", .s = "src/drivers/net/stack/tlsstream.zig" }, // TLS plaintext read policy + failure naming (NET-016/017)
        .{ .n = "netown", .s = "src/drivers/net/stack/netown.zig" }, // who may drive the stack: claim/skip policy (NET-018)
        .{ .n = "igc_desc", .s = "src/drivers/net/nic/igc_desc.zig" }, // I226 advanced-descriptor codec — QEMU runs e1000, so this has NO emulated coverage
        .{ .n = "edid", .s = "src/drivers/gpu/display/edid.zig" }, // VESA E-EDID preferred-mode parse
        .{ .n = "keymap", .s = "src/drivers/input/keymap.zig" }, // PS/2 scancode + USB HID → ASCII
        .{ .n = "gmmu_fmt", .s = "src/drivers/gpu/base/gmmu_fmt.zig" }, // GP100 PTE/PDE encode + VA-index math
        .{ .n = "barfill", .s = "src/widgets/barfill.zig" }, // System-monitor usage-bar fill (no underflow/overflow)
        .{ .n = "clockface", .s = "src/widgets/clockface.zig" }, // analog clock-face hand/tick trigonometry
        .{ .n = "plot", .s = "src/widgets/plot.zig" }, // function-plot sampling, auto y-range, nice ticks
        .{ .n = "expr", .s = "src/apps/expr.zig" }, // calculator expression parse + postfix eval
        .{ .n = "calchistory", .s = "src/apps/calchistory.zig" }, // calculator home-screen ledger: scroll, truncate
        .{ .n = "abi", .s = "src/kernel/loader/abi.zig" }, // .kudos binary ABI: header/CRC verify + factory round-trip
        .{ .n = "runner", .s = "src/kernel/loader/runner.zig" }, // .kudos loader placement mechanics (verify → copy → zero → entry)
        .{ .n = "features", .s = "src/kernel/loader/features.zig" }, // feature-command registry: exact lookup, replace-in-place, loud overflow
        .{ .n = "config", .s = "src/agent/config.zig" }, // AI.CFG key/factory/model parse
        .{ .n = "keystore", .s = "src/agent/keystore.zig" }, // the sealed service credential: PBKDF2 + AEAD envelope (AGT-017)
        .{ .n = "openrouter", .s = "src/agent/openrouter.zig" }, // chat wire: request build, response + SSE parse
        .{ .n = "prompt", .s = "src/agent/prompt.zig" }, // system prompt; ABI-generated capability docs
        .{ .n = "history", .s = "src/agent/history.zig" }, // bounded conversation with pinned system message
        .{ .n = "loop", .s = "src/agent/loop.zig" }, // agent tool-calling control loop (injected transport/tools/sink/clock)
        .{ .n = "budget", .s = "src/agent/budget.zig" }, // agent action budget: turns/tools/tokens/time charge + statement
        .{ .n = "tools", .s = "src/agent/tools.zig" }, // tool registry: chat-tools JSON + dispatch routing
        .{ .n = "mcp", .s = "src/agent/mcp.zig" }, // bidirectional MCP over JSON-RPC (server handle + client build/parse)
        .{ .n = "http_wire", .s = "src/drivers/net/stack/http_wire.zig" }, // HTTP URL/header/chunked framing
        .{ .n = "tcp_seg", .s = "src/drivers/net/stack/tcp_seg.zig" }, // TCP outbound segmentation + RTO + wrap-safe ACK math
        .{ .n = "tcp_tx", .s = "src/drivers/net/stack/tcp_tx.zig" }, // TCP go-back-N send engine: segment/window/retransmit state machine
        .{ .n = "caldate", .s = "src/kernel/timer/caldate.zig" }, // civil date → epoch (TLS cert validity)
        .{ .n = "rtc_decode", .s = "src/kernel/timer/rtc_decode.zig" }, // RTC snapshot decode: BCD/12h/century → civil + epoch
        .{ .n = "uptime", .s = "src/kernel/timer/uptime.zig" }, // the wall-clock definition: TSC-derived once calibrated, so no core failure can stop time
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/debug/crashlog_test.zig" }, // per-core crash records: the fatal path's lock-free output channel
        .{ .n = "aiconsole", .s = "src/agent/aiconsole.zig" }, // agent console: prompt vs /command parsing
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/debug/backtrace_test.zig" }, // RBP frame-pointer backtrace walk
        .{ .n = "surface", .s = "src/ui/screen/surface.zig" }, // alpha-blend fast path (blendConst) exactness
        .{ .n = "geom", .s = "src/ui/screen/geom.zig" }, // GPU-UI tessellation: rounded-rect/disc fans, quad strips
        .{ .n = "gltext", .s = "src/ui/screen/gltext.zig" }, // GPU text geometry: glyph quads + atlas texcoords
        .{ .n = "overlay_plane", .s = "src/drivers/gpu/present/overlay_plane.zig" }, // HW-plane arm/blank state machine (step 2b)
        .{ .n = "ui_wm", .s = "src/ui/wm_testroot.zig", .t = "test/ui/wm/wm_test.zig" }, // window-manager model: stacking/focus/mouse + damage coalescing
        .{ .n = "square", .s = "src/ui/wm/square.zig" }, // bouncing-square integer edge reflection + no-escape invariant
        .{ .n = "chrome", .s = "src/ui/wm/chrome.zig" }, // traffic-light hit-tests (draws through kgl)
        .{ .n = "dock", .s = "src/ui/desktop/dock.zig" }, // dock slab/icon layout + hit-tests (draws through kgl)
        .{ .n = "cursor", .s = "src/ui/desktop/cursor.zig" }, // software mouse pointer: baked arrow coverage/outline
        .{ .n = "spin", .s = "src/apps/spin.zig" }, // model-viewer spin angle: uniform 60 Hz steps, wrap-accurate at any uptime
        .{ .n = "debounce", .s = "src/drivers/usb/debounce.zig" }, // USB connect-debounce stability window (hub.c parity)
        .{ .n = "hid_report", .s = "src/drivers/usb/hid_report.zig" }, // HID descriptor walk/pick + report decode (G Pro layout parity)
        .{ .n = "port_fsm", .s = "src/drivers/usb/port_fsm.zig" }, // PORTSC/wPortStatus reset verdicts, interval encode, port-change table
        .{ .n = "trb", .s = "src/drivers/usb/trb.zig" }, // xHCI TRB math: the 64 KiB boundary split rule QEMU does not enforce
        .{ .n = "xhci_cc", .s = "src/drivers/usb/xhci_cc.zig" }, // xHCI completion-code verdicts: real HW says Short Packet where QEMU says Success
        .{ .n = "xhci_ctx", .s = "src/drivers/usb/xhci_ctx.zig" }, // xHCI context/TRB packing incl. the 64-byte context stride QEMU never uses
        .{ .n = "devmask", .s = "src/drivers/usb/devmask.zig" }, // the vid:pid mask — devices kudos deliberately does not drive
        .{ .n = "msc", .s = "src/drivers/usb/msc.zig" }, // USB mass-storage BOT/SCSI engine, pure over the Transport seam
        .{ .n = "mouse_accel", .s = "src/ui/desktop/mouse_accel.zig" }, // libinput-style pointer acceleration curve
        .{ .n = "gate", .s = "src/kernel/debug/gate.zig" }, // module debug gate (EnumSet enable/on)
        .{ .n = "flood", .s = "src/kernel/debug/flood.zig" }, // trace-bus flood suppression (a metered channel must survive its producers)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/debug/counter_test.zig" }, // named-counter registry + changed-only flush (the no-temporary-variables rail)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/debug/debug_test.zig" }, // dbg record atomicity: one set = one bus call (trace-tear incident class)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/drivers/net/stack/tlsclient_test.zig" }, // TLS 1.3 client: ClientHello construction + hostile-peer error paths
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/drivers/storage/bootlog_test.zig" }, // flight recorder: boot trace mirrored to the stick's ring file (DIAG-014)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/sched/taskstat_test.zig" }, // ps read-side view: label slices stay bounded however torn the snapshot
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/sched/lockorder_test.zig" }, // scheduler lock-lattice policy (ascending-only, no recursion)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/sched/stackcanary_test.zig" }, // stack-overflow detection on guard-page-less heap stacks (MEM-011)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/debug/deadman_test.zig" }, // wedge-fuse policy (alive/due windows; the IRQ glue is thin)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/debug/spinwait_test.zig" }, // bounded-spin budget policy (expiry + report-once gate)
        .{ .n = "multiboot2", .s = "src/kernel/boot/multiboot2.zig" }, // GRUB info-blob tag walk (malformed-blob guards)
        .{ .n = "job", .s = "src/kernel/sched/job.zig" }, // cooperative long-task runner: one bounded step per frame (render stays smooth)
        .{ .n = "acpi", .s = "src/kernel/acpi/acpi.zig" }, // RSDP/MADT parse vs synthetic tables (discover() never analyzed on host)
        .{ .n = "flip_stats", .s = "src/drivers/gpu/present/flip_stats.zig" }, // steady-60Hz verdict criteria (FLIPSTAT)
        .{ .n = "flip_pacing", .s = "src/drivers/gpu/present/flip_pacing.zig" }, // one-flip-per-refresh pacing decision core
        .{ .n = "input_latency", .s = "src/drivers/gpu/present/input_latency.zig" }, // PERF-008 receipt→present latency latch + budget judgement
        .{ .n = "tri_ring", .s = "src/drivers/gpu/present/tri_ring.zig" }, // triple-buffer compose/pending/scanout rotation
        .{ .n = "fps_window", .s = "src/drivers/gpu/present/fps_window.zig" }, // rolling-window FPS sample ring + rate
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/drivers/gpu/prof_test.zig" }, // profiler span accumulator math (Acc/spanTicks)
        // The GPU cross-layer suites share ONE module rooted at drivers/gpu/
        // (gpu_testroot.zig): dp/modeset/push reach across the GPU layers, so no
        // single layer directory can be their module path.
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/drivers/gpu/display/dp_test.zig" }, // DP link training + watermark math
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/drivers/gpu/display/modeset_test.zig" }, // EVO method-stream goldens
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/drivers/gpu/core/push_test.zig" }, // pushbuffer method-header packing
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/drivers/storage/ramdisk_test.zig" }, // in-RAM name→bytes store (shim: ramdisk @embedFiles ui assets)
        .{ .n = "vfs", .s = "src/drivers/storage/vfs.zig" }, // `/` namespace routing + pure path normalization
        .{ .n = "complete", .s = "src/console/complete.zig" }, // Tab filename completion over an injected directory enumeration
        .{ .n = "redirect", .s = "src/console/redirect.zig" }, // `>`/`>>` grammar + the bounded capture a redirected command writes into
        .{ .n = "grants", .s = "src/console/grants.zig" }, // the capability grant table: which .kudos module may bind what, at which version
        .{ .n = "editline", .s = "src/console/editline.zig" }, // console line editor core: keystroke → line edits, recall, Tab → completion (shared by both terminal editors)
        .{ .n = "cmdtoken", .s = "src/console/cmdtoken.zig" }, // single-flight command token: consume-on-claim (the double-dispatch GP incident)
        .{ .n = "methods", .s = "src/drivers/gl/ada/methods.zig" }, // ADA_A 3D method-stream goldens (ctxInit/RT/viewport/clear)
        .{ .n = "til", .s = "src/drivers/gl/ada/til.zig" }, // block-linear sizing vs NIL rules
        .{ .n = "tex", .s = "src/drivers/gl/ada/tex.zig" }, // TIC/TSC builders (pitch BGRA8, sampler, handles)
        .{ .n = "variant", .s = "src/drivers/gl/ada/variant.zig" }, // key → shader-program lookup vs the generated manifest
        .{ .n = "lower", .s = "src/drivers/gl/ada/lower.zig" }, // draw-seam-enum → ADA_A register-value dictionary
        .{ .n = "extent_heap", .s = "src/drivers/gl/extent_heap.zig" }, // VA-extent free list: alloc/free/coalescing/page-rounding
        .{ .n = "crc32", .s = "src/drivers/storage/crc32.zig" }, // CRC-32 vectors (netdebug file integrity)
        .{ .n = "fileproto", .s = "src/drivers/net/debug/fileproto.zig" }, // netdebug wire codec round-trips
        .{ .n = "ctx_init_full", .s = "src/drivers/gl/ada/ctx_init_full.zig" }, // full NVK one-time 3D ctx init transcription (fits-a-page)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/memory/heap_test.zig" }, // free-list heap core (FreeListHeap; kernel wrappers never analyzed on host)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/memory/pmm_test.zig" }, // frame-bitmap core (FrameBitmap; kernel wrappers never analyzed on host)
        .{ .n = "imouse", .s = "src/iface/imouse.zig" }, // pointer-event coalescing (ilog's sink defaults to null → silent, correct on the host)
        .{ .n = "iwindow", .s = "src/iface/iwindow.zig" }, // blob-window cross-core mailbox: open handshake, clamp, one-at-a-time, blit→dirty, focused keys
        .{ .n = "iscene", .s = "src/iface/iscene.zig" }, // scene mailbox: slot double-buffer + the validator every replayed frame passes
        .{ .n = "inet", .s = "src/iface/inet.zig" }, // module-fetch mailbox: parked-request handshake, one at a time, no module-side cancel
        .{ .n = "idesk", .s = "src/iface/idesk.zig" }, // desktop-control mailbox: one request at a time, published readback
        .{ .n = "armpolicy", .s = "src/kernel/sched/armpolicy.zig" }, // tickless arming policy: idle disarms (KRN-007), due sleepers never stranded
        .{ .n = "tracering", .s = "src/kernel/debug/tracering.zig" }, // lock-free trace-ring reservation algebra: a dead writer cannot wedge the bus
        .{ .n = "hudcontrol", .s = "src/widgets/hudcontrol.zig" }, // HUD control state + counter rates: latch, freeze, sampling period
        .{ .n = "hudsnapshot", .s = "src/widgets/hudsnapshot.zig" }, // HUD model: snapshot values, capacities, fault marks
        .{ .n = "lineasm", .s = "src/drivers/net/debug/lineasm.zig" }, // trace line assembly: one assembler per writer, no shared buffer to splice
        .{ .n = "linestore", .s = "src/drivers/net/debug/linestore.zig" }, // seq-stamped retained line ring: two-phase drain + resend-by-seq (the reliable trace)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/drivers/gl/softdisplay_test.zig" }, // ARCH-015 runtime guard: the publish decision
        // gles: OpenGL ES 1.1 (Common profile) — every module under src/drivers/gl/es/
        // is pure over the `idraw` seam, so the state machine host-tests with no GPU.
        // gl_test.zig's comptime check is the one that matters — it fails the BUILD if
        // any of the standard's 145 entry points is missing, so the entry-point surface
        // cannot silently shrink. That checks the API surface is PRESENT, not that its
        // behaviour conforms — no Khronos conformance suite runs here. (buffer/enums/entrypoints
        // carry no suite of their own; gl.zig's entry points analyze them.)
        .{ .n = "gl", .s = "src/drivers/gl/es/gl.zig" },
        .{ .n = "errors", .s = "src/drivers/gl/es/errors.zig" },
        .{ .n = "fixed", .s = "src/drivers/gl/es/fixed.zig" },
        .{ .n = "limits", .s = "src/drivers/gl/es/limits.zig" },
        .{ .n = "matrix", .s = "src/drivers/gl/es/matrix.zig" },
        .{ .n = "objects", .s = "src/drivers/gl/es/objects.zig" },
        .{ .n = "state", .s = "src/drivers/gl/es/state.zig" },
        .{ .n = "enable", .s = "src/drivers/gl/es/enable.zig" },
        .{ .n = "get", .s = "src/drivers/gl/es/get.zig" },
        .{ .n = "vertex", .s = "src/drivers/gl/es/vertex.zig" },
        .{ .n = "texobj", .s = "src/drivers/gl/es/texobj.zig" },
        .{ .n = "texparam", .s = "src/drivers/gl/es/texparam.zig" },
        .{ .n = "texenv", .s = "src/drivers/gl/es/texenv.zig" },
        .{ .n = "draw", .s = "src/drivers/gl/es/draw.zig" },
        .{ .n = "frame", .s = "src/drivers/gl/es/frame.zig" },
        .{ .n = "shaderkey", .s = "src/drivers/gl/es/shaderkey.zig" },
        .{ .n = "uniforms", .s = "src/drivers/gl/es/uniforms.zig" },
        .{ .n = "pipeline", .s = "src/drivers/gl/es/pipeline.zig" },
        .{ .n = "attrib", .s = "src/drivers/gl/es/attrib.zig" },
        .{ .n = "unpack", .s = "src/drivers/gl/es/unpack.zig" }, // pixel-unpack row math (was never wired as a root before)
        // --- virtualization subsystem (src/kernel/virt/): pure cores, host-tested ---
        .{ .n = "vmcs", .s = "src/kernel/virt/vmcs.zig" }, // VMCS field encodings + control-bit vocabulary
        .{ .n = "vmxcaps", .s = "src/kernel/virt/vmxcaps.zig" }, // VMX capability-MSR adjust/fixed-bit math
        .{ .n = "ept", .s = "src/kernel/virt/ept.zig" }, // EPT 2 MiB-page identity-offset map builder + walker
        .{ .n = "exitinfo", .s = "src/kernel/virt/exitinfo.zig" }, // VM-exit qualification decoders (IO/EPT/CR)
        .{ .n = "vmcheck", .s = "src/kernel/virt/vmcheck.zig" }, // guest-state validity checks (SDM §27.3)
        .{ .n = "uart16550", .s = "src/kernel/virt/uart16550.zig" }, // emulated 16550 serial state machine
        .{ .n = "i8259", .s = "src/kernel/virt/i8259.zig" }, // emulated 8259A PIC pair
        .{ .n = "i8254", .s = "src/kernel/virt/i8254.zig" }, // emulated 8254 PIT: the guest's legacy timer (IRQ 0)
        .{ .n = "guestcmos", .s = "src/kernel/virt/mc146818.zig", .t = "test/kernel/virt/mc146818_test.zig" }, // emulated MC146818 clock: the RTC read every Linux waits on
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/guestacpi_test.zig" }, // the guest's ACPI tables: RSDP + XSDT + MADT
        .{ .n = "x2apic", .s = "src/kernel/virt/x2apic.zig" }, // emulated x2APIC MSR register file
        .{ .n = "vcpuid", .s = "src/kernel/virt/vcpuid.zig" }, // guest CPUID filtering policy
        .{ .n = "vmsr", .s = "src/kernel/virt/vmsr.zig" }, // guest MSR read/write policy
        .{ .n = "msrarea", .s = "src/kernel/virt/msrarea.zig" }, // VM-entry/exit MSR-load/store area entry layout
        .{ .n = "bzimage", .s = "src/kernel/virt/bzimage.zig" }, // Linux/x86 bzImage header parse (64-bit boot protocol)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/layout_test.zig" }, // guest memory map + boot-artifact placement
        .{ .n = "e820", .s = "src/kernel/virt/e820.zig" }, // guest E820 map builder
        .{ .n = "bootparams", .s = "src/kernel/virt/bootparams.zig" }, // boot_params zero-page builder (byte-exact offsets)
        .{ .n = "gpt", .s = "src/kernel/virt/gpt.zig" }, // guest boot page tables + GDT
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/linuxload_test.zig" }, // full bzImage+initramfs load → entry state
        .{ .n = "guestwalk", .s = "src/kernel/virt/guestwalk.zig" }, // software walk of the guest's own page tables
        .{ .n = "insn", .s = "src/kernel/virt/insn.zig" }, // x86 MOV-subset decoder for MMIO exits
        .{ .n = "virtq", .s = "src/kernel/virt/virtio/virtq.zig" }, // split virtqueue over guest RAM (bounds-checked)
        .{ .n = "virtio_mmio", .s = "src/kernel/virt/virtio/mmio.zig", .t = "test/kernel/virt/virtio/virtio_mmio_test.zig" }, // virtio-mmio transport register machine
        .{ .n = "virtio_gpu", .s = "src/kernel/virt/virtio/gpu.zig", .t = "test/kernel/virt/virtio/virtio_gpu_test.zig" }, // virtio-gpu 2D command model
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/virtio/virtio_gpudev_test.zig" }, // the display adapter: 2D model behind the transport
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/virtio/virtio_netdev_test.zig" }, // the network adapter: rx/tx queues behind the transport, frames over the FrameSink seam
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/virtio/virtio_inputdev_test.zig" }, // keyboard + tablet: config selectors and evdev events behind the transport
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/virtio/virtio_blkdev_test.zig" }, // the disk: read/write/flush requests over a RAM-backed store
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/netbridge_test.zig" }, // the guest NIC bridge's forwarding policy (which port a frame is for)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/vfpu_test.zig" }, // the guest FPU register file: reset control words + the layout vmentry.asm indexes
        .{ .n = "vmslots", .s = "src/kernel/virt/vmslots.zig" }, // VM slot retirement handshake (window ↔ vCPU)
        .{ .n = "vspace", .s = "src/kernel/memory/vspace.zig" }, // 4-level address-space builder (MEM-001; session isolation)
        .{ .n = "testroot", .s = "src/test_root.zig", .t = "test/kernel/virt/guestlist_test.zig" }, // the `vm boot` network-image catalog (VIRT-019/020)
        .{ .n = "ivirt", .s = "src/iface/ivirt.zig" }, // hypervisor ↔ vm-app cross-core mailboxes
        .{ .n = "vmconsole", .s = "src/apps/vmconsole.zig" }, // VT100/ANSI serial-console terminal grid + named-key encoding
        // --- the widget toolkit (src/widgets/): the pieces the HUD is composed of ---
        .{ .n = "rects", .s = "src/widgets/rects.zig" }, // rectangle algebra: split, inset, grid
        .{ .n = "sampler", .s = "src/widgets/sampler.zig" }, // timed sample ring: rates, ranges, trend
    }) |hs| {
        // Default pairing MIRRORS the module's src/ directory: the test for
        // src/<group.../file>.zig lives at test/<group...>/<file>_test.zig.
        const sdir = std.fs.path.dirname(hs.s).?;
        const tst = hs.t orelse if (sdir.len > 4)
            b.fmt("test/{s}/{s}_test.zig", .{ sdir[4..], std.fs.path.stem(hs.s) })
        else
            b.fmt("test/{s}_test.zig", .{std.fs.path.stem(hs.s)});
        const mod = b.createModule(.{ .root_source_file = b.path(hs.s) });
        // The shared pantry, reachable from any pure module; each file imports
        // only what it names, the rest cost nothing.
        mod.addOptions("buildinfo", pure_buildinfo); // comptime flags (host shape: smp=false)
        mod.addImport("hostpush", hostpush_shared); // gl/ada method goldens
        mod.addImport("iramdisk", iramdisk_mod); // net/fileproto.zig server logic
        mod.addImport("algn", algn_mod); // alignment: one home
        mod.addImport("ilog", ilog_mod); // the log seam (null sink on the host)
        mod.addImport("ifilesys", ifilesys_mod); // vfs routing
        mod.addImport("vfs", vfs_mod); // complete's path normalization + MAX_PATH
        mod.addImport("keymap", keymap_mod); // editline's key codes
        mod.addImport("iblockdev", iblockdev_mod); // msc's Transport seam
        mod.addImport("abi", abi_mod); // .kudos loadable-binary ABI (loader + agent prompt)
        mod.addImport("sampler", sampler_mod); // hudsnapshot's trace-ring type
        mod.addImport("inet", inet_mod); // the network app-seam (http_wire's Header contract)
        mod.addImport("ring", ring_mod); // imouse's event ring
        mod.addImport("keymap", keymap_mod); // vmconsole's named-key control bytes (one home)
        mod.addImport("ivirt", ivirt_mod); // virtio-gpu / vm-app scanout + serial mailbox
        mod.addImport("surface", surface_mod); // chrome/dock theme dep
        mod.addImport("kgl", kgl_mod); // chrome/dock draw toolkit
        mod.addImport("idraw", idraw_mod); // the gl/es + gl/ada silicon seam
        mod.addImport("manifest", manifest_mod); // variant's compiled-shader set
        mod.addImport("theme", theme_mod); // the shared palette
        mod.addImport("rects", rects_mod); // widget rectangle algebra
        mod.addImport("sampler", sampler_mod); // widget sample rings
        mod.addImport("typeface", typeface_mod); // the baked scalable face
        mod.addImport("gltext", gltext_mod); // glyph sheets (one instance with kgl)
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(tst), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport(hs.n, mod);
        t.root_module.addImport("inet", inet_mod); // loop's Chat streams through inet.BodySink
        t.root_module.addImport("theme", theme_mod); // …against the shared palette
        t.root_module.addImport("rects", rects_mod); // widget tests assert on Rects
        t.root_module.addImport("typeface", typeface_mod); // …and measure real text
        // The .kudos ABI is reachable from any test (iwindow clamps to its bounds);
        // the abi entry already imports it under its own name via hs.n.
        if (!std.mem.eql(u8, hs.n, "abi")) t.root_module.addImport("abi", abi_mod);
        // Named-key control bytes, reachable from any test (vmconsole's arrow
        // encoding and the editline scripts name them); keymap self-imports via hs.n.
        if (!std.mem.eql(u8, hs.n, "keymap")) t.root_module.addImport("keymap", keymap_mod);
        t.root_module.addImport("draw_sim", draw_sim_mod); // shared draw fixture (test/support/)
        t.root_module.addImport("ramdisk_sim", ramdisk_sim_mod); // shared ramdisk fake (test/support/)
        t.root_module.addImport("percept", percept_mod); // perceptual-diff metric (test/support/)
        t.root_module.addImport("iblockdev", iblockdev_mod); // block-device seam for storage fakes
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // `zig build coverage` — run the host tests under kcov and merge the reports
    // into build/coverage/ (open index.html). Requires kcov on PATH. The >95%
    // branch+statement target is measured here.
    const cov_step = b.step("coverage", "Run host tests under kcov → build/coverage/ (needs kcov)");

    // gueststage: the staged-guest embed + validation (src/kernel/virt/gueststage.zig).
    // It needs the two guest blobs as named embeds — the same real-or-empty paths
    // the kernel gets — so the reachability test parses the exact bytes `vm boot`
    // would hand the loader. Not a pantry row: it carries these embeds alone.
    {
        const mod = b.createModule(.{ .root_source_file = b.path("src/test_root.zig") });
        mod.addAnonymousImport("guest_bzimage", .{ .root_source_file = guest_bzimage_path });
        mod.addAnonymousImport("guest_initramfs", .{ .root_source_file = guest_initramfs_path });
        for (bakeable, 0..) |id, i| {
            mod.addAnonymousImport(b.fmt("baked_{s}_bzimage", .{id}), .{ .root_source_file = baked_paths[i][0] });
            mod.addAnonymousImport(b.fmt("baked_{s}_initramfs", .{id}), .{ .root_source_file = baked_paths[i][1] });
        }
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/kernel/virt/gueststage_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("testroot", mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // truetype: the outline rasteriser, tested against the REAL shipped face —
    // the same file scripts/gen-font.py bakes the fixed-size atlas from, so the
    // test pins the rasteriser to the metrics the baked atlas already ships
    // (9 px advance at 14 px em). Not a pantry row: it carries that embed alone.
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/screen/truetype_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("truetype", truetype_mod);
        t.root_module.addAnonymousImport("font_ttf", .{ .root_source_file = b.path("src/ui/assets/RobotoMono-Regular.ttf") });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // glyphcache: the packed sheet the any-size text path draws from. It sits on
    // the rasteriser and the text-geometry module, and its test looks at both the
    // recorded boxes and the pixels under them, so it carries all three.
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/screen/glyphcache_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("glyphcache", glyphcache_mod);
        t.root_module.addImport("truetype", truetype_mod);
        t.root_module.addImport("gltext", gltext_mod);
        t.root_module.addAnonymousImport("font_ttf", .{ .root_source_file = b.path("src/ui/assets/RobotoMono-Regular.ttf") });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // The widget toolkit's tests. They drive the SAME module instances the kernel
    // draws with (widget_mods above), so a test asserting a Rect asserts the very
    // type the HUD passes in.
    // The test paths are written out rather than derived: an unwired test is a
    // comment, and the gate can only see wiring it can read (scripts/tests/layering.sh).
    const widget_tests = [widget_names.len][]const u8{
        "test/widgets/panel_test.zig",
        "test/widgets/meter_test.zig",
        "test/widgets/stackbar_test.zig",
        "test/widgets/sparkline_test.zig",
        "test/widgets/statile_test.zig",
        "test/widgets/hudview_test.zig",
    };
    for (widget_names, widget_tests, 0..) |wn, wt, wi| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(wt),
            .target = b.graph.host,
            .optimize = optimize,
        }) });
        t.root_module.addImport(wn, widget_mods[wi]);
        t.root_module.addImport("rects", rects_mod);
        t.root_module.addImport("theme", theme_mod);
        t.root_module.addImport("typeface", typeface_mod);
        // The paint stack, so a widget suite can also DRAW its widget (through
        // the real painter into the software rasteriser) — the pure-math half
        // alone leaves every fill/outline arm a ghost.
        t.root_module.addImport("kgl", kgl_mod);
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("soft", soft_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // netdebug server logic through the iramdisk seam with RamdiskSim
    // (the kernel glue adds only transport).
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/net/debug/fileserv_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("iramdisk", iramdisk_mod);
        t.root_module.addImport("fileproto", fileproto_mod);
        t.root_module.addImport("ramdisk_sim", ramdisk_sim_mod); // shared ramdisk fake (test/support/)
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }
    // The whole interface layer compiles on the host (ARCH-003): one sweep suite
    // imports every src/iface contract by name; layering.sh enforces completeness.
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/iface/contracts_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("iaccel", iaccel_mod);
        t.root_module.addImport("iblockdev", iblockdev_mod);
        t.root_module.addImport("idesk", idesk_mod);
        t.root_module.addImport("idevices", idevices_mod);
        t.root_module.addImport("idisplay", idisplay_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("ifilesys", ifilesys_mod);
        t.root_module.addImport("ilog", ilog_mod);
        t.root_module.addImport("imouse", imouse_mod);
        t.root_module.addImport("inet", inet_mod);
        t.root_module.addImport("ipci", ipci_mod);
        t.root_module.addImport("ipresent", ipresent_mod);
        t.root_module.addImport("iramdisk", iramdisk_mod);
        t.root_module.addImport("ivirt", ivirt_mod);
        const iwindow_sweep = b.createModule(.{ .root_source_file = b.path("src/iface/iwindow.zig") });
        iwindow_sweep.addImport("abi", abi_mod);
        iwindow_sweep.addImport("ring", ring_mod); // the focused-window key ring (MOD-013)
        t.root_module.addImport("iwindow", iwindow_sweep);
        t.root_module.addImport("iscene", b.createModule(.{ .root_source_file = b.path("src/iface/iscene.zig") }));
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // fetchjob: the resumable HTTP GET state machine over the job runner + the
    // pure http_wire framing (which reaches the inet Header contract). Both the
    // module and its test name `job`, so wire it explicitly (not the pantry).
    {
        const fetchjob_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/net/stack/fetchjob.zig") });
        fetchjob_mod.addImport("job", job_mod); // the shared job module (created above)
        fetchjob_mod.addImport("inet", inet_mod); // http_wire.zig's Header contract
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/net/stack/fetchjob_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("fetchjob", fetchjob_mod);
        t.root_module.addImport("job", job_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // IRamdisk contract conformance: the real ramdisk and the RamdiskSim fake
    // through ONE shared vector suite (spec R69).
    {
        const sroot = b.createModule(.{ .root_source_file = b.path("src/test_root.zig") });
        sroot.addImport("iramdisk", iramdisk_mod);
        // ramdisk.zig also reaches the ifilesys seam.
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/iface/iramdisk_conformance.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("ramdisk_sim", ramdisk_sim_mod); // shared fixture (test/support/)
        t.root_module.addImport("iramdisk", iramdisk_mod);
        t.root_module.addImport("testroot", sroot);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // IFileSys contract conformance: the real ramdisk fileSys and an in-memory
    // fake through ONE shared vector suite (spec R69).
    {
        const sroot = b.createModule(.{ .root_source_file = b.path("src/test_root.zig") });
        sroot.addImport("iramdisk", iramdisk_mod);
        sroot.addImport("ifilesys", ifilesys_mod);
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/iface/ifilesys_conformance.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("ifilesys", ifilesys_mod);
        t.root_module.addImport("testroot", sroot);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // IBlockDev contract conformance: the 512-byte block seam through ONE
    // shared vector suite (spec R69). The real MSC driver satisfies the same
    // surface via msc_test/fat_test.
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/iface/iblockdev_conformance.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("iblockdev", iblockdev_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // pngenc: the PNG ENCODER round-tripped through the tree's own decoder —
    // what kudos writes (screenshots, R33) its asset pipeline reads back.
    {
        const pngenc_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/gpu/base/pngenc.zig") });
        const png_mod = b.createModule(.{ .root_source_file = b.path("src/ui/assets/png.zig") });
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/gpu/base/pngenc_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("pngenc", pngenc_mod);
        t.root_module.addImport("png", png_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // Trusted-CA roots (spec NET-011/NET-015): PEM-bundle parse + the
    // clock-validity floor rule, exercised against the REAL shipped bundle
    // (as an anonymous import — test/ cannot @embedFile outside its root).
    {
        const roots_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/net/stack/roots.zig") });
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/net/stack/roots_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("roots", roots_mod);
        t.root_module.addAnonymousImport("cacert_pem", .{ .root_source_file = b.path("assets/net/cacert.pem") });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // GLB parser: the synthetic container/accessor error matrix + the real
    // Khronos fixtures (test/ui/assets/fixtures/*.glb) + the teapot.glb ramdisk
    // seed (as an anonymous import — no fixture copy).
    {
        const glb_mod = b.createModule(.{ .root_source_file = b.path("src/ui/assets/glb.zig") });
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/assets/glb_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("glb", glb_mod);
        t.root_module.addAnonymousImport("model_alphablend", .{ .root_source_file = b.path("assets/models/AlphaBlendModeTest.glb") });
        t.root_module.addAnonymousImport("model_box", .{ .root_source_file = b.path("assets/models/Box.glb") });
        t.root_module.addAnonymousImport("model_boxinterleaved", .{ .root_source_file = b.path("assets/models/BoxInterleaved.glb") });
        t.root_module.addAnonymousImport("model_boxtextured", .{ .root_source_file = b.path("assets/models/BoxTextured.glb") });
        t.root_module.addAnonymousImport("model_duck", .{ .root_source_file = b.path("src/ui/assets/duck.glb") });
        t.root_module.addAnonymousImport("model_orientation", .{ .root_source_file = b.path("assets/models/OrientationTest.glb") });
        t.root_module.addAnonymousImport("model_simplemeshes", .{ .root_source_file = b.path("assets/models/SimpleMeshes.gltf") });
        t.root_module.addAnonymousImport("model_texcoord", .{ .root_source_file = b.path("assets/models/TextureCoordinateTest.glb") });
        t.root_module.addAnonymousImport("model_triangle", .{ .root_source_file = b.path("assets/models/Triangle.gltf") });
        t.root_module.addAnonymousImport("model_trianglenoidx", .{ .root_source_file = b.path("assets/models/TriangleWithoutIndices.gltf") });
        t.root_module.addAnonymousImport("model_vertexcolor", .{ .root_source_file = b.path("assets/models/VertexColorTest.glb") });
        t.root_module.addAnonymousImport("teapot_glb", .{ .root_source_file = b.path("src/ui/assets/teapot.glb") });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // PNG decoder (assets/png.zig): in-test-encoded synthetic PNGs (every row
    // filter/color type/error class) + Duck.glb's real embedded texture
    // against Python-reference goldens. Imports glb for the end-to-end path.
    {
        const png_mod = b.createModule(.{ .root_source_file = b.path("src/ui/assets/png.zig") });
        const glb_mod2 = b.createModule(.{ .root_source_file = b.path("src/ui/assets/glb.zig") });
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/assets/png_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("png", png_mod);
        t.root_module.addImport("glb", glb_mod2);
        t.root_module.addAnonymousImport("model_duck", .{ .root_source_file = b.path("src/ui/assets/duck.glb") });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // JPEG decoder (assets/jpeg.zig): real baseline + progressive fixtures
    // (test/ui/assets/fixtures/jpeg_*.jpg) decoded against libjpeg-turbo PPM goldens
    // (same 2.1.5 library ImageMagick links) within a small per-channel
    // tolerance, plus the loud-rejection error matrix. Imports glb for the
    // end-to-end embedded-JPEG path.
    {
        const jpeg_mod = b.createModule(.{ .root_source_file = b.path("src/ui/assets/jpeg.zig") });
        const glb_mod4 = b.createModule(.{ .root_source_file = b.path("src/ui/assets/glb.zig") });
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/assets/jpeg_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("jpeg", jpeg_mod);
        t.root_module.addImport("glb", glb_mod4);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // DrawSim: the IDraw fake's contract tests — the pipelined frame cycle and the
    // object lifetimes the GL layer drives through the silicon seam (the real impl is
    // HW-verified via the live-run screenshot).
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/support/draw_sim.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("idraw", idraw_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // Pixels, on the host. RasterSim implements the SAME device contract in software and
    // decodes the SAME constant buffer the shaders will, so these tests answer the one
    // question DrawSim cannot: does this draw the right thing? It found the unflipped
    // scissor in glClear on its first run. It is a reference for the specification, not
    // a renderer kudos ships — the 4090 path stays hardware-verified.
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/gl/raster_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("soft", soft_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // The blob-window scene replay against real pixels: the reference cube's
    // recorded frame, drawn by the same call sequence blobwin.drawInline
    // issues, judged for solidity and shading (MOD-015).
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/gl/cube_replay_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("soft", soft_mod);
        // The lamp the replay lights lit scenes with — spin.zig owns those facts.
        t.root_module.addImport("spin", b.createModule(.{ .root_source_file = b.path("src/apps/spin.zig") }));
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // gles end to end: the API driven the way an application drives it — glEnable,
    // glVertexPointer, glDrawArrays — all the way to what DrawSim says arrived at the
    // silicon seam. The per-file tests below prove each part; this proves they agree,
    // which is a different thing and has already caught a bug that lived between two
    // files rather than in either.
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/gl/gles_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("draw_sim", draw_sim_mod); // shared fixture (test/support/)
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // The GPU-drawn UI's pure logic: the macOS window chrome's traffic-light hit-tests
    // (chrome.zig) and the dock's slab/icon layout + hit-tests (dock.zig). Both draw
    // through `kgl` (which brings gles + the geom/gltext internals) and read the theme
    // (which imports surface), so they carry those two named deps.
    for ([_][]const u8{ "src/ui/wm/chrome.zig", "src/ui/desktop/dock.zig" }) |tf| {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(tf), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("kgl", kgl_mod);
        t.root_module.addImport("surface", surface_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // `zig build screenshot` — compose the whole GPU-drawn desktop (wallpaper, windows
    // with traffic-light chrome, the dock) through the real gles toolkit into RasterSim,
    // and write it out as build/desktop_shot.ppm. The window manager, SEEN, with no 4090:
    // the same draws the 4090 will run, rasterised in software so a chrome or dock change
    // can be reviewed on a laptop. Its own step (not `test`) because it writes a file.
    // `zig build hud-shot` — a picture of the heads-up display, drawn through the
    // real painter into the software rasteriser. The display's view is a pure
    // function of a snapshot, so this needs no machine to read and no GPU to draw:
    // it is how the layout gets looked at on a laptop.
    {
        const hud_shot_step = b.step("hud-shot", "Render the heads-up display (gles → Soft) to build/hud_shot.ppm");
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/hud_shot.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("soft", soft_mod);
        t.root_module.addImport("kgl", kgl_mod);
        t.root_module.addImport("rects", rects_mod);
        t.root_module.addImport("typeface", typeface_mod);
        t.root_module.addImport("hudview", widget_mods[widget_names.len - 1]);
        hud_shot_step.dependOn(&b.addRunArtifact(t).step);
        // The layout assertions inside it are part of the gate, not just the picture.
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // `zig build vm-shot` — a picture of the VM console window, replaying a REAL
    // guest transcript through the same painter the desktop uses. The nested
    // guest runs on a machine with no GPU, so this is the only way its window
    // can be seen at all.
    {
        const vm_shot_step = b.step("vm-shot", "Render the VM console window (gles → Soft) to build/vm_shot.ppm");
        const shot_ui = b.createModule(.{ .root_source_file = b.path("src/ui/desktop_shot_testroot.zig") });
        shot_ui.addImport("kgl", kgl_mod);
        shot_ui.addImport("surface", surface_mod);
        shot_ui.addImport("theme", theme_mod);
        const vmconsole_mod = b.createModule(.{ .root_source_file = b.path("src/apps/vmconsole.zig") });
        vmconsole_mod.addImport("keymap", keymap_mod); // the named-key control bytes vmconsole encodes
        vmconsole_mod.addImport("ring", ring_mod); // SerialQueue's FIFO of bytes owed to the guest
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/vm_shot.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("soft", soft_mod);
        t.root_module.addImport("ui", shot_ui);
        t.root_module.addImport("vmconsole", vmconsole_mod);
        vm_shot_step.dependOn(&b.addRunArtifact(t).step);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
    }

    {
        const shot_step = b.step("screenshot", "Render the desktop (gles → RasterSim) to build/desktop_shot.ppm");
        // The toolkit through one module root (src/ui/) so its cross-folder relative
        // imports resolve; gles + surface (theme's dep) come in by name.
        const shot_ui_mod = b.createModule(.{ .root_source_file = b.path("src/ui/desktop_shot_testroot.zig") });
        shot_ui_mod.addImport("kgl", kgl_mod);
        shot_ui_mod.addImport("surface", surface_mod);
        shot_ui_mod.addImport("theme", theme_mod); // chrome + dock draw from the palette
        shot_ui_mod.addImport("modelcache", kernel_modelcache_mod); // its png decoder, for the wallpaper
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/desktop_shot.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addAnonymousImport("background_png", .{ .root_source_file = b.path("assets/media/background.png") });
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("ui", shot_ui_mod);
        t.root_module.addImport("soft", soft_mod);
        shot_step.dependOn(&b.addRunArtifact(t).step);
        // ...and in the GATE, not only behind `zig build screenshot`: it
        // renders the whole desktop through kgl → gles → the software
        // rasteriser and asserts GL_NO_ERROR, which is the composition check
        // no other host suite makes. A suite only a manual step runs is a
        // suite that rots (process.md §17).
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // The ES 1.1 state entry points, driven through the PUBLIC gles surface on
    // the software rasteriser: strings, capability toggles, get*v, texparams.
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/gl/es/entrypoints_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("soft", soft_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // modelcache: the model viewer's pure load chain (vfs → glb → png →
    // textureCreate/meshCreate) end-to-end against the REAL seed assets
    // through OpenGlSim — the kernel adds only the stack it runs on.
    {
        const modelcache_mod = b.createModule(.{ .root_source_file = b.path("src/ui/assets/modelcache.zig") });
        modelcache_mod.addImport("vfs", vfs_mod);
        modelcache_mod.addImport("kgl", kgl_mod); // GL image upload lives in kgl
        modelcache_mod.addImport("gles", gles_mod);
        modelcache_mod.addImport("ilog", ilog_mod);
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/assets/modelcache_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("modelcache", modelcache_mod);
        t.root_module.addImport("vfs", vfs_mod);
        t.root_module.addImport("ifilesys", ifilesys_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("draw_sim", draw_sim_mod); // shared draw fixture (test/support/)
        t.root_module.addAnonymousImport("teapot_glb", .{ .root_source_file = b.path("src/ui/assets/teapot.glb") });
        t.root_module.addAnonymousImport("duck_glb", .{ .root_source_file = b.path("src/ui/assets/duck.glb") });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // The reference-render oracle, host half (spec TEST-004/TEST-006): every
    // feature-tier fixture rendered through the real loader into the software
    // rasteriser — byte-compared against committed self-blessed goldens
    // (test/ui/assets/fixtures/renders; bless via scripts/gl/bless_renders.sh after
    // inspecting build/renders), and the feature models additionally compared
    // perceptually against the PUBLISHED Khronos screenshots
    // (test/ui/assets/fixtures/reference, metric in test/support/percept.zig).
    {
        const assets_root_mod = b.createModule(.{ .root_source_file = b.path("src/test_root.zig") });
        assets_root_mod.addImport("modelcache", kernel_modelcache_mod);
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/ui/assets/render_oracle_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("percept", percept_mod); // shared fixture (test/support/)
        t.root_module.addImport("testroot", assets_root_mod);
        t.root_module.addImport("vfs", vfs_mod);
        t.root_module.addImport("ifilesys", ifilesys_mod);
        t.root_module.addImport("gles", gles_mod);
        t.root_module.addImport("idraw", idraw_mod);
        t.root_module.addImport("soft", soft_mod);
        // spin.zig owns the viewer's pose + lamp; the oracle frames from it.
        t.root_module.addImport("spin", b.createModule(.{ .root_source_file = b.path("src/apps/spin.zig") }));
        t.root_module.addAnonymousImport("oracle_triangle", .{ .root_source_file = b.path("assets/models/Triangle.gltf") });
        t.root_module.addAnonymousImport("oracle_boxinterleaved", .{ .root_source_file = b.path("assets/models/BoxInterleaved.glb") });
        t.root_module.addAnonymousImport("oracle_boxtextured", .{ .root_source_file = b.path("assets/models/BoxTextured.glb") });
        t.root_module.addAnonymousImport("oracle_duck", .{ .root_source_file = b.path("src/ui/assets/duck.glb") });
        t.root_module.addAnonymousImport("oracle_vertexcolortest", .{ .root_source_file = b.path("assets/models/VertexColorTest.glb") });
        t.root_module.addAnonymousImport("oracle_alphablendmodetest", .{ .root_source_file = b.path("assets/models/AlphaBlendModeTest.glb") });
        t.root_module.addAnonymousImport("oracle_texturecoordinatetest", .{ .root_source_file = b.path("assets/models/TextureCoordinateTest.glb") });
        t.root_module.addAnonymousImport("oracle_orientationtest", .{ .root_source_file = b.path("assets/models/OrientationTest.glb") });
        t.root_module.addAnonymousImport("oracle_normaltangenttest", .{ .root_source_file = b.path("assets/models/NormalTangentTest.glb") });
        t.root_module.addAnonymousImport("oracle_metalroughspheres", .{ .root_source_file = b.path("assets/models/MetalRoughSpheres.glb") });
        // The published Khronos reference renderings (TEST-006) — provenance
        // and licenses in test/ui/assets/fixtures/reference/README.md.
        t.root_module.addAnonymousImport("ref_alphablendmodetest", .{ .root_source_file = b.path("test/ui/assets/fixtures/reference/AlphaBlendModeTest.png") });
        t.root_module.addAnonymousImport("ref_vertexcolortest", .{ .root_source_file = b.path("test/ui/assets/fixtures/reference/VertexColorTest.png") });
        t.root_module.addAnonymousImport("ref_texturecoordinatetest", .{ .root_source_file = b.path("test/ui/assets/fixtures/reference/TextureCoordinateTest.png") });
        t.root_module.addAnonymousImport("ref_orientationtest", .{ .root_source_file = b.path("test/ui/assets/fixtures/reference/OrientationTest.png") });
        t.root_module.addAnonymousImport("ref_normaltangenttest", .{ .root_source_file = b.path("test/ui/assets/fixtures/reference/NormalTangentTest.png") });
        t.root_module.addAnonymousImport("ref_metalroughspheres", .{ .root_source_file = b.path("test/ui/assets/fixtures/reference/MetalRoughSpheres.png") });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // The perceptual-comparison metric (test/support/percept.zig, pure): the TEST-006
    // conformance gate's arithmetic, pinned by hand-computable cases.
    {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/support/percept_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // fat: the FAT16/FAT32 reader against REAL mkfs.vfat images
    // (test/ui/assets/fixtures/fat*.img.gz — scripts/tests/make-fat-fixtures.sh), through a
    // fake IBlockDev; includes the FAT-read → GLB-parse end-to-end.
    {
        const fat_mod = b.createModule(.{ .root_source_file = b.path("src/drivers/storage/fat.zig") });
        fat_mod.addImport("iblockdev", iblockdev_mod);
        fat_mod.addImport("ifilesys", ifilesys_mod);
        fat_mod.addImport("ilog", ilog_mod); // the failure-report seam (null sink on the host)
        const glb_mod3 = b.createModule(.{ .root_source_file = b.path("src/ui/assets/glb.zig") });
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/drivers/storage/fat_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("fat", fat_mod);
        t.root_module.addImport("glb", glb_mod3);
        t.root_module.addImport("iblockdev", iblockdev_mod);
        t.root_module.addImport("ifilesys", ifilesys_mod);
        t.root_module.addAnonymousImport("duck_glb", .{ .root_source_file = b.path("src/ui/assets/duck.glb") });
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // terminal: the resize/grid re-layout path (the resize text-corruption bug). The
    // module roots at src/test_root.zig so terminal.zig's cross-group relative
    // imports resolve. It needs the iface modules by name plus a host buildinfo
    // (smp=false; the SMP plumbing is never analyzed by these tests but the named
    // module must resolve).
    {
        const terminal_root_mod = b.createModule(.{ .root_source_file = b.path("src/test_root.zig") });
        for (iface_mods) |im| terminal_root_mod.addImport(im.name, im.mod);
        const host_buildinfo = b.addOptions();
        host_buildinfo.addOption(u32, "build_number", build_number);
        host_buildinfo.addOption([]const u8, "git_hash", git_hash);
        host_buildinfo.addOption([]const u8, "build_time", build_time);
        host_buildinfo.addOption(bool, "smp", false);
        host_buildinfo.addOption(bool, "smp_minimal", false);
        host_buildinfo.addOption(bool, "flip_sample", flip_sample);
        host_buildinfo.addOption(bool, "test_hooks", test_hooks);
        host_buildinfo.addOption(bool, "verify_script", false);
        host_buildinfo.addOption(bool, "heartbeat", false);
        host_buildinfo.addOption([]const u8, "staged_guest", staged_guest_name);
        host_buildinfo.addOption(u32, "usb_max_gb", usb_max_gb);
        terminal_root_mod.addOptions("buildinfo", host_buildinfo);
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/apps/terminal_test.zig"), .target = b.graph.host, .optimize = optimize }) });
        t.root_module.addImport("testroot", terminal_root_mod);
        if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);
        cov_bins.append(b.allocator, t) catch @panic("OOM");
    }

    // Coverage runs OUTSIDE the build runner (scripts/tests/coverage.sh): under
    // the runner every kcov invocation exits 1 AFTER its tests pass, while the
    // identical command succeeds in a shell — so the build's whole job here is
    // to BUILD and NAME the test binaries. They install to build/testbin/ and
    // the script sweeps kcov over them and merges the report.
    //
    // `-Dllvm` forces the LLVM backend on these binaries: the self-hosted Debug
    // backend's DWARF is thin enough that kcov attributes only a fraction of
    // the files; the measurement needs LLVM's full line tables.
    const cov_llvm = b.option(bool, "llvm", "Coverage binaries via the LLVM backend (full DWARF for kcov)") orelse false;
    for (cov_bins.items, 0..) |t, i| {
        if (cov_llvm) t.use_llvm = true;
        const inst = b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "testbin" } },
            .dest_sub_path = b.fmt("t{d}", .{i}),
        });
        cov_step.dependOn(&inst.step);
    }
}

/// Whether `-Dtest-only`'s substring admits this test root into the test step.
/// An empty filter admits everything; a root with no source path is never
/// filtered out (there is nothing to match it against).
fn testWired(only: []const u8, t: *std.Build.Step.Compile) bool {
    if (only.len == 0) return true;
    const src = t.root_module.root_source_file orelse return true;
    return std.mem.indexOf(u8, src.getDisplayName(), only) != null;
}

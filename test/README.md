# test/ — host-test fakes, end-to-end test suites, fixtures

Everything here runs on the HOST via `zig build test` (rerun under kcov by
`zig build coverage`). Naming (CLAUDE.md "Interface naming"):

- `*_sim.zig` — a FAKE implementing an `src/iface/` contract. Two shapes:
  - fake-only helper, sibling-imported by the tests that need it
    (`ramdisk_sim.zig` → `RamdiskSim`);
  - fake + its own `test {}` blocks, wired as its own test root in build.zig
    (`opengl_sim.zig` → `OpenGlSim`; the present path's pure sub-suites, which
    drives the real present/mirror path against a poison-filled address-space
    model).
  A fake used by exactly ONE test may live inline in that test file instead
  (`DisplaySim` inside `display_sim_test.zig`) — no indirection for no benefit.
- `*_test.zig` — a host test suite over real `src/` code reached through the
  iface seams / named modules (wired in build.zig's `test` step):
  `compositor_geom_test`, `display_sim_test` (end-to-end Compositor.render
  against the fake Display), `fileserv_test` (the KMR1 netdebug server logic),
  `glb_test` + `png_test` + `jpeg_test` (model/texture/image parsers vs real Khronos
  files and libjpeg-turbo goldens), `modelcache_test`, `fat_test` (FAT16/32 vs real
  mkfs.vfat images).
- `fixtures/` — binary test inputs: Khronos sample models (`Box.glb`,
  `BoxInterleaved.glb`, `Duck.glb`), a JPEG corpus with libjpeg-turbo PPM goldens
  (`jpeg_*.jpg` / `.ppm`), generated FAT volume images (`fat*.img.gz`, regenerate with
  `scripts/tests/make-fat-fixtures.sh`), and `usbdisk/hello.txt` — the pinned content of
  the real USB stick (`scripts/tests/usbdisk.py`). The ramdisk
  seed models (`teapot.glb`, `duck.glb`) live in `src/ui/assets/` — they are
  PRODUCT assets the kernel embeds, referenced by tests as anonymous imports;
  fixtures here are TEST-ONLY inputs. `fixtures/renders/` holds the
  self-blessed regression goldens and `fixtures/reference/` the published
  Khronos screenshots (see its README) — both consumed by
  `render_oracle_test.zig`, whose perceptual metric lives in `percept.zig`
  (pure, sibling-imported, unit-tested in `percept_test.zig`).

Test roots that must sit inside `src/` to resolve relative imports
(the one host-test module root, `src/test_root.zig`) is wired only
into the `test` build; see CLAUDE.md "Source layout".

The RUNNING-OS integration suite (boots kudos and drives it end-to-end) is
separate: `scripts/tests/` — see its README.

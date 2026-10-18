# Japan Open World — V1 release

**V1 is the first verified, playable, packaged build of a real Kyoto open-world slice.**

- **Project:** Japan Open World
- **Engine:** Godot 4.6.3 (`4.6.3.stable.official.7d41c59c4`)
- **Platform:** Linux/X11 x86_64
- **Repository:** <https://github.com/Daniel-debug-boop/japan-game-openworld1>
- **This release:** commit `cd6cba9` on `freebuff/51adb5b5ab6c0f2a4385ab00`
- **Build:** `build_output/japan_open_world-linux-x86_64.tar.gz`
- **Generated:** 2026-10-17 UTC (see `build_output/build_report.json`)

## What you get

A third-person game set in **central Kyoto**, generated from real world data:

- real Kyoto elevation terrain from AWS terrain tiles,
- real OpenStreetMap roads and building footprints,
- real MLIT PLATEAU Kyoto 3D city geometry,
- real CC0 Poly Haven PBR materials and HDRI sky,
- main menu, settings, third-person controller, lantern objective loop, save/pause.

The playable region is about **4 km × 4 km** around the Kyoto basin and eastern hills.

## What V1 verifies

V1 is not just "the build ran". It is the first point where the following are all true
at once, using the packaged binary, the visual acceptance tooling, and the headless suite:

- the project imports cleanly and passes static + data validation,
- a runtime smoke test boots the world and checks terrain, OSM, PLATEAU streaming, player
  placement, and objectives,
- the Linux export succeeds and the **packaged binary** passes a smoke test,
- the packaged binary renders distinct, non-blank, non-duplicate views of the streamed world,
- the visual acceptance tooling independently inspects the captured pixels,
- the archive is distributed with SHA-256 checksums.

Evidence lives in:

- `build_output/build_report.json`
- `build_output/SHA256SUMS.txt`
- `docs/TEST_REPORT.md`
- `tests/run_tests.sh`
- `tools/visual_acceptance.sh`
- `tools/verify_screenshots.py`

Feature status detail is in `docs/FEATURE_MATRIX.md`.

## Play it

```bash
tar -xzf japan_open_world-linux-x86_64.tar.gz
./japan_open_world.x86_64
```

Controls: move with `WASD`, sprint with `Shift`, jump with `Space`, interact with `E`,
toggle first/third person with `C`, pause with `Esc`.

The objective is to restore eight lanterns at real Kyoto landmarks.

## Rebuild it

```bash
python3 -m pip install pillow numpy DracoPy
python3 tools/build_world.py
python3 tools/fetch_assets.py
python3 tools/fetch_plateau.py   # optional; required for PLATEAU geometry
bash tools/build_release.sh
```

The build pins Godot 4.6.3 and verifies the download by SHA-256. See `BUILD.md` for
requirements, the Terrain3D decision, PLATEAU setup, and troubleshooting.

## What this is not yet

V1 is a **playable vertical slice**, not a finished game.

It does **not** yet include:

- a playable character model (the slice uses a capsule proxy),
- multiplayer,
- building interiors,
- gamepad support,
- audio,
- Windows/macOS/Web/mobile exports,
- a fully reviewed GPU look, frame rate, and terrain LOD quality on real hardware.

Some of those are architectural scope decisions, not bugs. Others are flagged as
unverified where this environment could not exercise them, for example a real Vulkan ICD
and a real GPU frame-rate measurement. Those distinctions are recorded honestly in
`docs/FEATURE_MATRIX.md`.

## How to read "ready"

For this project, "V1 ready" means:

- the build is reproducible,
- the package is self-contained and checksummed,
- the shipped binary passes smoke + visual acceptance,
- the limitations are documented instead of assumed.

If your bar for "ready" is broader than that, say so and this can be adjusted before the
next push.

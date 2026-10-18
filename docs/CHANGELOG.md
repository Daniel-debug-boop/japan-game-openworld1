# Changelog

All notable changes are listed here.

## 2026-10-17 — fix: the rendered image (visual acceptance failure)

The build and every headless test passed while the game rendered an unusable image: a grey
band with green blocks. Root causes, each fixed and verified by rendering the packaged build
under Xvfb + Mesa and inspecting the pixels:

- **Camera roll on steep views.** The harness aimed with `look_at(at, Vector3.UP)`, which is
  ill-conditioned when the view direction is nearly parallel to the up vector — a camera high
  above the basin looking down into it — and the camera came out inverted, producing the
  original frame with ground above the sky. `_up_for()` now selects a stable up axis for
  near-vertical views. Correction for the record: an earlier revision of this entry blamed a
  Y-inverted viewport readback under the Compatibility renderer. Measurement disproved that —
  `camera_up_dot_world_up` is 0.94-1.00 and `orientation_corrected` is false on every shot,
  i.e. the readback is upright. The probe bands remain as a measurement, not a workaround.
- **PLATEAU geometry was missing from the packaged build.** `export_presets.cfg` had
  `include_filter="*.json, *.f32, *.dat"`, so the PCK shipped `index.json` but none of the 193
  `.pmesh` payloads and the loader fell back to OSM boxes. The packaged smoke test said
  `plateau_available=no`; adding `*.pmesh` changed it to `plateau_available=yes
  plateau_tiles=18` and the PCK from 92 MB to 247 MB.
- **Facades were green.** Poly Haven's `painted_concrete` albedo is a green-painted wall
  (measured mean RGB 72,106,79). Both building materials now apply a `FACADE_TINT` solved
  from that mean, giving a neutral concrete albedo (~0.35) without raising brightness.
  `tests/validate_project.gd` asserts the effective albedo stays neutral.
- **Capture vantage points were outside the streamed world.** Every shot teleported the
  player to one spot and parked the camera hundreds of metres away, past the terrain/city
  stream radius, so the frame held almost no world. Shots are now anchored to the player.
- **Capture waited a fixed 3 frames** instead of the streaming counters. It now polls
  terrain/city/PLATEAU counts to a wall-clock deadline and records what was resident.
- **The software display never came up.** `tools/setup_software_display.sh` shipped the Xvfb
  binary but not its libraries, so Xvfb could not start and graphical capture silently
  degraded to headless. It now installs the full transitive set, provides `xkbcomp` where
  Debian's Xvfb looks for it (via a user namespace, no root), uses valid flags, and verifies
  the display before reporting success.
- Added `tools/visual_acceptance.sh` (end-to-end graphical acceptance), 
  `tools/verify_screenshots.py` (independent pixel verification) and an in-game capture
  driver that also runs in the exported build via `-- --visual-capture=DIR`.
- Added a graphical acceptance stage (cell 3b) to the Colab notebook, which picks `vulkan`
  when a Vulkan ICD is present and falls back to `opengl3` otherwise.
- Verified: packaged build renders 5 distinct 1280x704 views with terrain (8 chunks), OSM
  city (8 chunks) and PLATEAU (up to 18 tiles) resident; 69 validation assertions, runtime
  smoke and packaged smoke all exit 0.

## 2026-10-17 — PLATEAU Kyoto building integration (this commit: `4a467c2`)

- Added `tools/fetch_plateau.py`: official PLATEAU/MLIT tileset discovery → 3D Tiles 1.0 b3dm → Draco decode (via `DracoPy`) → Godot `.pmesh` + collision, georeferenced with a real vertical offset (224.95 m).
- Added `scripts/world/plateau_city.gd`: streaming PLATEAU loader (radius + hysteresis unload, async build, cache, graceful missing-tile skip) integrated with `main_world.gd`, suppressing OSM box buildings under real PLATEAU coverage.
- Added PLATEAU validation assertions (index, vertical offset, source, sampled `.pmesh` structural validity) in `tests/validate_project.gd`, and PLATEAU streaming/runtime assertions in `tests/smoke_test.gd`.
- Added dedicated `tests/plateau_failure_test.gd`/`.tscn` for missing-tile resilience.
- Added screenshot capture harness `tests/capture_screenshots.gd`/`.tscn` and frame/rendering probe scenes (`tests/probe_rendering.gd`, `tests/probe_frames.gd`).
- Updated `tools/build_release.sh` with a `step_plateau` build step (skip-able via `--skip-plateau`).
- Updated docs: `FEATURE_MATRIX.md`, `TEST_REPORT.md`, `THIRD_PARTY_NOTICES.md` (PDL 1.0 attribution), `BUILD.md`.
- Verified on this commit: static + data validation 59 assertions / exit 0; runtime smoke 20 assertions / exit 0; packaged smoke / exit 0.

## 2026-10-17 — docs: record measured build metrics and full test report (commit `d7355f3`)

- Recorded measured build metrics and a full test report in `docs/TEST_REPORT.md`.
- Static + data validation: 55 assertions, exit 0. Runtime smoke: 15 assertions, exit 0. Packaged smoke: exit 0.

## 2026-10-16 — feat: playable Kyoto open-world slice with verified Linux build pipeline (commit `3051712`)

- First playable vertical slice: main menu + settings, third-person controller, orbit camera, interact/objective loop, save/pause, DEM terrain, OSM roads + buildings, chunk streaming, Poly Haven PBR + HDRI, Linux/X11 export with packaged smoke test and SHA-256 archive.

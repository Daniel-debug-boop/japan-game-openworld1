# Building Japan Open World

## Target

- **Engine:** Godot **4.6.3** (verified: `4.6.3.stable.official.7d41c59c4`)
- **First target platform:** Linux x86_64 desktop
- **Renderer:** Forward+ (Vulkan) with GL Compatibility fallback declared for web/mobile

---

## Requirements

| Requirement | Version | Notes |
|---|---|---|
| Godot editor | 4.6.3-stable | Downloaded and SHA-256 verified by `tools/build_release.sh` |
| Godot export templates | 4.6.3-stable | Same script |
| Python | 3.9+ | For the world-data pipeline |
| `pillow`, `numpy` | recent | `python3 -m pip install pillow numpy` |
| `curl`, `unzip`, `tar`, `sha256sum` | any | System tools |
| Disk | ~2.5 GB | Godot + templates + build output |

No GPU is required to build. Rendering quality and frame rate must be validated on real
hardware (see `TESTING.md`).

---

## One-command build

```bash
GODOT_BIN=/path/to/godot bash tools/build_release.sh
```

If `GODOT_BIN` is unset, the script looks for `godot`/`godot4` on `PATH`, then downloads the
pinned release into `.cache/godot/`. The pipeline:

1. resolves / downloads Godot 4.6.3 and verifies its SHA-256;
2. installs matching export templates into `~/.local/share/godot/export_templates/4.6.3.stable/`;
3. runs `--headless --import` and fails on any `SCRIPT ERROR`/`Parse Error`;
4. runs `tests/validate_project.gd` (static + data checks);
5. runs `tests/smoke_test.tscn` (real runtime, autoloads active);
6. exports `Linux/X11` to `build_output/`;
7. runs the **packaged** binary with `-- --smoke-test`;
8. creates `japan_open_world-linux-x86_64.tar.gz` and `SHA256SUMS.txt`;
9. writes `build_output/build_report.json`.

Flags: `--skip-download`, `--skip-tests`, `SKIP_SMOKE=1`.

---

## Manual steps

```bash
# 1. real world data
python3 tools/build_world.py          # add --force to re-download everything
python3 tools/fetch_assets.py

# 2. regenerate manifests from recorded hashes
python3 tools/write_manifests.py

# 3. import + test + export
godot --headless --path . --import
godot --headless --path . --script tests/validate_project.gd
godot --headless --path . res://tests/smoke_test.tscn
godot --headless --path . --export-release "Linux/X11" build_output/japan_open_world.x86_64
```

Running the game from the editor: open `project.godot` and press **F5** — the main scene is
`scenes/main_menu.tscn`.

---

## Dependency decisions and rationale

### Terrain3D — evaluated, **not integrated**

- Evaluated release: **v1.0.2-stable** (https://github.com/TokisanGames/Terrain3D, MIT).
- Its `terrain.gdextension` declares `compatibility_minimum = 4.4`, so 4.6.3 is nominally in range.
- **However**, the release publishes **no binaries**. The repository contains only `src/`,
  `SConstruct` and a `godot-cpp` submodule. Using it requires compiling `godot-cpp` and the
  addon with SCons against the exact engine version, then shipping per-platform `.so` files.
- Impact on this project: a multi-stage native compile per target, plus a new class of
  platform/architecture failures for the Colab and CI pipelines, for a feature (editable
  sculptable terrain) the game does not require — the terrain here is authoritative DEM data
  that is never edited at runtime.
- **Decision:** implement chunked DEM terrain in GDScript (`scripts/world/terrain_streamer.gd`)
  with per-chunk LOD-free meshes, trimesh collision, and streaming. This is data-driven and has
  no native binaries to validate.
- **Revisit if:** prebuilt binaries matching the engine are published, or a compile stage is
  acceptable in the build budget. The world data format is engine-independent, so switching the
  renderer later does not invalidate the pipeline.

### meshoptimizer — already shipped by the engine

The engine repository already contains `modules/meshoptimizer` and `thirdparty/meshoptimizer`;
this is recorded in the pre-existing module manifest at `.github/scripts/modules.manifest.tsv`
and is verifiable in the Godot source tree. No separate integration is required or desirable.

Separately, the world geometry in this project is generated at runtime (`ArrayMesh`), not imported
as glTF, so an external meshoptimizer pass has nothing to operate on. Chunk streaming plus
per-chunk mesh merging keeps draw calls and vertex counts bounded. An offline bake of
building/road chunks is recorded as future work in `docs/FEATURE_MATRIX.md`.

### Jolt physics — already shipped by the engine

Godot ships `modules/jolt_physics` and `thirdparty/jolt_physics`, and the module manifest in this
repository records that the standalone `godot-jolt` project is now a CMake GDExtension in
maintenance mode and is not an SCons module. Linking it again would duplicate the engine's own
copy. The scene here (one character body, static trimesh terrain and buildings) is well within
the default physics backend's capability, so no override is set.

### Navigation (recastnavigation) — already shipped by the engine

`thirdparty/recastnavigation` is vendored by the engine and backs `navigation_3d`. No separate
integration is needed; navigation data is not yet baked because there are no roaming agents.

### Existing engine-module infrastructure in this repository

This repository already tracks 14 gitlinks under `modules/` and keeps a researched, verified
inventory in `.github/scripts/modules.manifest.tsv`, plus a manual
`.github/workflows/build_engine.yml` that can compile a custom monolithic engine. Those files
are preserved. This project intentionally builds against the **stock** 4.6.3 release so the
Colab pipeline does not need a 1–3 hour engine compile; the custom-engine workflow remains
available for experiments that genuinely need a patched engine.

### World streaming and LOD

Implemented directly against the engine:

- terrain and city geometry are built per `Vector2i` chunk on a **16 × 16** grid;
- chunks are loaded inside the configured view distance and freed at 1.35× that distance to
  avoid thrash;
- the player's camera uses `SpringArm3D` for occlusion;
- occlusion culling is enabled in project settings.

At the default 1400 m view distance the smoke test streams **97 terrain chunks and 97 city
chunks** around the spawn point.

---

## PLATEAU 3D city models (optional)

The build can optionally convert real Kyoto building geometry from **Project PLATEAU**
(MLIT) into Godot `.pmesh` files via `tools/fetch_plateau.py`.

### What it does

`tools/fetch_plateau.py` discovers the official PLATEAU 3D Tiles datasets for Kyoto,
downloads the Draco-compressed `b3dm` tiles, decodes them with DracoPy, and writes
Godot `.pmesh` files under `assets/plateau/`. A streaming loader
(`scripts/world/plateau_city.gd`) overlays the real geometry over the OSM box buildings.

### Requirements

| Requirement | Version | Notes |
|---|---|---|
| `DracoPy` | any | `python3 -m pip install DracoPy` |
| Network access to `assets.cms.plateau.reearth.io` | — | PLATEAU tile CDN |
| Disk | ~150 MB | 193 tiles, ~1.95M triangles (Kyoto 5 wards) |

### Run

```bash
python3 -m pip install DracoPy
python3 tools/fetch_plateau.py
```

The `.pmesh` payloads are **gitignored** (see `.gitignore`); only
`assets/plateau/index.json` and `assets/plateau/manifest.json` are committed. To
regenerate the meshes, delete the ward subdirectories under `assets/plateau/` and
re-run `tools/fetch_plateau.py`.

### Skipping

If DracoPy is not installed or the network is unavailable, the build continues with
OSM box buildings only. The build script and Colab notebook both guard the step:
`tools/build_release.sh --skip-plateau`, and the Colab cell catches missing
DracoPy and prints a warning.

### Licence

PLATEAU uses the **Public Data License 1.0 (PDL 1.0)**, which MLIT states is
compatible with CC BY 4.0. Attribution is required (both in-game and in
`THIRD_PARTY_NOTICES.md`). See `THIRD_PARTY_NOTICES.md` section 6 for the exact
required notice.

---

## Visual capture (screenshots)

Graphical capture is **automated**. `tools/visual_acceptance.sh` provisions a display,
runs the **packaged** game with a real graphics backend, captures five framed views of
the streamed world (plus an optional gameplay video) and verifies the pixels. The
packaged binary drives the capture itself via `-- --visual-capture=DIR`, so the same
code path that ships is the one under test (`tests/*` is excluded from the export, which
is why the driver lives in `scripts/tools/visual_capture.gd`).

```bash
bash tools/visual_acceptance.sh build_output/visual_diag
```

Environment knobs: `RENDER_DRIVER` (`opengl3` default, `vulkan` on a GPU with a working
Vulkan ICD), `VIDEO_FRAMES`, `RESOLUTION`, `SKIP_DISPLAY=1`.

What that run has to survive, and why each check exists:

| Check | Failure it catches |
|---|---|
| Framebuffer orientation probe | Readback Y orientation is measured with red/blue probe bands instead of assumed, and recorded per shot (`orientation_corrected`) |
| Stable camera up axis | `look_at(at, Vector3.UP)` is ill-conditioned for near-vertical views and can roll the camera over — the original inverted frame |
| Recorded camera geometry | `camera_up_dot_world_up`, pitch and camera-vs-terrain height are written per shot so orientation is measured, not eyeballed |
| Streaming-aware settle per shot | Shots taken before terrain/city/PLATEAU chunks were resident, which photographed an empty plain |
| Camera anchored to the player | Vantage points parked hundreds of metres outside the stream radius |
| Non-blank, non-duplicate pixel analysis | Flat, black or repeated frames passing as evidence |
| `*.pmesh` in the export filter | The packaged game silently shipping zero PLATEAU geometry |
| Effective facade albedo check | `painted_concrete` is a green-painted wall; used raw it turns the whole city mint-green |

### Known limitation

Godot's **headless OpenGL mode** (the dummy renderer used in `--headless`) does **not**
produce readable viewport textures: `get_viewport().get_texture().get_image()` and
SubViewport textures both return `null`. This is a fundamental limitation of the dummy
renderer, not a bug in the harness. Screenshot capture therefore:

- works only with a real display + a real OpenGL/Vulkan context (windowed or Xvfb);
- does **not** work in `--headless` mode;
- **is** part of the automated pipeline (`tools/visual_acceptance.sh`), and fails the
  run when the runtime cannot produce a graphics context instead of silently passing.

To capture from the editor instead of the packaged build:

```bash
bash tools/setup_software_display.sh && source .cache/xvfb/env.sh
godot --path . --rendering-driver opengl3 \
    --resolution 1280x720 res://tests/capture_screenshots.tscn
```

(With Xvfb: see `tools/setup_software_display.sh`.) The harness writes PNGs to
`user://screenshots/` (i.e. `~/.local/share/godot/app_userdata/Japan Open World/screenshots/`).

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `libfontconfig.so.1: cannot open shared object file` | Cosmetic warning on minimal containers; headless import/export still works. Install `libfontconfig1` if you want it gone. |
| `Export template not found` | Templates must live in `~/.local/share/godot/export_templates/4.6.3.stable/`. Re-run `tools/build_release.sh` (it verifies `linux_release.x86_64`). |
| `Overpass` returns 406 / 429 | Send a `User-Agent` (the script does). If the public endpoint is busy, wait and re-run; the script retries alternate mirrors. |
| Terrain is flat / empty | `assets/terrain/heightmap.f32` missing → run `python3 tools/build_world.py`. |
| No buildings in the game | `assets/world/buildings.dat` missing or magic invalid → run `python3 tools/build_world.py`. |
| `Could not parse global class` | A GDScript parse error; run `godot --headless --path . --import` and read the first `SCRIPT ERROR`. |
| PLATEAU tiles not showing | Run `python3 tools/fetch_plateau.py` (requires DracoPy); check `build_output/logs/plateau_fetch.log`. |
| Screenshots save to `null` / capture produces 0 PNGs | Headless mode cannot read back viewport textures. Run with a real display (Xvfb or physical monitor) via `tools/visual_acceptance.sh`. |
| `libfontconfig.so.1` / `libfreetype.so.6` / `libXcursor.so.1: cannot open shared object file`, then `Unable to create DisplayServer` | The software-display bootstrap is incomplete. `tools/setup_software_display.sh` installs the full transitive library set, provides `xkbcomp` where Xvfb looks for it, and *verifies* the display came up before returning success. |
| Screenshots have ground above and sky below | Not a readback flip: the camera is rolled over, which `look_at` does when the view direction is nearly parallel to the up vector. Check `camera_up_dot_world_up` in `capture_report.json`; `_up_for()` in the driver picks a stable up axis. |
| Packaged game has no PLATEAU buildings but the editor does | `export_presets.cfg` must include `*.pmesh` in `include_filter`; without it the PCK ships the index but none of the geometry and the loader falls back to OSM boxes. |

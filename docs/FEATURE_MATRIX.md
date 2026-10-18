# Feature matrix

Statuses: **Implemented & tested** · **Implemented, partially validated** · **Partially implemented** · **Not implemented**

Evidence column names the exact check that proves the claim.

## Engine and platform

| Feature | Status | Evidence |
|---|---|---|
| Godot 4.6.3 project | Implemented & tested | `--version` → `4.6.3.stable.official.7d41c59c4`; validation checks project name/renderer |
| Forward+ renderer | Implemented & tested | `project.godot`; export succeeds |
| Linux x86_64 export | Implemented & tested | `build_output/japan_open_world.x86_64` + `.pck`; packaged smoke test exits 0 |
| Web / mobile builds | Not implemented | Only a Linux preset exists |
| Windows / macOS builds | Not implemented | Preset not authored; templates available but unverified |

## World

| Feature | Status | Evidence |
|---|---|---|
| Real Kyoto elevation terrain | Implemented & tested | 512×512 DEM grid, 29.0–244.8 m; elevation sampling asserted in smoke test |
| Playable region ~4.0 × 4.0 km | Implemented & tested | `world_size_m` 4006.7 × 3979.8 |
| Terrain collision | Implemented & tested | Player did not fall through after physics steps |
| Chunked terrain streaming (16×16) | Implemented & tested | 97 chunks streamed at 1400 m view distance |
| Real OSM roads | Implemented & tested | 8,500 ways parsed; ribbon geometry per chunk |
| Real OSM buildings | Implemented & tested | 61,368 footprints parsed, extruded, merged per chunk |
| Building collision | Implemented & tested | `BuildingCollision` StaticBody3D per chunk, wall trimesh |
| Terrain-following roads | Implemented & tested | Road vertices sample `get_height_at` + 0.25 m |
| Elevation-based material blend (grass → rock) | Implemented, partially validated | Chunks > 115 m use `rocky_terrain_02`; visual result not yet reviewed on GPU |
| Expanded region beyond 4 km | Not implemented | Streamer supports it; bbox is fixed at Kyoto Central |

## Graphics

| Feature | Status | Evidence |
|---|---|---|
| Real PBR materials (albedo/normal/roughness) | Implemented & tested | 4 material sets imported and referenced; assets validated |
| Real HDRI sky + IBL | Implemented & tested | `kloofendal_48d_partly_cloudy_puresky_2k.hdr` loaded into `PanoramaSkyMaterial` |
| Directional sun with 4-split shadows | Implemented | `main_world.gd` sun setup |
| SSAO, glow, aerial fog | Implemented | `Environment` configuration |
| TAA / MSAA / render scale | Implemented | `SettingsManager` quality presets |
| Occlusion culling | Implemented | `occlusion_culling/use_occlusion_culling=true` |
| Distance LOD on terrain | Not implemented | Single mesh resolution per chunk |
| FSR / upscaling | Not implemented | Only viewport scaling (`scaling_3d_scale`) |
| Automated graphical capture (packaged build) | Implemented & tested | `tools/visual_acceptance.sh` — 5 framed views, `capture_report.json`, exit 0 on the packaged binary |
| Framebuffer orientation correction | Implemented & tested | On-screen red/blue probe bands; without it the Compatibility renderer saved inverted PNGs |
| Non-blank / non-duplicate image analysis | Implemented & tested | `tools/verify_screenshots.py` — stddev, luminance, colour buckets, green dominance, pairwise difference |
| Visual acceptance on a real GPU (Tesla T4) | **Unverified** | Verified on Mesa llvmpipe (software OpenGL) only; no Vulkan ICD in the verification environment |
| Frame rate on target hardware | **Unverified** | Software renderer measured single-digit FPS, which says nothing about a GPU |

## Gameplay

| Feature | Status | Evidence |
|---|---|---|
| Third-person controller (walk/run/jump) | Implemented & tested | Player spawned, physics settled, no fall-through |
| Orbit camera with spring arm | Implemented | `CameraPivot` + `SpringArm3D` + collision mask |
| First/third-person toggle | Implemented | `C`, spring length swap |
| Interaction raycast | Implemented & tested | Lantern prompt path exercised via `get_interact_target` |
| Objective loop: 8 lanterns at real landmarks | Implemented & tested | 8 placed; `objectives_total == 8` asserted |
| Main menu + settings | Implemented | New/Continue/Settings/Quit; resolution, quality, scale, sensitivity, view distance |
| Pause menu | Implemented | Resume / Save / Save & Quit |
| Save game | Implemented, partially validated | Writes `user://savegame.json`; no automated round-trip yet |
| Audio | Not implemented | No licensed audio assets integrated |
| Gamepad support | Not implemented | Actions are keyboard-only |
| NPCs, vehicles, combat | Not implemented | Out of vertical-slice scope |
| Multiplayer | Not implemented | Architecture is single-player |

## Tooling and quality

| Feature | Status | Evidence |
|---|---|---|
| Reproducible data pipeline | Implemented & tested | `tools/build_world.py`, cached + `--force` |
| Pinned engine + templates with SHA-256 | Implemented & tested | checksums enforced in `build_release.sh` |
| Asset hashing manifest | Implemented & tested | `DEPENDENCIES.lock`, `ASSET_MANIFEST.md` generated from real hashes |
| Static validation suite | Implemented & tested | 69 assertions, exit 0 (incl. PLATEAU index/offset/source/vertical-offset checks and effective facade albedo) |
| Runtime smoke test | Implemented & tested | 20 assertions, exit 0 (terrain, OSM, PLATEAU streaming, lantern objectives) |
| PLATEAU `.pmesh` payloads present in the exported PCK | Implemented & tested | Packaged smoke test reports `plateau_available=yes plateau_tiles=18` (this was broken: no `*.pmesh` in `include_filter`) |
| Packaged-build smoke test | Implemented & tested | exported binary exits 0 |
| Colab notebook | Implemented, unverified | Builds, validates, exports, archives **and** runs the graphical acceptance stage (cell 3b); not executed inside this environment |
| Software-display bootstrap | Implemented & tested | `tools/setup_software_display.sh` installs the full library set, supplies `xkbcomp` via a user namespace, and verifies the display came up |
| CI workflow | Implemented, unverified | Authored; not yet run on GitHub-hosted runners |
| meshoptimizer offline bake | Not implemented | See `BUILD.md` rationale |
| Terrain3D native addon | Not implemented (evaluated) | No prebuilt binaries; see `BUILD.md` |
| Jolt physics | Not implemented | Default physics sufficient for current scene |

## Deliberate scope statement

This is an **implemented, playable vertical slice** with a real, data-driven Japanese world and a
verified Linux build — not a finished commercial game. The distinction matters: systems above are
either demonstrated by a test or listed as unimplemented/unverified.

# V1 shipment package

This is the package to look at if you want to judge V1 itself, not just hear that it
"passed". Everything below is a real file in this repository.

## 1. One-page summary

- `release/RELEASE_NOTES.md` — what V1 is, how to play it, how to rebuild it, and what it
  is not yet.

## 2. Build evidence

- `build_output/build_report.json` — measured build metadata: engine version, platform,
  export preset, world sources, package checks, PLATEAU tile counts.
- `build_output/SHA256SUMS.txt` — SHA-256 for the archive, executable, and PCK.

## 3. Test evidence

- `docs/TEST_REPORT.md` — what was tested and how.
- `tests/run_tests.sh` — the headless suite runner: static validation, runtime smoke,
  PLATEAU graceful-degradation test.
- `tools/visual_acceptance.sh` — graphical acceptance: provisions a display, runs the
  **packaged** binary, captures views, and verifies the pixels.
- `tools/verify_screenshots.py` — independent pixel verification of the captured frames.

## 4. Feature status

- `docs/FEATURE_MATRIX.md` — honest status of every major feature, with the exact evidence
  that supports each claim.

## 5. Change history

- `docs/CHANGELOG.md` — what changed and why, including the capture-camera and diagnosis
  corrections.

## 6. Provenance and attribution

- `THIRD_PARTY_NOTICES.md` — licences and attribution for the data and art this build is made
  from.
- `README.md` — repository overview, controls, and quickstart.

## 7. Build instructions

- `BUILD.md` — full build pipeline, dependencies, the Terrain3D evaluation, PLATEAU setup,
  visual-capture notes, and troubleshooting.

If you only want the shortest honest path:

1. read `release/RELEASE_NOTES.md`,
2. skim `build_output/build_report.json` and `build_output/SHA256SUMS.txt`,
3. then `docs/TEST_REPORT.md` if you want the details.

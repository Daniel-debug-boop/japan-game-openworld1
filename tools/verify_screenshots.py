#!/usr/bin/env python3
"""Verify visual-capture output is a real render of the Kyoto world.

This is the independent half of the visual acceptance test. The in-game driver
(`scripts/tools/visual_capture.gd`) proves that terrain, OSM and PLATEAU geometry
were resident and reports it in `capture_report.json`; this script inspects the
actual pixels, so a build cannot pass by reporting success while emitting flat,
blank or duplicated images.

Usage:
    python3 tools/verify_screenshots.py build_output/visual_diag/after

Exit status is 0 only when every check passes. Failures are printed with the exact
measurement that failed.
"""

from __future__ import annotations

import json
import os
import sys

try:
    from PIL import Image
except Exception:  # pragma: no cover - dependency is installed by the pipeline
    print("FATAL: Pillow is required (pip install pillow)", file=sys.stderr)
    sys.exit(2)

# A frame is "flat / debug-only output" when it carries almost no tonal spread.
MIN_STDDEV = 3.0
# Two shots closer than this (mean absolute channel difference, 0-255) are the same
# viewpoint captured twice, which is the failure mode the old harness shipped.
MIN_PAIRWISE_DIFF = 4.0
# Quoted from the measured mean of the `painted_concrete` albedo. If building facades
# regress back to the raw green texture this climbs; in a correctly tinted scene under
# a blue sky and fog, blue leads green.
MAX_GREEN_DOMINANCE = 3.0
MIN_MEAN_LUMA = 8.0


def load_small(path: str, size=(160, 90)):
    im = Image.open(path).convert("RGB")
    return im.resize(size), im.size


def analyse(im_small, native_size):
    px = list(im_small.getdata())
    n = len(px)
    r = sum(p[0] for p in px) / n
    g = sum(p[1] for p in px) / n
    b = sum(p[2] for p in px) / n
    luma = [0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2] for p in px]
    mean = sum(luma) / n
    var = sum((v - mean) ** 2 for v in luma) / n
    colours = {(p[0] // 8, p[1] // 8, p[2] // 8) for p in px}
    return {
        "size": native_size,
        "r": r,
        "g": g,
        "b": b,
        "mean": mean,
        "stddev": var ** 0.5,
        "colours": len(colours),
        "green_dominance": g - (r + b) / 2.0,
        "pixels": px,
    }


def mean_abs_diff(a, b) -> float:
    n = min(len(a), len(b))
    if n == 0:
        return 0.0
    total = 0
    for i in range(n):
        pa, pb = a[i], b[i]
        total += abs(pa[0] - pb[0]) + abs(pa[1] - pb[1]) + abs(pa[2] - pb[2])
    return total / (3.0 * n)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    out_dir = sys.argv[1]
    if not os.path.isdir(out_dir):
        print(f"FATAL: {out_dir} is not a directory", file=sys.stderr)
        return 2

    report_path = os.path.join(out_dir, "capture_report.json")
    failures: list[str] = []
    warnings: list[str] = []

    if os.path.exists(report_path):
        with open(report_path) as fh:
            report = json.load(fh)
        renderer = report.get("renderer", {})
        print("renderer:")
        for k in ("video_adapter", "video_api_version", "project_method",
                  "active_backend", "display_driver"):
            print(f"  {k:18s} = {renderer.get(k)}")
        if report.get("result") != "PASS":
            failures.append(f"in-game capture reported {report.get('result')}")
        if renderer.get("active_backend") is None:
            warnings.append("capture report has no renderer backend")
    else:
        warnings.append("no capture_report.json (scene-resource checks skipped)")
        renderer = {}

    shots = sorted(f for f in os.listdir(out_dir) if f.endswith(".png"))
    if len(shots) < 5:
        failures.append(f"expected at least 5 screenshots, found {len(shots)}")

    print("\nimages:")
    metrics = {}
    for name in shots:
        path = os.path.join(out_dir, name)
        im_small, native = load_small(path)
        m = analyse(im_small, native)
        metrics[name] = m
        print(f"  {name:28s} {native[0]}x{native[1]}  mean={m['mean']:6.1f} "
              f"sd={m['stddev']:6.1f} colours={m['colours']:4d} "
              f"green-dom={m['green_dominance']:+5.2f}")
        if m["stddev"] < MIN_STDDEV:
            failures.append(f"{name}: flat image (stddev {m['stddev']:.2f} < {MIN_STDDEV})")
        if m["mean"] < MIN_MEAN_LUMA:
            failures.append(f"{name}: image is essentially black (mean {m['mean']:.1f})")
        if m["colours"] < 8:
            failures.append(f"{name}: only {m['colours']} distinct colour buckets")
        if m["green_dominance"] > MAX_GREEN_DOMINANCE:
            failures.append(
                f"{name}: green-dominant render ({m['green_dominance']:+.2f} > "
                f"{MAX_GREEN_DOMINANCE}) - building/terrain materials regressed "
                f"towards the raw green albedo")

    names = list(metrics)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            d = mean_abs_diff(metrics[names[i]]["pixels"], metrics[names[j]]["pixels"])
            if d < MIN_PAIRWISE_DIFF:
                failures.append(
                    f"{names[i]} and {names[j]} are the same view (mean diff {d:.2f})")

    print("\n=== visual acceptance ===")
    for w in warnings:
        print(f"  WARN {w}")
    for f in failures:
        print(f"  FAIL {f}")
    print(f"RESULT: {'PASS' if not failures else 'FAIL'} "
          f"({len(shots)} images, {len(failures)} failures)")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())

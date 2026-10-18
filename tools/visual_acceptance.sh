#!/usr/bin/env bash
# Japan Open World - graphical visual acceptance.
#
# Runs the *packaged* game on a real display (Xvfb or a physical one) with a real
# graphics backend, captures several views of the streamed world, verifies the
# pixels independently, and optionally encodes a gameplay video.
#
# Usage:
#   bash tools/visual_acceptance.sh [out_dir]
#
# Environment:
#   RENDER_DRIVER   opengl3 (default) or vulkan. Use vulkan on a GPU that has a
#                   working Vulkan ICD; opengl3 falls back to Mesa llvmpipe.
#   VIDEO_FRAMES    >0 to also dump a PNG sequence for ffmpeg (default 0)
#   SKIP_DISPLAY    1 to use an existing DISPLAY instead of starting Xvfb
#   RESOLUTION      window size, default 1280x720
#
# Exit status is 0 only when the capture and the pixel verification both pass.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${1:-build_output/visual_diag}"
RENDER_DRIVER="${RENDER_DRIVER:-opengl3}"
VIDEO_FRAMES="${VIDEO_FRAMES:-0}"
RESOLUTION="${RESOLUTION:-1280x720}"

log() { printf '\033[36m[visual]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[visual] ERROR\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# 1. Renderer / hardware detection
# ---------------------------------------------------------------------------
log "graphics capability report"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader \
    | sed 's/^/  nvidia: /' || true
else
  log "  nvidia-smi not present (no NVIDIA GPU visible to this runtime)"
fi
if [[ -d /usr/share/vulkan/icd.d ]]; then
  log "  vulkan ICDs: $(ls /usr/share/vulkan/icd.d 2>/dev/null | tr '\n' ' ')"
else
  log "  no /usr/share/vulkan/icd.d - Vulkan will not initialise here"
fi

# ---------------------------------------------------------------------------
# 2. Display
# ---------------------------------------------------------------------------
if [[ "${SKIP_DISPLAY:-0}" != "1" ]]; then
  log "provisioning software display"
  XVFB_SCREEN="${RESOLUTION}x24" bash tools/setup_software_display.sh
  # shellcheck disable=SC1091
  source .cache/xvfb/env.sh
else
  [[ -n "${DISPLAY:-}" ]] || die "SKIP_DISPLAY=1 but DISPLAY is unset"
  log "using existing DISPLAY=${DISPLAY}"
fi

# ---------------------------------------------------------------------------
# 3. Pick the artifact to test: the packaged build if present, else the project
# ---------------------------------------------------------------------------
BIN=""
if [[ -x build_output/japan_open_world.x86_64 ]]; then
  BIN="build_output/japan_open_world.x86_64"
  log "testing the packaged build: $BIN"
else
  die "no packaged build at build_output/japan_open_world.x86_64 - run tools/build_release.sh first"
fi

# ---------------------------------------------------------------------------
# 4. Capture
# ---------------------------------------------------------------------------
CAPTURE_DIR="$OUT/screenshots"
rm -rf "$CAPTURE_DIR"
mkdir -p "$CAPTURE_DIR"

CMD=( "$BIN" --rendering-driver "$RENDER_DRIVER" --resolution "$RESOLUTION"
      -- --visual-capture="$ROOT/$CAPTURE_DIR" )
if [[ "$VIDEO_FRAMES" != "0" ]]; then
  CMD+=( "--capture-video=$VIDEO_FRAMES" )
fi

log "running: ${CMD[*]}"
set +e
"${CMD[@]}" > "$OUT/capture.log" 2>&1
code=$?
set -e

# Surface the meaningful lines but never hide the real exit code (captured above).
grep -E "renderer\.|visual capture|RESULT:|FAIL|WARN" "$OUT/capture.log" || true

if [[ $code -ne 0 ]]; then
  die "capture exited $code; see $OUT/capture.log"
fi

# ---------------------------------------------------------------------------
# 5. Independent pixel verification
# ---------------------------------------------------------------------------
log "verifying captured pixels"
python3 tools/verify_screenshots.py "$CAPTURE_DIR" || die "visual verification failed"

# ---------------------------------------------------------------------------
# 6. Optional gameplay video
# ---------------------------------------------------------------------------
SEQ="$CAPTURE_DIR/sequence"
if [[ -d "$SEQ" ]] && command -v ffmpeg >/dev/null 2>&1; then
  log "encoding gameplay video"
  ffmpeg -y -loglevel error -framerate 10 -i "$SEQ/frame_%04d.png" \
    -pix_fmt yuv420p "$OUT/gameplay.mp4" \
    && log "video: $OUT/gameplay.mp4" \
    || log "WARN ffmpeg encoding failed"
elif [[ -d "$SEQ" ]]; then
  log "WARN ffmpeg not installed; leaving $(ls "$SEQ" | wc -l) frames in $SEQ"
fi

log "acceptance PASSED - artifacts in $OUT"

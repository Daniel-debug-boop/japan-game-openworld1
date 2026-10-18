#!/usr/bin/env bash
# Provision a throwaway Xvfb + Mesa software-rendering display so the game can be
# rendered and captured on a machine with no GPU and no display server.
#
# Everything is extracted into .cache/xvfb (no root, no system changes).
#
# Usage:  bash tools/setup_software_display.sh          # install + start display
#         source .cache/xvfb/env.sh                     # then DISPLAY is exported
#         godot --path . --rendering-driver opengl3 res://tests/capture_screenshots.tscn
#
# Why the package list is long: Debian's Xvfb looks up `xkbcomp` at the hardcoded
# path /usr/bin/xkbcomp and both Xvfb and Godot's X11 display server dlopen a large
# set of X/FreeType/font libraries. Shipping only the Xvfb binary (an earlier
# version of this script did exactly that) leaves the server unable to start, which
# silently degrades every graphical capture to headless mode and produces no
# screenshots at all. The list below is the transitive dependency set that was
# actually required to bring the display up and render a frame.
#
# Notes:
#  * Mesa's swrast/llvmpipe DRI drivers must already exist on the host.
#  * Packages come from deb.debian.org (bookworm), which are ABI compatible with
#    modern Ubuntu hosts for these libraries.
#  * This is a *development aid* for visual validation; it is not part of the game
#    build and nothing here ships with the game.
#  * Xvfb is started inside a user+mount namespace so `xkbcomp` can be provided at
#    its hardcoded location without root. If user namespaces are unavailable the
#    script falls back to running Xvfb as-is and reports the failure honestly.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT}/.cache/xvfb"
DEBS="${DEST}/debs"
EXTRACT="${DEST}/root"
BASE="http://deb.debian.org/debian/pool"
DISPLAY_NUM="${XVFB_DISPLAY_NUM:-99}"
SCREEN="${XVFB_SCREEN:-1280x720x24}"

log() { printf '\033[36m[xvfb]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[xvfb] WARN\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[xvfb] ERROR\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$DEBS" "$EXTRACT"

fetch() {
  # fetch <pool path> <package glob prefix>
  local pooldir="$1" prefix="$2"
  local name
  name="$(curl -s --max-time 60 "${BASE}/${pooldir}/" \
    | grep -oE "${prefix}[^\"]*_(amd64|all)\.deb" \
    | sort -u | tail -n 1)"
  if [[ -z "$name" ]]; then
    warn "could not resolve ${prefix} in ${pooldir}"
    return 1
  fi
  if [[ ! -f "${DEBS}/${name}" ]]; then
    log "downloading ${name}"
    curl -fsSL --max-time 180 -o "${DEBS}/${name}.part" "${BASE}/${pooldir}/${name}" \
      || { warn "download failed: ${name}"; rm -f "${DEBS}/${name}.part"; return 1; }
    mv "${DEBS}/${name}.part" "${DEBS}/${name}"
  fi
  return 0
}

# --- the X server itself and its xkb tooling --------------------------------
fetch "main/x/xorg-server"        "xvfb_"
fetch "main/x/x11-xkb-utils"      "x11-xkb-utils_"
fetch "main/x/xkeyboard-config"   "xkb-data_" || true
fetch "main/libx/libxkbfile"      "libxkbfile1_"
fetch "main/libx/libxfont"        "libxfont2_"
fetch "main/libf/libfontenc"      "libfontenc1_"

# --- X client libraries Godot's X11 display server dlopens -------------------
fetch "main/libx/libx11"          "libx11-6_"
fetch "main/libx/libxext"         "libxext6_"
fetch "main/libx/libxcursor"      "libxcursor1_"
fetch "main/libx/libxinerama"     "libxinerama1_"
fetch "main/libx/libxi"           "libxi6_"
fetch "main/libx/libxrandr"       "libxrandr2_"
fetch "main/libx/libxrender"      "libxrender1_"
fetch "main/libx/libxfixes"       "libxfixes3_"
fetch "main/libx/libxkbcommon"    "libxkbcommon0_"
fetch "main/libx/libxau"          "libxau6_"
fetch "main/libx/libxdmcp"        "libxdmcp6_"

# --- font stack (without libfontconfig/libfreetype Godot aborts X11 init) ----
fetch "main/f/fontconfig"         "libfontconfig1_"
fetch "main/f/freetype"           "libfreetype6_"
fetch "main/e/expat"              "libexpat1_"
fetch "main/b/bzip2"              "libbz2-1.0_"
fetch "main/libp/libpng1.6"       "libpng16-16_"
fetch "main/b/brotli"             "libbrotli1_"

# --- misc support libraries -------------------------------------------------
fetch "main/p/pixman"             "libpixman-1-0_"

log "extracting packages"
for deb in "${DEBS}"/*.deb; do
  [[ -e "$deb" ]] || continue
  dpkg-deb -x "$deb" "$EXTRACT" 2>/dev/null || warn "failed to extract $(basename "$deb")"
done

LIBDIR="${EXTRACT}/usr/lib/x86_64-linux-gnu"
BINDIR="${EXTRACT}/usr/bin"
XKB="${EXTRACT}/usr/share/X11/xkb"

XVFB="${BINDIR}/Xvfb"
[[ -x "$XVFB" ]] || XVFB="$(find "$EXTRACT" -name Xvfb -type f -print -quit)"
[[ -n "$XVFB" && -x "$XVFB" ]] || die "Xvfb binary not found"

XKBCOMP="${BINDIR}/xkbcomp"
[[ -x "$XKBCOMP" ]] || warn "xkbcomp not found in X11 packages; Xvfb may fail to start"

cat > "${DEST}/env.sh" <<EOF
export XVFB_BIN="${XVFB}"
export XVFB_LIBS="${LIBDIR}"
export XKB_CONFIG_ROOT="${XKB}"
export LD_LIBRARY_PATH="${LIBDIR}:\${LD_LIBRARY_PATH:-}"
export DISPLAY=:${DISPLAY_NUM}
EOF

# --- start the display and prove it works -----------------------------------
# Debian's Xvfb invokes the hardcoded path /usr/bin/xkbcomp. When we have our own
# copy and no root, run inside a user+mount namespace and bind an overlay over
# /usr/bin that only adds xkbcomp.
start_display() {
  local script="${DEST}/start_display.sh"
  cat > "$script" <<EOF
#!/bin/bash
set -uo pipefail
if [[ "\${USE_NS:-0}" == "1" ]]; then
  REAL="\${DEST}/realbin"; OVER="\${DEST}/binoverlay"
  rm -rf "\$OVER"; mkdir -p "\$REAL" "\$OVER"
  mount --bind /usr/bin "\$REAL" 2>/dev/null || true
  for f in "\$REAL"/*; do ln -sfn "\$f" "\$OVER/\$(basename "\$f")"; done
  if [[ -x "\${XKBCOMP}" ]]; then cp -f "\${XKBCOMP}" "\$OVER/xkbcomp"; chmod +x "\$OVER/xkbcomp"; fi
  mount --bind "\$OVER" /usr/bin 2>/dev/null || true
fi
export LD_LIBRARY_PATH="\${XVFB_LIBS}:\${LD_LIBRARY_PATH:-}"
export XKB_CONFIG_ROOT="\${XKB_CONFIG_ROOT}"
exec "\${XVFB_BIN}" :${DISPLAY_NUM} -screen 0 ${SCREEN} -nolisten tcp
EOF
  chmod +x "$script"

  local wrapper=(bash "$script")
  if unshare --map-root-user --mount true 2>/dev/null && [[ -x "$XKBCOMP" ]]; then
    log "starting Xvfb in a user namespace (provides xkbcomp at /usr/bin)"
    wrapper=(unshare --map-root-user --mount env DEST="$DEST" USE_NS=1 bash "$script")
  else
    log "starting Xvfb directly (no user namespace)"
  fi

  rm -f "/tmp/.X${DISPLAY_NUM}-lock" 2>/dev/null || true
  setsid nohup "${wrapper[@]}" > "${DEST}/xvfb.log" 2>&1 < /dev/null &
  echo $! > "${DEST}/xvfb.pid"
}

display_up() {
  [[ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]]
}

if display_up; then
  log "display :${DISPLAY_NUM} already running"
else
  start_display
  for _ in $(seq 1 20); do
    sleep 1
    display_up && break
  done
fi

if ! display_up; then
  warn "display :${DISPLAY_NUM} did not come up"
  warn "--- ${DEST}/xvfb.log (last 20 lines) ---"
  tail -n 20 "${DEST}/xvfb.log" >&2 || true
  die "software display unavailable; graphical capture cannot run"
fi

log "display :${DISPLAY_NUM} is up"
log "  Xvfb: ${XVFB}"
log "  libs: ${LIBDIR}"
log "run:  source ${DEST}/env.sh && godot --path . --rendering-driver opengl3 <scene>"

#!/usr/bin/env bash
# Builds libghostty (macOS slice) from pinned sources into Vendor/GhosttyKit.xcframework.
#
# Alethe needs Ghostty's host-managed I/O mode (GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED: the app
# owns the PTY and feeds bytes to the surface). Upstream Ghostty does not ship it; the
# libghostty-spm project (MIT) carries it as Patches/ghostty/0002-host-managed-io.patch together
# with the Darwin build fixes. We build with that pipeline, pinned by commit on both sides:
#
#   LIBGHOSTTY_SPM_COMMIT  the patch set and build scripts
#   GHOSTTY_COMMIT         the Ghostty source (must equal libghostty-spm's Ghostty.ref)
#
# Git commit ids are content hashes, so the inputs are verified. The output is NOT bit-reproducible
# (two builds of the same inputs differ, even with ZERO_AR_DATE), so BUILD_INFO's sha256 identifies a
# particular build, not the inputs. Output is gitignored (~40 MB). Requires the Metal Toolchain.
#
#   Vendor/ghostty/build.sh            build Vendor/GhosttyKit (local package) if missing
#   Vendor/ghostty/build.sh --force    rebuild
set -euo pipefail

LIBGHOSTTY_SPM_REPO="https://github.com/Lakr233/libghostty-spm.git"
LIBGHOSTTY_SPM_COMMIT="b7f888e3baf8585ea9d590ab1a45b49475e00d1c"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
GHOSTTY_COMMIT="3c47ca159368eb4a860ffe5333abdf4a85b2767b"
ZIG_VERSION="0.16.0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$(dirname "$HERE")"
WORK="$HERE/.work"
PACKAGE="$VENDOR/GhosttyKit"
DEST="$PACKAGE/BinaryTarget/GhosttyKit.xcframework"

if [[ -d "$DEST" && "${1:-}" != "--force" ]]; then
  echo "ghostty: already built at $DEST (use --force to rebuild)"
  exit 0
fi

if [[ "$(zig version)" != "$ZIG_VERSION" ]]; then
  echo "ghostty: zig $ZIG_VERSION required, found $(zig version)" >&2
  exit 1
fi

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "ghostty: the Metal Toolchain is missing; install it with:" >&2
  echo "  xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

checkout() { # <repo> <commit> <dir>
  if [[ ! -d "$3/.git" ]]; then git clone --quiet "$1" "$3"; fi
  git -C "$3" fetch --quiet origin "$2" 2>/dev/null || git -C "$3" fetch --quiet origin
  git -C "$3" checkout --quiet --force "$2"
  [[ "$(git -C "$3" rev-parse HEAD)" == "$2" ]] || { echo "ghostty: $3 is not at $2" >&2; exit 1; }
}

mkdir -p "$WORK"
checkout "$LIBGHOSTTY_SPM_REPO" "$LIBGHOSTTY_SPM_COMMIT" "$WORK/libghostty-spm"
PINNED_REF="$(tr -d '[:space:]' < "$WORK/libghostty-spm/Ghostty.ref")"
[[ "$PINNED_REF" == "$GHOSTTY_COMMIT" ]] || {
  echo "ghostty: libghostty-spm pins Ghostty $PINNED_REF, expected $GHOSTTY_COMMIT" >&2; exit 1; }
checkout "$GHOSTTY_REPO" "$GHOSTTY_COMMIT" "$WORK/ghostty"

# Patches are re-runnable; reset the source first so a rebuild starts from the pinned tree.
git -C "$WORK/ghostty" reset --quiet --hard "$GHOSTTY_COMMIT"
git -C "$WORK/ghostty" clean --quiet -fdx
(cd "$WORK/libghostty-spm" && ./build.sh --source "$WORK/ghostty" --platforms macos --skip-tests)

BUILT="$WORK/libghostty-spm/BinaryTarget/GhosttyKit.xcframework"
HEADER="$(find "$BUILT" -name ghostty.h | head -1)"
grep -q "GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED" "$HEADER" || {
  echo "ghostty: built header lacks HOST_MANAGED" >&2; exit 1; }

# Assemble a self-contained local SwiftPM package: libghostty + libghostty-spm's Swift wrapper
# (GhosttyKit C shim and GhosttyTerminal: AppKit view, input/IME, host-managed session bridge).
rm -rf "$PACKAGE"
mkdir -p "$PACKAGE/Sources" "$PACKAGE/BinaryTarget"
cp -R "$BUILT" "$DEST"
cp -R "$WORK/libghostty-spm/Sources/GhosttyKit" "$WORK/libghostty-spm/Sources/GhosttyTerminal" "$PACKAGE/Sources/"
cp "$WORK/libghostty-spm/LICENSE" "$PACKAGE/LICENSE"
cp "$HERE/Package.swift.in" "$PACKAGE/Package.swift"
ARCHIVE="$(find "$DEST" -name '*.a' | head -1)"
cat > "$HERE/BUILD_INFO" <<INFO
libghostty-spm: $LIBGHOSTTY_SPM_COMMIT
ghostty:        $GHOSTTY_COMMIT
zig:            $(zig version)
xcode:          $(xcodebuild -version | head -1)
archive:        ${ARCHIVE#"$VENDOR/"}
sha256:         $(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
INFO
echo "ghostty: built $PACKAGE"
cat "$HERE/BUILD_INFO"

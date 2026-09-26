#!/usr/bin/env bash
# Recopies the upstream remote-control phone client (src-tauri/remote/ and the files its server
# embeds) into AletheRemote's resources, byte for byte, then applies the native patches in
# Scripts/remote-client-patches/*.patch (none today) and writes bundle-manifest.json: the upstream
# SHA, each file's source and checksums, and the patches applied. The Caskaydia fonts are not copied
# (AletheDesign serves them); the script only checks they still match upstream's.
#
#   Scripts/sync-remote-client.sh [<tauri-checkout>]
#
# <tauri-checkout> defaults to this repository's root. Environment overrides:
#   NODE_MODULES  where @xterm/xterm 5.5 and @xterm/addon-unicode11 0.9 live
#                 (default <tauri-checkout>/node_modules; run `npm ci` there first)
#   UPSTREAM_SHA  the commit recorded as the source (default: the checkout's HEAD)
set -euo pipefail

NATIVE="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="$(cd "${1:-$NATIVE/..}" && pwd)"
NODE_MODULES="${NODE_MODULES:-$CHECKOUT/node_modules}"
KIT="$NATIVE/Packages/AletheKit"
DEST="$KIT/Sources/AletheRemote/Resources/RemoteClient"
FONTS="$KIT/Sources/AletheDesign/Resources/Fonts"
PATCHES="$NATIVE/Scripts/remote-client-patches"
UPSTREAM_SHA="${UPSTREAM_SHA:-$(git -C "$CHECKOUT" rev-parse HEAD)}"

fail() { echo "sync-remote-client: $*" >&2; exit 1; }

[ -f "$CHECKOUT/src-tauri/remote/app.js" ] || fail "$CHECKOUT is not a Tauri checkout (no src-tauri/remote/app.js)"
[ -d "$NODE_MODULES/@xterm/xterm" ] || fail "no @xterm/xterm under $NODE_MODULES (run npm ci, or set NODE_MODULES)"

package_version() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1/package.json"
}
XTERM_VERSION="$(package_version "$NODE_MODULES/@xterm/xterm")"
UNICODE11_VERSION="$(package_version "$NODE_MODULES/@xterm/addon-unicode11")"
case "$XTERM_VERSION" in 5.5.*) ;; *) fail "@xterm/xterm $XTERM_VERSION, expected 5.5.x" ;; esac
case "$UNICODE11_VERSION" in 0.9.*) ;; *) fail "@xterm/addon-unicode11 $UNICODE11_VERSION, expected 0.9.x" ;; esac

for style in Regular Bold Italic BoldItalic; do
  font="CaskaydiaCoveNerdFontMono-$style.ttf"
  cmp -s "$CHECKOUT/src/assets/fonts/$font" "$FONTS/$font" \
    || fail "$font differs from upstream's src/assets/fonts; update AletheDesign's copy first"
done

# <bundle path> <source relative to the checkout, or npm:<path under node_modules>>
FILES=(
  "index.html src-tauri/remote/index.html"
  "app.js src-tauri/remote/app.js"
  "app.css src-tauri/remote/app.css"
  "locales.js src-tauri/remote/locales.js"
  "manifest.webmanifest src-tauri/remote/manifest.webmanifest"
  "theme.css src/styles/theme.css"
  "vendor/xterm.js npm:@xterm/xterm/lib/xterm.js"
  "vendor/xterm.css npm:@xterm/xterm/css/xterm.css"
  "vendor/LICENSE-xterm.txt npm:@xterm/xterm/LICENSE"
  "vendor/addon-unicode11.js npm:@xterm/addon-unicode11/lib/addon-unicode11.js"
  "vendor/LICENSE-addon-unicode11.txt npm:@xterm/addon-unicode11/LICENSE"
  "assets/agents/claude.png src/assets/claude-code.png"
  "assets/agents/codex.png src/assets/codex.png"
  "assets/agents/opencode.png src/assets/open-white.png"
  "brand-icons/elite-original.png src/assets/theme-icons/elite-original.png"
  "brand-icons/elite-pure-black.png src/assets/theme-icons/elite-pure-black.png"
  "brand-icons/elite-indigo.png src/assets/theme-icons/elite-indigo.png"
  "brand-icons/elite-blush.png src/assets/theme-icons/elite-blush.png"
)

rm -rf "$DEST"
mkdir -p "$DEST"
LISTING="$(mktemp)"
trap 'rm -f "$LISTING"' EXIT

for entry in "${FILES[@]}"; do
  target="${entry%% *}"
  source="${entry#* }"
  case "$source" in
    npm:*)
      path="${source#npm:}"
      package="$(echo "$path" | cut -d/ -f1-2)"
      version="$(package_version "$NODE_MODULES/$package")"
      from="$NODE_MODULES/$path"
      label="node_modules/$path@$version"
      ;;
    *)
      from="$CHECKOUT/$source"
      label="$source"
      ;;
  esac
  [ -f "$from" ] || fail "missing $from"
  mkdir -p "$DEST/$(dirname "$target")"
  cp "$from" "$DEST/$target"
  printf '%s\t%s\t%s\n' "$target" "$label" "$(shasum -a 256 "$DEST/$target" | cut -d' ' -f1)" >> "$LISTING"
done

APPLIED=()
if [ -d "$PATCHES" ]; then
  for patch in "$PATCHES"/*.patch; do
    [ -e "$patch" ] || continue
    patch --quiet --forward --directory "$DEST" -p1 < "$patch" || fail "$(basename "$patch") no longer applies"
    APPLIED+=("$(basename "$patch")")
  done
fi

python3 - "$DEST" "$LISTING" "$UPSTREAM_SHA" "$XTERM_VERSION" "$UNICODE11_VERSION" "${APPLIED[@]+"${APPLIED[@]}"}" <<'PY'
import hashlib, json, sys
from pathlib import Path

dest, listing, sha, xterm, unicode11, *patches = sys.argv[1:]
files = []
for line in Path(listing).read_text().splitlines():
    path, source, upstream = line.split("\t")
    current = hashlib.sha256((Path(dest) / path).read_bytes()).hexdigest()
    files.append({"path": path, "source": source, "upstreamSHA256": upstream, "sha256": current,
                  "patched": current != upstream})
manifest = {
    "upstreamSHA": sha,
    "xterm": xterm,
    "addonUnicode11": unicode11,
    "patches": patches,
    "files": files,
}
(Path(dest) / "bundle-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "sync-remote-client: ${#FILES[@]} file(s) from ${UPSTREAM_SHA:0:7} (xterm $XTERM_VERSION, unicode11 $UNICODE11_VERSION), ${#APPLIED[@]} patch(es) → ${DEST#"$NATIVE"/}"

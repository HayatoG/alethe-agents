#!/usr/bin/env python3
"""One-shot conversion of the Tauri app's built-in themes into AletheDesign data.

Run once (P0-3) against an upstream checkout; the output is committed and from then on the Swift
side is the source of truth. Kept for audit and for converting the theme-pack plugin themes in P4.
It is NOT part of the build.

    Scripts/oneshot/convert-themes.py <upstream-repo-root> <output-dir>
    Scripts/oneshot/convert-themes.py --theme-pack <upstream-repo-root> <output-dir>

With --theme-pack it converts src/plugins/theme-pack/themes.ts instead (P4-18): each theme's tokens
lay over the dark base and its terminal entries over the dark xterm palette, like upstream's
plugin-theme cascade. Only <output-dir>/Themes/<id>.json is written.

Reads:
  src/styles/theme.css                       token blocks per [data-theme='<id>'] (dark = :root base)
  src/lib/themes.ts                          BUILTIN_THEME_OPTIONS swatches
  src/components/XTermView/xtermThemes.ts    terminal palettes

Writes <output-dir>/Themes/<id>.json (every token resolved: themes inherit the dark base, like the
CSS cascade) and <output-dir>/ThemeToken.swift (the token enum).
"""
import json
import re
import sys
from pathlib import Path

# xterm.js DEFAULT_ANSI_COLORS (Tango), used when a palette does not override the ANSI colors.
XTERM_DEFAULT_ANSI = [
    "#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
    "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
]
ANSI_KEYS = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "brightBlack", "brightRed", "brightGreen", "brightYellow",
    "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
]
# Tokens that are not per-theme colors: they become Metrics/Motion/Typography constants.
NON_COLOR_PREFIXES = ("--anim-", "--ease-", "--radius-", "--font-", "--shadow-")


def parse_theme_blocks(css: str) -> dict[str, dict[str, str]]:
    blocks: dict[str, dict[str, str]] = {}
    for match in re.finditer(r"\[data-theme='([a-z0-9-]+)'\]\s*\{([^}]*)\}", css):
        theme_id, body = match.group(1), match.group(2)
        body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
        tokens = blocks.setdefault(theme_id, {})
        for name, value in re.findall(r"(--[a-z0-9-]+)\s*:\s*([^;]+);", body):
            tokens[name] = " ".join(value.split())
    return blocks


def resolve_vars(tokens: dict[str, str]) -> dict[str, str]:
    resolved = dict(tokens)
    for _ in range(8):
        changed = False
        for name, value in resolved.items():
            ref = re.fullmatch(r"var\((--[a-z0-9-]+)\)", value)
            if ref and ref.group(1) in resolved:
                resolved[name] = resolved[ref.group(1)]
                changed = True
        if not changed:
            break
    return resolved


def to_hex(value: str) -> str:
    """Normalizes #rgb/#rrggbb/#rrggbbaa/rgba()/rgb() to #RRGGBBAA."""
    value = value.strip().lower()
    if value.startswith("#"):
        digits = value[1:]
        if len(digits) == 3:
            digits = "".join(c * 2 for c in digits) + "ff"
        elif len(digits) == 6:
            digits += "ff"
        if len(digits) != 8:
            raise ValueError(f"bad hex color: {value}")
        return "#" + digits
    match = re.fullmatch(r"rgba?\(([^)]*)\)", value)
    if not match:
        raise ValueError(f"not a color: {value}")
    parts = [p.strip() for p in match.group(1).split(",")]
    r, g, b = (int(float(p)) for p in parts[:3])
    a = float(parts[3]) if len(parts) == 4 else 1.0
    return "#{:02x}{:02x}{:02x}{:02x}".format(r, g, b, round(a * 255))


def parse_shadow(value: str) -> dict:
    match = re.fullmatch(r"(-?[\d.]+)(?:px)?\s+(-?[\d.]+)px\s+([\d.]+)px\s+(rgba?\([^)]*\))", value)
    if not match:
        raise ValueError(f"unsupported shadow: {value}")
    return {
        "x": float(match.group(1)),
        "y": float(match.group(2)),
        "blur": float(match.group(3)),
        "color": to_hex(match.group(4)),
    }


def parse_swatches(ts: str) -> dict[str, list[str]]:
    return {
        theme_id: [to_hex(c) for c in colors]
        for theme_id, colors in (
            (m.group(1), re.findall(r"'(#[0-9a-fA-F]+)'", m.group(2)))
            for m in re.finditer(r"\{\s*id:\s*'([a-z0-9-]+)',\s*colors:\s*\[([^\]]*)\]\s*\}", ts)
        )
    }


def parse_xterm_themes(ts: str) -> dict[str, dict[str, str]]:
    consts: dict[str, dict[str, str]] = {}
    for match in re.finditer(r"const ([A-Z_]+) = \{(.*?)\} as const", ts, flags=re.S):
        name, body = match.group(1), match.group(2)
        entries: dict[str, str] = {}
        for line in body.splitlines():
            line = line.strip().rstrip(",")
            spread = re.fullmatch(r"\.\.\.([A-Z_]+)", line)
            if spread:
                entries.update(consts[spread.group(1)])
                continue
            pair = re.fullmatch(r"([a-zA-Z]+):\s*'([^']+)'", line)
            if pair:
                entries[pair.group(1)] = pair.group(2)
        consts[name] = entries
    table = re.search(r"const XTERM_THEMES = \{(.*?)\} satisfies", ts, flags=re.S).group(1)
    themes = {}
    for key, const in re.findall(r"'?([a-z0-9-]+)'?:\s*([A-Z_]+)", table):
        themes[key] = consts[const]
    return themes


def luminance_is_light(hex_color: str) -> bool:
    # Same heuristic as isLightTheme() upstream: relative luminance of the first swatch color.
    h = hex_color[1:7]
    channel = lambda start: int(h[start:start + 2], 16) / 255
    return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4) > 0.5


def camel(name: str) -> str:
    head, *rest = name.removeprefix("--").split("-")
    return head + "".join(part.capitalize() for part in rest)


def parse_theme_pack(ts: str) -> list[dict]:
    themes = []
    chunks = re.split(r"\n  \{\n    id: ", ts)[1:]
    for chunk in chunks:
        theme_id = re.match(r"'([a-z0-9-]+)'", chunk).group(1)
        label = re.search(r"label:\s*'([^']+)'", chunk).group(1)
        swatch = re.findall(r"'(#[0-9a-fA-F]+)'", re.search(r"swatch:\s*\[([^\]]*)\]", chunk).group(1))
        tokens_body = re.search(r"tokens:\s*\{(.*?)\n    \}", chunk, flags=re.S).group(1)
        tokens = dict(re.findall(r"'(--[a-z0-9-]+)':\s*'([^']+)'", tokens_body))
        terminal_body = re.search(r"terminal:\s*\{(.*?)\n    \}", chunk, flags=re.S).group(1)
        terminal = dict(re.findall(r"([a-zA-Z]+):\s*'([^']+)'", terminal_body))
        themes.append({"id": theme_id, "label": label, "swatch": swatch, "tokens": tokens, "terminal": terminal})
    return themes


def convert_theme_pack(upstream: Path, out_dir: Path) -> None:
    base = parse_theme_blocks((upstream / "src/styles/theme.css").read_text())["dark"]
    xterm = parse_xterm_themes((upstream / "src/components/XTermView/xtermThemes.ts").read_text())
    pack = parse_theme_pack((upstream / "src/plugins/theme-pack/themes.ts").read_text())
    color_names = sorted(n for n in base if not n.startswith(NON_COLOR_PREFIXES))
    themes_dir = out_dir / "Themes"
    themes_dir.mkdir(parents=True, exist_ok=True)
    for theme in pack:
        tokens = resolve_vars({**base, **theme["tokens"]})
        palette = {**xterm["dark"], **theme["terminal"]}
        swatch = [to_hex(c) for c in theme["swatch"]]
        document = {
            "id": theme["id"],
            "name": theme["label"],
            "isLight": luminance_is_light(swatch[0]),
            "swatch": swatch,
            "colors": {camel(n): to_hex(tokens[n]) for n in color_names},
            "shadows": {
                level: parse_shadow(tokens[f"--shadow-{level}"]) for level in ("sm", "md", "lg")
            },
            "terminal": {
                "background": to_hex(palette["background"]),
                "foreground": to_hex(palette["foreground"]),
                "cursor": to_hex(palette["cursor"]),
                "selection": to_hex(palette["selectionBackground"]),
                "ansi": [to_hex(palette.get(k, XTERM_DEFAULT_ANSI[i])) for i, k in enumerate(ANSI_KEYS)],
            },
        }
        (themes_dir / f"{theme['id']}.json").write_text(json.dumps(document, indent=2) + "\n")
    print(f"{len(pack)} theme-pack themes")


def main() -> None:
    if sys.argv[1] == "--theme-pack":
        convert_theme_pack(Path(sys.argv[2]), Path(sys.argv[3]))
        return
    upstream, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    css = (upstream / "src/styles/theme.css").read_text()
    blocks = parse_theme_blocks(css)
    base = blocks["dark"]
    swatches = parse_swatches((upstream / "src/lib/themes.ts").read_text())
    xterm = parse_xterm_themes((upstream / "src/components/XTermView/xtermThemes.ts").read_text())

    color_names = sorted(n for n in base if not n.startswith(NON_COLOR_PREFIXES))
    themes_dir = out_dir / "Themes"
    themes_dir.mkdir(parents=True, exist_ok=True)

    for theme_id, swatch in swatches.items():
        tokens = resolve_vars({**base, **blocks.get(theme_id, {})})
        palette = xterm[theme_id]
        ansi = [
            to_hex(palette.get(key, XTERM_DEFAULT_ANSI[i])) for i, key in enumerate(ANSI_KEYS)
        ]
        document = {
            "id": theme_id,
            "isLight": luminance_is_light(swatch[0]),
            "swatch": swatch,
            "colors": {camel(n): to_hex(tokens[n]) for n in color_names},
            "shadows": {
                level: parse_shadow(tokens[f"--shadow-{level}"]) for level in ("sm", "md", "lg")
            },
            "terminal": {
                "background": to_hex(palette["background"]),
                "foreground": to_hex(palette["foreground"]),
                "cursor": to_hex(palette["cursor"]),
                "selection": to_hex(palette["selectionBackground"]),
                "ansi": ansi,
            },
        }
        (themes_dir / f"{theme_id}.json").write_text(json.dumps(document, indent=2) + "\n")

    cases = "\n".join(f'    case {camel(n)}' for n in color_names)
    (out_dir / "ThemeToken.swift").write_text(
        "/// Semantic color tokens. Converted once from the Tauri app's `theme.css` (P0-3);\n"
        "/// this file is now the source of truth.\n"
        "public enum ThemeToken: String, CaseIterable, Codable, Sendable {\n"
        f"{cases}\n}}\n"
    )
    print(f"{len(swatches)} themes, {len(color_names)} color tokens")


if __name__ == "__main__":
    main()

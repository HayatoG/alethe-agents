#!/usr/bin/env python3
"""String-catalog gate (ADR-6). Fails when:

  1. a key in any Localizable.xcstrings lacks a translated, non-empty value for a required
     language (en, pt-BR) — unless the key is marked "shouldTranslate": false;
  2. a key is an orphan: no Swift source in the catalog's module references it as a literal;
  3. Swift code uses a dotted key that is missing from its module's catalog;
  4. Swift code passes a plain-text literal to Text/Label/Button/etc. — user-visible text must be
     a catalog key; product names and other non-translatable text use `Text(verbatim:)`.

Keys are dotted identifiers (e.g. `sidebar.projects.title`), used as
`Text("sidebar.projects.title", bundle: .module)` / `String(localized: "…", bundle: .module)`.

    Scripts/check-strings.py [<AletheNative root>]
"""
import json
import re
import sys
from pathlib import Path

REQUIRED_LANGUAGES = ("en", "pt-BR")
KEY_PATTERN = r"[a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+)+"
# First string-literal argument of APIs that render or resolve localized text.
LOCALIZED_CALL = re.compile(
    r"\b(Text|Label|Button|Toggle|Section|Menu|Picker|TextField|SecureField|Tab|Link|"
    r"LocalizedStringKey|LocalizedStringResource|navigationTitle|help|accessibilityLabel|"
    r"accessibilityHint|String\(localized:)\s*\(?\s*\"((?:[^\"\\]|\\.)*)\""
)
DOTTED_KEY = re.compile(rf"^{KEY_PATTERN}$")


def unit_ok(unit: dict) -> bool:
    string_unit = unit.get("stringUnit")
    if string_unit:
        return string_unit.get("state") == "translated" and bool(string_unit.get("value", "").strip())
    variations = unit.get("variations")
    if variations:
        return all(
            unit_ok(case)
            for kind in variations.values()
            for case in kind.values()
        )
    return False


def module_root(catalog: Path, root: Path) -> Path:
    """The app target folder or the SwiftPM target folder that owns the catalog."""
    for parent in catalog.parents:
        if parent.parent.name == "Sources" or parent == root / "Alethe":
            return parent
    return catalog.parent


def swift_files(folder: Path) -> list[Path]:
    return sorted(p for p in folder.rglob("*.swift"))


def check(root: Path) -> list[str]:
    problems: list[str] = []
    catalogs = sorted(p for p in root.rglob("*.xcstrings") if "/build/" not in str(p))
    catalog_by_module: dict[Path, set[str]] = {}

    for catalog in catalogs:
        data = json.loads(catalog.read_text())
        if data.get("sourceLanguage") != "en":
            problems.append(f"{catalog}: sourceLanguage must be en")
        keys = set()
        for key, entry in data.get("strings", {}).items():
            keys.add(key)
            if not DOTTED_KEY.match(key):
                problems.append(f"{catalog.name}: key '{key}' is not a dotted identifier")
            if entry.get("shouldTranslate") is False:
                continue
            localizations = entry.get("localizations", {})
            for language in REQUIRED_LANGUAGES:
                if not unit_ok(localizations.get(language, {})):
                    problems.append(f"{catalog.name}: '{key}' has no translated {language} value")
        catalog_by_module.setdefault(module_root(catalog, root), set()).update(keys)

    # Every Swift module folder: the app target and each SwiftPM source target.
    modules = [root / "Alethe"] + sorted(
        p for p in (root / "Packages").glob("*/Sources/*") if p.is_dir()
    )
    for module in modules:
        keys = catalog_by_module.get(module, set())
        sources = {path: path.read_text() for path in swift_files(module)}
        referenced: set[str] = set()
        for path, text in sources.items():
            for line_number, line in enumerate(text.splitlines(), start=1):
                referenced.update(re.findall(rf"\"({KEY_PATTERN})\"", line))
                for match in LOCALIZED_CALL.finditer(line):
                    literal = match.group(2)
                    if "verbatim:" in line[max(0, match.start() - 1):match.end()]:
                        continue
                    where = f"{path.relative_to(root)}:{line_number}"
                    if DOTTED_KEY.match(literal):
                        if literal not in keys:
                            problems.append(f"{where}: key '{literal}' is missing from the catalog")
                    elif literal.strip():
                        problems.append(
                            f"{where}: plain text \"{literal}\" — use a catalog key or Text(verbatim:)"
                        )
        for orphan in sorted(keys - referenced):
            problems.append(f"{module.relative_to(root)}: orphan key '{orphan}' is never referenced")
    return problems


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    problems = check(root)
    for problem in problems:
        print(f"error: {problem}")
    if problems:
        print(f"check-strings: {len(problems)} problem(s)")
        return 1
    print("check-strings: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

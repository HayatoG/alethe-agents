#!/usr/bin/env python3
"""Adds or updates keys in a String Catalog with both required languages.

    Scripts/dev/strings.py <catalog.xcstrings> <key> "<English>" "<Português (Brasil)>" [...]

Arguments repeat in groups of three. Keys are sorted; the file keeps Xcode's formatting.
"""
import json
import sys
from pathlib import Path


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def main() -> int:
    path = Path(sys.argv[1])
    triples = sys.argv[2:]
    if len(triples) == 0 or len(triples) % 3:
        print(__doc__)
        return 1
    catalog = json.loads(path.read_text())
    strings = catalog.setdefault("strings", {})
    for i in range(0, len(triples), 3):
        key, en, pt = triples[i:i + 3]
        strings[key] = {"extractionState": "manual", "localizations": {"en": unit(en), "pt-BR": unit(pt)}}
    catalog["strings"] = dict(sorted(strings.items()))
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n")
    print(f"{path.name}: {len(triples) // 3} key(s) written")
    return 0


if __name__ == "__main__":
    sys.exit(main())

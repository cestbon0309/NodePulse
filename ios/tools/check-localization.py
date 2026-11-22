#!/usr/bin/env python3
"""Check catalog coverage, translated formats, and Chinese source literals."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1] / "NodePulse"
count = 0
catalog = json.loads((root / "Localizable.xcstrings").read_text())["strings"]
for file in root.glob("*.xcstrings"):
    data = json.loads(file.read_text())
    for key, entry in data["strings"].items():
        formats = []
        for language in ("en", "zh-Hans"):
            unit = entry["localizations"][language]["stringUnit"]
            assert unit["state"] == "translated" and unit["value"], (file, key, language)
            formats.append(re.findall(r"%(?:\d+\$)?@", unit["value"]))
        assert formats[0] == formats[1], (key, formats)
        count += 1
for file in root.rglob("*.swift"):
    source = file.read_text()
    for match in re.finditer(r'"([^"\n]*[\u3400-\u9fff][^"\n]*)"', source):
        assert source[:match.start()].endswith("L10n.text("), (file, match.group())
        key = json.loads(match.group())
        assert key in catalog, (file, key)
print(f"PASS {count} catalog entries: complete en/zh-Hans translations, matching format arguments, no unlocalized Chinese Swift literals")

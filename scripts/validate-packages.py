#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Validate shipped catalog schemas and removable payloads without executing code."""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[1] / "Sources/RadiusApp/Resources/Modules"
capabilities = {"resourceMonitor", "notes", "reader", "screenshot", "focusMode", "tabSystem", "theme", "layout", "icons", "menu", "startWidget"}
found = set()
counts = {"native": 0, "behavior": 0, "declarative": 0}
for path in sorted(root.glob("*/manifest.json")):
    manifest = json.loads(path.read_text())
    assert manifest["id"] == path.parent.name and manifest["id"] not in found, path
    found.add(manifest["id"])
    assert manifest["capability"] in capabilities, path
    assert manifest["version"] > 0 and manifest["publisher"] == "Radius", path
    assert manifest["source"] == "https://github.com/starharbor2491/radius-browser", path
    assert not manifest["dependencies"], path
    runtime = manifest["runtime"]
    if runtime in {"nativeResourceWorker", "nativeReaderWorker"}:
        assert (runtime, manifest["capability"]) in {("nativeResourceWorker", "resourceMonitor"), ("nativeReaderWorker", "reader")}, path
        counts["native"] += 1
    elif runtime == "behaviorProgram":
        assert manifest["capability"] in {"notes", "screenshot", "focusMode"}, path
        program = json.loads((path.parent / "program.json").read_text())
        assert program["formatVersion"] == 1 and program["entrypoints"], path
        counts["behavior"] += 1
    else:
        assert runtime == "declarative", path
        definition = json.loads((path.parent / "definition.json").read_text())
        assert definition["formatVersion"] == 1, path
        counts["declarative"] += 1
assert counts == {"native": 3, "behavior": 3, "declarative": 12}, counts
print(f"{len(found)} official packages validated: {counts['native']} native, {counts['behavior']} behavior, {counts['declarative']} declarative.")

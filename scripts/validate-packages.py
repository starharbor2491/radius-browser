#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Validate the shipped catalog without executing any package content."""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[1] / "Sources/RadiusApp/Resources/Modules"
capabilities = {"resourceMonitor", "notes", "reader", "screenshot", "focusMode"}
found = set()
for path in sorted(root.glob("*/manifest.json")):
    manifest = json.loads(path.read_text())
    assert manifest["id"] == path.parent.name, path
    assert manifest["id"] not in found, path
    found.add(manifest["id"])
    assert manifest["capability"] in capabilities, path
    assert manifest["version"] > 0 and manifest["publisher"] == "Radius", path
    assert manifest["source"].startswith("https://github.com/starharbor2491/radius-browser"), path
    assert not manifest["dependencies"], path
assert len(found) == 6, f"Expected six official packages, found {len(found)}"
workers = [json.loads(path.read_text()) for path in root.glob("*/manifest.json") if json.loads(path.read_text()).get("runtime")]
assert {item["id"] for item in workers} == {"org.radius.resource-monitor", "org.radius.memory-monitor", "org.radius.reader"}
assert all((item["runtime"], item["capability"]) in {("nativeResourceWorker", "resourceMonitor"), ("nativeReaderWorker", "reader")} for item in workers)
assert sum(item["defaultInstalled"] for item in workers if item["capability"] == "resourceMonitor") == 1
print("Six official package manifests validated (three native workers, three descriptors).")

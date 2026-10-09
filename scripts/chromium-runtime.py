#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Build an optional Radius Alloy adapter package from the pinned upstream CEF SDK.

This is a development package. Ad-hoc signatures verify local integrity; they do
not provide Developer ID publisher trust or notarized consumer distribution.
"""
import argparse
import hashlib
import importlib.util
import json
import platform
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("cef_proof", ROOT / "scripts/chromium-proof.py")
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


def build(work, arch):
    proof.require_mac()
    archive, stem = proof.fetch_archive(work, arch)
    source = work / stem
    marker = source / ".radius-extracted-sha256"
    expected_digest = proof.ARCHIVES[arch][1]
    if not marker.is_file() or marker.read_text().strip() != expected_digest:
        # An interrupted extraction must never be mistaken for a complete SDK.
        with tempfile.TemporaryDirectory(prefix="cef-extract-", dir=work) as staging:
            with tarfile.open(archive, "r:bz2") as compressed:
                compressed.extractall(staging, filter="data")
            extracted = Path(staging) / stem
            (extracted / marker.name).write_text(expected_digest + "\n")
            if source.exists():
                shutil.rmtree(source)
            extracted.rename(source)
    output = work / ("adapter-build-" + arch)
    proof.checked(["cmake", "-S", ROOT / "ChromiumRuntime", "-B", output, "-G", "Xcode",
                   "-DCEF_ROOT=" + str(source), "-DPROJECT_ARCH=" + arch, "-DUSE_SANDBOX=ON"])
    proof.checked(["cmake", "--build", output, "--config", "Release", "--target", "RadiusChromiumBridge", "--", "-quiet"])
    package = work / ("Chromium-" + arch + ".radiusengine")
    if package.exists():
        shutil.rmtree(package)
    binaries = package / "Contents/MacOS"
    frameworks = package / "Contents/Frameworks"
    binaries.mkdir(parents=True)
    frameworks.mkdir(parents=True)
    shutil.copy2(output / "Release/RadiusChromiumBridge.dylib", binaries)
    framework = source / "Release/Chromium Embedded Framework.framework"
    # ditto preserves framework symlinks and permissions on macOS.
    proof.checked(["ditto", framework, frameworks / framework.name])
    helpers = list((output / "Release").glob("RadiusChromium Helper*.app"))
    if len(helpers) != 5:
        raise RuntimeError(f"Expected five sandbox helper variants, found {len(helpers)}")
    for helper in helpers:
        proof.checked(["ditto", helper, frameworks / helper.name])
    legal = package / "Contents/Resources/Legal"
    legal.mkdir(parents=True)
    shutil.copy2(source / "LICENSE.txt", legal / "CEF-LICENSE.txt")
    for notice in source.glob("*LICENSE*"):
        if notice.is_file():
            shutil.copy2(notice, legal / notice.name)
    for name in ("LICENSE", "COPYING.MPL"):
        shutil.copy2(ROOT / name, legal / ("Radius-" + name))
    # Sign leaf code before containing helpers; do not alter upstream framework signing.
    proof.checked(["codesign", "--force", "--sign", "-", binaries / "RadiusChromiumBridge.dylib"])
    for helper in frameworks.glob("RadiusChromium Helper*.app"):
        proof.checked(["codesign", "--force", "--sign", "-", helper])
        proof.checked(["codesign", "--verify", "--strict", helper])
    proof.checked(["lipo", binaries / "RadiusChromiumBridge.dylib", "-verify_arch", arch])
    files = {}
    for path in sorted(package.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as content:
            files[str(path.relative_to(package))] = hashlib.file_digest(content, "sha256").hexdigest()
    manifest = {"format": 1, "abi": 1, "architecture": arch, "cefVersion": proof.VERSION, "files": files}
    (package / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    evidence = {"package": str(package), "architecture": arch, "cefVersion": proof.VERSION,
                "archiveSHA256": proof.ARCHIVES[arch][1], "sandbox": True,
                "radiusAdapter": True, "radiusEmbeddedRuntimeValidated": False,
                "chromeExtensions": False, "developerID": False, "notarized": False,
                "hostArchitecture": platform.machine()}
    (work / ("radius-adapter-" + arch + ".json")).write_text(json.dumps(evidence, indent=2) + "\n")
    print("Development package:", package, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=proof.ARCHIVES, default=platform.machine())
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    build(args.work_dir.resolve(), args.arch)

#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Build an optional Radius Chrome Views adapter from the pinned upstream CEF SDK.

This is a development package. Ad-hoc signatures verify local integrity; they do
not provide Developer ID publisher trust or notarized consumer distribution.
"""
import argparse
import hashlib
import importlib.util
import json
import platform
import plistlib
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
    # Match CEF's COPY_MAC_FRAMEWORK macro: the SDK is flat; applications use
    # a versioned macOS framework with these standard relative symlinks.
    packaged_framework = frameworks / framework.name
    (packaged_framework / "Versions").mkdir(parents=True)
    proof.checked(["ditto", framework, packaged_framework / "Versions/A"])
    for name in ("Chromium Embedded Framework", "Libraries", "Resources"):
        (packaged_framework / name).symlink_to("Versions/A/" + name)
    (packaged_framework / "Versions/Current").symlink_to("A")
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
    # A proper nested code bundle can be sealed by the containing Radius app.
    (package / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.radius.chromium", "CFBundlePackageType": "BNDL",
        "CFBundleExecutable": "RadiusChromiumBridge.dylib", "CFBundleName": "Radius Chromium",
        "CFBundleVersion": "1", "CFBundleShortVersionString": proof.VERSION,
    }))
    # Sign nested code before its containers, using local ad-hoc identities.
    for helper in frameworks.glob("RadiusChromium Helper*.app"):
        proof.checked(["codesign", "--force", "--sign", "-", helper])
        proof.checked(["codesign", "--verify", "--strict", helper])
    proof.checked(["codesign", "--force", "--sign", "-", packaged_framework])
    proof.checked(["lipo", binaries / "RadiusChromiumBridge.dylib", "-verify_arch", arch])
    manifest = {"format": 2, "abi": 3, "runtimeStyle": "chrome", "architecture": arch, "cefVersion": proof.VERSION}
    (package / "Contents/Resources/manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    proof.checked(["codesign", "--force", "--sign", "-", package])
    proof.checked(["codesign", "--verify", "--deep", "--strict", package])
    source_files = [ROOT / "ChromiumRuntime/RadiusChromiumBridge.mm", ROOT / "ChromiumRuntime/Helper.cc",
                    ROOT / "ChromiumRuntime/CMakeLists.txt", ROOT / "ChromiumRuntime/Helper-Info.plist.in",
                    ROOT / "Sources/RadiusEngineABI/include/RadiusEngineABI.h", Path(__file__).resolve()]
    source_digests = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files}
    try:
        radius_commit = subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        radius_commit = None
    evidence = {"package": str(package), "architecture": arch, "cefVersion": proof.VERSION,
                "radiusCommit": radius_commit, "adapterSourceSHA256": source_digests,
                "archiveSHA256": proof.ARCHIVES[arch][1], "sandbox": True,
                "radiusAdapter": True, "radiusEmbeddedRuntimeValidated": False,
                "chromeExtensions": False, "developerID": False, "notarized": False,
                "hostArchitecture": platform.machine()}
    (work / ("radius-adapter-" + arch + ".json")).write_text(json.dumps(evidence, indent=2) + "\n")
    print("Development package:", package, flush=True)


def embed(package, app):
    """Embed validated native code before the containing application is signed."""
    proof.require_mac()
    package = package.resolve(strict=True)
    manifest_path = package / "Contents/Resources/manifest.json"
    if manifest_path.stat().st_size > 4096 or not manifest_path.is_file():
        raise ValueError("Invalid Chromium package manifest")
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("format") != 2 or manifest.get("abi") != 3 or manifest.get("runtimeStyle") != "chrome" or
            manifest.get("cefVersion") != proof.VERSION or manifest.get("architecture") not in proof.ARCHIVES):
        raise ValueError("Incompatible Chromium development package")
    for path in package.rglob("*"):
        if not path.resolve(strict=True).is_relative_to(package):
            raise ValueError("A Chromium package link escapes its bundle")
    proof.checked(["codesign", "--verify", "--deep", "--strict", package])
    destination = app.resolve(strict=True) / "Contents/Frameworks/Chromium.radiusengine"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    proof.checked(["ditto", package, destination])
    proof.checked(["codesign", "--verify", "--deep", "--strict", destination])
    print("Embedded Chromium for " + manifest["architecture"] + "; other architectures use WebKit.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=proof.ARCHIVES, default=platform.machine())
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--embed-package", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    if args.embed_package:
        if not args.app:
            parser.error("--embed-package requires --app")
        embed(args.embed_package, args.app)
    else:
        if not args.work_dir:
            parser.error("building requires --work-dir")
        build(args.work_dir.resolve(), args.arch)

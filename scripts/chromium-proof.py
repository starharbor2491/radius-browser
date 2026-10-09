#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Build/run upstream CEF experiments. This does not install an engine in Radius."""

import argparse
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import platform
import shutil
import signal
import subprocess
import tarfile
import tempfile
from threading import Event, Thread
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


VERSION = "154.0.34+g14c5a08+chromium-154.0.8037.98"
# Upstream standard distributions, observed 2026-10-09. SHA-256 values are pinned
# independently of future CDN responses. Update these deliberately with VERSION.
ARCHIVES = {
    "arm64": ("macosarm64", "2e4a60880addad09c85d9ea27f4df09cb803069e1709377576e9cf62169648fe"),
    "x86_64": ("macosx64", "b11f8b0d190541f167d0f66265c5017f2faf9b9d08790172732eb09accf00e40"),
}


def checked(command):
    print("Running:", " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True)


def write_evidence(path, evidence):
    path.write_text(json.dumps(evidence, indent=2) + "\n")


def require_mac():
    if platform.system() != "Darwin":
        raise RuntimeError("A Mac with Xcode is required to build or run CEF. "
                           "The fetch command can verify archives on Linux.")
    for tool in ("cmake", "xcodebuild", "xcrun"):
        if not shutil.which(tool):
            raise RuntimeError(f"Missing developer tool: {tool}")
    checked(["xcodebuild", "-version"])
    checked(["xcrun", "--sdk", "macosx", "--show-sdk-path"])


def fetch_archive(directory, architecture):
    cef_platform, expected_digest = ARCHIVES[architecture]
    stem = f"cef_binary_{VERSION}_{cef_platform}"
    archive = directory / (stem + ".tar.bz2")
    directory.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        url = "https://cef-builds.spotifycdn.com/" + urllib.parse.quote(archive.name)
        print(f"Downloading pinned CEF archive: {url}", flush=True)
        # A temporary file avoids treating an interrupted transfer as complete.
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
            temporary = Path(output.name)
            try:
                with urllib.request.urlopen(url, timeout=60) as response:
                    shutil.copyfileobj(response, output)
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
        temporary.rename(archive)
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected_digest:
        raise RuntimeError(f"Checksum mismatch; refusing to extract {archive}. "
                           "Remove this file before retrying.")
    print(f"Verified SHA-256: {digest.hexdigest()}", flush=True)
    return archive, stem


def build(directory, architecture):
    require_mac()
    if not hasattr(tarfile, "data_filter"):
        raise RuntimeError("Use Python 3.12+ (or a Python release with tarfile.data_filter).")
    directory.mkdir(parents=True, exist_ok=True)
    evidence_path = directory / f"build-{architecture}.json"
    evidence = {
        "cef_version": VERSION,
        "architecture": architecture,
        "build_machine": platform.platform(),
        "host_architecture": platform.machine(),
        "started_at": datetime.now(timezone.utc).isoformat(),
        "source_revision": os.environ.get("GITHUB_SHA"),
        "archive_sha256": ARCHIVES[architecture][1],
        "archive_verified": False,
        "compiled": False,
        "sandbox_requested": True,
        "radius_integration_verified": False,
        "consumer_extensions_verified": False,
        "signed_release_verified": False,
    }
    write_evidence(evidence_path, evidence)
    archive, stem = fetch_archive(directory, architecture)
    evidence["archive_verified"] = True
    write_evidence(evidence_path, evidence)
    # Re-extract into a fresh directory on every build: a partial extraction or
    # modified cached sample must never stand in for the verified archive.
    with tempfile.TemporaryDirectory(prefix="source-", dir=directory) as temporary:
        with tarfile.open(archive, "r:bz2") as package:
            package.extractall(temporary, filter="data")
        source = Path(temporary) / stem
        if not (source / "tests/cefclient/CMakeLists.txt").is_file():
            raise RuntimeError("The pinned archive does not contain the expected CEF sample.")
        output = source / "build"
        # This pinned distribution's sample CMake ARC block refers to an unset
        # ${target} before defining its target. Use its supported MRC option.
        checked(["cmake", "-S", source, "-B", output, "-G", "Xcode",
                 f"-DPROJECT_ARCH={architecture}",
                 f"-DCMAKE_OSX_ARCHITECTURES={architecture}", "-DUSE_SANDBOX=ON",
                 "-DOPTION_USE_ARC=OFF"])
        checked(["cmake", "--build", output, "--config", "Release", "--target", "cefclient"])
        apps = list(output.rglob("cefclient.app"))
        if len(apps) != 1:
            raise RuntimeError(f"Expected one cefclient.app; found {len(apps)}")
        # Keep the whole bundle (framework, helper apps and resources), never
        # copy only the main executable. Build output is not a signed release.
        destination = directory / f"cefclient-{architecture}.app"
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(apps[0], destination, symlinks=True)
    executable = destination / "Contents/MacOS/cefclient"
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    if architectures != [architecture]:
        raise RuntimeError(f"Unexpected executable architectures: {architectures}")
    evidence.update(sample_bundle=str(destination), compiled=True, executable_architectures=architectures)
    write_evidence(evidence_path, evidence)
    print(f"Built upstream CEF sample: {destination}")
    print("Radius integration, extension compatibility, and distribution remain unverified.")


def sample_command(directory, architecture, style, url, probe=False):
    executable = directory / f"cefclient-{architecture}.app/Contents/MacOS/cefclient"
    if not executable.is_file():
        raise RuntimeError("Build the sample first with the build command.")
    # Both experiments use separate persistent CEF stores. Neither reads the
    # user's Chrome/WebKit profiles or Radius's browser metadata.
    profile = directory / "profiles" / architecture / (("probe-" if probe else "") + style)
    profile.mkdir(parents=True, exist_ok=True)
    flags = ["--use-views"] if style == "chrome" else ["--use-native", "--use-alloy-style"]
    # cefclient sets CefSettings.cache_path from this switch; CEF uses that path
    # as root_cache_path when the latter is empty (see cef_types.h).
    return [str(executable), *flags, f"--url={url}", f"--cache-path={profile}",
            f"--log-file={profile / 'cef.log'}"]


def run(directory, architecture, style, url):
    require_mac()
    checked(sample_command(directory, architecture, style, url))


def probe(directory, architecture, style):
    """Observe a renderer callback and an ordinary app quit, without weakening protections."""
    require_mac()
    directory.mkdir(parents=True, exist_ok=True)
    evidence_path = directory / f"probe-{architecture}-{style}.json"
    evidence = {
        "cef_version": VERSION,
        "architecture": architecture,
        "host_architecture": platform.machine(),
        "requested_style": style,
        "status": "started",
        "sandbox_disabled": False,
        "renderer_javascript_verified": False,
        "graceful_browser_exit_verified": False,
        "radius_integration_verified": False,
        "consumer_extensions_verified": False,
        "signed_release_verified": False,
    }
    if architecture != platform.machine():
        evidence.update(status="skipped", reason="Cross-compiled architecture; no native runtime test on this host.")
        write_evidence(evidence_path, evidence)
        print(evidence["reason"], flush=True)
        return
    write_evidence(evidence_path, evidence)
    ready = Event()
    token = uuid.uuid4().hex

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == f"/ready/{token}":
                body = b"ok"
                ready.set()
            else:
                body = ("<!doctype html><title>Radius CEF integration proof</title>"
                        "<h1>Upstream CEF renderer check</h1>"
                        f"<script>fetch('/ready/{token}')</script>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    process = None
    try:
        url = f"http://127.0.0.1:{server.server_port}/"
        command = sample_command(directory, architecture, style, url, probe=True)
        print("Launching upstream sample:", " ".join(command), flush=True)
        with (directory / f"runtime-{architecture}-{style}.log").open("w") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 45
            while not ready.wait(0.1):
                if process.poll() is not None:
                    raise RuntimeError(f"Sample exited before rendering (status {process.returncode}).")
                if time.monotonic() > deadline:
                    raise RuntimeError("Sample did not execute the loopback page's JavaScript within 45 seconds.")
            evidence["renderer_javascript_verified"] = True
            write_evidence(evidence_path, evidence)
            # The pinned sample routes ordinary Cocoa quit through browser closure
            # and CefShutdown. A failed Apple event is a failed gate, not permission
            # to force a quit and claim lifecycle success.
            bundle = directory / f"cefclient-{architecture}.app"
            script = "on run argv\n tell application (item 1 of argv) to quit\nend run"
            subprocess.run(["osascript", "-e", script, str(bundle)], check=True, timeout=15)
            result = process.wait(timeout=20)
            evidence["exit_status"] = result
            if result != 0:
                raise RuntimeError(f"Sample did not quit cleanly (status {result}).")
            evidence.update(status="passed", graceful_browser_exit_verified=True)
            print("Upstream sample rendered JavaScript and quit cleanly. Radius hosting and extensions remain unverified.", flush=True)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        evidence.update(status="failed", error=str(error))
        raise
    finally:
        # This group contains only this proof's sample and helpers. Forced cleanup
        # is never recorded as a successful lifecycle test.
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        server.shutdown()
        server.server_close()
        thread.join()
        write_evidence(evidence_path, evidence)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "build", "run", "probe"))
    parser.add_argument("--arch", choices=tuple(ARCHIVES), default=platform.machine())
    parser.add_argument("--work-dir", type=Path,
                        default=Path(__file__).resolve().parents[1] / ".build/chromium-proof")
    parser.add_argument("--style", choices=("chrome", "native-alloy"), default="chrome")
    parser.add_argument("--url", default="chrome://version")
    arguments = parser.parse_args()
    if arguments.arch not in ARCHIVES:
        parser.error("Select a macOS architecture with --arch arm64 or --arch x86_64.")
    directory = arguments.work_dir.expanduser().resolve()
    try:
        if arguments.command == "fetch":
            archive, _ = fetch_archive(directory, arguments.arch)
            print(archive)
        elif arguments.command == "build":
            build(directory, arguments.arch)
        elif arguments.command == "probe":
            probe(directory, arguments.arch, arguments.style)
        else:
            run(directory, arguments.arch, arguments.style, arguments.url)
    except (OSError, RuntimeError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(1, f"Chromium proof: {error}\n")


if __name__ == "__main__":
    main()

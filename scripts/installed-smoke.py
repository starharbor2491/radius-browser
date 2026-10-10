#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Verify the generated DMG through a read-only mount, installed launch and removal.

This is CI acceptance of the actual package bytes. Development signatures remain
ad-hoc; this check does not grant Gatekeeper or consumer-updater trust.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / 'dist'


def checked(command, timeout=60):
    result = subprocess.run([str(x) for x in command], timeout=timeout,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(str(command[0]) + ' failed: ' + result.stderr[:8192].decode(errors='replace'))
    return result.stdout


def bounded_json(path):
    with path.open('rb') as handle:
        data = handle.read(16 * 1024 + 1)
    if len(data) > 16 * 1024:
        raise ValueError('Package metadata exceeds its size limit')
    return json.loads(data)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def code_hashes(app):
    checked(['codesign', '--verify', '--deep', '--strict', '--all-architectures', app])
    result = {}
    for architecture in ('arm64', 'x86_64'):
        info = subprocess.run(['codesign', '-d', '--verbose=4', '--arch', architecture, str(app)],
                              check=True, timeout=30, capture_output=True, text=True)
        match = re.search(r'^CDHash=([0-9a-f]{40})$', info.stderr, re.MULTILINE)
        if not match:
            raise ValueError('The universal app has no verifiable ' + architecture + ' code hash')
        result[architecture] = match.group(1)
    return result


def process_snapshot():
    output = checked(['ps', '-ww', '-axo', 'pid=,ppid=,rss=,time=,command='], timeout=5)
    if len(output) > 4 * 1024 * 1024:
        raise ValueError('Process listing exceeds the CI observation limit')
    rows = {}
    for line in output.decode(errors='replace').splitlines():
        fields = line.split(None, 4)
        if len(fields) != 5:
            continue
        pid, parent, rss, cpu, command = fields
        days, clock = cpu.split('-', 1) if '-' in cpu else ('0', cpu)
        seconds = 0.0
        for part in clock.split(':'):
            seconds = seconds * 60 + float(part)
        rows[int(pid)] = {'parent': int(parent), 'rssKiB': int(rss),
                          'cpuSeconds': seconds + int(days) * 86400, 'command': command}
    return rows


def owned_processes(app):
    # The unique owned copy path distinguishes this launch from other Radius apps.
    aliases = {str(app), str(app.resolve())}
    return [pid for pid, row in process_snapshot().items()
            if any(alias + '/Contents/' in row['command'] for alias in aliases)]


def run_smoke(command, environment, timeout):
    process = subprocess.Popen(command, cwd=ROOT, env=environment, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
        if status:
            raise subprocess.CalledProcessError(status, command)
    except BaseException:
        # Timeout/interruption never counts as a normal quit. Stop only this
        # owned invocation's process group, even if its leader exited first.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 8
        while True:
            process.poll()  # Reap the leader without conflating it with its group.
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if process.poll() is None:
                    process.wait(timeout=5)
                break
            time.sleep(0.1)
        raise


class PerformanceObservation:
    """Optional CI observations; missing samples never alter acceptance."""
    def __init__(self, temporary):
        self.temporary = temporary
        self.stop = threading.Event()
        self.result = {'gating': False, 'workloads': {
                       'initial-shell-onboarding': 'Initial native shell/onboarding before loopback navigation or Chromium initialization',
                       'loaded-webkit-loopback': 'One loaded loopback WebKit page, before split panes',
                       'loaded-chromium-with-webkit-pane': 'Loaded loopback Chromium page with the other WebKit split pane retained'},
                       'idleWindows': {},
                       'runnerArchitecture': platform.machine(), 'macOS': platform.mac_ver()[0],
                       'notes': ['Files were copied and signature-verified before launch; no cold-start claim.',
                                 'RSS sums can double-count shared pages; they are not physical footprint.',
                                 'CPU uses surviving process-tree deltas; exited children are not counted.',
                                 'System-managed WebKit processes outside the app process tree are not counted.',
                                 'Navigation is title/load readiness with a 100 ms poll, not paint or input latency.']}
        self.thread = threading.Thread(target=self.observe, daemon=True)

    def tree(self):
        pid = int((self.temporary / 'pid').read_text().strip())
        self.host_pid = pid
        rows = process_snapshot()
        selected = {pid} if pid in rows else set()
        while True:
            additions = {key for key, row in rows.items() if row['parent'] in selected}
            if additions.issubset(selected):
                break
            selected.update(additions)
        return {key: rows[key] for key in selected}

    def observe(self):
        initial = None
        phase = None
        first_at = 0
        peak_rss = 0
        next_sample = 0
        try:
            while not self.stop.wait(0.05):
                if not (self.temporary / 'launch').is_file() or not (self.temporary / 'pid').is_file():
                    continue
                log = DIST / 'smoke-app.log'
                if not log.exists():
                    continue
                with log.open('rb') as handle:
                    content = handle.read(256 * 1024).decode(errors='replace')
                if 'Browser window opened\n' in content and 'launchToWindowReadySecondsUpperBound' not in self.result:
                    started = bounded_json(self.temporary / 'launch')['monotonic']
                    self.result['launchToWindowReadySecondsUpperBound'] = time.monotonic() - started
                    self.result['readinessObserverPollSeconds'] = 0.05
                begins = re.findall(r'SMOKE_PERFORMANCE_IDLE_BEGIN ([a-z-]+)\n', content)
                pending = [name for name in begins if name not in self.result['idleWindows']]
                if pending and initial is None:
                    phase = pending[0]
                    initial = self.tree()
                    first_at = time.monotonic()
                    peak_rss = sum(row['rssKiB'] for row in initial.values())
                    next_sample = first_at + 1
                if initial is not None:
                    ended = 'SMOKE_PERFORMANCE_IDLE_END ' + phase + '\n' in content
                    if time.monotonic() >= next_sample or ended:
                        final = self.tree()
                        peak_rss = max(peak_rss, sum(row['rssKiB'] for row in final.values()))
                        next_sample = time.monotonic() + 1
                        if ended:
                            elapsed = time.monotonic() - first_at
                            deltas = {pid: max(0, row['cpuSeconds'] - initial[pid]['cpuSeconds'])
                                      for pid, row in final.items() if pid in initial and row['command'] == initial[pid]['command']}
                            cpu = sum(deltas.values())
                            self.result['idleWindows'][phase] = {'observedSeconds': elapsed, 'processTreeCPUSeconds': cpu,
                                                   'hostCPUSeconds': deltas.get(self.host_pid, 0),
                                                   'childCPUSeconds': cpu - deltas.get(self.host_pid, 0),
                                                   'hostRSSKiB': final.get(self.host_pid, {}).get('rssKiB', 0),
                                                   'childRSSKiB': sum(row['rssKiB'] for pid, row in final.items() if pid != self.host_pid),
                                                   'percentOfOneCore': cpu / elapsed * 100,
                                                   'peakSampledSummedRSSKiB': peak_rss,
                                                   'processes': [{'pid': pid, 'role': 'host' if pid == self.host_pid else 'child',
                                                                  'rssKiB': row['rssKiB'], 'cpuDeltaSeconds': deltas.get(pid)}
                                                                 for pid, row in sorted(final.items())]}
                            if elapsed < 4:
                                self.result['idleWindows'][phase] = {'unavailable': 'The observer missed the idle window'}
                            initial = None
                match = re.search(r'SMOKE_PERFORMANCE_NAVIGATION_SECONDS ([0-9.]+)', content)
                if match:
                    self.result['loopbackNavigationToTitleAndLoadReadySeconds'] = float(match.group(1))
        except Exception as error:
            self.result['observationUnavailable'] = str(error)

    def finish(self):
        self.stop.set()
        self.thread.join(timeout=6)
        try:
            if not self.result['idleWindows']:
                self.result.setdefault('observationUnavailable', 'The native idle window did not produce complete samples')
            (DIST / 'smoke-performance.json').write_text(json.dumps(self.result, indent=2) + '\n')
        except OSError as error:
            print('Optional performance receipt unavailable: ' + str(error), flush=True)


def main(restart):
    if platform.system() != 'Darwin':
        raise RuntimeError('Installed package acceptance requires macOS')
    receipts = list(DIST.glob('*-package.json'))
    if len(receipts) != 1:
        raise ValueError('Build exactly one current installer before installed acceptance')
    package = bounded_json(receipts[0])
    name = package['file']
    if not isinstance(name, str) or Path(name).name != name or not name.endswith('.dmg'):
        raise ValueError('Invalid installer basename')
    dmg = DIST / name
    if dmg.is_symlink() or not dmg.is_file() or not 0 < package['bytes'] <= 4 * 1024**3:
        raise ValueError('Invalid installer file or size')
    if dmg.stat().st_size != package['bytes'] or digest(dmg) != package['sha256']:
        raise ValueError('Installer bytes differ from the packaging receipt')
    expected = code_hashes(DIST / 'Radius.app')
    evidence = {'sourceCheckout': checked(['git', '-C', ROOT, 'rev-parse', 'HEAD']).decode().strip(),
                'workflowSource': os.environ.get('GITHUB_SHA'), 'workflowRun': os.environ.get('GITHUB_RUN_ID'),
                'package': package, 'codeDirectoryHashes': expected, 'passed': False}
    temporary = Path(tempfile.mkdtemp(prefix='radius-installed-smoke-', dir=os.environ.get('RUNNER_TEMP')))
    mount = temporary / 'mount'
    mount.mkdir()
    copied = temporary / 'Applications/Radius.app'
    attached = False
    observation = PerformanceObservation(temporary)
    try:
        # A failed/timeout attach can still leave a mounted volume; retain ownership
        # before starting it, so cleanup never removes an attached directory.
        attached = True
        entities = plistlib.loads(checked(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount,
                                          '-plist', dmg], timeout=90))['system-entities']
        if not any(Path(item.get('mount-point', '')).resolve() == mount.resolve() for item in entities):
            raise ValueError('The disk image did not mount at its owned mount point')
        if not os.statvfs(mount).f_flag & os.ST_RDONLY:
            raise ValueError('The installer volume is not read-only')
        if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications':
            raise ValueError('The graphical installer has no correct Applications shortcut')
        instructions = mount / 'Install Radius.txt'
        if instructions.is_symlink() or not instructions.is_file() or not 0 < instructions.stat().st_size <= 16 * 1024:
            raise ValueError('The graphical installer has no bounded installation instructions')
        mounted = mount / 'Radius.app'
        if mounted.is_symlink() or code_hashes(mounted) != expected:
            raise ValueError('The mounted app differs from the sealed build')
        if bounded_json(mounted / 'Contents/Resources/Distribution.json') != package['release']:
            raise ValueError('The mounted release differs from its package receipt')
        expected_modules = {path.name for path in (ROOT / 'Sources/RadiusApp/Resources/Modules').iterdir() if path.is_dir()}
        mounted_modules = {path.name for path in (mounted / 'Contents/Resources/Modules').iterdir() if path.is_dir()}
        if mounted_modules != expected_modules:
            raise ValueError('The offline installer is missing default module payloads')
        evidence['defaultModules'] = sorted(mounted_modules)
        checked(['ditto', mounted, copied], timeout=120)
        if code_hashes(copied) != expected:
            raise ValueError('The installed copy differs from the mounted app')
        checked(['hdiutil', 'detach', mount], timeout=60)
        attached = False
        evidence.update(readOnlyMount=True, sealedCopyVerified=True, detachedBeforeLaunch=True)
        environment = os.environ.copy()
        environment.update(RADIUS_SMOKE_APP_PATH=str(copied), RADIUS_SMOKE_PERFORMANCE='1',
                           RADIUS_SMOKE_LAUNCH_RECORD=str(temporary / 'launch'), RADIUS_SMOKE_PID_RECORD=str(temporary / 'pid'))
        observation.thread.start()
        run_smoke(['bash', str(ROOT / 'scripts/smoke-app.sh')], environment, 500)
        if 'Radius packaged-app smoke test passed.' not in (DIST / 'smoke-app.log').read_text():
            raise ValueError('The installed launch did not finish its native acceptance checks')
        evidence['normalQuit'] = True
        if restart:
            run_smoke(['python3', str(ROOT / 'scripts/smoke-chromium-restart.py')], environment, 100)
            if 'Chromium real-process restart acceptance passed' not in (DIST / 'smoke-chromium-restart.log').read_text():
                raise ValueError('The installed restart did not finish its extension persistence checks')
            evidence['chromiumProcessRestartAndNormalQuit'] = True
        deadline = time.monotonic() + 5
        while owned_processes(copied):
            if time.monotonic() > deadline:
                raise ValueError('An installed app process survived normal quit')
            time.sleep(0.1)
        data = DIST / 'smoke-data'
        library = data / 'library.sqlite'
        if library.is_symlink() or not library.is_file() or not 0 < library.stat().st_size <= 256 * 1024**2:
            raise ValueError('The installed app did not save its actual external user library')
        preserved = digest(library)
        shutil.rmtree(copied)
        if copied.exists() or digest(library) != preserved:
            raise ValueError('Removing the installed app did not preserve external user data')
        evidence.update(ownedAppProcessesExited=True, installedCopyRemoved=True, externalUserDataKept=True,
                        preservedUserLibrarySHA256=preserved, passed=True)
        print('Read-only DMG copy, installed launch, normal quit and removal passed.', flush=True)
    except BaseException as error:
        evidence['error'] = str(error)
        raise
    finally:
        if observation.thread.ident is not None:
            observation.finish()
        if attached:
            try:
                checked(['hdiutil', 'detach', mount], timeout=60)
                attached = False
            except Exception as error:
                evidence['cleanupError'] = str(error)
        # Keep a failed live copy or still-mounted volume for diagnostic inspection.
        try:
            if not attached and not owned_processes(copied):
                shutil.rmtree(temporary)
            else:
                evidence['preservedTemporaryDirectory'] = str(temporary)
        except Exception as error:
            evidence['cleanupError'] = str(error)
        (DIST / 'installed-smoke.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    def interrupt(signum, frame):
        raise InterruptedError('Installed acceptance interrupted by signal ' + str(signum))

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGHUP, interrupt)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium-restart', action='store_true')
    main(parser.parse_args().chromium_restart)

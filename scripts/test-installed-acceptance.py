#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Regression checks for installed acceptance without macOS or a real package."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('installed_smoke', ROOT / 'scripts/installed-smoke.py')
installed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installed)


class InstalledAcceptanceTests(unittest.TestCase):
    def check_log(self, content, acceptance='Radius packaged-app smoke test passed.'):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'app.log'
            log.write_text(content)
            installed.verify_normal_quit(log, acceptance)

    def test_acceptance_then_termination_reply_is_required(self):
        self.check_log('Radius packaged-app smoke test passed.\n'
                       'Radius app delegate: applicationShouldTerminate entered\n'
                       'Radius app delegate: Sending termination reply: true\n')

    def test_success_message_without_normal_quit_is_rejected(self):
        with self.assertRaises(ValueError):
            self.check_log('Radius packaged-app smoke test passed.\n')

    def test_termination_before_acceptance_is_rejected(self):
        with self.assertRaises(ValueError):
            self.check_log('Radius app delegate: applicationShouldTerminate entered\n'
                           'Radius app delegate: Sending termination reply: true\n'
                           'Radius packaged-app smoke test passed.\n')

    def test_refused_termination_is_rejected(self):
        with self.assertRaises(ValueError):
            self.check_log('Radius packaged-app smoke test passed.\n'
                           'Radius app delegate: applicationShouldTerminate entered\n'
                           'Radius app delegate: Sending termination reply: false\n')

    def test_restart_requires_its_own_normal_quit(self):
        self.check_log('Chromium real-process restart acceptance passed\n'
                       'Radius app delegate: applicationShouldTerminate entered\n'
                       'Radius app delegate: Sending termination reply: true\n',
                       'Chromium real-process restart acceptance passed')

    def test_watchdog_rejects_term_even_when_app_exits_zero(self):
        # Run the actual shell driver in an owned fixture tree. HTTP and long
        # waits are replaced; the launched process really handles TERM with exit 0.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            commands = root / 'commands'
            executable = root / 'Radius.app/Contents/MacOS/Radius'
            scripts.mkdir()
            commands.mkdir()
            executable.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'scripts/smoke-app.sh', scripts / 'smoke-app.sh')
            (scripts / 'smoke-server.py').write_text(
                'import pathlib, sys, time\n'
                'pathlib.Path(sys.argv[2]).write_text("12345")\n'
                'while True: time.sleep(1)\n')
            sleeper = commands / 'sleep'
            sleeper.write_text('#!' + sys.executable + '\nimport sys, time\n'
                               'time.sleep(0.02 if float(sys.argv[1]) < 10 else 0.25)\n')
            curl = commands / 'curl'
            curl.write_text('#!/bin/sh\nexit 0\n')
            executable.write_text('#!' + sys.executable + '\nimport signal, sys, time\n'
                                  'signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n'
                                  'print("Radius packaged-app smoke test passed.", flush=True)\n'
                                  'while True: time.sleep(1)\n')
            for path in (sleeper, curl, executable):
                path.chmod(0o755)
            environment = installed.os.environ.copy()
            for name in ('RADIUS_CHROMIUM_PACKAGE', 'RADIUS_SMOKE_LAUNCH_RECORD', 'RADIUS_SMOKE_PID_RECORD'):
                environment.pop(name, None)
            environment.update(PATH=str(commands) + installed.os.pathsep + environment['PATH'],
                               RADIUS_SMOKE_APP_PATH=str(root / 'Radius.app'))
            result = subprocess.run(['bash', str(scripts / 'smoke-app.sh')], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertIn('Radius packaged-app smoke test passed.', result.stdout)
            self.assertTrue((root / 'dist/smoke-timeout.txt').is_file())


if __name__ == '__main__':
    unittest.main()

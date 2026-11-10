import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('finite', Path(__file__).parents[1] / 'scripts/finite_helper.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class FiniteHelperTests(unittest.TestCase):
    def test_success_and_failure_are_atomic(self):
        self.assertEqual(helper.run([sys.executable, '-c', 'print("ok")'], 2, 20), b'ok\n')
        with self.assertRaises(helper.HelperError):
            helper.run([sys.executable, '-c', 'print("partial"); exit(1)'], 2, 20)

    def test_flood_silence_drip_and_eof_without_exit(self):
        for code in ['import time; time.sleep(60)',
                     'import os,time; os.close(1); time.sleep(60)',
                     'import os\nwhile True: os.write(1,b"x"*65536)',
                     'import os,time\nwhile True: os.write(1,b"x"); time.sleep(.01)']:
            started = time.monotonic()
            with self.assertRaises(helper.HelperError):
                helper.run([sys.executable, '-c', code], .2, 1000)
            self.assertLess(time.monotonic() - started, 1.5)

    def test_stderr_is_discarded(self):
        code = 'import os; os.write(2,b"x"*1000000); print("ok")'
        self.assertEqual(helper.run([sys.executable, '-c', code], 2, 10), b'ok\n')

    def test_sigterm_ignoring_descendant_is_killed(self):
        with tempfile.TemporaryDirectory() as folder:
            pidfile = Path(folder) / 'pid'
            code = ('import os,signal,time\n'
                    'if os.fork()==0:\n signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                    'open(%r,"w").write(str(os.getpid())); time.sleep(60)\n'
                    'else: time.sleep(60)') % str(pidfile)
            with self.assertRaises(helper.HelperError):
                helper.run([sys.executable, '-c', code], .3, 100)
            pid = int(pidfile.read_text())
            for _ in range(100):
                try:
                    state = Path(f'/proc/{pid}/stat').read_text().split()[2]
                except (FileNotFoundError, ProcessLookupError):
                    break
                if state == 'Z':
                    break
                time.sleep(.01)
            else:
                self.fail('descendant survived forced cleanup')

    def test_import_fifo_rejected_and_normal_import_recovers(self):
        cli = str(Path(helper.__file__).resolve())
        with tempfile.TemporaryDirectory() as folder:
            fifo = Path(folder) / 'stalled.json'
            os.mkfifo(fifo)
            result = subprocess.run([sys.executable, cli, 'import', str(fifo)], capture_output=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')
            regular = Path(folder) / 'normal.json'
            regular.write_text('{}')
            result = subprocess.run([sys.executable, cli, 'import', str(regular)], capture_output=True, timeout=2)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'{}')

    def test_supervisor_sigterm_cleans_up_ignoring_child(self):
        with tempfile.TemporaryDirectory() as folder:
            pidfile = Path(folder) / 'pid'
            code = ('import importlib.util,signal,sys; '
                    's=importlib.util.spec_from_file_location("finite",sys.argv[1]); '
                    'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                    'signal.signal(signal.SIGTERM,m.cancel); '
                    'm.run([sys.executable,"-c",sys.argv[2]],60,100)')
            childcode = ('import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                         f'open({str(pidfile)!r},"w").write(str(os.getpid())); time.sleep(60)')
            process = subprocess.Popen([sys.executable, '-c', code, str(Path(helper.__file__).resolve()), childcode],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    if pidfile.exists():
                        break
                    time.sleep(.01)
                self.assertTrue(pidfile.exists())
                process.terminate()
                process.wait(timeout=2)
                self.assertFalse(Path('/proc/' + pidfile.read_text()).exists())
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()

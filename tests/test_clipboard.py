import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('clipboard_read', Path(__file__).parents[1] / 'scripts/clipboard_read.py')
clipboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clipboard)


class ClipboardTests(unittest.TestCase):
    def transfer(self, code, **kwargs):
        return clipboard.read_transfer([sys.executable, '-c', code], **kwargs)

    def test_utf8_single_line_and_controls(self):
        value = self.transfer("import os; os.write(1, '音楽 🎵\\nartist\\ttrack\\x00\\x7f'.encode())")
        self.assertEqual(value, '音楽 🎵 artist track')

    def test_exact_byte_limit_and_empty_clipboard(self):
        self.assertEqual(self.transfer("import os; os.write(1,b'a'*4096)"), 'a' * 4096)
        self.assertEqual(self.transfer('pass'), '')

    def test_oversize_is_rejected_instead_of_partially_inserted(self):
        with self.assertRaisesRegex(clipboard.PasteError, 'exceeds'):
            self.transfer("import os; os.write(1,b'a'*4097)")
        with self.assertRaisesRegex(clipboard.PasteError, 'exceeds'):
            self.transfer("import os; os.write(1,'音'.encode()*1366)")

    def test_infinite_flood_is_bounded(self):
        start = time.monotonic()
        with self.assertRaisesRegex(clipboard.PasteError, 'exceeds'):
            self.transfer("import os\nwhile True: os.write(1,b'x'*65536)", timeout=1)
        self.assertLess(time.monotonic() - start, 1.5)

    def test_silent_provider_and_slow_drip_have_total_deadline(self):
        for code in ['import time; time.sleep(60)',
                     "import os,time\nwhile True:\n os.write(1,b'a'); time.sleep(.02)"]:
            start = time.monotonic()
            with self.assertRaisesRegex(clipboard.PasteError, 'timed out'):
                self.transfer(code, timeout=.35)
            self.assertLess(time.monotonic() - start, 1.5)

    def test_eof_without_process_exit_still_has_deadline(self):
        with self.assertRaisesRegex(clipboard.PasteError, 'timed out'):
            self.transfer('import os,time; os.close(1); time.sleep(60)', timeout=.35)

    def test_failure_and_invalid_utf8_return_no_text(self):
        with self.assertRaisesRegex(clipboard.PasteError, 'unavailable'):
            self.transfer("import os,sys; os.write(1,b'partial'); sys.exit(2)")
        with self.assertRaisesRegex(clipboard.PasteError, 'UTF-8'):
            self.transfer("import os; os.write(1,b'\\xff')")

    def test_timeout_kills_descendant_writer_after_parent_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            pid_file = Path(folder) / 'pid'
            child = "import os,time; open(%r,'w').write(str(os.getpid())); time.sleep(60)" % str(pid_file)
            code = 'import subprocess,sys; subprocess.Popen([sys.executable,"-c",%r])' % child
            with self.assertRaisesRegex(clipboard.PasteError, 'timed out'):
                self.transfer(code, timeout=.5)
            pid = int(pid_file.read_text())
            stat = Path('/proc') / str(pid) / 'stat'
            until = time.monotonic() + 1
            while stat.exists() and stat.read_text().split()[2] != 'Z' and time.monotonic() < until:
                time.sleep(.01)
            self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z')

    def test_cli_bounded_failure_and_sigterm_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            fake = Path(folder) / 'wl-paste'
            pid_file = Path(folder) / 'pid'
            fake.write_text('#!' + sys.executable + '\nimport os,time\n'
                            + 'open(%r,"w").write(str(os.getpid()))\n' % str(pid_file)
                            + 'while True:\n os.write(1,b"x"); time.sleep(.02)\n')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=folder + os.pathsep + os.environ.get('PATH', ''))
            worker = subprocess.Popen([sys.executable, spec.origin, 'clipboard'], stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, env=env)
            try:
                until = time.monotonic() + 2
                while not pid_file.exists() and time.monotonic() < until:
                    time.sleep(.01)
                self.assertTrue(pid_file.exists())
                worker.terminate()
                out, err = worker.communicate(timeout=2)
                payload = json.loads(out)
                self.assertFalse(payload['ok'])
                self.assertNotIn('text', payload)
                self.assertLess(len(out), 200)
                self.assertEqual(err, b'')
            finally:
                if worker.poll() is None:
                    worker.kill()
                    worker.wait()

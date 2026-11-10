#!/usr/bin/env python3
"""Supervise finite operations; only bounded successful output reaches QML."""
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


class HelperError(Exception):
    pass


def cancel(signum, frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise HelperError('cancelled')


def run(command, timeout, limit):
    end = time.monotonic() + timeout
    child = None
    try:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, start_new_session=True, bufsize=0)
        os.set_blocking(child.stdout.fileno(), False)
        output = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while True:
                remaining = end - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise HelperError('timeout')
                chunk = os.read(child.stdout.fileno(), min(65536, limit + 1 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > limit:
                    raise HelperError('output limit')
        # EOF is not process termination. Observe without reaping: retain the
        # PID/group identity until all descendant cleanup has been requested.
        while True:
            status = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if status is not None:
                if status.si_code != os.CLD_EXITED or status.si_status != 0:
                    raise HelperError('operation failed')
                return bytes(output)
            if time.monotonic() >= end:
                raise HelperError('timeout')
            time.sleep(min(.01, max(0, end - time.monotonic())))
    finally:
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.stdout.close()
            child.wait(timeout=.5)


def main():
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        if len(sys.argv) == 4 and sys.argv[1] == 'resolve':
            command = ['yt-dlp', '--no-warnings', '--no-playlist', '--socket-timeout', '15',
                       '--retries', '1', '--extractor-retries', '1', '-f', sys.argv[2],
                       '--print', '%(ext)s\t%(url)s', '--', sys.argv[3]]
            output = run(command, 45, 65536)
        elif len(sys.argv) == 3 and sys.argv[1] == 'import':
            output = run([sys.executable, str(Path(__file__).with_name('library_io.py')), sys.argv[2]], 5, 4_000_000)
        else:
            raise HelperError('invalid operation')
        sys.stdout.buffer.write(output)
        return 0
    except (HelperError, OSError, subprocess.SubprocessError):
        return 1


if __name__ == '__main__':
    sys.exit(main())

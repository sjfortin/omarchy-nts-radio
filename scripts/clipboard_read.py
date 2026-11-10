#!/usr/bin/env python3
"""Bound an explicit Wayland paste before returning anything to the shell GUI.

wl-paste/cat streams through finite kernel pipes; no QClipboard API is used.
The shell only collects our one size-bounded JSON result, never the clipboard
producer's stdout. A stalled, endless or oversized transfer yields no text.
"""
import json
import os
import selectors
import signal
import subprocess
import sys
import time

MAX_BYTES = 4096
DEADLINE_SECONDS = 2.0


class PasteError(Exception):
    pass


def read_transfer(command, *, max_bytes=MAX_BYTES, timeout=DEADLINE_SECONDS):
    """Read at most N+1 bytes with a single monotonic deadline, including exit.

    command is supplied internally, never from clipboard contents. The optional
    argument exists for adversarial pipe tests without touching a real clipboard.
    Stderr is discarded rather than accumulated. The process group includes
    wl-paste's cat child, so timeout/cancellation cannot orphan a blocked reader.
    """
    deadline = time.monotonic() + timeout
    process = None
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   start_new_session=True, bufsize=0)
        os.set_blocking(process.stdout.fileno(), False)
        data = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise PasteError('Clipboard transfer timed out')
                if not selector.select(remaining):
                    raise PasteError('Clipboard transfer timed out')
                chunk = os.read(process.stdout.fileno(), min(1024, max_bytes + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > max_bytes:
                    raise PasteError('Clipboard text exceeds 4 KB')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise PasteError('Clipboard transfer timed out')
        try:
            code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            raise PasteError('Clipboard transfer timed out') from None
        if code != 0:
            raise PasteError('Clipboard text is unavailable')
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError:
            raise PasteError('Clipboard text is not valid UTF-8') from None
        # Search is a single line. Keep Unicode, but never insert controls.
        return ''.join(' ' if char.isspace() else char for char in text
                       if not (ord(char) < 32 and not char.isspace())
                       and not 0x7f <= ord(char) <= 0x9f)
    finally:
        if process is not None:
            # Also kill descendants when the direct child exited but retained
            # a pipe writer exists. A new session gives this request its own PGID.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if process.stdout is not None:
                process.stdout.close()
            try:
                process.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass


def cancelled(signum, frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise PasteError('Clipboard transfer cancelled')


def main():
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    result = {'ok': False, 'error': 'Clipboard text is unavailable'}
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ('clipboard', 'primary'):
            raise PasteError('Invalid clipboard selection')
        command = ['wl-paste', '--no-newline', '--type', 'text/plain']
        if sys.argv[1] == 'primary':
            command.append('--primary')
        result = {'ok': True, 'text': read_transfer(command)}
    except FileNotFoundError:
        result = {'ok': False, 'error': 'Clipboard paste needs wl-clipboard'}
    except (PasteError, OSError) as error:
        result = {'ok': False, 'error': str(error) if isinstance(error, PasteError) else 'Clipboard text is unavailable'}
    # Bound before StdioCollector: at most 4096 input bytes, JSON escaping
    # bounded to six characters per code point; no partial payload on failure.
    sys.stdout.write(json.dumps(result, ensure_ascii=True, separators=(',', ':')) + '\n')
    sys.stdout.flush()
    return 0


if __name__ == '__main__':
    sys.exit(main())

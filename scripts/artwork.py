#!/usr/bin/env python3
"""Fetch/decode remote artwork outside the shared shell; emit one bounded PPM URI."""
import base64
import contextlib
import json
import os
from pathlib import Path
import re
import resource
import selectors
import http.client
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_ENCODED = 2_000_000
MAX_DIMENSION = 4096
MAX_PIXELS = 4_194_304
EDGE = 384
RGB_BYTES = EDGE * EDGE * 3
MAX_URI = 600_000
TOTAL_SECONDS = 10
ALLOWED_HOST = re.compile(r'(?:[a-z0-9-]+\.)?(?:ntslive\.co\.uk|ntslive\.net|nts\.live)\Z')


class ArtworkError(Exception):
    pass


def validate_url(value):
    if not isinstance(value, str) or len(value) > 600 or re.search(r'[\x00-\x20\x7f]', value):
        raise ArtworkError('Invalid artwork URL')
    try:
        url = urllib.parse.urlsplit(value)
        allowed = (url.scheme == 'https' and ALLOWED_HOST.fullmatch(url.hostname or '')
                   and url.username is None and url.password is None and url.port in (None, 443))
    except ValueError:
        allowed = False
    if not allowed:
        raise ArtworkError('Invalid artwork URL')
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@contextlib.contextmanager
def deadline(seconds):
    # One absolute budget interrupts DNS/TLS/header/body reads and decode wait,
    # including a provider that continuously sends data before socket timeout.
    def expired(signum, frame):
        raise ArtworkError('Artwork deadline exceeded')
    previous = signal.signal(signal.SIGALRM, expired)
    previous_timer = signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield time.monotonic() + seconds
    finally:
        signal.setitimer(signal.ITIMER_REAL, *previous_timer)
        signal.signal(signal.SIGALRM, previous)


def fetch(url, end_at, opener=None):
    opener = opener or urllib.request.build_opener(NoRedirect(), urllib.request.ProxyHandler({}))
    target = validate_url(url)
    for hop in range(4):
        remaining = end_at - time.monotonic()
        if remaining <= 0:
            raise ArtworkError('Artwork deadline exceeded')
        request = urllib.request.Request(target, headers={
            'Accept': 'image/png,image/jpeg,image/webp', 'Accept-Encoding': 'identity',
            'User-Agent': 'omarchy-nts-radio'})
        try:
            response = opener.open(request, timeout=remaining)
        except urllib.error.HTTPError as error:
            response = error
        with contextlib.closing(response):
            if response.status in (301, 302, 303, 307, 308):
                location = response.headers.get('Location')
                if hop == 3 or not location:
                    raise ArtworkError('Artwork redirect limit exceeded')
                # Validate every destination before making another request.
                target = validate_url(urllib.parse.urljoin(target, location))
                continue
            if response.status != 200:
                raise ArtworkError('Artwork unavailable')
            if response.headers.get('Content-Encoding', 'identity').lower() not in ('', 'identity'):
                raise ArtworkError('Compressed HTTP artwork is unsupported')
            length = response.headers.get('Content-Length')
            if length is not None:
                try:
                    if int(length) < 0 or int(length) > MAX_ENCODED:
                        raise ArtworkError('Artwork exceeds encoded byte limit')
                except ValueError:
                    raise ArtworkError('Invalid artwork length') from None
            body = bytearray()
            while True:
                if time.monotonic() >= end_at:
                    raise ArtworkError('Artwork deadline exceeded')
                chunk = response.read1(min(65536, MAX_ENCODED + 1 - len(body)))
                if not chunk:
                    return bytes(body)
                if len(body) + len(chunk) > MAX_ENCODED:
                    raise ArtworkError('Artwork exceeds encoded byte limit')
                body.extend(chunk)
    raise ArtworkError('Artwork unavailable')


def raster_header(body):
    """Check dimensions before invoking any decoder. Accept static 8-bit raster only."""
    if len(body) > MAX_ENCODED:
        raise ArtworkError('Artwork exceeds encoded byte limit')
    fmt = None
    if body.startswith(b'\x89PNG\r\n\x1a\n') and len(body) >= 33:
        if body[8:16] != b'\0\0\0\rIHDR' or body[24] > 8:
            raise ArtworkError('Unsupported PNG header')
        fmt = 'png'
        width = int.from_bytes(body[16:20], 'big')
        height = int.from_bytes(body[20:24], 'big')
    elif body.startswith(b'\xff\xd8'):
        index = 2
        while index + 4 <= len(body):
            if body[index] != 255:
                break
            while index < len(body) and body[index] == 255:
                index += 1
            if index >= len(body):
                break
            marker = body[index]
            index += 1
            if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
                continue
            if index + 2 > len(body):
                break
            size = int.from_bytes(body[index:index + 2], 'big')
            if size < 2 or index + size > len(body):
                break
            if marker in (0xC0, 0xC2) and size >= 8 and body[index + 2] == 8:
                fmt = 'jpeg'
                height = int.from_bytes(body[index + 3:index + 5], 'big')
                width = int.from_bytes(body[index + 5:index + 7], 'big')
                break
            if marker == 0xDA:
                break
            index += size
    elif body[:4] == b'RIFF' and body[8:12] == b'WEBP' and len(body) >= 30:
        kind = body[12:16]
        if kind == b'VP8X' and not body[20] & 2:  # Reject animation.
            width = int.from_bytes(body[24:27], 'little') + 1
            height = int.from_bytes(body[27:30], 'little') + 1
            fmt = 'webp'
        elif kind == b'VP8 ' and body[23:26] == b'\x9d\x01\x2a':
            width = int.from_bytes(body[26:28], 'little') & 0x3FFF
            height = int.from_bytes(body[28:30], 'little') & 0x3FFF
            fmt = 'webp'
        elif kind == b'VP8L' and body[20] == 0x2F:
            bits = int.from_bytes(body[21:25], 'little')
            width, height = (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
            fmt = 'webp'
    if fmt is None:
        raise ArtworkError('Unsupported artwork raster')
    if min(width, height) <= 0 or max(width, height) > MAX_DIMENSION or width * height > MAX_PIXELS:
        raise ArtworkError('Artwork dimensions exceed limit')
    return fmt, width, height


def decoder_limits():
    resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_CPU, (3, 3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (RGB_BYTES, RGB_BYTES))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def decode(body, end_at, directory=None):
    fmt, _, _ = raster_header(body)
    executable = shutil.which('magick') or shutil.which('convert')
    if not executable:
        raise ArtworkError('Artwork needs ImageMagick')
    temporary = tempfile.TemporaryDirectory(prefix='nts-artwork-') if directory is None else contextlib.nullcontext(directory)
    with temporary as folder:
        source = Path(folder) / 'input.bin'
        output = Path(folder) / 'output.rgb'
        source.write_bytes(body)
        command = [executable, '-limit', 'thread', '1', '-limit', 'memory', '32MiB',
                   '-limit', 'map', '0', '-limit', 'disk', '0', '-limit', 'time', '3',
                   '-limit', 'width', str(MAX_DIMENSION), '-limit', 'height', str(MAX_DIMENSION),
                   fmt + ':' + str(source) + '[0]', '-strip', '-resize', f'{EDGE}x{EDGE}^',
                   '-gravity', 'center', '-extent', f'{EDGE}x{EDGE}', '-alpha', 'remove',
                   '-alpha', 'off', '-colorspace', 'sRGB', '-depth', '8', 'rgb:' + str(output)]
        process = None
        try:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=False,
                                       preexec_fn=decoder_limits,
                                       env=dict(os.environ, MAGICK_THREAD_LIMIT='1', MAGICK_TEMPORARY_PATH=folder))
            remaining = end_at - time.monotonic()
            if remaining <= 0:
                raise ArtworkError('Artwork deadline exceeded')
            try:
                code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                raise ArtworkError('Artwork deadline exceeded') from None
            if code != 0 or not output.exists() or output.stat().st_size != RGB_BYTES:
                raise ArtworkError('Artwork decode failed')
            pixels = output.read_bytes()
        finally:
            if process is not None:
                if process.poll() is None:
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                process.wait(timeout=.5)
    # Construct a minimal, uncompressed raster ourselves. No downloaded image
    # metadata, original codec or remote URL reaches Qt's image/network stack.
    ppm = f'P6\n{EDGE} {EDGE}\n255\n'.encode('ascii') + pixels
    uri = 'data:image/x-portable-pixmap;base64,' + base64.b64encode(ppm).decode('ascii')
    if len(uri) > MAX_URI:
        raise ArtworkError('Artwork output exceeds limit')
    return uri


def cancelled(signum, frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise ArtworkError('Artwork cancelled')


def supervised(command, timeout=TOTAL_SECONDS):
    """Hard wall deadline outside DNS/TLS/decoder code; cap before GUI IPC."""
    end_at = time.monotonic() + timeout
    process = None
    stopped = False
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, start_new_session=True, bufsize=0)
        os.set_blocking(process.stdout.fileno(), False)
        result = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = end_at - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise ArtworkError('Artwork deadline exceeded')
                part = os.read(process.stdout.fileno(), min(65536, 600201 - len(result)))
                if not part:
                    break
                if len(result) + len(part) > 600200:
                    raise ArtworkError('Artwork output exceeds limit')
                result.extend(part)
        # EOF from our worker occurs at exit. Stop the entire group before
        # reaping its PID, so descendants cannot retain files or pipe writers.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stopped = True
        if process.wait(timeout=.5) != 0:
            raise ArtworkError('Artwork worker failed')
        payload = json.loads(result)
        uri = payload.get('uri', '')
        prefix = 'data:image/x-portable-pixmap;base64,'
        if not payload.get('ok') or not isinstance(uri, str) or len(uri) > MAX_URI or not uri.startswith(prefix):
            raise ArtworkError('Artwork worker failed')
        # Independently validate the normalized output, even if the decoder
        # worker crashes or emits a malformed protocol reply.
        ppm = base64.b64decode(uri[len(prefix):], validate=True)
        header = f'P6\n{EDGE} {EDGE}\n255\n'.encode('ascii')
        if len(ppm) != len(header) + RGB_BYTES or not ppm.startswith(header):
            raise ArtworkError('Artwork output exceeds limit')
        return uri
    finally:
        if process is not None:
            if not stopped:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.stdout.close()
            process.wait(timeout=.5)


def main():
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    # Children inherit the hard limit; leave the decoder its stated 256 MiB
    # budget rather than imposing a lower limit it cannot raise in preexec.
    resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    result = {'ok': False}
    try:
        if len(sys.argv) == 4 and sys.argv[1] == '--worker':
            with deadline(TOTAL_SECONDS) as end_at:
                result = {'ok': True, 'uri': decode(fetch(validate_url(sys.argv[2]), end_at), end_at, sys.argv[3])}
        elif len(sys.argv) == 2:
            url = validate_url(sys.argv[1])
            # The supervisor owns temp files, so killing a stuck worker group
            # on deadline/cancellation still releases its download/decode data.
            with tempfile.TemporaryDirectory(prefix='nts-artwork-') as directory:
                uri = supervised([sys.executable, str(Path(__file__).resolve()), '--worker', url, directory])
                result = {'ok': True, 'uri': uri}
        else:
            raise ArtworkError('Invalid artwork request')
    except (ArtworkError, OSError, ValueError, MemoryError, http.client.HTTPException):
        result = {'ok': False}
    sys.stdout.write(json.dumps(result, separators=(',', ':')) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())

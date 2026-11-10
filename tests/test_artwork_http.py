"""Real chunked/slow HTTP transfers mapped to allowed URLs without external traffic."""
import contextlib
import http.server
import importlib.util
from pathlib import Path
import threading
import time
import unittest
import urllib.parse
import urllib.request

spec = importlib.util.spec_from_file_location('artwork_http', Path(__file__).parents[1] / 'scripts/artwork.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self):
        try:
            if self.path == '/foreign':
                self.send_response(302)
                self.send_header('Location', 'https://evil.invalid/image')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            if self.path in ('/relative', '/loop'):
                self.send_response(302)
                self.send_header('Location', '/small' if self.path == '/relative' else '/loop')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            self.send_response(200)
            if self.path == '/known-big':
                self.send_header('Content-Length', str(artwork.MAX_ENCODED + 1))
                self.end_headers()
                return
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            if self.path == '/small':
                chunks = [b'a', b'bc', b'def']
            elif self.path == '/chunked-big':
                chunks = [b'x' * 65536] * 32
            else:
                chunks = [b'x'] * 1000
            for chunk in chunks:
                if self.server.stopping.is_set():
                    break
                self.wfile.write(('%x\r\n' % len(chunk)).encode() + chunk + b'\r\n')
                self.wfile.flush()
                if self.path == '/slow':
                    time.sleep(.02)
            self.wfile.write(b'0\r\n\r\n')
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


class MappedOpener:
    def __init__(self, port):
        self.port = port
        self.calls = []
        self.opener = urllib.request.build_opener(artwork.NoRedirect(), urllib.request.ProxyHandler({}))
    def open(self, request, timeout):
        self.calls.append(request.full_url)
        path = urllib.parse.urlsplit(request.full_url).path
        target = 'http://127.0.0.1:%s%s' % (self.port, path)
        return self.opener.open(target, timeout=timeout)


class ArtworkHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.daemon_threads = True
        cls.server.stopping = threading.Event()
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
    @classmethod
    def tearDownClass(cls):
        cls.server.stopping.set()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(1)
    def fetch(self, path, seconds=2):
        self.opener = MappedOpener(self.server.server_port)
        with artwork.deadline(seconds) as end_at:
            return artwork.fetch('https://media.ntslive.co.uk' + path, end_at, self.opener)
    def test_small_chunked_response_and_allowed_relative_redirect(self):
        self.assertEqual(self.fetch('/small'), b'abcdef')
        self.assertEqual(self.fetch('/relative'), b'abcdef')
        self.assertEqual(len(self.opener.calls), 2)
    def test_known_and_unknown_length_oversize_responses(self):
        for path in ['/known-big', '/chunked-big']:
            with self.assertRaisesRegex(artwork.ArtworkError, 'byte limit'):
                self.fetch(path)
    def test_slow_continuously_supplied_response_has_absolute_deadline(self):
        start = time.monotonic()
        with self.assertRaisesRegex(artwork.ArtworkError, 'deadline'):
            self.fetch('/slow', .25)
        self.assertLess(time.monotonic() - start, 1.5)
    def test_foreign_redirect_is_rejected_before_request(self):
        with self.assertRaisesRegex(artwork.ArtworkError, 'Invalid artwork URL'):
            self.fetch('/foreign')
        self.assertEqual(len(self.opener.calls), 1)
    def test_redirect_loop_is_bounded(self):
        with self.assertRaisesRegex(artwork.ArtworkError, 'redirect limit'):
            self.fetch('/loop')
        self.assertEqual(len(self.opener.calls), 4)

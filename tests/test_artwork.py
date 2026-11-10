import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

spec = importlib.util.spec_from_file_location('nts_artwork', Path(__file__).parents[1] / 'scripts/artwork.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)


def png(width=3, height=2, depth=8):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    header = struct.pack('>IIBBBBB', width, height, depth, 2, 0, 0, 0)
    pixels = (b'\0' + b'\xff\0\0' * min(width, 3)) * min(height, 2)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


class ArtworkTests(unittest.TestCase):
    def test_origin_and_redirect_url_boundary(self):
        for url in ['https://media.ntslive.co.uk/a.jpg', 'https://nts.live/a.png', 'https://media.ntslive.net/a.webp']:
            self.assertEqual(artwork.validate_url(url), url)
        for url in ['http://media.ntslive.co.uk/a', 'https://evil.test/a', 'https://media.ntslive.co.uk.evil.test/a',
                    'https://user:pass@nts.live/a', 'https://nts.live:8443/a', 'file:///tmp/a', 'https://nts.live/a\nheader']:
            with self.assertRaises(artwork.ArtworkError):
                artwork.validate_url(url)

    def test_dimensions_and_raster_format_checked_before_decoder(self):
        self.assertEqual(artwork.raster_header(png()), ('png', 3, 2))
        for raw in [png(4097, 1), png(4096, 4096), png(depth=16), b'<svg/>', b'%PDF-1.7', b'GIF89a']:
            with patch.object(artwork.subprocess, 'Popen') as start:
                with self.assertRaises(artwork.ArtworkError):
                    artwork.decode(raw, time.monotonic() + 2)
                start.assert_not_called()

    @unittest.skipUnless(shutil.which('magick') or shutil.which('convert'), 'ImageMagick is required for decode tests')
    def test_png_jpeg_webp_normalize_to_fixed_plain_raster(self):
        exe = shutil.which('magick') or shutil.which('convert')
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.png'
            source.write_bytes(png())
            for fmt in ['png', 'jpeg', 'webp']:
                path = Path(folder) / ('image.' + fmt)
                subprocess.run([exe, str(source), '-depth', '8', fmt + ':' + str(path)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                body = path.read_bytes()
                self.assertEqual(artwork.raster_header(body)[0], fmt)
                uri = artwork.decode(body, time.monotonic() + 3)
                self.assertLessEqual(len(uri), artwork.MAX_URI)
                raw = base64.b64decode(uri.split(',', 1)[1], validate=True)
                header = b'P6\n384 384\n255\n'
                self.assertTrue(raw.startswith(header))
                self.assertEqual(len(raw), len(header) + artwork.RGB_BYTES)
                self.assertGreater(raw[len(header)], 200)

    def test_hard_supervisor_deadline_and_output_limit(self):
        for code, timeout in [('import time; time.sleep(60)', .25),
                              ('import os,time\nwhile True:\n os.write(1,b"x"); time.sleep(.01)', .25),
                              ('import os\nwhile True: os.write(1,b"x"*65536)', 2)]:
            start = time.monotonic()
            with self.assertRaises(artwork.ArtworkError):
                artwork.supervised([sys.executable, '-c', code], timeout=timeout)
            self.assertLess(time.monotonic() - start, 2.5)

    @unittest.skipUnless(shutil.which('magick') or shutil.which('convert'), 'ImageMagick required')
    def test_worker_cli_limits_allow_real_decoder(self):
        with tempfile.TemporaryDirectory() as folder:
            code = ("import runpy,sys; m=runpy.run_path(sys.argv[1]); "
                    "body=bytes.fromhex(sys.argv[3]); m['main'].__globals__['fetch']=lambda *args: body; "
                    "sys.argv=['artwork.py','--worker','https://nts.live/a',sys.argv[2]]; m['main']()")
            uri = artwork.supervised([sys.executable, '-c', code, str(Path(artwork.__file__).resolve()),
                                      folder, png().hex()], timeout=4)
            self.assertTrue(uri.startswith('data:image/x-portable-pixmap;base64,'))

    def test_supervisor_accepts_only_fixed_normalized_raster(self):
        code = "import base64,json; raw=b'P6\\n384 384\\n255\\n'+b'\\xff\\x00\\x00'*(384*384); print(json.dumps({'ok':True,'uri':'data:image/x-portable-pixmap;base64,'+base64.b64encode(raw).decode()}))"
        uri = artwork.supervised([sys.executable, '-c', code], timeout=2)
        self.assertTrue(uri.startswith('data:image/x-portable-pixmap;base64,'))
        self.assertLess(len(uri), 600000)

    def test_supervisor_rejects_invalid_normalized_dimensions(self):
        uri = 'data:image/x-portable-pixmap;base64,' + base64.b64encode(b'P6\n99999 99999\n255\n').decode()
        code = 'import json; print(json.dumps(%r))' % {'ok': True, 'uri': uri}
        with self.assertRaises(artwork.ArtworkError):
            artwork.supervised([sys.executable, '-c', code], timeout=2)

    def test_decoder_timeout_kills_process_and_uses_bounded_output_file(self):
        with tempfile.TemporaryDirectory() as folder:
            fake = Path(folder) / 'magick'
            fake.write_text('#!' + sys.executable + '\nimport time\ntime.sleep(60)\n')
            fake.chmod(0o755)
            with patch.object(artwork.shutil, 'which', return_value=str(fake)):
                with self.assertRaisesRegex(artwork.ArtworkError, 'deadline'):
                    artwork.decode(png(), time.monotonic() + .25)
            fake.write_text('#!' + sys.executable + '\nimport sys\n'
                            'open(sys.argv[-1].split(":",1)[1],"wb").write(b"x"*1000000)\n')
            with patch.object(artwork.shutil, 'which', return_value=str(fake)):
                with self.assertRaisesRegex(artwork.ArtworkError, 'decode failed'):
                    artwork.decode(png(), time.monotonic() + 2)

    def test_supervisor_temporary_files_cleaned_on_failure(self):
        locations = []
        def fail(command):
            folder = Path(command[-1])
            locations.append(folder)
            (folder / 'input.bin').write_bytes(b'partial')
            raise artwork.ArtworkError('timeout')
        out = io.StringIO()
        # Avoid applying CLI address-space limits to the whole unittest process.
        with patch.object(artwork.resource, 'setrlimit'), patch.object(artwork.signal, 'signal'), patch.object(artwork, 'supervised', side_effect=fail), \
             patch.object(sys, 'argv', ['artwork.py', 'https://nts.live/image']), contextlib.redirect_stdout(out):
            artwork.main()
        self.assertEqual(json.loads(out.getvalue()), {'ok': False})
        self.assertFalse(locations[0].exists())

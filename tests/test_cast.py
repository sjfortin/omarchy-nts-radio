import contextlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace, ModuleType
import sys
import tempfile
import unittest
from unittest.mock import patch


def load_script(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / 'scripts' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The bridge tests run without a Chromecast or the optional dependency.
modules = {}
for name in ['pychromecast', 'pychromecast.controllers', 'pychromecast.controllers.media', 'pychromecast.controllers.receiver']:
    modules[name] = ModuleType(name)
modules['pychromecast.controllers.media'].MediaStatusListener = type('MediaStatusListener', (), {})
modules['pychromecast.controllers.receiver'].CastStatusListener = type('CastStatusListener', (), {})
with patch.dict(sys.modules, modules):
    cast_module = load_script('nts_cast_test', 'cast.py')
library_io = load_script('nts_library_test', 'library_io.py')


class CastTests(unittest.TestCase):
    def make_cast(self):
        self.calls = []
        status = SimpleNamespace(content_id='https://cdn.test/audio', media_custom_data={
            'plugin': 'sjfortin.nts-radio', 'session': {'mode': 'live', 'channel': 2}},
            player_state='PLAYING', adjusted_current_time=123, duration=3600, idle_reason=None)
        return SimpleNamespace(
            media_controller=SimpleNamespace(status=status, play_media=lambda *a, **kw: self.calls.append((a, kw)),
                block_until_active=lambda **kw: self.fail('play must not block the command reader')),
            status=SimpleNamespace(volume_level=0.5))

    def test_play_is_nonblocking_and_marks_recoverable_session(self):
        bridge = cast_module.Bridge()
        bridge.cast = self.make_cast()
        bridge.play('https://cdn.test/audio', session={'mode': 'archive', 'episode': {'showAlias': 'show', 'episodeAlias': 'a'}})
        self.assertEqual(len(self.calls), 1)
        custom = self.calls[0][1]['media_info']['customData']
        self.assertEqual(custom['plugin'], 'sjfortin.nts-radio')
        self.assertEqual(custom['session']['mode'], 'archive')

    def test_status_reports_identity_position_and_finish_reason(self):
        bridge = cast_module.Bridge()
        bridge.cast = self.make_cast()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            bridge._emit_status()
        message = json.loads(out.getvalue())
        self.assertEqual(message['session']['channel'], 2)
        self.assertEqual(message['position'], 123)
        self.assertEqual(message['state'], 'PLAYING')

    def test_unrelated_custom_data_is_not_forwarded_as_plugin_session(self):
        bridge = cast_module.Bridge()
        bridge.cast = self.make_cast()
        bridge.cast.media_controller.status.media_custom_data = {'plugin': 'another-app', 'session': {'mode': 'live'}}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            bridge._emit_status()
        self.assertIsNone(json.loads(out.getvalue())['session'])

    def test_superseded_connection_is_disconnected(self):
        bridge = cast_module.Bridge()
        bridge.connect_generation = 1
        disconnected = []
        candidate = SimpleNamespace(
            wait=lambda **kw: setattr(bridge, 'connect_generation', 2),
            disconnect=lambda **kw: disconnected.append(True))
        bridge.devices['speaker'] = candidate
        bridge._connect_now('speaker', 1)
        self.assertIsNone(bridge.cast)
        self.assertEqual(disconnected, [True])


class BackupTests(unittest.TestCase):
    def test_size_bound_and_valid_text(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'backup.json'
            path.write_text('{"version": 2}')
            self.assertEqual(library_io.read_backup(str(path)), '{"version": 2}')
            path.write_bytes(b' ' * 4_000_001)
            with self.assertRaises(ValueError):
                library_io.read_backup(str(path))

    def test_rejects_relative_path(self):
        with self.assertRaises(ValueError):
            library_io.read_backup('backup.json')


if __name__ == '__main__':
    unittest.main()

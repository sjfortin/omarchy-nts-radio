import contextlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace, ModuleType
import sys
import tempfile
import threading
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


class ContractCast:
    """The dependency's exact wait/disconnect/join signatures, no **kwargs."""
    def __init__(self, uuid='speaker', *, fail_wait=False, auto_stop=True, hook=None):
        self.cast_info = SimpleNamespace(uuid=uuid, friendly_name=uuid, model_name='test', host='127.0.0.1', port=8009)
        self.socket_client = SimpleNamespace(alive=False, stop=threading.Event(), is_alive=lambda: self.socket_client.alive)
        self.status = None
        self.media_controller = SimpleNamespace(register_status_listener=lambda listener: None, update_status=lambda: None)
        self.fail_wait = fail_wait
        self.auto_stop = auto_stop
        self.hook = hook
        self.disconnect_calls = []
        self.wait_calls = []
        self.join_calls = []

    def wait(self, timeout=None):
        self.wait_calls.append(timeout)
        self.socket_client.alive = True
        if self.hook:
            self.hook()
        if self.fail_wait:
            raise TimeoutError('wait')

    def disconnect(self, timeout=None):
        self.disconnect_calls.append(timeout)
        self.socket_client.stop.set()
        if self.auto_stop:
            self.socket_client.alive = False
        if self.socket_client.alive:
            raise TimeoutError('join')

    def join(self, timeout=None):
        self.join_calls.append(timeout)
        if self.socket_client.alive:
            raise TimeoutError('join')

    def register_status_listener(self, listener):
        pass


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
        candidate = ContractCast(hook=lambda: setattr(bridge, 'connect_generation', 2))
        bridge.devices['speaker'] = candidate.cast_info
        with patch.object(cast_module.pychromecast, 'get_chromecast_from_cast_info', lambda info, zconf, tries, timeout, retry_wait: candidate, create=True):
            bridge._connect_now('speaker', 1)
        self.assertIsNone(bridge.cast)
        self.assertEqual(candidate.disconnect_calls, [0])
        self.assertTrue(candidate.socket_client.stop.is_set())

    def test_wait_failure_is_retained_and_blocks_new_socket_workers(self):
        bridge = cast_module.Bridge()
        bridge.cleanup_wait = 0
        first = ContractCast('first', fail_wait=True, auto_stop=False)
        second = ContractCast('second')
        bridge.devices = {'first': first.cast_info, 'second': second.cast_info}
        created = []
        def construct(info, zconf, tries, timeout, retry_wait):
            created.append(info.uuid)
            return first if info.uuid == 'first' else second
        with patch.object(cast_module.pychromecast, 'get_chromecast_from_cast_info', construct, create=True), patch.object(cast_module, 'emit'):
            bridge._connect_now('first', 0)
            self.assertEqual(first.disconnect_calls, [0])
            self.assertTrue(first.socket_client.stop.is_set())
            self.assertEqual(bridge.retiring, [first])
            self.assertIsNone(bridge.connecting_cast)
            for _ in range(2000):
                bridge._connect_now('second', 0)
            self.assertEqual(created, ['first'])
            self.assertEqual(len(bridge.retiring), 1)
            self.assertEqual(second.wait_calls, [])
            first.socket_client.alive = False
            bridge._connect_now('second', 0)
            self.assertEqual(created, ['first', 'second'])
            self.assertEqual(bridge.retiring, [])
            self.assertIs(bridge.cast, second)
            bridge.shutdown()
            self.assertTrue(second.socket_client.stop.is_set())

    def test_replacement_waits_for_old_dependency_worker_to_end(self):
        bridge = cast_module.Bridge()
        bridge.cleanup_wait = 0
        old = ContractCast('old', auto_stop=False)
        old.socket_client.alive = True
        new = ContractCast('new')
        bridge.cast = old
        bridge.devices['new'] = new.cast_info
        with patch.object(cast_module.pychromecast, 'get_chromecast_from_cast_info', lambda info, zconf, tries, timeout, retry_wait: new, create=True), patch.object(cast_module, 'emit'):
            bridge._connect_now('new', 0)
            self.assertEqual(old.disconnect_calls, [0])
            self.assertEqual(new.wait_calls, [])
            self.assertEqual(bridge.retiring, [old])
            old.socket_client.alive = False
            bridge._connect_now('new', 0)
            self.assertEqual(new.wait_calls, [12])
            self.assertIs(bridge.cast, new)
            bridge.shutdown()

    def test_discovery_retains_metadata_without_creating_socket_clients(self):
        bridge = cast_module.Bridge()
        info = ContractCast('metadata').cast_info
        browser = SimpleNamespace(zc=None)
        discovery = SimpleNamespace(discover_chromecasts=lambda timeout, max_devices: ([info], browser), stop_discovery=lambda browser: None)
        with patch.object(cast_module.pychromecast, 'discovery', discovery, create=True), patch.object(cast_module.pychromecast, 'get_chromecast_from_cast_info', create=True) as constructor, patch.object(cast_module, 'emit'):
            bridge._discover_now(6)
            self.assertIs(bridge.devices['metadata'], info)
            constructor.assert_not_called()
            bridge.shutdown()

    def test_shutdown_stops_and_retains_connecting_candidate(self):
        bridge = cast_module.Bridge()
        candidate = ContractCast(auto_stop=False)
        candidate.socket_client.alive = True
        bridge.connecting_cast = candidate
        bridge.shutdown()
        self.assertEqual(candidate.disconnect_calls, [0])
        self.assertTrue(candidate.socket_client.stop.is_set())
        self.assertEqual(bridge.retiring, [candidate])
        self.assertFalse(bridge.connect('another'))
        candidate.socket_client.alive = False
        self.assertTrue(bridge._reap_retired())


class WorkerAdmissionTests(unittest.TestCase):
    def test_burst_keeps_one_discovery_and_one_latest_connection(self):
        bridge = cast_module.Bridge()
        started, release, connected = threading.Event(), threading.Event(), threading.Event()
        calls = []
        def slow_discover(timeout):
            calls.append(('discover', timeout))
            started.set()
            release.wait(2)
        def connect(uuid, generation):
            calls.append(('connect', uuid))
            connected.set()
        bridge._discover_now = slow_discover
        bridge._connect_now = connect
        try:
            self.assertTrue(bridge.discover())
            self.assertTrue(started.wait(1))
            worker = bridge.worker
            for i in range(2000):
                self.assertFalse(bridge.discover())
                self.assertTrue(bridge.connect('speaker-' + str(i)))
            self.assertIs(bridge.worker, worker)
            self.assertEqual(bridge.pending_connect[0], 'speaker-1999')
            self.assertEqual(len(calls), 1)
            release.set()
            self.assertTrue(connected.wait(1))
            self.assertEqual(calls, [('discover', 6.0), ('connect', 'speaker-1999')])
        finally:
            release.set()
            bridge.shutdown()
            bridge.worker.join(1)
            self.assertFalse(bridge.worker.is_alive())

    def test_active_connection_repeats_coalesce_and_shutdown_clears_pending(self):
        bridge = cast_module.Bridge()
        started, release = threading.Event(), threading.Event()
        calls = []
        def slow_connect(uuid, generation):
            calls.append(uuid)
            started.set()
            release.wait(2)
        bridge._connect_now = slow_connect
        try:
            self.assertTrue(bridge.connect('first'))
            self.assertTrue(started.wait(1))
            generation = bridge.connect_generation
            for i in range(2000):
                self.assertTrue(bridge.connect('first'))
            self.assertEqual(bridge.connect_generation, generation)
            self.assertIsNone(bridge.pending_connect)
            for i in range(2000):
                bridge.connect('next-' + str(i))
            self.assertEqual(bridge.pending_connect[0], 'next-1999')
            bridge.shutdown()
            self.assertIsNone(bridge.pending_connect)
            self.assertFalse(bridge.connect('late'))
            self.assertFalse(bridge.discover())
        finally:
            release.set()
            bridge.shutdown()
            bridge.worker.join(1)
        self.assertEqual(calls, ['first'])

    def test_late_discovery_browser_is_closed_after_shutdown(self):
        bridge = cast_module.Bridge()
        started, release = threading.Event(), threading.Event()
        browser = object()
        stopped = []
        def discover(**kwargs):
            started.set()
            release.wait(2)
            return [], browser
        with patch.object(cast_module.pychromecast, 'discovery', SimpleNamespace(discover_chromecasts=discover, stop_discovery=stopped.append), create=True):
            try:
                bridge.discover()
                self.assertTrue(started.wait(1))
                bridge.shutdown()
                release.set()
                bridge.worker.join(1)
                self.assertIsNone(bridge.browser)
                self.assertEqual(stopped, [browser])
            finally:
                release.set()
                bridge.shutdown()
                bridge.worker.join(1)


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

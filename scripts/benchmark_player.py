#!/usr/bin/env python3
"""Offline mpv lifecycle benchmark. Uses silent WAV audio and --ao=null.

Measures playback-restart IPC events, not audible/network latency. Never uses
or changes the plugin's own player, IPC socket, library or cast session.
"""
import json
import math
from pathlib import Path
import socket
import statistics
import subprocess
import tempfile
import time
import wave


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def start_player(folder, audio):
    path = str(folder / 'mpv.sock')
    before = time.monotonic()
    process = subprocess.Popen(['mpv', '--no-config', '--no-video', '--ao=null',
        '--ytdl=no', '--idle=yes', '--no-terminal', '--input-ipc-server=' + path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    client = socket.socket(socket.AF_UNIX)
    deadline = time.monotonic() + 5
    while True:
        try:
            client.connect(path)
            break
        except OSError:
            if time.monotonic() >= deadline:
                process.kill()
                process.wait()
                raise TimeoutError('mpv IPC did not appear')
            time.sleep(0.002)
    client.settimeout(5)
    file = client.makefile('r', encoding='utf-8')
    # Start loading only after IPC connects so both measurements use the
    # same playback-restart event, even on a very fast machine.
    client.sendall((json.dumps({'command': ['loadfile', str(audio), 'replace']}) + '\n').encode())
    while True:
        message = json.loads(file.readline())
        if message.get('event') == 'playback-restart':
            break
    return process, client, file, (time.monotonic() - before) * 1000


def main():
    cold, reuse = [], []
    with tempfile.TemporaryDirectory(prefix='nts-mpv-benchmark-') as temporary:
        folder = Path(temporary)
        audio = folder / 'silent.wav'
        with wave.open(str(audio), 'wb') as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(8000)
            out.writeframes(b'\0\0' * 8000 * 20)
        for _ in range(12):
            process, client, file, elapsed = start_player(folder, audio)
            try:
                cold.append(elapsed)
                # Drain startup through a roundtrip before measuring replacement.
                client.sendall(b'{"command":["get_property","time-pos"],"request_id":99}\n')
                while json.loads(file.readline()).get('request_id') != 99:
                    pass
                before = time.monotonic()
                client.sendall((json.dumps({'command': ['loadfile', str(audio), 'replace', -1, {'start': '1'}]}) + '\n').encode())
                while json.loads(file.readline()).get('event') != 'playback-restart':
                    pass
                reuse.append((time.monotonic() - before) * 1000)
            finally:
                client.close()
                file.close()
                process.terminate()
                process.wait(timeout=5)
                (folder / 'mpv.sock').unlink(missing_ok=True)
    result = {'trials': len(cold), 'conditions': 'offline silent WAV, ao=null, monotonic clock; software readiness, not audible/network latency'}
    for key, values in [('cold_start', cold), ('warm_replace', reuse)]:
        result[key] = {'median_ms': round(statistics.median(values), 1), 'p95_ms': round(percentile(values, .95), 1)}
    result['old_restart_floor_ms'] = 400
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Chromecast bridge for the Omarchy NTS Radio plugin.

Speaks newline-delimited JSON on stdin/stdout, the same shape as the mpv IPC
the local player uses, so the QML side drives both backends the same way.

Casting is genuinely different from local playback: the device fetches the NTS
stream itself, so nothing is decoded or re-encoded here and the laptop can
sleep without interrupting the radio. This process exists only to start, stop,
and report on that session.

Commands in (one JSON object per line):
    {"cmd": "discover", "timeout": 6}
    {"cmd": "connect",  "uuid": "..."}
    {"cmd": "play",     "url": "...", "title": "...", "artwork": "...", "subtitle": "...",
                        "live": true, "start": 0, "type": "audio/mpeg"}
    {"cmd": "seek",     "position": 0}
    {"cmd": "pause"}
    {"cmd": "resume"}
    {"cmd": "stop"}
    {"cmd": "volume",   "level": 0-100}
    {"cmd": "quit"}

Events out:
    {"event": "ready",       "backend": "pychromecast", "version": "..."}
    {"event": "unavailable", "reason": "..."}
    {"event": "devices",     "devices": [{"uuid","name","model","host","port"}]}
    {"event": "connected",   "uuid": "...", "name": "...", "volume": 0-100}
    {"event": "status",      "state": "...", "volume": 0-100, "connected": bool,
                             "content": "..."}
    {"event": "error",       "message": "..."}
"""

import json
import sys
import threading
import traceback

# Nothing below the import guard may run if pychromecast is missing: the plugin
# treats that as "casting unavailable" and keeps working locally.
try:
    import pychromecast
    from pychromecast.controllers.media import MediaStatusListener
    from pychromecast.controllers.receiver import CastStatusListener
except Exception as exc:  # ImportError, but a broken install can raise others
    sys.stdout.write(json.dumps({
        "event": "unavailable",
        "reason": "python-pychromecast is not installed ({})".format(exc.__class__.__name__),
    }) + "\n")
    sys.stdout.flush()
    sys.exit(0)


_write_lock = threading.Lock()


def emit(**payload):
    """One JSON object per line, flushed, serialized across threads.

    pychromecast delivers status from its own threads, so unsynchronized
    writes would interleave and produce lines the QML parser cannot read.
    """
    line = json.dumps(payload, separators=(",", ":"))
    with _write_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def _seconds(value):
    """A finite, sane number of seconds, or 0."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    if number != number or number < 0 or number > 86400:
        return 0.0
    return round(number, 1)


def volume_to_percent(level):
    try:
        return max(0, min(100, int(round(float(level) * 100))))
    except (TypeError, ValueError):
        return 0


def clean(value, limit=200):
    """Metadata is shown on the device and in the Home app; keep it sane."""
    if value is None:
        return ""
    text = str(value).replace("\n", " ").replace("\r", " ").strip()
    return text[:limit]


class Bridge(CastStatusListener, MediaStatusListener):
    def __init__(self):
        self.browser = None
        self.devices = {}          # uuid -> Chromecast
        self.cast = None
        self.lock = threading.Lock()

    # ------------------------------------------------------------ discovery

    def discover(self, timeout=6):
        # get_chromecasts blocks for the full timeout, so it runs off the
        # command loop and reports back when it has an answer.
        threading.Thread(target=self._discover_now, args=(timeout,), daemon=True).start()

    def _discover_now(self, timeout=6):
        """Refresh the device table. Safe to call from any worker thread."""
        def run():
            try:
                casts, browser = pychromecast.get_chromecasts(timeout=float(timeout))
            except Exception as exc:
                emit(event="error", message="discovery failed: {}".format(exc))
                return

            with self.lock:
                # Keep the connected device's object; replacing it would drop
                # the live session out from under an active cast.
                connected_uuid = str(self.cast.cast_info.uuid) if self.cast else None
                found = {}
                for cast in casts:
                    uuid = str(cast.cast_info.uuid)
                    if connected_uuid and uuid == connected_uuid:
                        found[uuid] = self.cast
                        continue
                    found[uuid] = cast
                self.devices = found
                if self.browser is not None:
                    try:
                        pychromecast.discovery.stop_discovery(self.browser)
                    except Exception:
                        pass
                self.browser = browser

            emit(event="devices", devices=[
                {
                    "uuid": str(c.cast_info.uuid),
                    "name": clean(c.cast_info.friendly_name, 80),
                    "model": clean(c.cast_info.model_name, 80),
                    "host": str(c.cast_info.host),
                    "port": int(c.cast_info.port),
                }
                for c in self.devices.values()
            ])

        run()

    # ----------------------------------------------------------- connection

    def connect(self, uuid):
        threading.Thread(target=self._connect_now, args=(str(uuid),), daemon=True).start()

    def _connect_now(self, uuid):
        with self.lock:
            cast = self.devices.get(uuid)

        if cast is None:
            # A remembered device, or one named over IPC, before this process
            # has ever looked at the network. Look, then connect — erroring
            # here would just make the caller do the same thing by hand.
            self._discover_now(6)
            with self.lock:
                cast = self.devices.get(uuid)

        if cast is None:
            emit(event="error", message="that device is not on this network")
            return

        if self.cast is not None and str(self.cast.cast_info.uuid) == uuid:
            return  # already connected

        self.disconnect()
        try:
            cast.wait(timeout=12)
        except Exception as exc:
            emit(event="error", message="could not reach device: {}".format(exc))
            return

        self.cast = cast
        cast.register_status_listener(self)
        cast.media_controller.register_status_listener(self)
        emit(
            event="connected",
            uuid=str(cast.cast_info.uuid),
            name=clean(cast.cast_info.friendly_name, 80),
            volume=volume_to_percent(cast.status.volume_level if cast.status else 0),
        )

        # Report what the device is doing right now rather than waiting for it
        # to change. A session we started before this process existed — the
        # shell restarted, the plugin reloaded — is still ours to adopt, and
        # the content id is how the caller tells it apart from someone else's
        # music.
        try:
            cast.media_controller.update_status()
        except Exception:
            pass
        self._emit_status()

    def disconnect(self):
        cast, self.cast = self.cast, None
        if cast is None:
            return
        try:
            cast.disconnect(blocking=False)
        except Exception:
            pass

    # ------------------------------------------------------------- playback

    def play(self, url, title="", subtitle="", artwork="", live=True, start=0,
             content_type="audio/mpeg"):
        if self.cast is None:
            emit(event="error", message="not connected to a device")
            return
        if not str(url).startswith("https://"):
            emit(event="error", message="refusing a non-https stream url")
            return

        metadata = {"metadataType": 3, "title": clean(title), "artist": clean(subtitle)}

        # LIVE tells the device there is no seekable timeline, which is what
        # stops it presenting a scrub bar for a radio stream. An archived show
        # is the opposite: a finite recording the device can seek within, so it
        # is sent as BUFFERED and may start part-way in.
        stream_type = "LIVE" if live else "BUFFERED"
        try:
            offset = max(0.0, float(start))
        except (TypeError, ValueError):
            offset = 0.0

        # NTS's live relay is MP3; archived episodes resolve to whatever the
        # host published — MP3 on SoundCloud, MP4/AAC on Mixcloud — so the type
        # comes from the resolver rather than being assumed.
        wanted_type = clean(content_type, 40) or "audio/mpeg"
        if not wanted_type.startswith("audio/"):
            wanted_type = "audio/mpeg"

        try:
            self.cast.media_controller.play_media(
                str(url),
                content_type=wanted_type,
                title=clean(title) or "NTS Radio",
                thumb=clean(artwork, 600) or None,
                stream_type=stream_type,
                current_time=offset if (not live and offset > 0) else None,
                metadata=metadata,
            )
            self.cast.media_controller.block_until_active(timeout=12)
        except Exception as exc:
            emit(event="error", message="could not start playback: {}".format(exc))

    def seek(self, position):
        """Jump to a point in an archived show.

        Meaningless for live radio, where the device has no timeline; the
        caller only sends this for BUFFERED media.
        """
        if self.cast is None:
            return
        try:
            self.cast.media_controller.seek(max(0.0, float(position)))
        except Exception as exc:
            emit(event="error", message="could not seek: {}".format(exc))

    def pause(self):
        """Hold an archived show where it is.

        Only sent for BUFFERED media. Pausing live radio is meaningless — there
        is nothing to come back to — so the caller stops it instead.
        """
        if self.cast is None:
            return
        try:
            self.cast.media_controller.pause()
        except Exception as exc:
            emit(event="error", message="could not pause: {}".format(exc))

    def resume(self):
        if self.cast is None:
            return
        try:
            self.cast.media_controller.play()
        except Exception as exc:
            emit(event="error", message="could not resume: {}".format(exc))

    def stop(self):
        """Stop the stream and hand the device back.

        Stopping the media alone leaves our receiver app loaded, so the
        speaker keeps showing as busy in the Home app long after the radio
        went quiet. Quitting the app returns it to whatever it was doing
        before, which is what a user means by "stop casting".
        """
        if self.cast is None:
            return
        try:
            self.cast.media_controller.stop()
        except Exception as exc:
            emit(event="error", message="could not stop playback: {}".format(exc))
        try:
            self.cast.quit_app()
        except Exception:
            # Best effort: the stream is already stopped, which is the part
            # the user asked for.
            pass

    def set_volume(self, level):
        if self.cast is None:
            return
        try:
            self.cast.set_volume(max(0.0, min(1.0, float(level) / 100.0)))
        except Exception as exc:
            emit(event="error", message="could not set volume: {}".format(exc))

    # ------------------------------------------------- pychromecast callbacks

    def _emit_status(self, state=None, volume_level=None):
        cast = self.cast
        content = ""
        position = 0.0
        duration = 0.0
        if cast is not None:
            status = cast.media_controller.status
            content = clean(getattr(status, "content_id", ""), 400)
            # Both are None for live radio and for a session that has not
            # loaded yet; 0 reads the same to the UI as "no timeline".
            position = _seconds(getattr(status, "adjusted_current_time", None)
                                or getattr(status, "current_time", None))
            duration = _seconds(getattr(status, "duration", None))
        if volume_level is None:
            volume_level = cast.status.volume_level if cast and cast.status else 0
        emit(
            event="status",
            state=clean(state if state is not None else self._player_state(), 20),
            volume=volume_to_percent(volume_level),
            connected=cast is not None,
            content=content,
            position=position,
            duration=duration,
        )

    def new_cast_status(self, status):
        self._emit_status(volume_level=getattr(status, "volume_level", 0))

    def new_media_status(self, status):
        self._emit_status(state=getattr(status, "player_state", "UNKNOWN"))

    def load_media_failed(self, item, error_code):
        emit(event="error", message="device rejected the stream (code {})".format(error_code))

    def _player_state(self):
        if self.cast is None:
            return "IDLE"
        status = self.cast.media_controller.status
        return clean(getattr(status, "player_state", "IDLE"), 20)

    # ------------------------------------------------------------- shutdown

    def shutdown(self):
        self.disconnect()
        if self.browser is not None:
            try:
                pychromecast.discovery.stop_discovery(self.browser)
            except Exception:
                pass
            self.browser = None


def main():
    bridge = Bridge()
    emit(event="ready", backend="pychromecast",
         version=getattr(pychromecast, "__version__", "unknown"))

    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                emit(event="error", message="malformed command")
                continue
            if not isinstance(message, dict):
                continue

            command = message.get("cmd")
            try:
                if command == "discover":
                    bridge.discover(message.get("timeout", 6))
                elif command == "connect":
                    bridge.connect(message.get("uuid", ""))
                elif command == "play":
                    bridge.play(
                        message.get("url", ""),
                        message.get("title", ""),
                        message.get("subtitle", ""),
                        message.get("artwork", ""),
                        message.get("live", True),
                        message.get("start", 0),
                        message.get("type", "audio/mpeg"),
                    )
                elif command == "seek":
                    bridge.seek(message.get("position", 0))
                elif command == "pause":
                    bridge.pause()
                elif command == "resume":
                    bridge.resume()
                elif command == "stop":
                    bridge.stop()
                elif command == "volume":
                    bridge.set_volume(message.get("level", 50))
                elif command == "quit":
                    break
                else:
                    emit(event="error", message="unknown command")
            except Exception:
                # One bad command must never take the bridge down; the QML side
                # would see the process vanish and report casting as broken.
                emit(event="error", message=traceback.format_exc(limit=1).strip())
    except KeyboardInterrupt:
        pass
    finally:
        bridge.shutdown()


if __name__ == "__main__":
    main()

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
    except (TypeError, ValueError, OverflowError):
        return 0


def clean(value, limit=200):
    """Metadata is shown on the device and in the Home app; keep it sane."""
    if value is None:
        return ""
    text = str(value).replace("\n", " ").replace("\r", " ").strip()
    return text[:limit]


def clean_session(value):
    """Only bounded public episode identity is carried over the cast protocol."""
    if not isinstance(value, dict):
        return None
    if value.get("mode") == "live" and type(value.get("channel")) is int and value["channel"] in (1, 2):
        return {"mode": "live", "channel": value["channel"]}
    episode = value.get("episode")
    if value.get("mode") != "archive" or not isinstance(episode, dict):
        return None
    fields = {"showAlias": 200, "episodeAlias": 200, "name": 500, "showName": 500,
              "audioUrl": 2000, "artworkSmall": 600, "artworkLarge": 600, "dateLabel": 40}
    item = {key: clean(episode.get(key), limit) for key, limit in fields.items()}
    if not item["showAlias"] or not item["episodeAlias"]:
        return None
    return {"mode": "archive", "episode": item}


class Bridge(CastStatusListener, MediaStatusListener):
    def __init__(self):
        self.browser = None
        self.devices = {}          # uuid -> Chromecast
        self.cast = None
        self.lock = threading.Lock()
        self.work_ready = threading.Condition(self.lock)
        self.worker = None
        self.closing = False
        self.discovery_pending = False
        self.discovery_running = False
        self.discovery_timeout = 6.0
        self.pending_connect = None
        self.active_connect = None
        self.connect_generation = 0

    # ------------------------------------------------------------ discovery

    def _ensure_worker_locked(self):
        if self.worker is None:
            self.worker = threading.Thread(target=self._work_loop, daemon=True)
            self.worker.start()
        self.work_ready.notify()

    def _work_loop(self):
        # Exactly one lazy worker; admission retains one discovery flag and
        # one replaceable connection tuple, never a thread/future per command.
        while True:
            with self.work_ready:
                while not self.closing and not self.discovery_pending and self.pending_connect is None:
                    self.work_ready.wait()
                if self.closing:
                    return
                if self.discovery_pending:
                    self.discovery_pending = False
                    self.discovery_running = True
                    kind, value = 'discover', self.discovery_timeout
                else:
                    kind, value = 'connect', self.pending_connect
                    self.pending_connect = None
                    self.active_connect = value[0]
            try:
                if kind == 'discover':
                    self._discover_now(value)
                else:
                    self._connect_now(*value)
            except Exception:
                emit(event='error', message='cast worker request failed')
            finally:
                with self.work_ready:
                    if kind == 'discover':
                        self.discovery_running = False
                    else:
                        self.active_connect = None

    def discover(self, timeout=6):
        try:
            seconds = max(1.0, min(6.0, float(timeout)))
        except (TypeError, ValueError):
            seconds = 6.0
        with self.work_ready:
            if self.closing or self.discovery_pending or self.discovery_running:
                return False
            self.discovery_pending = True
            self.discovery_timeout = seconds
            self._ensure_worker_locked()
            return True

    def _discover_now(self, timeout=6):
        """Refresh the device table. Safe to call from any worker thread."""
        try:
            casts, browser = pychromecast.get_chromecasts(timeout=float(timeout))
        except Exception as exc:
            emit(event="error", message="discovery failed: {}".format(exc))
            return

        with self.lock:
            closing = self.closing
            old_browser = self.browser
            if not closing:
                connected = self.cast
                connected_uuid = str(connected.cast_info.uuid) if connected else None
                found = {}
                for cast in casts[:64]:
                    uuid = str(cast.cast_info.uuid)
                    found[uuid] = connected if connected_uuid == uuid else cast
                self.devices = found
                self.browser = browser
                listing = list(found.values())
        # Network/browser cleanup must not hold the admission lock: the stdin
        # thread can still coalesce work while a slow browser shuts down.
        if closing:
            try:
                pychromecast.discovery.stop_discovery(browser)
            except Exception:
                pass
            return
        if old_browser is not None:
            try:
                pychromecast.discovery.stop_discovery(old_browser)
            except Exception:
                pass

        emit(event="devices", devices=[
            {
                "uuid": str(c.cast_info.uuid),
                "name": clean(c.cast_info.friendly_name, 80),
                "model": clean(c.cast_info.model_name, 80),
                "host": str(c.cast_info.host),
                "port": int(c.cast_info.port),
            }
            for c in listing[:64]
        ])

    # ----------------------------------------------------------- connection

    def connect(self, uuid):
        target = clean(uuid, 80)
        if not target:
            return False
        with self.work_ready:
            if self.closing:
                return False
            if self.pending_connect and self.pending_connect[0] == target:
                return True
            # Coalesce a repeated active target, but preserve a later explicit
            # selection after an intervening different pending target.
            if self.active_connect == target and self.pending_connect is None:
                return True
            self.connect_generation += 1
            self.pending_connect = (target, self.connect_generation)
            self._ensure_worker_locked()
            return True

    def _connect_now(self, uuid, generation):
        with self.lock:
            cast = self.devices.get(uuid)

        if cast is None:
            # A remembered device, or one named over IPC, before this process
            # has ever looked at the network. Look, then connect — erroring
            # here would just make the caller do the same thing by hand.
            self._discover_now(6)
            with self.lock:
                cast = self.devices.get(uuid)

        with self.lock:
            if self.closing or generation != self.connect_generation:
                return

        if cast is None:
            emit(event="error", message="that device is not on this network")
            return

        current = self.cast
        if current is not None and str(current.cast_info.uuid) == uuid:
            emit(event="connected", uuid=uuid,
                 name=clean(current.cast_info.friendly_name, 80),
                 volume=volume_to_percent(current.status.volume_level if current.status else 0))
            current.media_controller.update_status()
            return

        self.disconnect()
        try:
            cast.wait(timeout=12)
        except Exception as exc:
            emit(event="error", message="could not reach device: {}".format(exc))
            return

        with self.lock:
            stale = self.closing or generation != self.connect_generation
            if stale:
                if self.devices.get(uuid) is cast:
                    self.devices.pop(uuid, None)
            else:
                self.cast = cast
        if stale:
            cast.disconnect(blocking=False)
            return
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
        # Wait for the actual media response; the initial empty status can
        # incorrectly identify a still-playing session as IDLE.

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
             content_type="audio/mpeg", session=None):
        # Snapshot rather than read self.cast repeatedly: commands arrive on the
        # stdin thread while connect and disconnect run on workers, so the
        # attribute can be replaced between two reads of it. Every method below
        # takes the same precaution.
        cast = self.cast
        if cast is None:
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
            cast.media_controller.play_media(
                str(url),
                content_type=wanted_type,
                title=clean(title) or "NTS Radio",
                thumb=clean(artwork, 600) or None,
                stream_type=stream_type,
                current_time=offset if (not live and offset > 0) else None,
                metadata=metadata,
                media_info={"customData": {"plugin": "sjfortin.nts-radio", "session": clean_session(session) or {}}},
            )
            # Status listeners confirm activation. Waiting here blocks the
            # stdin loop and delays stop/pause and replacement selections.
        except Exception as exc:
            emit(event="error", message="could not start playback: {}".format(exc))

    def seek(self, position):
        """Jump to a point in an archived show.

        Meaningless for live radio, where the device has no timeline; the
        caller only sends this for BUFFERED media.
        """
        cast = self.cast
        if cast is None:
            return
        try:
            cast.media_controller.seek(max(0.0, float(position)))
        except Exception as exc:
            emit(event="error", message="could not seek: {}".format(exc))

    def pause(self):
        """Hold an archived show where it is.

        Only sent for BUFFERED media. Pausing live radio is meaningless — there
        is nothing to come back to — so the caller stops it instead.
        """
        cast = self.cast
        if cast is None:
            return
        try:
            cast.media_controller.pause()
        except Exception as exc:
            emit(event="error", message="could not pause: {}".format(exc))

    def resume(self):
        cast = self.cast
        if cast is None:
            return
        try:
            cast.media_controller.play()
        except Exception as exc:
            emit(event="error", message="could not resume: {}".format(exc))

    def stop(self):
        """Stop the stream and hand the device back.

        Stopping the media alone leaves our receiver app loaded, so the
        speaker keeps showing as busy in the Home app long after the radio
        went quiet. Quitting the app returns it to whatever it was doing
        before, which is what a user means by "stop casting".
        """
        cast = self.cast
        if cast is None:
            return
        try:
            cast.media_controller.stop()
        except Exception as exc:
            emit(event="error", message="could not stop playback: {}".format(exc))
        try:
            cast.quit_app()
        except Exception:
            # Best effort: the stream is already stopped, which is the part
            # the user asked for.
            pass

    def set_volume(self, level):
        cast = self.cast
        if cast is None:
            return
        try:
            cast.set_volume(max(0.0, min(1.0, float(level) / 100.0)))
        except Exception as exc:
            emit(event="error", message="could not set volume: {}".format(exc))

    # ------------------------------------------------- pychromecast callbacks

    def _emit_status(self, state=None, volume_level=None):
        cast = self.cast
        content = ""
        position = 0.0
        duration = 0.0
        session = None
        if cast is not None:
            status = cast.media_controller.status
            custom = getattr(status, "media_custom_data", {}) or {}
            if isinstance(custom, dict) and custom.get("plugin") == "sjfortin.nts-radio":
                value = custom.get("session")
                session = clean_session(value)
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
            session=session,
            idleReason=clean(getattr(cast.media_controller.status, "idle_reason", ""), 30) if cast else "",
        )

    def new_cast_status(self, status):
        self._emit_status(volume_level=getattr(status, "volume_level", 0))

    def new_media_status(self, status):
        self._emit_status()

    def load_media_failed(self, item, error_code):
        emit(event="error", message="device rejected the stream (code {})".format(error_code))

    def _player_state(self):
        cast = self.cast
        if cast is None:
            return "IDLE"
        status = cast.media_controller.status
        return clean(getattr(status, "player_state", "IDLE"), 20)

    # ------------------------------------------------------------- shutdown

    def shutdown(self):
        with self.work_ready:
            self.closing = True
            self.discovery_pending = False
            self.pending_connect = None
            self.connect_generation += 1
            self.work_ready.notify_all()
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
                    if not bridge.discover(message.get("timeout", 6)):
                        emit(event="busy", command="discover")
                elif command == "connect":
                    if not bridge.connect(message.get("uuid", "")):
                        emit(event="busy", command="connect")
                elif command == "play":
                    bridge.play(
                        message.get("url", ""),
                        message.get("title", ""),
                        message.get("subtitle", ""),
                        message.get("artwork", ""),
                        message.get("live", True),
                        message.get("start", 0),
                        message.get("type", "audio/mpeg"),
                        message.get("session"),
                    )
                elif command == "status":
                    cast = bridge.cast
                    if cast is not None:
                        cast.media_controller.update_status()
                        if not message.get("fresh"):
                            bridge._emit_status()
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
                #
                # The detail goes to stderr, which is for whoever is debugging
                # this. What reaches the UI is a sentence: a QML error line is
                # not a place for a Python traceback, and the file paths in one
                # are nobody's business but this machine's.
                traceback.print_exc(file=sys.stderr)
                emit(event="error", message="the cast helper could not do that")
    except KeyboardInterrupt:
        pass
    finally:
        bridge.shutdown()


if __name__ == "__main__":
    main()

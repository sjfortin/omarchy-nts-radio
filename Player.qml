import QtQuick
import Quickshell
import Quickshell.Io

import "Model.js" as Model

// Local playback of one NTS stream, backed by a single mpv child process.
//
// mpv is the whole audio backend: it resolves the geo relay redirect, decodes,
// and hands PCM to PipeWire the way any other desktop audio client does. There
// is no browser and no second daemon. While it runs we talk to it over its
// JSON IPC socket, which is what makes live volume, an honest paused state,
// and media-key round-tripping possible.
//
// MPRIS comes from mpv's own mpris script when the distro ships one. It is
// strictly optional: everything here works with `mprisScript` empty, the only
// loss being media-key control.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // --------------------------------------------------------------- inputs

  property string streamUrl: ""

  // "live" or "archive". The two are genuinely different media and the
  // difference runs right through this file: a live stream has no end, no
  // position and no seek, and resuming it means rejoining the edge rather
  // than unpausing. An archived show is an ordinary finite recording that
  // pauses, seeks, and finishes. Keeping them apart here is what stops the
  // live reconnect logic from fighting a paused archive.
  property string mode: "live"
  readonly property bool isArchive: mode === "archive"

  // The SoundCloud/Mixcloud page URL for an archived episode. NTS does not
  // host episode audio, so mpv's ytdl hook resolves this at load time.
  property string archiveUrl: ""

  // Where to start an archive, in seconds. Used to resume a part-heard show,
  // and to reach a tracklist timestamp when the process is not up yet.
  property real startPositionSec: 0

  // Shown by MPRIS clients and media-key OSDs. Pushed live, so the OSD
  // follows the NTS schedule rather than the icy stream name.
  property string mediaTitle: ""
  property int volume: 70
  // Absolute path to mpv's mpris script, or "" when none was found.
  property string mprisScript: ""
  // Paused playback holds a socket open on the NTS relay for no reason.
  // After this long, drop the process; the UI still reads as paused and the
  // next play simply starts a new one.
  property int pausedShutdownSeconds: 300

  readonly property string socketPath: {
    var runtimeDir = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    var base = runtimeDir !== "" ? runtimeDir : "/tmp"
    return base + "/omarchy-nts-radio.mpv.sock"
  }

  // -------------------------------------------------------------- outputs

  // What the user asked for, which is not the same as what mpv is doing yet.
  property bool wanted: false
  property bool paused: false
  property bool connectedToStream: false
  property string lastError: ""

  readonly property bool processRunning: mpv.running
  readonly property bool ipcAvailable: ipcSocket !== null && ipcSocket.connected
  // Without IPC there is no core-idle to read, so a running unpaused process
  // is taken at its word.
  readonly property bool playing: mpv.running && !paused && (connectedToStream || ipcGaveUp)
  readonly property bool loading: wanted && !paused && !playing
  readonly property bool failed: lastError !== ""

  // Archive position and length, in seconds. Both stay 0 for live, where
  // neither means anything. Position is polled rather than observed: mpv
  // pushes a time-pos property-change on every internal tick, which is a
  // flood of IPC lines for a number the UI only redraws once a second.
  property real positionSec: 0
  property real durationSec: 0

  // The recording ran out. A live stream cannot raise this.
  signal finished()

  // ---------------------------------------------------------------- state

  // Set around a loadfile we issued ourselves, so the resulting property
  // churn is not mistaken for someone else driving the player.
  property bool rejoining: false
  property int connectAttempts: 0
  property int requestSerial: 0
  property bool ipcGaveUp: false
  property bool ipcInitialized: false
  // Set while applying a volume mpv itself reported, so the echo does not
  // bounce straight back at it.
  property bool applyingReportedVolume: false
  property int retryCount: 0
  // A stop we asked for on the way to starting a new one. Without this the
  // exit reads as a dropped stream and flashes an error the user never had.
  property bool restarting: false

  // -------------------------------------------------------------- control

  function play() {
    lastError = ""
    wanted = true
    if (!mpv.running) {
      startProcess()
      return
    }
    // An archived show is a recording: resuming means carrying on from where
    // it was paused, which is the one thing a live stream must never do.
    if (isArchive) {
      if (ipcAvailable) {
        send(["set_property", "pause", false])
        paused = false
      } else {
        // No IPC to unpause with. Restart from the remembered position.
        startPositionSec = positionSec
        restarting = true
        mpv.running = false
        restartAfterStop.restart()
      }
      return
    }
    // Already up. Whether it is paused or mid-reconnect, the correct move for
    // a live stream is to reload it: resuming a paused live stream would play
    // back however far behind the buffer had drifted.
    rejoinLive()
  }

  function pause() {
    if (!mpv.running) {
      wanted = false
      paused = true
      return
    }
    if (ipcAvailable) {
      send(["set_property", "pause", true])
      paused = true
      connectedToStream = false
    } else {
      // Without IPC there is no pause to ask for, so stop and remember that
      // the user's intent was "not playing right now".
      stop()
      paused = true
    }
    wanted = false
  }

  function toggle() {
    if (playing || loading) pause()
    else play()
  }

  function stop() {
    wanted = false
    restarting = false
    paused = false
    connectedToStream = false
    rejoining = false
    closeIpc()
    mpv.running = false
  }

  // Swap the stream under a running player without a stop/start flicker.
  function switchStream(url) {
    streamUrl = url
    if (!mpv.running) return
    if (wanted) rejoinLive()
    else stop()
  }

  // Move the player between media. Unlike switchStream — which swaps one live
  // channel for another under a running process — this always tears the
  // process down, because the mode decides the mpv command line: whether the
  // ytdl hook is loaded at all, and where playback starts.
  function loadSource(newMode, url, startSec) {
    var hadProcess = mpv.running
    if (hadProcess) {
      // A stop we are about to follow with a start. Without this the exit
      // reads as a dropped stream and flashes an error nobody had.
      restarting = true
      closeIpc()
      mpv.running = false
    }

    mode = newMode === "archive" ? "archive" : "live"
    if (isArchive) archiveUrl = String(url || "")
    else streamUrl = String(url || "")

    startPositionSec = Math.max(0, Number(startSec) || 0)
    positionSec = startPositionSec
    durationSec = 0
    paused = false
    connectedToStream = false
    rejoining = false
    retryCount = 0
    lastError = ""
    wanted = true

    if (hadProcess) restartAfterStop.restart()
    else startProcess()
  }

  // Jump to a point in an archived show — a tracklist timestamp, or a drag on
  // the progress bar. Live has nothing to seek to.
  function seekTo(seconds) {
    if (!isArchive) return
    var target = Math.max(0, Number(seconds) || 0)
    if (durationSec > 0) target = Math.min(target, Math.max(0, durationSec - 1))
    // Move the displayed position immediately. mpv confirms on the next poll,
    // but a scrub that waits a second to redraw feels broken.
    positionSec = target
    if (ipcAvailable) {
      send(["seek", target, "absolute"])
      if (paused) {
        send(["set_property", "pause", false])
        paused = false
        wanted = true
      }
      return
    }
    // No IPC: restart at the target, which lands in the same place.
    startPositionSec = target
    if (mpv.running) {
      restarting = true
      mpv.running = false
      restartAfterStop.restart()
    } else {
      startProcess()
    }
  }

  // onVolumeChanged is the single place a volume reaches mpv.
  function setVolume(value) {
    volume = Model.clampVolume(value)
  }

  function pushTitle() {
    if (ipcAvailable && mediaTitle !== "") send(["set_property", "force-media-title", mediaTitle])
  }

  // ------------------------------------------------------------- internals

  readonly property string activeUrl: isArchive ? archiveUrl : streamUrl

  function startProcess() {
    if (activeUrl === "") return
    restarting = false
    connectAttempts = 0
    ipcGaveUp = false
    ipcInitialized = false
    paused = false
    connectedToStream = false
    mpv.command = buildCommand()
    mpv.running = true
  }

  function buildCommand() {
    var args = [
      "mpv",
      // Ignore the user's mpv.conf entirely: this is an appliance, and a
      // stray `pause=yes` or video option in a personal config should not be
      // able to break the bar widget. It also means scripts are not
      // autoloaded, which is why mpris is passed explicitly below.
      "--no-config",
      "--no-video",
      "--audio-display=no",
      // Errors arrive on stdout; keep the terminal layer alive to get them,
      // but never let mpv try to read the shell's stdin.
      "--terminal=yes",
      "--no-input-terminal",
      "--quiet",
      "--msg-level=all=error",
      "--idle=no",
      "--keep-open=no",
      "--network-timeout=10",
      "--cache=yes",
      "--user-agent=omarchy-nts-radio",
      // No spaces: mpv's mpris script derives a D-Bus name from this, and a
      // space produces an invalid bus name and no MPRIS at all.
      "--audio-client-name=ntsradio",
      "--volume=" + Model.clampVolume(volume),
      "--input-ipc-server=" + socketPath
    ]

    if (isArchive) {
      // NTS publishes archived episodes to SoundCloud and Mixcloud rather
      // than hosting them, so the ytdl hook is what turns a page URL into
      // audio. This is the only place the plugin needs it.
      args.push("--ytdl=yes")
      args.push("--ytdl-format=bestaudio/best")
      // Two hours of AAC needs more room to seek around in than a live
      // stream's few seconds of drift.
      args.push("--demuxer-max-bytes=32MiB")
      args.push("--demuxer-max-back-bytes=32MiB")
      if (startPositionSec > 0) args.push("--start=" + Math.floor(startPositionSec))
    } else {
      // A direct icecast URL never needs yt-dlp, and skipping the hook makes
      // a failure surface in a second rather than after a scrape attempt.
      args.push("--ytdl=no")
      args.push("--demuxer-max-bytes=4MiB")
    }

    if (mediaTitle !== "") args.push("--force-media-title=" + mediaTitle)
    if (mprisScript !== "") args.push("--script=" + mprisScript)
    args.push(activeUrl)
    return args
  }

  readonly property var ipcSocket: ipcLoader.item

  // mpv's own wording is accurate but long, and it puts a full stream URL in
  // a narrow panel. Keep the shape of the message, lose the URL.
  function friendlyError(text) {
    var message = String(text || "")
    // Decoder complaints about individual frames are routine on an icecast
    // stream — a corrupt frame at the join, a glitch mid-broadcast — and mpv
    // recovers from them. They are not something to put in front of a user.
    // If the stream really is broken, the process exit says so.
    if (/^\[(ffmpeg|lavf|ad|vd)/.test(message)) return ""

    // The ytdl hook is only in play for archives, and its failures are the
    // ones a user can act on: a missing yt-dlp, or a private/removed upload.
    if (/ytdl_hook|youtube-dl|yt-dlp/i.test(message)) {
      if (/not found|no such file|could not be found/i.test(message))
        return "yt-dlp is not installed — sudo pacman -S yt-dlp"
      return "This episode could not be loaded"
    }

    var unavailable = isArchive ? "Episode unavailable" : "Stream unavailable"
    if (/^Failed to open /.test(message)) return unavailable
    if (/Failed to recognize file format/.test(message)) return unavailable
    if (/^Could not open/.test(message)) return unavailable
    return message
  }

  function send(command) {
    if (!ipcAvailable) return
    requestSerial = (requestSerial + 1) % 100000
    ipcSocket.write(Model.ipcCommand(command, requestSerial))
    ipcSocket.flush()
  }

  function closeIpc() {
    ipcConnect.stop()
    ipcInitialized = false
    ipcLoader.active = false
  }

  // Runs one turn after the socket reports connected: the Loader has not
  // assigned `item` yet while the connection signal is being emitted, so
  // anything sent from inside that signal would be dropped on the floor.
  function onIpcReady() {
    if (!ipcAvailable || ipcInitialized) return
    ipcInitialized = true
    ipcConnect.stop()
    observeProperties()
    send(["set_property", "volume", Model.clampVolume(volume)])
    pushTitle()
  }

  function rejoinLive() {
    // Only live has an edge to rejoin. Reaching here in archive mode would
    // restart the recording from the top, which is the worst possible reading
    // of "resume".
    if (isArchive || streamUrl === "") return
    rejoining = true
    connectedToStream = false
    paused = false
    wanted = true
    if (ipcAvailable) {
      send(["set_property", "pause", false])
      send(["loadfile", streamUrl, "replace"])
      rejoinGuard.restart()
    } else {
      // No IPC to steer with — a clean restart gets to the same place.
      restarting = true
      mpv.running = false
      restartAfterStop.restart()
    }
  }

  // Fixed request ids for the position poll, well clear of the rotating
  // serial used by ordinary commands, so a reply can be identified by id
  // alone rather than by keeping a table of outstanding requests.
  readonly property int positionRequestId: 900001
  readonly property int durationRequestId: 900002

  function observeProperties() {
    send(["observe_property", 1, "pause"])
    send(["observe_property", 2, "core-idle"])
    send(["observe_property", 3, "volume"])
    send(["observe_property", 4, "idle-active"])
  }

  function pollPosition() {
    if (!ipcAvailable || !isArchive) return
    ipcSocket.write(Model.ipcCommand(["get_property", "time-pos"], positionRequestId))
    ipcSocket.write(Model.ipcCommand(["get_property", "duration"], durationRequestId))
    ipcSocket.flush()
  }

  function handleLine(line) {
    var message = Model.parseIpcLine(line)
    if (!message) return

    // A reply to one of the position polls above.
    if (message.request_id === positionRequestId || message.request_id === durationRequestId) {
      // mpv answers with error:"property unavailable" between files; that is
      // ordinary, not a failure, so it is dropped rather than reported.
      if (message.error !== "success") return
      var value = Number(message.data)
      if (!isFinite(value) || value < 0) return
      if (message.request_id === positionRequestId) positionSec = value
      else durationSec = value
      return
    }

    if (message.event === "file-loaded") {
      rejoining = false
      retryCount = 0
      lastError = ""
      // The --start= seek has been applied by now, so it must not be applied
      // again if this process is later restarted from a live position.
      startPositionSec = 0
      return
    }
    if (message.event === "end-file") {
      // Only an archive can legitimately end. `reason` distinguishes the
      // recording running out from an error or from our own loadfile.
      if (isArchive && String(message.reason || "") === "eof") {
        wanted = false
        connectedToStream = false
        positionSec = durationSec
        root.finished()
      }
      return
    }
    if (message.event !== "property-change") return

    if (message.name === "pause") {
      var isPaused = message.data === true
      if (isPaused === paused) return
      paused = isPaused
      if (isPaused) {
        connectedToStream = false
        wanted = false
      } else if (!rejoining) {
        // Someone outside this plugin resumed us — a media key, playerctl,
        // another MPRIS client. Rejoin the live edge rather than replaying
        // whatever was left in the buffer.
        rejoinLive()
      }
      return
    }

    if (message.name === "core-idle") {
      connectedToStream = message.data === false
      return
    }

    if (message.name === "volume") {
      var reported = Model.clampVolume(message.data)
      if (reported !== volume) {
        applyingReportedVolume = true
        volume = reported
        applyingReportedVolume = false
      }
      return
    }

    if (message.name === "idle-active" && message.data === true) {
      connectedToStream = false
    }
  }

  onMediaTitleChanged: pushTitle()
  onVolumeChanged: {
    if (applyingReportedVolume || !ipcAvailable) return
    send(["set_property", "volume", Model.clampVolume(volume)])
  }

  // Paused with the process still up: let it go after a while.
  onPausedChanged: {
    if (paused && mpv.running) pausedShutdown.restart()
    else pausedShutdown.stop()
  }

  Component.onDestruction: {
    closeIpc()
    mpv.running = false
  }

  // ------------------------------------------------------------ subprocess

  Process {
    id: mpv
    running: false

    // With --terminal=yes and --msg-level=all=error, anything mpv prints is
    // a real failure worth showing the user once.
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var text = root.friendlyError(Model.plainText(data, 160))
        if (text !== "") root.lastError = text
      }
    }

    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        // GLib chatter from the mpris script is noise, not a playback error.
        var text = String(data)
        if (text.indexOf("GLib") !== -1 || text.replace(/\s/g, "") === "") return
        var clean = root.friendlyError(Model.plainText(text, 160))
        if (clean !== "") root.lastError = clean
      }
    }

    onStarted: {
      root.connectAttempts = 0
      ipcConnect.restart()
    }

    onExited: function(exitCode, exitStatus) {
      root.closeIpc()
      root.connectedToStream = false
      root.ipcGaveUp = false
      if (root.restarting) {
        root.restarting = false
        return
      }
      if (root.paused) return
      if (!root.wanted) return

      // An archived show is finite, so a clean exit is the recording ending —
      // the one case where stopping is the correct outcome and retrying would
      // replay the whole two hours.
      if (root.isArchive) {
        if (exitCode === 0) {
          root.wanted = false
          root.positionSec = root.durationSec
          root.finished()
          return
        }
        // A genuine failure. Resume where it stopped rather than from the top.
        root.startPositionSec = root.positionSec
        if (root.lastError === "") root.lastError = "Episode unavailable"
        if (!retryAfterFailure.running) retryAfterFailure.restart()
        return
      }

      // Still wanted audio and mpv is gone. A live stream has no legitimate
      // end, so a clean exit here means the relay dropped the connection —
      // exactly the case a radio should reconnect from, not treat as "the
      // track finished". Reconnect on a backoff and keep the reason visible
      // while it tries.
      if (root.lastError === "")
        root.lastError = exitCode === 0 ? "Stream interrupted" : "Stream unavailable"
      if (!retryAfterFailure.running) retryAfterFailure.restart()
    }
  }

  // mpv creates its IPC socket a moment after exec, so the first connect
  // attempt usually loses the race — and a Quickshell Socket that has failed
  // once stays failed however many times `connected` is set again. Each
  // attempt therefore gets a brand new Socket, which is what makes the retry
  // actually retry. Verified against a socket that appears three seconds late.
  //
  // If the whole budget runs out, playback is unaffected: only live volume,
  // the honest paused state, and media-key round-tripping are lost.
  Timer {
    id: ipcConnect
    interval: 200
    repeat: true
    running: false
    onTriggered: {
      if (!mpv.running || root.ipcAvailable) {
        ipcConnect.stop()
        return
      }
      root.connectAttempts++
      if (root.connectAttempts > 40) {
        ipcConnect.stop()
        root.ipcGaveUp = true
        root.ipcInitialized = false
        ipcLoader.active = false
        return
      }
      root.ipcInitialized = false
      ipcLoader.active = false
      ipcLoader.active = true
    }
  }

  Loader {
    id: ipcLoader
    active: false
    onLoaded: if (item && item.connected) Qt.callLater(root.onIpcReady)

    sourceComponent: Socket {
      path: root.socketPath
      connected: true

      parser: SplitParser {
        splitMarker: "\n"
        onRead: function(data) { root.handleLine(data) }
      }

      onConnectionStateChanged: if (connected) Qt.callLater(root.onIpcReady)

      // Expected while mpv is still starting; the timer above builds a
      // replacement on the next tick.
      onError: function(error) {}
    }
  }

  // A loadfile that never reports back means the reload did not take.
  Timer {
    id: rejoinGuard
    interval: 8000
    onTriggered: {
      if (!root.rejoining) return
      root.rejoining = false
      if (root.wanted && !root.connectedToStream) {
        root.restarting = true
        mpv.running = false
        restartAfterStop.restart()
      }
    }
  }

  Timer {
    id: restartAfterStop
    interval: 400
    onTriggered: if (root.wanted) root.startProcess()
  }

  // 5s, 15s, 45s, then every 60s. Long enough that a laptop with the lid
  // shut overnight is not hammering a dead network, short enough that a
  // blip recovers on its own.
  Timer {
    id: retryAfterFailure
    interval: Math.min(60000, 5000 * Math.pow(3, Math.min(3, root.retryCount)))
    onTriggered: {
      if (!root.wanted || mpv.running) return
      root.retryCount++
      root.startProcess()
    }
  }

  Timer {
    id: pausedShutdown
    interval: Math.max(30, root.pausedShutdownSeconds) * 1000
    onTriggered: {
      if (!root.paused || !mpv.running) return
      // Dropping the process loses mpv's place in the recording, so hand the
      // position to the restart path before letting go of it. The user still
      // sees a paused archive; pressing play resumes where they left off.
      if (root.isArchive) root.startPositionSec = root.positionSec
      root.closeIpc()
      mpv.running = false
    }
  }

  // 1 Hz, and only while an archive is genuinely moving. Live has no position
  // to report and a paused recording is not going anywhere, so neither polls.
  Timer {
    id: positionPoll
    interval: 1000
    repeat: true
    running: root.isArchive && root.playing && root.ipcAvailable
    triggeredOnStart: true
    onTriggered: root.pollPosition()
  }
}

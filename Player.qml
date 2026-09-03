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

  // onVolumeChanged is the single place a volume reaches mpv.
  function setVolume(value) {
    volume = Model.clampVolume(value)
  }

  function pushTitle() {
    if (ipcAvailable && mediaTitle !== "") send(["set_property", "force-media-title", mediaTitle])
  }

  // ------------------------------------------------------------- internals

  function startProcess() {
    if (streamUrl === "") return
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
      // A direct icecast URL never needs yt-dlp, and skipping the hook makes
      // a failure surface in a second rather than after a scrape attempt.
      "--ytdl=no",
      "--keep-open=no",
      "--network-timeout=10",
      "--cache=yes",
      "--demuxer-max-bytes=4MiB",
      "--user-agent=omarchy-nts-radio",
      // No spaces: mpv's mpris script derives a D-Bus name from this, and a
      // space produces an invalid bus name and no MPRIS at all.
      "--audio-client-name=ntsradio",
      "--volume=" + Model.clampVolume(volume),
      "--input-ipc-server=" + socketPath
    ]
    if (mediaTitle !== "") args.push("--force-media-title=" + mediaTitle)
    if (mprisScript !== "") args.push("--script=" + mprisScript)
    args.push(streamUrl)
    return args
  }

  readonly property var ipcSocket: ipcLoader.item

  // mpv's own wording is accurate but long, and it puts a full stream URL in
  // a narrow panel. Keep the shape of the message, lose the URL.
  function friendlyError(text) {
    var message = String(text || "")
    if (/^Failed to open /.test(message)) return "Stream unavailable"
    if (/Failed to recognize file format/.test(message)) return "Stream unavailable"
    if (/^Could not open/.test(message)) return "Stream unavailable"
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
    if (streamUrl === "") return
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

  function observeProperties() {
    send(["observe_property", 1, "pause"])
    send(["observe_property", 2, "core-idle"])
    send(["observe_property", 3, "volume"])
    send(["observe_property", 4, "idle-active"])
  }

  function handleLine(line) {
    var message = Model.parseIpcLine(line)
    if (!message) return
    if (message.event === "file-loaded") {
      rejoining = false
      retryCount = 0
      lastError = ""
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
      if (root.wanted && exitCode !== 0) {
        // Died while we still wanted audio: the stream dropped or the
        // network went away. Reconnect on a backoff, the way a radio would,
        // and leave the last error on screen while it tries.
        if (root.lastError === "") root.lastError = "Stream unavailable"
        if (!retryAfterFailure.running) retryAfterFailure.restart()
      } else if (!root.paused) {
        root.wanted = false
      }
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
      root.closeIpc()
      mpv.running = false
    }
  }
}

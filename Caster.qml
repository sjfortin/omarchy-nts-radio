import QtQuick
import Quickshell.Io

import "Model.js" as Model

// Playback on a Chromecast-protocol device (Google Home, Nest, Chromecast
// Audio, and anything else speaking `_googlecast._tcp`).
//
// This is not "route the laptop's audio elsewhere" — the device fetches the
// NTS stream itself. Nothing is decoded or re-encoded here, and the laptop can
// sleep without interrupting the radio. What this object owns is the control
// session: discovery, starting and stopping, volume, and status.
//
// The work happens in scripts/cast.py, a child process speaking newline JSON,
// because the Chromecast protocol is protobuf-over-TLS and has no business
// being reimplemented inside a shell. If python-pychromecast is missing the
// helper says so on its first line and `available` stays false — casting then
// simply is not offered, and local playback is unaffected.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // --------------------------------------------------------------- inputs

  property string pluginDir: ""
  property string streamUrl: ""

  // Live radio or an archived show. A live stream is sent as LIVE so the
  // device shows no scrub bar for a timeline that does not exist; an archive
  // is a finite recording the device can seek within, and is sent as BUFFERED.
  // The URL for an archive is resolved on this machine first — see Resolver.qml
  // — because NTS points at a SoundCloud page, not at audio.
  property bool liveStream: true
  // Where an archive should start, in seconds. Ignored for live.
  property real startPositionSec: 0

  // What the device should decode this as. The live relay is MP3; an archive
  // is whatever its host published, which the resolver reports.
  property string mediaContentType: "audio/mpeg"
  property string mediaTitle: ""
  property string mediaSubtitle: ""
  property string artworkUrl: ""
  property int volume: 70

  // The bridge is only worth running while a UI is showing device choices or
  // a cast is actually in progress.
  property bool bridgeEnabled: false

  // -------------------------------------------------------------- outputs

  property bool bridgeReady: false
  // Whether the backend works at all, which is a different question from
  // whether the helper happens to be running right now. It stops cycling with
  // the process, so the panel does not flicker its output list every time the
  // bridge is reaped.
  property bool backendUsable: false
  property string unavailableReason: ""
  readonly property bool available: backendUsable && unavailableReason === ""

  property var devices: []
  property string targetUuid: ""
  property string targetName: ""
  property bool connected: false
  property string deviceState: "IDLE"
  property string lastError: ""
  property bool discovering: false

  // What the user asked for, as distinct from what the device is doing.
  property bool wanted: false

  // A live stream on a Chromecast dips into BUFFERING whenever it refills,
  // several times a minute. Treating every dip as "not playing" would leave
  // the UI saying Connecting while audio is plainly coming out of the
  // speaker, so a session that has once reached PLAYING stays playing until
  // it actually stops.
  property bool everPlayed: false
  // What the device says it is playing, used to tell our own stream from
  // someone else's music when adopting an existing session.
  property string deviceContent: ""

  // The device's own clock for an archived show. Both stay 0 on live radio,
  // which has no timeline to report.
  property real positionSec: 0
  property real durationSec: 0
  readonly property bool sessionLive: deviceState === "PLAYING"
    || (everPlayed && deviceState === "BUFFERING")
  readonly property bool playing: wanted && connected && sessionLive && !paused
  readonly property bool loading: wanted && !paused && !playing

  // ---------------------------------------------------------------- state

  property int pendingConnectAttempts: 0
  property bool applyingReportedVolume: false

  // -------------------------------------------------------------- control

  function send(payload) {
    if (!bridge.running) return
    bridge.write(JSON.stringify(payload) + "\n")
  }

  // Asking what is on the network is itself a reason for the bridge to exist,
  // so a discovery request keeps it alive whether or not a panel is open.
  property bool discoveryRequested: false
  property bool discoverWhenReady: false

  function discover() {
    discoveryRequested = true
    discoverTimeout.restart()
    if (!bridge.running) {
      // The lifecycle binding starts it; discovery goes out on `ready`.
      discoverWhenReady = true
      return
    }
    discovering = true
    send({ cmd: "discover", timeout: 6 })
  }

  function selectDevice(uuid, name) {
    targetUuid = String(uuid || "")
    targetName = String(name || "")
    connected = false
    if (targetUuid === "") return
    send({ cmd: "connect", uuid: targetUuid })
  }

  // Starting from cold chains through the bridge's own events:
  // wanted -> bridge starts -> ready -> discover -> devices -> connect ->
  // connected -> startStream. Each step is driven by what came back, so there
  // is no sleeping or polling anywhere in it.
  function play() {
    lastError = ""
    everPlayed = false
    paused = false
    playWhenConnected = true
    wanted = true
    if (!bridge.running) {
      discoverWhenReady = true
      return
    }
    if (!available) return
    if (!connected) {
      if (targetUuid !== "") send({ cmd: "connect", uuid: targetUuid })
      else discover()
      return
    }
    playWhenConnected = false
    startStream()
  }

  property bool playWhenConnected: false

  function startStream() {
    if (streamUrl === "") return
    positionSec = liveStream ? 0 : startPositionSec
    durationSec = 0
    send({
      cmd: "play",
      url: streamUrl,
      title: mediaTitle,
      subtitle: mediaSubtitle,
      artwork: artworkUrl,
      live: liveStream,
      start: liveStream ? 0 : Math.max(0, startPositionSec),
      type: liveStream ? "audio/mpeg" : mediaContentType
    })
  }

  // Jump to a point in an archived show. The device owns the timeline, so
  // unlike the local player there is nothing to restart when it has no IPC —
  // either the session is up and can seek, or there is nothing to seek.
  function seekTo(seconds) {
    if (liveStream || !connected) return
    var target = Math.max(0, Number(seconds) || 0)
    if (durationSec > 0) target = Math.min(target, Math.max(0, durationSec - 1))
    // Move the reported position immediately; the device confirms on its next
    // status, and a scrubber that waits for the network feels broken.
    positionSec = target
    seekSettling.restart()
    send({ cmd: "seek", position: target })
  }

  // How long to disregard the device's own position after asking it to move.
  // Round-trip plus the status already in flight; shorter than this and the
  // scrubber snaps back before the seek lands.
  Timer {
    id: seekSettling
    interval: 2500
  }

  // Point the caster at different media. Always a fresh load: the stream type
  // is decided at play_media time, so switching between live and an archive
  // cannot be done by swapping the URL alone.
  function loadSource(live, url, startSec) {
    liveStream = live === true
    streamUrl = String(url || "")
    startPositionSec = Math.max(0, Number(startSec) || 0)
    if (wanted && connected) startStream()
  }

  // Pause an archived show on the device, keeping its place. Live radio has
  // nothing to come back to, so the service stops that instead.
  function pause() {
    if (liveStream || !connected) return
    paused = true
    send({ cmd: "pause" })
  }

  function resume() {
    if (liveStream || !connected) return
    paused = false
    wanted = true
    send({ cmd: "resume" })
  }

  property bool paused: false

  function stop() {
    // Tell the device before dropping our own intent: clearing `wanted` can
    // take the bridge down with it, and a stop sent after that goes nowhere.
    if (bridge.running) send({ cmd: "stop" })
    playWhenConnected = false
    everPlayed = false
    wanted = false
    paused = false
    positionSec = 0
    durationSec = 0
  }

  function setVolume(value) {
    volume = Model.clampVolume(value)
  }

  onVolumeChanged: {
    if (applyingReportedVolume || !connected) return
    send({ cmd: "volume", level: Model.clampVolume(volume) })
  }

  // Reconnect to a remembered device purely to find out what it is doing.
  // A cast survives this shell — that is the point of it — so after a restart
  // or a plugin reload the radio may well still be playing, and the right
  // thing is to pick the session back up rather than leave it orphaned with
  // no way to stop it.
  function adoptExistingSession() {
    if (targetUuid === "") return
    adopting = true
    adoptTimeout.restart()
    discover()
  }

  property bool adopting: false

  // Switching channel while casting reloads the stream on the device, which
  // is the only way to change what it is fetching.
  function switchStream(url) {
    streamUrl = url
    if (wanted && connected) startStream()
  }

  // ------------------------------------------------------------- lifecycle

  // Every reason the helper might need to be running, in one place.
  readonly property bool shouldRun: bridgeEnabled || wanted || discoveryRequested || adopting

  onShouldRunChanged: {
    if (shouldRun) {
      shutdownDelay.stop()
      bridge.running = true
    } else {
      shutdownDelay.restart()
    }
  }

  // A momentary dip — a widget being rebuilt, a panel reopening — should not
  // cycle a Python process.
  Timer {
    id: shutdownDelay
    interval: 3000
    onTriggered: if (!root.shouldRun) root.shutdown()
  }

  function shutdown() {
    if (!bridge.running) return
    send({ cmd: "quit" })
    quitGrace.restart()
  }

  Component.onDestruction: {
    if (bridge.running) {
      send({ cmd: "stop" })
      send({ cmd: "quit" })
    }
    bridge.running = false
  }

  // --------------------------------------------------------------- events

  function handleLine(line) {
    var message = Model.parseIpcLine(line)
    if (!message || !message.event) return

    switch (message.event) {
    case "ready":
      bridgeReady = true
      backendUsable = true
      unavailableReason = ""
      if (discoverWhenReady || targetUuid !== "" || wanted) {
        discoverWhenReady = false
        discover()
      }
      return

    case "unavailable":
      bridgeReady = true
      backendUsable = false
      unavailableReason = Model.plainText(message.reason, 120) || "casting unavailable"
      wanted = false
      return

    case "devices":
      discovering = false
      discoveryRequested = false
      discoverTimeout.stop()
      devices = Model.castDevices(message.devices)
      // Only reconnect to a remembered device when audio is actually headed
      // there. Opening the panel should list what is on the network, not open
      // a session with someone's speaker.
      if ((wanted || adopting) && targetUuid !== "" && !connected
        && Model.hasDevice(devices, targetUuid))
        send({ cmd: "connect", uuid: targetUuid })
      else if (wanted && targetUuid === "" && devices.length === 1)
        // Exactly one device on the network and no remembered choice: using
        // it is what the user meant by "cast".
        selectDevice(devices[0].uuid, devices[0].name)
      return

    case "connected":
      connected = true
      targetUuid = Model.plainText(message.uuid, 80)
      targetName = Model.plainText(message.name, 80)
      applyingReportedVolume = true
      volume = Model.clampVolume(message.volume)
      applyingReportedVolume = false
      if (playWhenConnected) {
        playWhenConnected = false
        startStream()
      }
      return

    case "status":
      connected = message.connected === true
      // UNKNOWN shows up between connecting and the first media session; it
      // is not a playback state and would flap the UI if treated as one.
      var reported = Model.plainText(message.state, 20)
      if (reported !== "" && reported !== "UNKNOWN") deviceState = reported
      deviceContent = Model.plainText(message.content, 400)

      // The device's clock for an archived show. Only trusted while a seek is
      // not in flight — the status that crosses a seek on the wire still
      // carries the old position, and letting it through makes the scrubber
      // jump back for a moment before settling.
      if (!liveStream && !seekSettling.running) {
        var reportedPosition = Number(message.position)
        if (isFinite(reportedPosition) && reportedPosition >= 0)
          positionSec = reportedPosition
      }
      var reportedDuration = Number(message.duration)
      if (isFinite(reportedDuration) && reportedDuration > 0) durationSec = reportedDuration

      // Adoption: the device may already be playing one of our streams,
      // started by a shell that is no longer around. Take ownership so the
      // panel shows it playing and can stop it.
      //
      // Only what the device actually reported counts here. A freshly
      // connected session answers UNKNOWN for a moment before the real state
      // arrives, and treating that as "not playing" would abandon a live
      // session a second before it identified itself.
      if (adopting) {
        if (reported === "PLAYING") {
          adopting = false
          adoptTimeout.stop()
          if (Model.isOwnStream(deviceContent)) {
            wanted = true
            everPlayed = true
          }
        } else if (reported === "IDLE" || reported === "PAUSED") {
          adopting = false
          adoptTimeout.stop()
        }
      }
      if (deviceState === "PLAYING") {
        everPlayed = true
        // Audio is coming out of the speaker; whatever went wrong on the way
        // here is no longer worth showing.
        lastError = ""
      }
      else if (deviceState === "IDLE" || deviceState === "PAUSED") everPlayed = false
      var reported = Model.clampVolume(message.volume)
      if (reported !== volume) {
        applyingReportedVolume = true
        volume = reported
        applyingReportedVolume = false
      }
      return

    case "error":
      lastError = Model.plainText(message.message, 140)
      return
    }
  }

  // ------------------------------------------------------------ subprocess

  Process {
    id: bridge
    running: false
    stdinEnabled: true
    command: ["python3", root.pluginDir + "/scripts/cast.py"]

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.handleLine(data) }
    }

    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var text = Model.plainText(data, 140)
        if (text !== "") root.lastError = text
      }
    }

    onExited: function(exitCode, exitStatus) {
      root.bridgeReady = false
      root.connected = false
      root.discovering = false
      root.discoveryRequested = false
      root.everPlayed = false
      root.adopting = false
      root.deviceContent = ""
      root.deviceState = "IDLE"
      // The device list is kept: it is the last thing we actually saw on the
      // network, and dropping it would empty the panel's output section every
      // time the idle helper is reaped.
      if (root.wanted) {
        // The device keeps playing when the controller goes away, but we can
        // no longer stop it or read its state, so say so rather than pretend.
        root.wanted = false
        if (root.lastError === "") root.lastError = "Lost the connection to the device"
      }
    }
  }

  // Discovery that never answers should not leave a spinner up forever.
  Timer {
    id: discoverTimeout
    interval: 9000
    onTriggered: {
      root.discoveryRequested = false
      if (!root.discovering) return
      root.discovering = false
      if (root.devices.length === 0 && root.lastError === "")
        root.lastError = "No cast devices found on this network"
    }
  }

  // A device that never says what it is doing should not hold the bridge up.
  Timer {
    id: adoptTimeout
    interval: 12000
    onTriggered: root.adopting = false
  }

  // Give the helper a moment to close its device connection cleanly before
  // the process is torn down.
  Timer {
    id: quitGrace
    interval: 1200
    onTriggered: bridge.running = false
  }
}

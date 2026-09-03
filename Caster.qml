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
  readonly property bool sessionLive: deviceState === "PLAYING"
    || (everPlayed && deviceState === "BUFFERING")
  readonly property bool playing: wanted && connected && sessionLive
  readonly property bool loading: wanted && !playing

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
    send({
      cmd: "play",
      url: streamUrl,
      title: mediaTitle,
      subtitle: mediaSubtitle,
      artwork: artworkUrl
    })
  }

  function stop() {
    // Tell the device before dropping our own intent: clearing `wanted` can
    // take the bridge down with it, and a stop sent after that goes nowhere.
    if (bridge.running) send({ cmd: "stop" })
    playWhenConnected = false
    everPlayed = false
    wanted = false
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

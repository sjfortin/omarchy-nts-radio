import QtQuick
import Quickshell
import Quickshell.Io

import "Model.js" as Model

// Shared state for every NTS bar widget instance (one per monitor) and the
// panel each of them can open. Playback and the schedule live here so that
// closing a panel — or moving the widget — never interrupts the stream.
//
// The shell creates exactly one of these per enabled plugin and destroys it
// when the plugin is disabled, which is also when mpv goes away.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // Injected by the shell.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "sjfortin.nts-radio"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir) : ""

  // ------------------------------------------------------------- settings
  //
  // Bar widgets own the shell.json entry, so they push settings in here and
  // persist changes back out. Defaults keep the service usable before any
  // widget has reported in.

  property int channel: 1
  property int volume: 70
  property int refreshMinutes: 1
  property bool settingsAdopted: false

  // Where audio goes: "local" (mpv on this machine) or "cast" (a Chromecast
  // device fetches the stream itself). The chosen device is remembered by
  // uuid so it can be reconnected without the user picking it again.
  property string outputMode: "local"
  property string castUuid: ""
  property string castName: ""
  readonly property bool casting: outputMode === "cast"

  // Raised when the user changes something a widget should write to
  // shell.json. Widgets listen and call their own persist path.
  signal settingsShouldPersist()

  // Applying settings that came *from* shell.json must not write back to it:
  // the channel is applied before the volume, and persisting mid-way would
  // save a half-adopted entry over the real one.
  property bool applyingSettings: false

  function requestPersist() {
    if (!applyingSettings) settingsShouldPersist()
  }

  // Called by the first bar widget that has a shell.json entry to give us.
  // The bar injects `settings` a turn after `bar` itself, so the widget calls
  // this again on every settings change until one of them carries something —
  // adopting an empty object would latch the defaults over remembered state.
  function adoptSettings(values) {
    if (settingsAdopted || !values) return
    if (values.channel === undefined && values.volume === undefined
      && values.refreshMinutes === undefined && values.output === undefined) return

    settingsAdopted = true
    applySettings(values)

    // Only now is it known which device the last session used. A cast
    // outlives this process, so before deciding we are stopped, ask the
    // device whether it is still playing one of our streams.
    if (casting && castUuid !== "") caster.adoptExistingSession()
  }

  // Live edits from the bar's own settings form land here too, so changing
  // the channel in Setup > Plugins takes effect without a restart.
  function applySettings(values) {
    if (!values) return
    applyingSettings = true
    if (values.channel !== undefined) {
      var wantedChannel = Model.channelFromSetting(values.channel)
      if (wantedChannel !== channel) setChannel(wantedChannel)
      else player.streamUrl = Model.streamUrl(channel)
    }
    if (values.volume !== undefined) {
      var wantedVolume = Model.clampVolume(values.volume)
      if (wantedVolume !== volume) {
        volume = wantedVolume
        player.setVolume(wantedVolume)
      }
    }
    if (values.refreshMinutes !== undefined)
      refreshMinutes = Math.max(1, Math.min(30, Math.floor(Number(values.refreshMinutes)) || 1))
    if (values.castDevice !== undefined) {
      castUuid = Model.plainText(values.castDevice, 80)
      castName = Model.plainText(values.castDeviceName, 60)
      caster.targetUuid = castUuid
      caster.targetName = castName
    }
    if (values.output !== undefined) outputMode = Model.outputModeFromSetting(values.output)
    player.volume = volume
    caster.volume = volume
    applyingSettings = false
  }

  // The values a widget should write back into its shell.json entry.
  function persistableSettings() {
    return {
      channel: Model.channelSettingValue(channel),
      volume: Model.clampVolume(volume),
      output: outputMode,
      castDevice: castUuid,
      castDeviceName: castName
    }
  }

  // ---------------------------------------------------------------- schedule

  // Last good parse of the live endpoint, kept across failures so a dropped
  // network shows stale data rather than an empty panel.
  property var live: null
  property double lastGoodFetchMs: 0
  property bool fetching: false
  property bool metadataFailed: false

  readonly property var currentChannel: live && live[channel] ? live[channel] : Model.emptyChannel(channel)
  readonly property var now: currentChannel.now
  readonly property var upNext: currentChannel.upNext
  readonly property bool hasMetadata: now && now.valid === true

  function channelState(number) {
    var wanted = Model.channelNumber(number)
    return live && live[wanted] ? live[wanted] : Model.emptyChannel(wanted)
  }

  // A UI is on screen somewhere. Widgets set this; it is the only thing that
  // makes this plugin poll at the fast interval while nothing is playing.
  property int uiWatchers: 0
  readonly property bool uiActive: uiWatchers > 0

  function addWatcher() { uiWatchers++ }
  function removeWatcher() { uiWatchers = Math.max(0, uiWatchers - 1) }

  // A clock only while something is showing it, so an idle shell does no
  // per-second work.
  property double nowMs: Date.now()

  Timer {
    interval: 1000
    repeat: true
    running: root.uiActive
    onTriggered: root.nowMs = Date.now()
  }

  // ---------------------------------------------------------------- fetching

  function refresh() {
    if (fetching) return
    fetching = true
    liveFetch.running = true
  }

  function scheduleNextRefresh() {
    var interval = uiActive || player.wanted || caster.wanted
      ? refreshMinutes * 60000
      // Nothing is playing and nothing is on screen: the only reason to keep
      // any schedule at all is so the bar is not stale the moment it is
      // looked at.
      : 15 * 60000
    var floor = metadataFailed ? 30000 : 15000
    refreshTimer.interval = Model.nextRefreshDelay(now, Date.now(), interval, floor)
    refreshTimer.restart()
  }

  Timer {
    id: refreshTimer
    interval: 60000
    repeat: false
    onTriggered: root.refresh()
  }

  // Fetching a fresh schedule the moment a panel opens or playback starts is
  // the difference between "instant" and "up to a minute stale".
  onUiActiveChanged: if (uiActive) refreshIfStale()

  function refreshIfStale() {
    if (Date.now() - lastGoodFetchMs > 30000) refresh()
    else scheduleNextRefresh()
  }

  Process {
    id: liveFetch
    running: false
    // -f fails the request on an HTTP error, --max-time bounds the whole
    // exchange so a hung connection can never wedge the widget. The work
    // happens in a subprocess, so the UI thread never blocks on the network.
    command: ["curl", "-fsS", "--compressed", "--max-time", "12",
      "-H", "Accept: application/json", Model.LIVE_ENDPOINT]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseLive(String(text || ""), 4)
        if (parsed) {
          root.live = parsed
          root.lastGoodFetchMs = Date.now()
          root.metadataFailed = false
        } else if (!root.live) {
          root.metadataFailed = true
        }
      }
    }

    // curl's diagnostics are noise here; the exit code is the signal.
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode, exitStatus) {
      root.fetching = false
      if (exitCode !== 0) root.metadataFailed = true
      root.pushMprisTitle()
      root.scheduleNextRefresh()
    }
  }

  // --------------------------------------------------------------- playback

  // Every playback question routes to whichever backend owns the audio, so
  // the widget and panel never have to know which one that is.
  readonly property bool playing: casting ? caster.playing : player.playing
  readonly property bool loading: casting ? caster.loading : player.loading
  readonly property bool stopped: !playing && !loading
  readonly property string playbackError: casting ? caster.lastError : player.lastError

  // Local playback needs mpv; casting needs python-pychromecast. Neither is
  // something a plugin may install, so the UI has to be able to say which one
  // is missing rather than reporting a generic failure.
  property bool mpvAvailable: true
  readonly property bool castAvailable: caster.available
  readonly property string castUnavailableReason: caster.unavailableReason
  readonly property var castDevices: caster.devices
  readonly property bool castDiscovering: caster.discovering
  readonly property bool castConnected: caster.connected
  readonly property string castTargetName: caster.targetName || castName

  function play() {
    if (casting) {
      caster.streamUrl = Model.streamUrl(channel)
      caster.play()
    } else {
      player.streamUrl = Model.streamUrl(channel)
      player.play()
    }
    refreshIfStale()
  }

  function pause() {
    if (casting) caster.stop()
    else player.pause()
  }

  function togglePlayback() {
    if (playing || loading) pause()
    else play()
  }

  function setChannel(number) {
    var wanted = Model.channelNumber(number)
    if (wanted === channel) return
    channel = wanted
    var url = Model.streamUrl(wanted)
    player.switchStream(url)
    caster.switchStream(url)
    pushMprisTitle()
    requestPersist()
    refreshIfStale()
  }

  function setVolume(value) {
    var wanted = Model.clampVolume(value)
    if (wanted === volume) return
    volume = wanted
    if (casting) caster.setVolume(wanted)
    else player.setVolume(wanted)
    volumePersist.restart()
  }

  // Moving the audio between this machine and a device. Playback follows the
  // move: if it was playing, it is playing when the move finishes.
  function setOutput(mode, uuid, name) {
    var wantedMode = Model.outputModeFromSetting(mode)
    var wantedUuid = wantedMode === "cast" ? Model.plainText(uuid, 80) : ""
    // Switching to local keeps the remembered device, so comparing uuids
    // here would make every "output local" look like a change and needlessly
    // restart playback. Only the device matters, and only while casting.
    var alreadyThere = wantedMode === outputMode
      && (wantedMode !== "cast" || wantedUuid === "" || wantedUuid === castUuid)
    if (alreadyThere) return

    var wasPlaying = playing || loading

    // Stop the backend that is losing the audio before the switch, or it
    // carries on playing into a UI that no longer represents it.
    if (casting) caster.stop()
    else player.stop()

    outputMode = wantedMode
    if (wantedMode === "cast") {
      castUuid = wantedUuid
      castName = Model.plainText(name, 60) || Model.deviceName(caster.devices, wantedUuid, "")
      caster.selectDevice(castUuid, castName)
    }
    requestPersist()
    if (wasPlaying) play()
  }

  function castTo(uuid, name) { setOutput("cast", uuid, name) }
  function castToLocal() { setOutput("local", "", "") }
  function discoverCastDevices() { caster.discover() }

  // Dragging a slider should not write shell.json on every frame.
  Timer {
    id: volumePersist
    interval: 800
    onTriggered: root.requestPersist()
  }

  function pushMprisTitle() {
    player.mediaTitle = Model.mprisTitle(channel, now)
  }

  onNowChanged: pushMprisTitle()

  function openCurrentShow() {
    var url = now && now.url ? String(now.url) : Model.SITE_URL
    // Model only ever produces https://www.nts.live/... here, but the guard
    // stays so a future parser change cannot hand the browser something else.
    if (url.indexOf(Model.SITE_URL) !== 0) url = Model.SITE_URL
    Quickshell.execDetached(["xdg-open", url])
  }

  Player {
    id: player
    pausedShutdownSeconds: 300
  }

  Caster {
    id: caster
    pluginDir: root.pluginDir
    // The bridge is a Python process; it runs only while a panel is showing
    // device choices or a cast is actually in progress.
    bridgeEnabled: root.uiActive || caster.wanted
    // Metadata is sent when playback starts, so the device and the Home app
    // show the programme rather than the raw stream name. It is deliberately
    // not resent on every schedule change: updating it means reloading the
    // media, and a gap in the audio is worse than a stale title.
    mediaTitle: Model.channelLabel(root.channel)
    mediaSubtitle: root.now ? Model.barTitle(root.now) : ""
    artworkUrl: root.now ? root.now.artworkLarge : ""
  }

  Connections {
    target: caster

    // A device can be adjusted from the Home app or its own touch controls.
    function onVolumeChanged() {
      if (!root.casting || root.volume === caster.volume) return
      root.volume = caster.volume
      volumePersist.restart()
    }

    // Casting keeps the schedule refreshing at the fast cadence the same way
    // local playback does.
    function onWantedChanged() { root.scheduleNextRefresh() }

    // Remember a device the moment it is actually connected, name included,
    // so the next session can reconnect without a discovery round trip.
    function onTargetNameChanged() {
      if (!root.casting || caster.targetName === "") return
      if (caster.targetName === root.castName) return
      root.castName = caster.targetName
      root.requestPersist()
    }

    // A device can be chosen by uuid alone — from the IPC surface, or from a
    // remembered setting saved before its name was known. Fill the name in
    // from the first discovery that sees it, so the panel has something to
    // call it even while it is offline.
    function onDevicesChanged() {
      if (root.castUuid === "" || root.castName !== "") return
      var found = Model.deviceName(caster.devices, root.castUuid, "")
      if (found === "") return
      root.castName = found
      root.requestPersist()
    }
  }

  // mpv is the local backend and cannot be installed by a plugin, so its
  // absence is a first-class state rather than a stream error.
  Process {
    id: mpvProbe
    running: true
    command: ["sh", "-c", "command -v mpv >/dev/null 2>&1 && echo yes || echo no"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.mpvAvailable = String(text || "").indexOf("yes") === 0
    }
  }

  Connections {
    target: player

    // Playback state changes what the refresh cadence should be.
    function onWantedChanged() { root.scheduleNextRefresh() }

    // mpv is also volume-controllable from outside (playerctl, pavucontrol's
    // stream slider does not reach it, but an MPRIS client does). Follow it
    // rather than fighting it.
    function onVolumeChanged() {
      if (root.volume === player.volume) return
      root.volume = player.volume
      volumePersist.restart()
    }
  }

  // ------------------------------------------------------------ mpris probe

  // mpv's MPRIS script is a distro package, not something this plugin ships.
  // Find it once at startup; if it is not installed, playback is unaffected
  // and only media-key control is missing.
  Process {
    id: mprisProbe
    running: true
    command: ["sh", "-c",
      'for candidate in /etc/mpv/scripts/mpris.so /usr/lib/mpv/mpris.so ' +
      '/usr/local/lib/mpv/mpris.so /usr/lib/x86_64-linux-gnu/mpv/mpris.so ' +
      '"$HOME/.config/mpv/scripts/mpris.so" "$HOME/.local/share/mpv/scripts/mpris.so"; do ' +
      '[ -e "$candidate" ] && printf %s "$candidate" && exit 0; done; exit 0']

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").replace(/^\s+|\s+$/g, "")
        if (path !== "" && path.charAt(0) === "/") player.mprisScript = path
      }
    }
  }

  readonly property bool mprisAvailable: player.mprisScript !== ""

  // -------------------------------------------------------------------- ipc

  // A scriptable surface for keybindings, so playback does not depend on the
  // panel being reachable with the mouse:
  //
  //   omarchy-shell nts-radio toggle
  //   omarchy-shell nts-radio channel 2
  //   omarchy-shell nts-radio status
  IpcHandler {
    target: "nts-radio"

    function play(): void { root.play() }
    function pause(): void { root.pause() }
    function toggle(): void { root.togglePlayback() }
    function next(): void { root.setChannel(root.channel === 1 ? 2 : 1) }

    function channel(number: string): string {
      root.setChannel(Model.channelNumber(number))
      return Model.channelLabel(root.channel)
    }

    function volume(level: string): string {
      var wanted = parseInt(String(level), 10)
      if (isFinite(wanted)) root.setVolume(wanted)
      return String(root.volume)
    }

    // Move audio between this machine and a device.
    //   omarchy-shell nts-radio output local
    //   omarchy-shell nts-radio output cast          (single device, or remembered)
    //   omarchy-shell nts-radio output <device-uuid>
    function output(target: string): string {
      var wanted = String(target || "").trim()
      if (wanted === "" || wanted === "local" || wanted === "this") {
        root.castToLocal()
        return "local"
      }
      if (wanted === "cast") {
        root.castTo(root.castUuid, root.castName)
        return root.castUuid === "" ? "cast (device will be chosen on connect)" : root.castUuid
      }
      root.castTo(wanted, Model.deviceName(root.castDevices, wanted, ""))
      return wanted
    }

    function devices(): string {
      root.discoverCastDevices()
      return JSON.stringify({
        available: root.castAvailable,
        reason: root.castUnavailableReason,
        discovering: root.castDiscovering,
        devices: root.castDevices
      })
    }

    function status(): string {
      return JSON.stringify({
        channel: root.channel,
        playing: root.playing,
        loading: root.loading,
        volume: root.volume,
        output: root.outputMode,
        castDevice: root.castTargetName,
        castUuid: root.castUuid,
        castConnected: root.castConnected,
        castAvailable: root.castAvailable,
        mpvAvailable: root.mpvAvailable,
        mpris: root.mprisAvailable,
        title: root.now ? root.now.title : "",
        show: root.now ? root.now.showName : "",
        url: root.now ? root.now.url : "",
        startsAt: root.now ? root.now.startMs : 0,
        endsAt: root.now ? root.now.endMs : 0,
        upNext: root.upNext.map(function(entry) { return entry.title }),
        metadataFailed: root.metadataFailed,
        playbackError: root.playbackError
      })
    }
  }

  // -------------------------------------------------------------- lifecycle

  Component.onCompleted: {
    player.streamUrl = Model.streamUrl(channel)
    refresh()
  }

  Component.onDestruction: {
    caster.stop()
    player.stop()
    // mpv does not unlink its IPC socket on exit. Harmless (it lives in the
    // runtime dir and the next mpv rebinds it), but leaving files behind
    // after the plugin is disabled is not tidy.
    Quickshell.execDetached(["rm", "-f", player.socketPath])
  }
}

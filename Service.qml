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

  // ------------------------------------------------------------- settings
  //
  // Bar widgets own the shell.json entry, so they push settings in here and
  // persist changes back out. Defaults keep the service usable before any
  // widget has reported in.

  property int channel: 1
  property int volume: 70
  property int refreshMinutes: 1
  property bool settingsAdopted: false

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
      && values.refreshMinutes === undefined) return

    settingsAdopted = true
    applySettings(values)
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
    player.volume = volume
    applyingSettings = false
  }

  // The values a widget should write back into its shell.json entry.
  function persistableSettings() {
    return {
      channel: Model.channelSettingValue(channel),
      volume: Model.clampVolume(volume)
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
    var interval = uiActive || player.wanted
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

  readonly property bool playing: player.playing
  readonly property bool loading: player.loading
  readonly property bool stopped: !player.playing && !player.loading
  readonly property string playbackError: player.lastError

  function play() {
    player.streamUrl = Model.streamUrl(channel)
    player.play()
    refreshIfStale()
  }

  function pause() { player.pause() }

  function togglePlayback() {
    if (player.playing || player.loading) player.pause()
    else play()
  }

  function setChannel(number) {
    var wanted = Model.channelNumber(number)
    if (wanted === channel) return
    channel = wanted
    player.switchStream(Model.streamUrl(wanted))
    pushMprisTitle()
    requestPersist()
    refreshIfStale()
  }

  function setVolume(value) {
    var wanted = Model.clampVolume(value)
    if (wanted === volume) return
    volume = wanted
    player.setVolume(wanted)
    volumePersist.restart()
  }

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

    function status(): string {
      return JSON.stringify({
        channel: root.channel,
        playing: root.playing,
        loading: root.loading,
        volume: root.volume,
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
    player.stop()
    // mpv does not unlink its IPC socket on exit. Harmless (it lives in the
    // runtime dir and the next mpv rebinds it), but leaving files behind
    // after the plugin is disabled is not tidy.
    Quickshell.execDetached(["rm", "-f", player.socketPath])
  }
}

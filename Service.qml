import QtQuick
import Quickshell
import Quickshell.Io

import "Model.js" as Model
import "NtsApi.js" as NtsApi
import "Library.js" as Library

// Shared state for every NTS bar widget instance (one per monitor), the panel
// each of them can open, and the browser window. Playback, the schedule, the
// API client and the local library all live here so that closing a panel,
// closing the browser, or moving the widget never interrupts the stream.
//
// Phase 2 added a second medium — archived episodes alongside live radio —
// and the browser window that finds them. Both surfaces drive this one object;
// neither owns playback.
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
  // uuid so it can be reconnected without the user picking it again — but the
  // *mode* always starts local; see adoptSettings.
  property string outputMode: "local"

  // What shell.json says the last session was doing. Only used to decide
  // whether to ask a remembered device if it is still playing, never to set
  // the current output.
  property string lastSessionOutput: "local"
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

    // Radio starts on this computer, always. A remembered device is a
    // convenience for switching back to it in one click — not an instruction
    // to start playing there, which is a surprising thing for a shell restart
    // to do to a speaker in another room.
    outputMode = "local"

    // The one exception, and it is not a preference: a cast outlives this
    // process, so if the last session ended while casting, the device may be
    // playing one of our streams right now. Ask it. If it is, the audio is
    // already happening and we take the output back so the panel can stop it
    // — abandoning it would leave a speaker playing with nothing to control
    // it. If it is not, we stay local and nothing has started.
    if (lastSessionOutput === "cast" && castUuid !== "") caster.adoptExistingSession()
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
    // Deliberately not applied to outputMode. What shell.json records is what
    // the *last* session was doing, which adoptSettings uses to decide whether
    // a cast is worth asking about — it is not a starting output.
    if (values.output !== undefined) lastSessionOutput = Model.outputModeFromSetting(values.output)
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

  // What is on the air right now: "live" for NTS 1/2, "archive" for a show
  // out of the archive. This is the single fact the bar widget, the panel and
  // the browser all read to decide what they are looking at.
  property string playbackMode: "live"
  readonly property bool archiveMode: playbackMode === "archive"

  // The episode an archive session is playing, in NtsApi's episode shape.
  property var archiveEpisode: null
  readonly property bool hasArchiveEpisode: archiveEpisode !== null && archiveEpisode.valid === true

  // Casting is a live-radio capability. A Chromecast fetches the stream URL
  // itself, and an archived episode has no such URL — only a SoundCloud page
  // that has to be resolved on this machine first. Archives therefore always
  // play locally, whatever output is selected; the choice is remembered and
  // takes effect again the moment live radio comes back.
  readonly property bool castingAudio: casting && !archiveMode

  // Every playback question routes to whichever backend owns the audio, so
  // the widget and panel never have to know which one that is.
  readonly property bool playing: castingAudio ? caster.playing : player.playing
  readonly property bool loading: castingAudio ? caster.loading : player.loading
  readonly property bool stopped: !playing && !loading
  readonly property string playbackError: castingAudio ? caster.lastError : player.lastError

  // Position and length, in seconds. Both are 0 for live, which has neither.
  readonly property real positionSec: archiveMode ? player.positionSec : 0
  readonly property real durationSec: archiveMode ? player.durationSec : 0
  readonly property bool canSeek: archiveMode && durationSec > 0

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
    if (archiveMode) {
      // The episode is already loaded into the player; this is a resume.
      player.play()
      return
    }
    if (castingAudio) {
      caster.streamUrl = Model.streamUrl(channel)
      caster.play()
    } else {
      player.streamUrl = Model.streamUrl(channel)
      player.play()
    }
    refreshIfStale()
  }

  function pause() {
    if (archiveMode) {
      // Note where it stopped before the process can be reaped, so the shelf
      // is right even if the user never comes back to it this session.
      player.pause()
      saveProgress()
      return
    }
    if (castingAudio) caster.stop()
    else player.pause()
  }

  function togglePlayback() {
    if (playing || loading) pause()
    else play()
  }

  // -------------------------------------------------------- archive playback

  // Put an archived episode on the air. `startSec` resumes a part-heard show;
  // pass 0 (or nothing) to start from the top, and the remembered position is
  // used automatically when there is one.
  function playEpisode(episode, startSec) {
    if (!episode || !episode.valid) return false
    if (!episode.audioUrl) {
      // NTS lists episodes it has no audio for — a broadcast that was never
      // uploaded, or one taken down. Saying so is better than a dead button.
      archiveError = "This episode has no audio on NTS"
      return false
    }
    if (!ytdlAvailable) {
      archiveError = "yt-dlp is not installed — sudo pacman -S yt-dlp"
      return false
    }

    archiveError = ""

    // Whatever was playing is losing the audio. A cast device keeps playing
    // the live stream on its own if it is not told to stop.
    if (caster.wanted) caster.stop()

    // Leaving one episode for another: record where we got to in the old one
    // before its position is overwritten.
    if (archiveMode && hasArchiveEpisode && !NtsApi.sameEpisode(archiveEpisode, episode))
      saveProgress()

    var resume = Number(startSec)
    if (!isFinite(resume) || resume < 0) resume = Library.resumePosition(library, episode)

    archiveEpisode = episode
    playbackMode = "archive"
    player.mediaTitle = archiveMprisTitle(episode)
    player.loadSource("archive", episode.audioUrl, resume)
    return true
  }

  // Back to live radio, optionally on a specific channel.
  function playLive(number) {
    var wanted = number === undefined ? channel : Model.channelNumber(number)
    // Whatever went wrong with the archive is no longer on screen or on the
    // air, so the message should not outlive it.
    archiveError = ""
    if (archiveMode) {
      saveProgress()
      player.stop()
      archiveEpisode = null
      playbackMode = "live"
    }
    if (wanted !== channel) {
      channel = wanted
      requestPersist()
    }
    var url = Model.streamUrl(channel)
    player.mode = "live"
    player.streamUrl = url
    caster.streamUrl = url
    pushMprisTitle()
    play()
  }

  function seekTo(seconds) {
    if (!archiveMode) return
    player.seekTo(seconds)
    // A scrub is a deliberate move; remember it straight away rather than
    // waiting for the next progress tick.
    progressSave.restart()
  }

  function seekBy(delta) {
    if (!archiveMode) return
    seekTo(player.positionSec + Number(delta || 0))
  }

  // Is this episode the one currently on the air?
  function isCurrentEpisode(episode) {
    return archiveMode && NtsApi.sameEpisode(archiveEpisode, episode)
  }

  function archiveMprisTitle(episode) {
    if (!episode) return "NTS"
    var name = episode.name || episode.showName
    return name ? "NTS — " + name : "NTS"
  }

  // A failure that belongs to the archive rather than to the player: no audio
  // listed, or no resolver installed. Cleared by the next successful start.
  property string archiveError: ""

  function setChannel(number) {
    var wanted = Model.channelNumber(number)

    // Choosing a channel while an archive is playing means "take me back to
    // live radio", which is a change of medium even when the channel number
    // is the one already selected.
    if (archiveMode) {
      playLive(wanted)
      return
    }

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
    if (castingAudio) caster.setVolume(wanted)
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

    // An archive cannot follow the audio to a cast device, so choosing one
    // mid-episode records the preference and leaves playback alone. It takes
    // effect the next time live radio is on.
    if (archiveMode) {
      outputMode = wantedMode
      if (wantedMode === "cast") {
        castUuid = wantedUuid
        castName = Model.plainText(name, 60) || Model.deviceName(caster.devices, wantedUuid, "")
        caster.selectDevice(castUuid, castName)
      }
      requestPersist()
      return
    }

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
    // An archive owns the media title for as long as it is playing; the live
    // schedule moving on underneath must not relabel it.
    if (archiveMode) return
    player.mediaTitle = Model.mprisTitle(channel, now)
  }

  onNowChanged: pushMprisTitle()

  // ---------------------------------------------------------------- browser

  // The full browser window. It is an `overlay` entry point on this same
  // plugin, so the shell hands it this very object as `service` — which is
  // what makes playback survive the window opening and closing.
  function openBrowser() {
    if (!shell || typeof shell.summon !== "function") return false
    return shell.summon(pluginId, "{}") === true
  }

  function toggleBrowser() {
    if (!shell || typeof shell.toggle !== "function") return false
    shell.toggle(pluginId, "{}")
    return true
  }

  function closeBrowser() {
    if (!shell || typeof shell.hide !== "function") return false
    return shell.hide(pluginId) === true
  }

  readonly property bool browserOpen: shell && typeof shell.isPluginOpen === "function"
    ? shell.isPluginOpen(pluginId) : false

  // Opens whatever is playing on nts.live — the archived episode when there
  // is one, otherwise the live broadcast.
  function openCurrent() {
    if (archiveMode && hasArchiveEpisode) openExternal(archiveEpisode.url)
    else openCurrentShow()
  }

  // Every URL that reaches the browser passes through here. Model and NtsApi
  // only ever build https://www.nts.live/... links, but this is the boundary
  // where a parser bug would become someone else's problem, so it is checked
  // once more on the way out.
  function openExternal(url) {
    var target = String(url || "")
    if (target.indexOf(Model.SITE_URL) !== 0 && !/^https:\/\/[a-zA-Z0-9.-]+\//.test(target))
      target = Model.SITE_URL
    Quickshell.execDetached(["xdg-open", target])
  }

  // -------------------------------------------------------------- api client

  // The one place the plugin talks to nts.live. Pages ask this for parsed
  // results; nothing else in the plugin opens a socket.
  readonly property alias api: apiClient

  Api { id: apiClient }

  // ----------------------------------------------------------------- library

  // Saved shows, saved episodes and resume positions, in a file the user owns.
  // See Library.js for why this is local rather than account-backed.
  property var library: Library.emptyLibrary()

  readonly property string libraryDir: {
    var stateHome = String(Quickshell.env("XDG_STATE_HOME") || "")
    var base = stateHome !== "" ? stateHome : String(Quickshell.env("HOME") || "") + "/.local/state"
    return base + "/omarchy/nts-radio"
  }
  readonly property string libraryPath: libraryDir + "/library.json"

  // Set once the file has been read (or found missing). Saving before this
  // would write an empty library over a real one.
  property bool libraryLoaded: false

  function saveLibrary() {
    if (!libraryLoaded) return
    libraryFile.setText(Library.serialize(library) + "\n")
  }

  function toggleSaveShow(show) {
    if (!show || !show.alias) return
    library = Library.toggleShow(library, show, Date.now())
    saveLibrary()
  }

  function toggleSaveEpisode(episode) {
    if (!episode || !episode.valid) return
    library = Library.toggleEpisode(library, episode, Date.now())
    saveLibrary()
  }

  function isShowSaved(alias) { return Library.hasShow(library, alias) }
  function isEpisodeSaved(episode) { return Library.hasEpisode(library, episode) }
  function resumePositionFor(episode) { return Library.resumePosition(library, episode) }

  // Fold the current archive position into the library. Cheap and idempotent:
  // Library.noteProgress returns the same object when nothing moved, and an
  // unchanged object means no disk write.
  function saveProgress() {
    if (!archiveMode || !hasArchiveEpisode || !libraryLoaded) return
    var updated = Library.noteProgress(library, archiveEpisode,
      player.positionSec, player.durationSec, Date.now())
    if (updated === library) return
    library = updated
    saveLibrary()
  }

  // Every 15s while an archive is actually moving. Often enough that killing
  // the shell loses almost nothing, rare enough to be invisible.
  Timer {
    id: progressSave
    interval: 15000
    repeat: true
    running: root.archiveMode && root.playing
    onTriggered: root.saveProgress()
  }

  Connections {
    target: player

    // The recording ran out. Clear the resume entry so it does not sit on the
    // "continue listening" shelf at 99%, and leave the episode loaded so the
    // UI still shows what just finished.
    function onFinished() {
      if (!root.archiveMode || !root.hasArchiveEpisode) return
      root.library = Library.clearResume(root.library, root.archiveEpisode)
      root.saveLibrary()
    }
  }

  // The directory will not exist on a first run, and FileView will not create
  // it. Cheap enough to do unconditionally at startup.
  Process {
    id: libraryDirInit
    running: true
    command: ["mkdir", "-p", root.libraryDir]
    onExited: libraryFile.reload()
  }

  FileView {
    id: libraryFile
    path: root.libraryPath
    watchChanges: false
    // The library is rewritten in full on every change; a torn file after a
    // crash would lose the lot.
    atomicWrites: true
    printErrors: false

    onLoaded: {
      root.library = Library.load(text())
      root.libraryLoaded = true
    }

    // No file yet, or an unreadable one. Either way an empty library is the
    // right starting point — never a reason to keep the browser from opening.
    onLoadFailed: function(error) {
      root.library = Library.emptyLibrary()
      root.libraryLoaded = true
    }
  }

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
    function onWantedChanged() {
      // The caster only wants audio for two reasons: we asked it to (in which
      // case the output is already cast), or it adopted a session that was
      // still running on the device from before this shell started. The second
      // is the only way the output moves without the user touching anything,
      // and it moves because the speaker is already playing.
      if (caster.wanted && !root.casting) root.outputMode = "cast"
      root.scheduleNextRefresh()
    }

    // The recovery probe has finished. If it found nothing to take back, say
    // so in shell.json: without this, a session that once ended while casting
    // would start a discovery on every shell restart forever, asking a
    // question that was already answered.
    function onAdoptingChanged() {
      if (caster.adopting) return
      if (root.casting || root.lastSessionOutput !== "cast") return
      root.lastSessionOutput = "local"
      root.requestPersist()
    }

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

  // Archived episodes live on SoundCloud and Mixcloud, not on NTS, so playing
  // one needs a resolver. Live radio does not, which is why this is a separate
  // question from mpv: the plugin stays fully useful without it and only the
  // archive half goes quiet.
  property bool ytdlAvailable: true

  Process {
    id: ytdlProbe
    running: true
    command: ["sh", "-c",
      'for candidate in yt-dlp youtube-dl; do ' +
      'command -v "$candidate" >/dev/null 2>&1 && { echo yes; exit 0; }; done; echo no']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ytdlAvailable = String(text || "").indexOf("yes") === 0
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

    // The browser window.
    //   omarchy-shell nts-radio browser
    function browser(): string {
      root.toggleBrowser()
      return "ok"
    }

    // Back to live radio from an archived show.
    //   omarchy-shell nts-radio live
    //   omarchy-shell nts-radio live 2
    function live(number: string): string {
      var wanted = String(number || "").trim()
      root.playLive(wanted === "" ? root.channel : Model.channelNumber(wanted))
      return Model.channelLabel(root.channel)
    }

    // Play an archived episode by its NTS aliases, the two path segments of
    // its nts.live URL:
    //   omarchy-shell nts-radio episode floating-points floating-points-27th-july-2026
    function episode(showAlias: string, episodeAlias: string): string {
      var show = Model.safeAlias(showAlias)
      var slot = Model.safeAlias(episodeAlias)
      if (!show || !slot) return "usage: episode <show-alias> <episode-alias>"
      root.api.episode(show, slot, function(parsed, ok) {
        if (!ok || !parsed) {
          root.archiveError = "Could not find that episode"
          return
        }
        root.playEpisode(parsed, -1)
      })
      return "loading " + show + "/" + slot
    }

    // Seek within an archived show. Accepts absolute seconds, or a relative
    // offset with a sign: `seek 90`, `seek +30`, `seek -30`.
    function seek(position: string): string {
      if (!root.archiveMode) return "not playing an archive"
      var raw = String(position || "").trim()
      var value = parseFloat(raw)
      if (!isFinite(value)) return "usage: seek [+|-]<seconds>"
      if (raw.charAt(0) === "+" || raw.charAt(0) === "-") root.seekBy(value)
      else root.seekTo(value)
      return NtsApi.clockFromSeconds(root.positionSec)
    }

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
      // The live fields keep the shape the MVP published, so anything already
      // parsing this output keeps working; the archive block is additive and
      // is only meaningful while mode is "archive".
      return JSON.stringify({
        mode: root.playbackMode,
        channel: root.channel,
        playing: root.playing,
        loading: root.loading,
        volume: root.volume,
        output: root.outputMode,
        archive: root.archiveMode && root.hasArchiveEpisode ? {
          show: root.archiveEpisode.showName || root.archiveEpisode.name,
          title: root.archiveEpisode.name,
          showAlias: root.archiveEpisode.showAlias,
          episodeAlias: root.archiveEpisode.episodeAlias,
          url: root.archiveEpisode.url,
          position: Math.floor(root.positionSec),
          duration: Math.floor(root.durationSec),
          positionLabel: NtsApi.clockFromSeconds(root.positionSec),
          durationLabel: NtsApi.clockFromSeconds(root.durationSec)
        } : null,
        saved: {
          shows: root.library.shows.length,
          episodes: root.library.episodes.length,
          continueListening: root.library.resume.length
        },
        browserOpen: root.browserOpen,
        ytdlAvailable: root.ytdlAvailable,
        archiveError: root.archiveError,
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
    // Last chance to remember where an archive got to: the plugin is being
    // disabled or the shell is going down, and mpv is about to be killed.
    saveProgress()
    caster.stop()
    player.stop()
    // mpv does not unlink its IPC socket on exit. Harmless (it lives in the
    // runtime dir and the next mpv rebinds it), but leaving files behind
    // after the plugin is disabled is not tidy.
    Quickshell.execDetached(["rm", "-f", player.socketPath])
  }
}

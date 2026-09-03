// Data layer for the NTS Radio plugin.
//
// Everything that knows an NTS URL or the shape of an NTS response lives in
// this file, so a change on their side is a change here and nowhere else.
// Pure functions only — no QML types, no side effects, no network. The QML
// layer owns the fetching (curl in a Process) and hands the raw body here.

// ------------------------------------------------------------------ endpoints

// Undocumented but stable: this is the JSON the nts.live player itself polls
// for both channels. One request covers now-playing plus the next 17 slots.
var LIVE_ENDPOINT = "https://www.nts.live/api/v2/live"

// Geo-routed relays that 302 to the current CDN edge. mpv follows the
// redirect, so these stay correct even when NTS moves hosts.
var STREAM_ENDPOINTS = {
  1: "https://stream-relay-geo.ntslive.net/stream",
  2: "https://stream-relay-geo.ntslive.net/stream2"
}

var SITE_URL = "https://www.nts.live"

// Artwork is only ever loaded from hosts NTS serves media from. An artwork
// URL is attacker-influenced data as far as this plugin is concerned, so it
// gets an allowlist rather than a scheme check.
var ARTWORK_HOSTS = /^https:\/\/(?:[a-z0-9-]+\.)?(?:ntslive\.co\.uk|ntslive\.net|nts\.live)\//

var CHANNELS = [1, 2]

// Cap on any string taken from the API before it reaches a QML Text item.
var MAX_TEXT = 240
var MAX_DESCRIPTION = 900

function channelNumber(value) {
  var n = parseInt(String(value), 10)
  return n === 2 ? 2 : 1
}

function channelLabel(channel) {
  return "NTS " + channelNumber(channel)
}

function streamUrl(channel) {
  return STREAM_ENDPOINTS[channelNumber(channel)]
}

// The enum stored in shell.json is a human label; the rest of the plugin
// works in channel numbers.
function channelFromSetting(value) {
  return String(value || "").indexOf("2") !== -1 ? 2 : 1
}

function channelSettingValue(channel) {
  return channelLabel(channel)
}

// ------------------------------------------------------------- sanitization

var ENTITIES = {
  amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ",
  hellip: "…", mdash: "—", ndash: "–",
  lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”"
}

function decodeEntities(value) {
  return String(value).replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, function(match, body) {
    if (body.charAt(0) === "#") {
      var code = body.charAt(1) === "x" || body.charAt(1) === "X"
        ? parseInt(body.slice(2), 16)
        : parseInt(body.slice(1), 10)
      // Reject anything outside the BMP-safe printable range rather than
      // risk emitting a lone surrogate or a control character.
      if (!isFinite(code) || code < 32 || code > 0x10ffff) return ""
      return String.fromCharCode(code)
    }
    var named = ENTITIES[body.toLowerCase()]
    return named === undefined ? "" : named
  })
}

// Every string that reaches the UI goes through here: tags stripped, entities
// decoded, control characters dropped, whitespace collapsed, length capped.
// Text items are all PlainText as well, so this is belt and braces.
function plainText(value, limit) {
  if (value === undefined || value === null) return ""
  var text = String(value)
  if (text.length > 8192) text = text.slice(0, 8192)
  text = text.replace(/<[^>]*>/g, " ")
  text = decodeEntities(text)
  // Strip C0/C1 controls and line/paragraph separators; QML Text renders
  // some of them as boxes and others as unexpected line breaks.
  text = text.replace(/[\x00-\x1f\x7f-\x9f\u2028\u2029]+/g, " ")
  text = text.replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  var max = limit === undefined ? MAX_TEXT : limit
  if (text.length > max) text = text.slice(0, Math.max(0, max - 1)).replace(/\s+\S*$/, "") + "…"
  return text
}

function safeArtwork(value) {
  var url = String(value === undefined || value === null ? "" : value)
  if (url.length > 600) return ""
  return ARTWORK_HOSTS.test(url) ? url : ""
}

// Only [a-z0-9-] aliases become part of a URL we hand to the browser.
function safeAlias(value) {
  var alias = String(value === undefined || value === null ? "" : value)
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,180}$/.test(alias) ? alias : ""
}

function parseTimestamp(value) {
  if (!value) return 0
  var ms = Date.parse(String(value))
  return isFinite(ms) ? ms : 0
}

// ------------------------------------------------------------------ parsing

function emptyShow() {
  return {
    title: "",
    showName: "",
    description: "",
    location: "",
    genres: [],
    artworkSmall: "",
    artworkLarge: "",
    startMs: 0,
    endMs: 0,
    url: "",
    valid: false
  }
}

// One entry from `results[].now` / `results[].nextN` — the two have the same
// shape, so up-next rows and the live show are built by the same function.
function showFromEntry(entry) {
  var show = emptyShow()
  if (!entry || typeof entry !== "object") return show

  var details = entry.embeds && entry.embeds.details ? entry.embeds.details : {}
  var media = details.media && typeof details.media === "object" ? details.media : {}

  show.title = plainText(entry.broadcast_title)
  show.showName = plainText(details.name)
  show.description = plainText(details.description, MAX_DESCRIPTION)
  show.location = plainText(details.location_long || details.location_short, 60)

  if (Array.isArray(details.genres)) {
    for (var i = 0; i < details.genres.length && show.genres.length < 4; i++) {
      var genre = plainText(details.genres[i] && details.genres[i].value, 40)
      if (genre) show.genres.push(genre)
    }
  }

  show.artworkSmall = safeArtwork(media.picture_medium || media.background_medium
    || media.picture_small || media.background_small)
  show.artworkLarge = safeArtwork(media.picture_medium_large || media.background_medium_large
    || show.artworkSmall)

  show.startMs = parseTimestamp(entry.start_timestamp)
  show.endMs = parseTimestamp(entry.end_timestamp)

  var showAlias = safeAlias(details.show_alias)
  var episodeAlias = safeAlias(details.episode_alias)
  if (showAlias && episodeAlias) show.url = SITE_URL + "/shows/" + showAlias + "/episodes/" + episodeAlias
  else if (showAlias) show.url = SITE_URL + "/shows/" + showAlias
  else show.url = SITE_URL

  show.valid = show.title !== "" || show.showName !== ""
  return show
}

function emptyChannel(channel) {
  return { channel: channelNumber(channel), now: emptyShow(), upNext: [] }
}

// Parses the live endpoint into { 1: channelState, 2: channelState }.
// Returns null for anything it cannot make sense of, so callers can keep
// showing the last good response instead of blanking the panel.
function parseLive(raw, upNextCount) {
  var wanted = upNextCount === undefined ? 3 : Math.max(0, Math.min(8, upNextCount))
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!data || !Array.isArray(data.results) || data.results.length === 0) return null

  var out = {}
  var found = 0
  for (var i = 0; i < data.results.length; i++) {
    var result = data.results[i]
    if (!result || typeof result !== "object") continue
    var channel = channelNumber(result.channel_name)
    if (out[channel]) continue

    var state = emptyChannel(channel)
    state.now = showFromEntry(result.now)
    for (var slot = 1; slot <= wanted; slot++) {
      var key = slot === 1 ? "next" : "next" + slot
      var upcoming = showFromEntry(result[key])
      if (upcoming.valid) state.upNext.push(upcoming)
    }
    out[channel] = state
    found++
  }
  if (found === 0) return null

  for (var c = 0; c < CHANNELS.length; c++) {
    if (!out[CHANNELS[c]]) out[CHANNELS[c]] = emptyChannel(CHANNELS[c])
  }
  return out
}

// ---------------------------------------------------------------- formatting

function progressFraction(show, nowMs) {
  if (!show || !show.startMs || !show.endMs || show.endMs <= show.startMs) return 0
  var fraction = (nowMs - show.startMs) / (show.endMs - show.startMs)
  return Math.max(0, Math.min(1, fraction))
}

function minutesRemaining(show, nowMs) {
  if (!show || !show.endMs || show.endMs <= nowMs) return 0
  return Math.round((show.endMs - nowMs) / 60000)
}

function remainingLabel(show, nowMs) {
  var minutes = minutesRemaining(show, nowMs)
  if (minutes <= 0) return ""
  if (minutes < 60) return minutes + " min left"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  return rest === 0 ? hours + " hr left" : hours + " hr " + rest + " min left"
}

// A broadcast title is usually "Show Name w/ Guest" or "Show Name (R)". The
// bar only has room for the front of it.
function barTitle(show) {
  if (!show || !show.valid) return ""
  return show.title || show.showName
}

// mpv reports this over MPRIS, so it is what media-key OSDs and other
// desktop media clients display.
function mprisTitle(channel, show) {
  var title = barTitle(show)
  return title ? channelLabel(channel) + " — " + title : channelLabel(channel)
}

// The next refresh should land just after the current broadcast ends, but no
// sooner than the floor and no later than the ceiling. All values in ms.
function nextRefreshDelay(show, nowMs, intervalMs, minimumMs) {
  var floor = minimumMs === undefined ? 15000 : minimumMs
  var delay = Math.max(floor, intervalMs)
  if (show && show.endMs > nowMs) {
    // +2s so the API has settled on the new show before we ask for it.
    var untilHandover = (show.endMs - nowMs) + 2000
    if (untilHandover < delay) delay = Math.max(floor, untilHandover)
  }
  return delay
}

// ------------------------------------------------------------------ casting

// Devices reported by scripts/cast.py. The helper is ours, but the names and
// models inside come from whatever is on the network, so they get the same
// sanitizing treatment as anything from NTS.
function castDevices(raw) {
  if (!raw || !raw.length) return []
  var out = []
  for (var i = 0; i < raw.length && out.length < 12; i++) {
    var entry = raw[i]
    if (!entry || typeof entry !== "object") continue
    var uuid = plainText(entry.uuid, 80)
    if (!/^[A-Za-z0-9-]{8,80}$/.test(uuid)) continue
    var name = plainText(entry.name, 60)
    out.push({
      uuid: uuid,
      name: name === "" ? "Cast device" : name,
      model: plainText(entry.model, 60)
    })
  }
  return out
}

function hasDevice(devices, uuid) {
  if (!devices || !devices.length) return false
  for (var i = 0; i < devices.length; i++) {
    if (devices[i].uuid === String(uuid)) return true
  }
  return false
}

function deviceName(devices, uuid, fallback) {
  if (devices) {
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].uuid === String(uuid)) return devices[i].name
    }
  }
  return fallback === undefined ? "" : fallback
}

// Output selection is persisted, so it has to survive a round trip through
// shell.json as plain strings.
function outputModeFromSetting(value) {
  return String(value || "") === "cast" ? "cast" : "local"
}

function clampVolume(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 70
  return Math.max(0, Math.min(100, n))
}

// mpv JSON IPC is newline-delimited; a command is one object per line.
function ipcCommand(args, requestId) {
  var payload = { command: args }
  if (requestId !== undefined) payload.request_id = requestId
  return JSON.stringify(payload) + "\n"
}

function parseIpcLine(line) {
  try {
    var parsed = JSON.parse(String(line || ""))
    return parsed && typeof parsed === "object" ? parsed : null
  } catch (e) {
    return null
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    LIVE_ENDPOINT: LIVE_ENDPOINT,
    STREAM_ENDPOINTS: STREAM_ENDPOINTS,
    SITE_URL: SITE_URL,
    CHANNELS: CHANNELS,
    channelNumber: channelNumber,
    channelLabel: channelLabel,
    streamUrl: streamUrl,
    channelFromSetting: channelFromSetting,
    channelSettingValue: channelSettingValue,
    decodeEntities: decodeEntities,
    plainText: plainText,
    safeArtwork: safeArtwork,
    safeAlias: safeAlias,
    parseTimestamp: parseTimestamp,
    emptyShow: emptyShow,
    showFromEntry: showFromEntry,
    emptyChannel: emptyChannel,
    parseLive: parseLive,
    progressFraction: progressFraction,
    minutesRemaining: minutesRemaining,
    remainingLabel: remainingLabel,
    barTitle: barTitle,
    mprisTitle: mprisTitle,
    nextRefreshDelay: nextRefreshDelay,
    castDevices: castDevices,
    hasDevice: hasDevice,
    deviceName: deviceName,
    outputModeFromSetting: outputModeFromSetting,
    clampVolume: clampVolume,
    ipcCommand: ipcCommand,
    parseIpcLine: parseIpcLine
  }
}

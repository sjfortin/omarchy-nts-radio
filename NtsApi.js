// Archive data layer for the NTS Radio plugin.
//
// Model.js owns the live schedule; this file owns everything else NTS
// publishes — search, shows, episodes, tracklists, and the editorial
// collections on the home page. Same contract as Model.js: pure functions,
// no QML types, no side effects, no network. The QML layer fetches (curl in a
// Process) and hands the raw body here.
//
// Endpoint notes, from reading the nts.live player bundle rather than any
// documentation — there is no published API:
//
//   * /search REQUIRES version=2. Without it the endpoint answers 200 with an
//     empty results[] forever, which looks exactly like "no matches" and is
//     the single easiest way to conclude search is broken when it is not.
//   * Episodes are not hosted by NTS. Every archived show points at SoundCloud
//     or Mixcloud through audio_sources[], which is why playback needs yt-dlp.
//   * /resolve-stream would hand back a direct URL, but only against NTS's own
//     Basic token embedded in their page. Borrowing a company's client
//     credential to ship in a plugin is not on; yt-dlp reaches the same public
//     audio without it.

.import "Model.js" as Model

// ------------------------------------------------------------------ endpoints

var API = "https://www.nts.live/api/v2"

// Audio we are willing to hand to mpv. audio_sources[] is attacker-influenced
// data the same way an artwork URL is, and the consumer here is a subprocess
// with a URL resolver attached, so it gets an allowlist rather than a scheme
// check. Only the two hosts NTS actually publishes to.
var AUDIO_HOSTS = /^https:\/\/(?:[a-z0-9-]+\.)?(?:soundcloud\.com|mixcloud\.com)\//

// The editorial rails on the home page. Both are public.
var COLLECTIONS = {
  picks: "nts-picks",
  recent: "recently-added"
}

// What the search endpoint will group for us. `track` and `tag` are queried
// separately from the rest because NTS returns them from different indexes and
// mixing them into one request buries the shows.
var SEARCH_TYPES = ["show", "episode"]
var SEARCH_TYPES_TRACK = ["track"]
var SEARCH_TYPES_TAG = ["tag"]

function encode(value) {
  return encodeURIComponent(String(value === undefined || value === null ? "" : value))
}

function clampInt(value, low, high, fallback) {
  var n = Math.floor(Number(value))
  if (!isFinite(n)) return fallback
  return Math.max(low, Math.min(high, n))
}

// A query is the one piece of user input that reaches a URL. Cap it and let
// encodeURIComponent do the escaping.
function searchUrl(query, types, limit, offset) {
  var list = Array.isArray(types) && types.length ? types : SEARCH_TYPES
  var parts = [
    "q=" + encode(String(query || "").slice(0, 120)),
    // Not optional. See the header comment.
    "version=2",
    "offset=" + clampInt(offset, 0, 5000, 0),
    "limit=" + clampInt(limit, 1, 40, 12)
  ]
  for (var i = 0; i < list.length; i++) parts.push("types%5B%5D=" + encode(list[i]))
  return API + "/search?" + parts.join("&")
}

function showUrl(alias) {
  var safe = Model.safeAlias(alias)
  return safe ? API + "/shows/" + encode(safe) : ""
}

function showEpisodesUrl(alias, limit, offset) {
  var safe = Model.safeAlias(alias)
  if (!safe) return ""
  return API + "/shows/" + encode(safe) + "/episodes?limit="
    + clampInt(limit, 1, 40, 16) + "&offset=" + clampInt(offset, 0, 5000, 0)
}

function episodeUrl(showAlias, episodeAlias) {
  var show = Model.safeAlias(showAlias)
  var episode = Model.safeAlias(episodeAlias)
  if (!show || !episode) return ""
  return API + "/shows/" + encode(show) + "/episodes/" + encode(episode)
}

function tracklistUrl(showAlias, episodeAlias) {
  var base = episodeUrl(showAlias, episodeAlias)
  return base ? base + "/tracklist" : ""
}

function collectionUrl(which, limit) {
  var name = COLLECTIONS[which] || COLLECTIONS.recent
  return API + "/collections/" + name + "?limit=" + clampInt(limit, 1, 24, 8)
}

// Public site URLs, for "Open on nts.live".
function siteShowUrl(alias) {
  var safe = Model.safeAlias(alias)
  return safe ? Model.SITE_URL + "/shows/" + safe : Model.SITE_URL
}

function siteEpisodeUrl(showAlias, episodeAlias) {
  var show = Model.safeAlias(showAlias)
  var episode = Model.safeAlias(episodeAlias)
  if (!show) return Model.SITE_URL
  return episode
    ? Model.SITE_URL + "/shows/" + show + "/episodes/" + episode
    : Model.SITE_URL + "/shows/" + show
}

// ------------------------------------------------------------- sanitization

// The only URL in this file that becomes a subprocess argument.
function safeAudioUrl(value) {
  var url = String(value === undefined || value === null ? "" : value)
  if (url.length > 600) return ""
  return AUDIO_HOSTS.test(url) ? url : ""
}

// Search results carry the destination as a site path — "/shows/floating-points"
// or "/shows/x/episodes/y" — rather than aliases. Pull the aliases back out,
// rejecting anything that is not exactly one of those two shapes.
function aliasesFromPath(value) {
  var path = String(value === undefined || value === null ? "" : value)
  var episodeMatch = path.match(/^\/shows\/([^/?#]+)\/episodes\/([^/?#]+)\/?$/)
  if (episodeMatch) {
    return {
      showAlias: Model.safeAlias(decodeSegment(episodeMatch[1])),
      episodeAlias: Model.safeAlias(decodeSegment(episodeMatch[2]))
    }
  }
  var showMatch = path.match(/^\/shows\/([^/?#]+)\/?$/)
  if (showMatch) {
    return { showAlias: Model.safeAlias(decodeSegment(showMatch[1])), episodeAlias: "" }
  }
  return { showAlias: "", episodeAlias: "" }
}

function decodeSegment(value) {
  try {
    return decodeURIComponent(String(value))
  } catch (e) {
    return String(value)
  }
}

function parseJson(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    return data && typeof data === "object" ? data : null
  } catch (e) {
    return null
  }
}

function genreList(source, limit) {
  var max = limit === undefined ? 4 : limit
  var out = []
  if (!Array.isArray(source)) return out
  for (var i = 0; i < source.length && out.length < max; i++) {
    var entry = source[i]
    // /shows uses {value}, /search uses {name}. Both appear on episodes.
    var label = Model.plainText(entry && (entry.value !== undefined ? entry.value : entry.name), 40)
    if (label) out.push(label)
  }
  return out
}

function pickArtwork(media) {
  var source = media && typeof media === "object" ? media : {}
  var small = Model.safeArtwork(source.picture_medium || source.background_medium
    || source.picture_small || source.background_small)
  var large = Model.safeArtwork(source.picture_medium_large || source.background_medium_large
    || source.picture_large || source.background_large)
  return { small: small || large, large: large || small }
}

// ------------------------------------------------------------------- models

function emptyEpisode() {
  return {
    kind: "episode",
    showAlias: "",
    episodeAlias: "",
    name: "",
    showName: "",
    description: "",
    location: "",
    genres: [],
    artworkSmall: "",
    artworkLarge: "",
    broadcastMs: 0,
    // Set only on search results, which give a rendered date rather than a
    // timestamp. episodeMeta prefers it when present.
    dateLabel: "",
    audioUrl: "",
    audioSource: "",
    url: "",
    valid: false
  }
}

function emptyShow() {
  return {
    kind: "show",
    alias: "",
    name: "",
    description: "",
    location: "",
    genres: [],
    moods: [],
    artworkSmall: "",
    artworkLarge: "",
    externalLinks: [],
    url: "",
    episodeCount: 0,
    valid: false
  }
}

// One entry from /shows/{alias}/episodes, /collections/*, or embeds.episodes —
// they are all the same episode object.
function episodeFromEntry(entry) {
  var episode = emptyEpisode()
  if (!entry || typeof entry !== "object") return episode

  episode.showAlias = Model.safeAlias(entry.show_alias)
  episode.episodeAlias = Model.safeAlias(entry.episode_alias)
  episode.name = Model.plainText(entry.name)
  episode.description = Model.plainText(entry.description, 900)
  episode.location = Model.plainText(entry.location_long || entry.location_short, 60)
  episode.genres = genreList(entry.genres)

  var art = pickArtwork(entry.media)
  episode.artworkSmall = art.small
  episode.artworkLarge = art.large

  episode.broadcastMs = Model.parseTimestamp(entry.broadcast)

  // Prefer whatever NTS lists first; fall back to the bare mixcloud field,
  // which older episodes carry instead of an audio_sources entry.
  if (Array.isArray(entry.audio_sources)) {
    for (var i = 0; i < entry.audio_sources.length && !episode.audioUrl; i++) {
      var source = entry.audio_sources[i]
      if (!source || typeof source !== "object") continue
      var url = safeAudioUrl(source.url)
      if (!url) continue
      episode.audioUrl = url
      episode.audioSource = Model.plainText(source.source, 20)
    }
  }
  if (!episode.audioUrl) {
    var mixcloud = safeAudioUrl(entry.mixcloud)
    if (mixcloud) {
      episode.audioUrl = mixcloud
      episode.audioSource = "mixcloud"
    }
  }

  episode.url = siteEpisodeUrl(episode.showAlias, episode.episodeAlias)
  episode.valid = episode.name !== "" && episode.episodeAlias !== ""
  return episode
}

// /shows/{alias}. `embeds.episodes.results` rides along, so one request fills
// both the header and the first page of the episode list.
function parseShow(raw) {
  var data = parseJson(raw)
  if (!data) return null

  var show = emptyShow()
  show.alias = Model.safeAlias(data.show_alias)
  show.name = Model.plainText(data.name)
  show.description = Model.plainText(data.description, 900)
  show.location = Model.plainText(data.location_long || data.location_short, 60)
  show.genres = genreList(data.genres)
  show.moods = genreList(data.moods, 3)

  var art = pickArtwork(data.media)
  show.artworkSmall = art.small
  show.artworkLarge = art.large
  show.url = siteShowUrl(show.alias)
  show.valid = show.name !== ""

  if (Array.isArray(data.external_links)) {
    for (var i = 0; i < data.external_links.length && show.externalLinks.length < 4; i++) {
      var link = String(data.external_links[i] || "")
      // Only ever https, and only ever handed to xdg-open.
      if (/^https:\/\/[a-zA-Z0-9.-]+\//.test(link) && link.length < 300)
        show.externalLinks.push(link)
    }
  }

  var episodes = []
  if (data.embeds && data.embeds.episodes && Array.isArray(data.embeds.episodes.results))
    episodes = episodeListFromResults(data.embeds.episodes.results)

  return { show: show, episodes: episodes }
}

function episodeListFromResults(results) {
  var out = []
  if (!Array.isArray(results)) return out
  for (var i = 0; i < results.length && out.length < 60; i++) {
    var episode = episodeFromEntry(results[i])
    if (episode.valid) out.push(episode)
  }
  return out
}

// /shows/{alias}/episodes and /collections/*.
function parseEpisodeList(raw) {
  var data = parseJson(raw)
  if (!data) return null
  var total = 0
  if (data.metadata && data.metadata.resultset)
    total = clampInt(data.metadata.resultset.count, 0, 100000, 0)
  var episodes = episodeListFromResults(data.results)
  return { episodes: episodes, total: total || episodes.length }
}

// A single /shows/{a}/episodes/{e}. Same shape as a list entry.
function parseEpisode(raw) {
  var data = parseJson(raw)
  if (!data) return null
  var episode = episodeFromEntry(data)
  return episode.valid ? episode : null
}

// ---------------------------------------------------------------- tracklist

function emptyTrack() {
  return { artist: "", title: "", offsetSec: -1, durationSec: 0,
    estimated: false, valid: false }
}

// offset is seconds into the recording, which is exactly what mpv seeks to.
//
// Two traps here. NTS only fingerprints part of a tracklist, so `offset` is
// frequently null and the position lives in `offset_estimate` instead — their
// own player falls back to it, and so does this. And `Number(null)` is 0, not
// NaN, so a null offset sails through an isFinite check and lands every
// untimed track at the very start of the show. Both have to be rejected
// explicitly before the number is taken.
function numberOrNull(value) {
  if (value === null || value === undefined || value === "") return null
  var number = Number(value)
  return isFinite(number) ? number : null
}

function trackFromEntry(entry) {
  var track = emptyTrack()
  if (!entry || typeof entry !== "object") return track
  track.artist = Model.plainText(entry.artist, 120)
  track.title = Model.plainText(entry.title, 160)

  var offset = numberOrNull(entry.offset)
  if (offset === null) {
    offset = numberOrNull(entry.offset_estimate)
    // Worth distinguishing: an estimate is evenly spaced rather than heard,
    // so it can be out by a minute or so.
    if (offset !== null) track.estimated = true
  }
  if (offset !== null && offset >= 0 && offset < 86400) track.offsetSec = Math.floor(offset)

  var duration = numberOrNull(entry.duration)
  if (duration === null) duration = numberOrNull(entry.duration_estimate)
  if (duration !== null && duration > 0 && duration < 86400)
    track.durationSec = Math.floor(duration)

  track.valid = track.artist !== "" || track.title !== ""
  return track
}

function parseTracklist(raw) {
  var data = parseJson(raw)
  if (!data || !Array.isArray(data.results)) return null
  var out = []
  for (var i = 0; i < data.results.length && out.length < 200; i++) {
    var track = trackFromEntry(data.results[i])
    if (track.valid) out.push(track)
  }
  return out
}

// ------------------------------------------------------------------- search
//
// Results come back flat with an `article_type` discriminator. The UI groups
// them, so parsing normalizes each row into the same episode/show models used
// everywhere else and stamps the group on it.

function emptySearchResults() {
  return { shows: [], episodes: [], tracks: [], tags: [], total: 0, popular: [] }
}

function searchImage(image) {
  var source = image && typeof image === "object" ? image : {}
  var small = Model.safeArtwork(source.medium || source.small || source.thumb)
  var large = Model.safeArtwork(source.medium_large || source.large || source.medium)
  return { small: small || large, large: large || small }
}

function parseSearch(raw) {
  var data = parseJson(raw)
  if (!data) return null

  var out = emptySearchResults()

  if (data.metadata) {
    if (data.metadata.resultset)
      out.total = clampInt(data.metadata.resultset.count, 0, 1000000, 0)
    if (Array.isArray(data.metadata.popular_terms)) {
      for (var p = 0; p < data.metadata.popular_terms.length && out.popular.length < 8; p++) {
        var term = Model.plainText(data.metadata.popular_terms[p], 40)
        if (term) out.popular.push(term)
      }
    }
  }

  if (!Array.isArray(data.results)) return out

  for (var i = 0; i < data.results.length && i < 60; i++) {
    var row = data.results[i]
    if (!row || typeof row !== "object") continue

    var type = String(row.article_type || "")
    var path = row.article && typeof row.article === "object" ? row.article.path : ""
    var aliases = aliasesFromPath(path)
    var image = searchImage(row.image)
    var title = Model.plainText(row.title)

    if (type === "show" && aliases.showAlias) {
      var show = emptyShow()
      show.alias = aliases.showAlias
      show.name = title
      show.description = Model.plainText(
        row.description && row.description.highlight_plain, 200).replace(/\*/g, "")
      show.location = Model.plainText(row.location, 60)
      show.genres = genreList(row.genres, 3)
      show.artworkSmall = image.small
      show.artworkLarge = image.large
      show.url = siteShowUrl(show.alias)
      show.valid = show.name !== ""
      if (show.valid) out.shows.push(show)
      continue
    }

    if (type === "episode" && aliases.episodeAlias) {
      var episode = emptyEpisode()
      episode.showAlias = aliases.showAlias
      episode.episodeAlias = aliases.episodeAlias
      episode.name = title
      episode.description = Model.plainText(
        row.description && row.description.highlight_plain, 200).replace(/\*/g, "")
      episode.location = Model.plainText(row.location, 60)
      episode.genres = genreList(row.genres, 3)
      episode.artworkSmall = image.small
      episode.artworkLarge = image.large
      // Search rows carry a display date, not a timestamp. Keep the text.
      episode.dateLabel = Model.plainText(row.local_date, 40)
      if (Array.isArray(row.audio_sources)) {
        for (var a = 0; a < row.audio_sources.length && !episode.audioUrl; a++) {
          var candidate = row.audio_sources[a]
          var audio = safeAudioUrl(candidate && candidate.url)
          if (!audio) continue
          episode.audioUrl = audio
          episode.audioSource = Model.plainText(candidate.source, 20)
        }
      }
      episode.url = siteEpisodeUrl(episode.showAlias, episode.episodeAlias)
      episode.valid = episode.name !== ""
      if (episode.valid) out.episodes.push(episode)
      continue
    }

    if (type === "track") {
      var artists = []
      if (Array.isArray(row.artists)) {
        for (var t = 0; t < row.artists.length && artists.length < 3; t++) {
          var name = Model.plainText(
            row.artists[t] && (row.artists[t].name !== undefined ? row.artists[t].name : row.artists[t]), 80)
          if (name) artists.push(name)
        }
      }
      // A track's value is the episode it was played on, and that link lives
      // in article.path — `related_episode` is present but empty on every row
      // the search index returns. article.title is the episode's name, which
      // is the only context that makes a bare track row worth showing.
      if (!title && !artists.length) continue
      out.tracks.push({
        kind: "track",
        title: title,
        artist: artists.join(", "),
        showAlias: aliases.showAlias,
        episodeAlias: aliases.episodeAlias,
        episodeName: Model.plainText(row.article && row.article.title, 120),
        artworkSmall: image.small,
        dateLabel: Model.plainText(row.local_date, 40),
        valid: true
      })
      continue
    }

    if (type === "tag" || type === "genre" || type === "mood") {
      if (!title) continue
      out.tags.push({ kind: "tag", name: title, valid: true })
    }
  }

  return out
}

// ---------------------------------------------------------------- formatting

function pad2(value) {
  return value < 10 ? "0" + value : String(value)
}

// Seconds -> H:MM:SS or M:SS. Used for both track offsets and playback
// position, so an archive's clock and its tracklist agree on shape.
function clockFromSeconds(seconds) {
  var total = Math.max(0, Math.floor(Number(seconds) || 0))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var secs = total % 60
  return hours > 0
    ? hours + ":" + pad2(minutes) + ":" + pad2(secs)
    : minutes + ":" + pad2(secs)
}

// "3 Sep 2026" — the same shape NTS prints under a show card.
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function dateLabel(ms) {
  var value = Number(ms)
  if (!isFinite(value) || value <= 0) return ""
  var date = new Date(value)
  return date.getDate() + " " + MONTHS[date.getMonth()] + " " + date.getFullYear()
}

// What an episode row shows under its title.
function episodeMeta(episode) {
  if (!episode) return ""
  var parts = []
  var when = episode.dateLabel || dateLabel(episode.broadcastMs)
  if (when) parts.push(when)
  if (episode.location) parts.push(episode.location)
  for (var i = 0; i < episode.genres.length && parts.length < 4; i++) parts.push(episode.genres[i])
  return parts.join(" · ")
}

// A stable key for an episode, used by the local library and by the "is this
// the thing that is playing" checks.
function episodeKey(episode) {
  if (!episode) return ""
  if (episode.showAlias && episode.episodeAlias)
    return episode.showAlias + "/" + episode.episodeAlias
  return ""
}

function sameEpisode(a, b) {
  var keyA = episodeKey(a)
  return keyA !== "" && keyA === episodeKey(b)
}

if (typeof module !== "undefined") {
  module.exports = {
    API: API,
    AUDIO_HOSTS: AUDIO_HOSTS,
    COLLECTIONS: COLLECTIONS,
    SEARCH_TYPES: SEARCH_TYPES,
    SEARCH_TYPES_TRACK: SEARCH_TYPES_TRACK,
    SEARCH_TYPES_TAG: SEARCH_TYPES_TAG,
    searchUrl: searchUrl,
    showUrl: showUrl,
    showEpisodesUrl: showEpisodesUrl,
    episodeUrl: episodeUrl,
    tracklistUrl: tracklistUrl,
    collectionUrl: collectionUrl,
    siteShowUrl: siteShowUrl,
    siteEpisodeUrl: siteEpisodeUrl,
    safeAudioUrl: safeAudioUrl,
    aliasesFromPath: aliasesFromPath,
    emptyEpisode: emptyEpisode,
    emptyShow: emptyShow,
    episodeFromEntry: episodeFromEntry,
    parseShow: parseShow,
    parseEpisodeList: parseEpisodeList,
    parseEpisode: parseEpisode,
    emptyTrack: emptyTrack,
    parseTracklist: parseTracklist,
    emptySearchResults: emptySearchResults,
    parseSearch: parseSearch,
    clockFromSeconds: clockFromSeconds,
    dateLabel: dateLabel,
    episodeMeta: episodeMeta,
    episodeKey: episodeKey,
    sameEpisode: sameEpisode
  }
}

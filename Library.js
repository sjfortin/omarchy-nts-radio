// The local library: saved shows, saved episodes, and resume positions.
//
// This is Phase 2's answer to "saved content" after the account investigation
// came back negative. NTS authenticates through Firebase with an email/password
// provider and publishes no third-party integration surface, so a "log in"
// button here could only mean taking the user's real NTS password in a QML
// form and replaying it against Google with NTS's own embedded API key. That is
// the credential scraping the brief rules out, so the library is local instead:
// a file the user owns, in their own state directory, that works offline and
// cannot leak an account.
//
// Same contract as Model.js and NtsApi.js: pure functions, no QML types, no
// side effects, no IO. The QML layer reads and writes the file.
//
// The file is user-editable and holds strings that originally came off the
// network, so load() re-sanitizes everything rather than trusting what it
// parses — a hand-edited library must not be able to put markup into a Text
// item or an arbitrary URL into mpv.

.import "Model.js" as Model
.import "NtsApi.js" as NtsApi

var VERSION = 1

// Bounds so the file cannot grow without limit. Generous enough that nobody
// reaches them by listening; small enough that the whole thing stays a cheap
// synchronous read at startup.
var MAX_SHOWS = 300
var MAX_EPISODES = 500
var MAX_RESUME = 200

// Below this many seconds in, "continue listening" is really "start again",
// and past this fraction the episode is finished. Both ends are dropped from
// the resume list so it stays a useful shelf rather than a log.
var RESUME_MIN_SECONDS = 60
var RESUME_DONE_FRACTION = 0.97

function emptyLibrary() {
  return { version: VERSION, shows: [], episodes: [], resume: [] }
}

// ------------------------------------------------------------------- loading

function savedShowFromEntry(entry) {
  if (!entry || typeof entry !== "object") return null
  var alias = Model.safeAlias(entry.alias)
  if (!alias) return null
  return {
    kind: "show",
    alias: alias,
    name: Model.plainText(entry.name) || alias,
    artworkSmall: Model.safeArtwork(entry.artworkSmall),
    artworkLarge: Model.safeArtwork(entry.artworkLarge),
    location: Model.plainText(entry.location, 60),
    savedAt: Model.parseTimestamp(entry.savedAt) || Number(entry.savedAt) || 0,
    valid: true
  }
}

function savedEpisodeFromEntry(entry) {
  if (!entry || typeof entry !== "object") return null
  var showAlias = Model.safeAlias(entry.showAlias)
  var episodeAlias = Model.safeAlias(entry.episodeAlias)
  if (!showAlias || !episodeAlias) return null
  return {
    kind: "episode",
    showAlias: showAlias,
    episodeAlias: episodeAlias,
    name: Model.plainText(entry.name) || episodeAlias,
    showName: Model.plainText(entry.showName),
    description: "",
    location: Model.plainText(entry.location, 60),
    genres: [],
    artworkSmall: Model.safeArtwork(entry.artworkSmall),
    artworkLarge: Model.safeArtwork(entry.artworkLarge),
    broadcastMs: Number(entry.broadcastMs) || 0,
    // Search rows carry a rendered date ("3 Sep 2026") instead of a timestamp,
    // so keeping only broadcastMs would drop the date from anything saved out
    // of a search. NtsApi.episodeMeta prefers this when it is set.
    dateLabel: Model.plainText(entry.dateLabel, 40),
    // Re-checked against the allowlist: this string is a subprocess argument.
    audioUrl: NtsApi.safeAudioUrl(entry.audioUrl),
    audioSource: Model.plainText(entry.audioSource, 20),
    url: NtsApi.siteEpisodeUrl(showAlias, episodeAlias),
    savedAt: Number(entry.savedAt) || 0,
    valid: true
  }
}

function resumeFromEntry(entry) {
  if (!entry || typeof entry !== "object") return null
  var showAlias = Model.safeAlias(entry.showAlias)
  var episodeAlias = Model.safeAlias(entry.episodeAlias)
  if (!showAlias || !episodeAlias) return null
  var position = Math.floor(Number(entry.positionSec))
  if (!isFinite(position) || position < 0 || position > 86400) return null
  var duration = Math.floor(Number(entry.durationSec))
  if (!isFinite(duration) || duration < 0 || duration > 86400) duration = 0
  return {
    kind: "episode",
    showAlias: showAlias,
    episodeAlias: episodeAlias,
    name: Model.plainText(entry.name) || episodeAlias,
    showName: Model.plainText(entry.showName),
    artworkSmall: Model.safeArtwork(entry.artworkSmall),
    artworkLarge: Model.safeArtwork(entry.artworkLarge),
    broadcastMs: Number(entry.broadcastMs) || 0,
    dateLabel: Model.plainText(entry.dateLabel, 40),
    audioUrl: NtsApi.safeAudioUrl(entry.audioUrl),
    audioSource: Model.plainText(entry.audioSource, 20),
    url: NtsApi.siteEpisodeUrl(showAlias, episodeAlias),
    positionSec: position,
    durationSec: duration,
    updatedAt: Number(entry.updatedAt) || 0,
    genres: [],
    description: "",
    location: "",
    valid: true
  }
}

function mapValid(source, convert, limit) {
  var out = []
  if (!Array.isArray(source)) return out
  for (var i = 0; i < source.length && out.length < limit; i++) {
    var value = convert(source[i])
    if (value) out.push(value)
  }
  return out
}

// A missing or unreadable file is an empty library, never an error: the
// library is a convenience, and losing it must not stop the browser opening.
function load(raw) {
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    return emptyLibrary()
  }
  if (!data || typeof data !== "object") return emptyLibrary()

  return {
    version: VERSION,
    shows: mapValid(data.shows, savedShowFromEntry, MAX_SHOWS),
    episodes: mapValid(data.episodes, savedEpisodeFromEntry, MAX_EPISODES),
    resume: mapValid(data.resume, resumeFromEntry, MAX_RESUME)
  }
}

// Only the fields worth persisting; the rest are rebuilt on load.
function serialize(library) {
  var source = library && typeof library === "object" ? library : emptyLibrary()
  return JSON.stringify({
    version: VERSION,
    shows: (source.shows || []).map(function(show) {
      return {
        alias: show.alias,
        name: show.name,
        artworkSmall: show.artworkSmall,
        artworkLarge: show.artworkLarge,
        location: show.location,
        savedAt: show.savedAt
      }
    }),
    episodes: (source.episodes || []).map(function(episode) {
      return {
        showAlias: episode.showAlias,
        episodeAlias: episode.episodeAlias,
        name: episode.name,
        showName: episode.showName,
        artworkSmall: episode.artworkSmall,
        artworkLarge: episode.artworkLarge,
        location: episode.location,
        broadcastMs: episode.broadcastMs,
        dateLabel: episode.dateLabel,
        audioUrl: episode.audioUrl,
        audioSource: episode.audioSource,
        savedAt: episode.savedAt
      }
    }),
    resume: (source.resume || []).map(function(entry) {
      return {
        showAlias: entry.showAlias,
        episodeAlias: entry.episodeAlias,
        name: entry.name,
        showName: entry.showName,
        artworkSmall: entry.artworkSmall,
        artworkLarge: entry.artworkLarge,
        broadcastMs: entry.broadcastMs,
        dateLabel: entry.dateLabel,
        audioUrl: entry.audioUrl,
        audioSource: entry.audioSource,
        positionSec: entry.positionSec,
        durationSec: entry.durationSec,
        updatedAt: entry.updatedAt
      }
    })
  }, null, 2)
}

// ------------------------------------------------------------------ queries

function hasShow(library, alias) {
  var wanted = Model.safeAlias(alias)
  if (!wanted || !library || !Array.isArray(library.shows)) return false
  for (var i = 0; i < library.shows.length; i++)
    if (library.shows[i].alias === wanted) return true
  return false
}

function hasEpisode(library, episode) {
  var key = NtsApi.episodeKey(episode)
  if (!key || !library || !Array.isArray(library.episodes)) return false
  for (var i = 0; i < library.episodes.length; i++)
    if (NtsApi.episodeKey(library.episodes[i]) === key) return true
  return false
}

function resumeFor(library, episode) {
  var key = NtsApi.episodeKey(episode)
  if (!key || !library || !Array.isArray(library.resume)) return null
  for (var i = 0; i < library.resume.length; i++)
    if (NtsApi.episodeKey(library.resume[i]) === key) return library.resume[i]
  return null
}

function resumePosition(library, episode) {
  var entry = resumeFor(library, episode)
  return entry ? entry.positionSec : 0
}

// ------------------------------------------------------------------ mutation
//
// Every mutator returns a new library object rather than editing in place, so
// QML notices the change: assigning a mutated `var` property to itself does
// not re-evaluate bindings.

function cloneLibrary(library) {
  var source = library && typeof library === "object" ? library : emptyLibrary()
  return {
    version: VERSION,
    shows: (source.shows || []).slice(),
    episodes: (source.episodes || []).slice(),
    resume: (source.resume || []).slice()
  }
}

// Newest first, so "recently saved" is just the head of the list.
function toggleShow(library, show, nowMs) {
  var next = cloneLibrary(library)
  var alias = Model.safeAlias(show && show.alias)
  if (!alias) return next

  var existing = -1
  for (var i = 0; i < next.shows.length; i++)
    if (next.shows[i].alias === alias) { existing = i; break }

  if (existing !== -1) {
    next.shows.splice(existing, 1)
    return next
  }

  next.shows.unshift({
    kind: "show",
    alias: alias,
    name: Model.plainText(show.name) || alias,
    artworkSmall: Model.safeArtwork(show.artworkSmall),
    artworkLarge: Model.safeArtwork(show.artworkLarge),
    location: Model.plainText(show.location, 60),
    savedAt: Number(nowMs) || 0,
    valid: true
  })
  if (next.shows.length > MAX_SHOWS) next.shows.length = MAX_SHOWS
  return next
}

function toggleEpisode(library, episode, nowMs) {
  var next = cloneLibrary(library)
  var key = NtsApi.episodeKey(episode)
  if (!key) return next

  var existing = -1
  for (var i = 0; i < next.episodes.length; i++)
    if (NtsApi.episodeKey(next.episodes[i]) === key) { existing = i; break }

  if (existing !== -1) {
    next.episodes.splice(existing, 1)
    return next
  }

  next.episodes.unshift({
    kind: "episode",
    showAlias: episode.showAlias,
    episodeAlias: episode.episodeAlias,
    name: Model.plainText(episode.name),
    showName: Model.plainText(episode.showName),
    location: Model.plainText(episode.location, 60),
    artworkSmall: Model.safeArtwork(episode.artworkSmall),
    artworkLarge: Model.safeArtwork(episode.artworkLarge),
    broadcastMs: Number(episode.broadcastMs) || 0,
    dateLabel: Model.plainText(episode.dateLabel, 40),
    audioUrl: NtsApi.safeAudioUrl(episode.audioUrl),
    audioSource: Model.plainText(episode.audioSource, 20),
    url: NtsApi.siteEpisodeUrl(episode.showAlias, episode.episodeAlias),
    description: "",
    genres: [],
    savedAt: Number(nowMs) || 0,
    valid: true
  })
  if (next.episodes.length > MAX_EPISODES) next.episodes.length = MAX_EPISODES
  return next
}

// Called on a timer while an archive plays, so it has to be cheap and it has
// to be idempotent. Returns the same object when nothing would change, which
// is what lets the caller skip the disk write.
function noteProgress(library, episode, positionSec, durationSec, nowMs) {
  var key = NtsApi.episodeKey(episode)
  if (!key) return library

  var position = Math.floor(Number(positionSec))
  if (!isFinite(position) || position < 0) return library
  var duration = Math.floor(Number(durationSec)) || 0

  var finished = duration > 0 && position >= duration * RESUME_DONE_FRACTION
  var tooEarly = position < RESUME_MIN_SECONDS

  var next = cloneLibrary(library)
  var existing = -1
  for (var i = 0; i < next.resume.length; i++)
    if (NtsApi.episodeKey(next.resume[i]) === key) { existing = i; break }

  // Reaching the end, or scrubbing back to the top, retires the entry.
  if (finished || tooEarly) {
    if (existing === -1) return library
    next.resume.splice(existing, 1)
    return next
  }

  if (existing !== -1) {
    var current = next.resume[existing]
    // A second either way is not worth a disk write.
    if (Math.abs(current.positionSec - position) < 5 && current.durationSec === duration)
      return library
    next.resume.splice(existing, 1)
  }

  next.resume.unshift({
    kind: "episode",
    showAlias: episode.showAlias,
    episodeAlias: episode.episodeAlias,
    name: Model.plainText(episode.name),
    showName: Model.plainText(episode.showName),
    artworkSmall: Model.safeArtwork(episode.artworkSmall),
    artworkLarge: Model.safeArtwork(episode.artworkLarge),
    broadcastMs: Number(episode.broadcastMs) || 0,
    dateLabel: Model.plainText(episode.dateLabel, 40),
    audioUrl: NtsApi.safeAudioUrl(episode.audioUrl),
    audioSource: Model.plainText(episode.audioSource, 20),
    url: NtsApi.siteEpisodeUrl(episode.showAlias, episode.episodeAlias),
    positionSec: position,
    durationSec: duration,
    updatedAt: Number(nowMs) || 0,
    description: "",
    genres: [],
    location: "",
    valid: true
  })
  if (next.resume.length > MAX_RESUME) next.resume.length = MAX_RESUME
  return next
}

function clearResume(library, episode) {
  var key = NtsApi.episodeKey(episode)
  if (!key) return library
  var next = cloneLibrary(library)
  for (var i = 0; i < next.resume.length; i++) {
    if (NtsApi.episodeKey(next.resume[i]) !== key) continue
    next.resume.splice(i, 1)
    return next
  }
  return library
}

// How far through, for the thin rule under a "continue listening" card.
function resumeFraction(entry) {
  if (!entry || !entry.durationSec) return 0
  return Math.max(0, Math.min(1, entry.positionSec / entry.durationSec))
}

if (typeof module !== "undefined") {
  module.exports = {
    VERSION: VERSION,
    MAX_SHOWS: MAX_SHOWS,
    MAX_EPISODES: MAX_EPISODES,
    MAX_RESUME: MAX_RESUME,
    emptyLibrary: emptyLibrary,
    load: load,
    serialize: serialize,
    hasShow: hasShow,
    hasEpisode: hasEpisode,
    resumeFor: resumeFor,
    resumePosition: resumePosition,
    toggleShow: toggleShow,
    toggleEpisode: toggleEpisode,
    noteProgress: noteProgress,
    clearResume: clearResume,
    resumeFraction: resumeFraction
  }
}

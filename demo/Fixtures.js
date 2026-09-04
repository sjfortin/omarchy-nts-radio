// Canned responses for demo mode.
//
// Everything here is invented: the shows, the hosts, the episode titles and the
// cover art in demo/art are all original. Nothing NTS broadcasts, and nothing
// NTS's programme artwork depicts, appears in a screenshot taken this way —
// which is what makes the marketing assets ours to publish.
//
// It also makes the UI testable. Live radio changes every hour, so a bug in how
// a long title wraps, or an episode with no audio, or an empty search is
// otherwise a matter of waiting for one to come along. Here they are always
// there, and always the same.
//
// Responses are shaped exactly like the real endpoints, so they go through the
// same parsers as production data rather than around them.

.import "../Model.js" as Model

var SHOWS = [
  { alias: "tape-hiss", name: "Tape Hiss w/ Vela Moss", location: "London",
    genres: ["Ambient", "Drone", "Field Recordings"],
    description: "Four-track wobble, tape saturation and long-form drift. Vela Moss digs through a decade of unlabelled cassettes every fortnight." },
  { alias: "concrete-garden", name: "Concrete Garden", location: "Manchester",
    genres: ["Dub", "Post-Punk", "Industrial"],
    description: "Rhythm and rust. Dub weight, brutalist edges, and whatever came out of the north this month." },
  { alias: "night-ferry", name: "Night Ferry w/ Ida Brun", location: "Lisbon",
    genres: ["Downtempo", "Balearic", "Jazz"],
    description: "Late crossings and slow arrivals. Ida Brun plays for the hours when nowhere is open." },
  { alias: "low-orbit", name: "Low Orbit w/ Kestrel", location: "Glasgow",
    genres: ["Electro", "Techno", "Breakbeat"],
    description: "Transmissions from just above the atmosphere. Kestrel keeps it fast and cold." },
  { alias: "paper-radio", name: "Paper Radio", location: "Brooklyn",
    genres: ["Soul", "Rare Groove", "Funk"],
    description: "Everything pressed, nothing streamed. Records only, dust included." },
  { alias: "morning-static", name: "Morning Static w/ June Adeyemi", location: "Lagos",
    genres: ["Highlife", "Afrobeat", "Disco"],
    description: "The first hour of the day, played loud. June Adeyemi opens the week." },
  { alias: "third-coast", name: "Third Coast Sessions", location: "Chicago",
    genres: ["House", "Deep House", "Gospel"],
    description: "Warehouse lineage, church chords. Guests from the lake shore and beyond." },
  { alias: "sunday-service", name: "Sunday Service — Dub Edition", location: "Kingston",
    genres: ["Roots", "Dub", "Reggae"],
    description: "Two hours of foundation, echo and reverb, every Sunday without fail." }
]

// Two flavours of episode suffix. A show whose name already carries a host
// ("Night Ferry w/ Ida Brun") only ever gets the edition style, so titles do
// not come out reading "w/ Ida Brun w/ Otto Lind".
var GUEST_TITLES = [
  "w/ Marisol Reyes", "w/ Otto Lind", "w/ Priya Raman",
  "w/ The Salt Collective", "w/ Nadia Osei", "w/ Cormac Vale"
]
var EDITION_TITLES = [
  "— Winter Tape", "— Late Edition", "— Harbour Mix",
  "— Anniversary Special", "— Night Shift", "— Closing Set"
]

function suffix(name, n) {
  var list = String(name).indexOf("w/") !== -1 ? EDITION_TITLES : GUEST_TITLES
  return list[((n % list.length) + list.length) % list.length]
}

var TRACKS = [
  ["Halden Bay", "Slow Tide"], ["The Ochre Quartet", "Second Room"],
  ["Nils Aurland", "Paper Boats"], ["Móa", "Winterlight"],
  ["Rue Sardine", "Concrete Waltz"], ["Delta Foxtrot", "Long Way Round"],
  ["Ivy Kwon", "Blue Hour"], ["The Meridian Trio", "Northbound"],
  ["Sable & Vane", "Undertow"], ["Kofi Mensah", "Sunday Best"],
  ["Lantern Club", "Static Bloom"], ["Wren Halloway", "Off Season"],
  ["The Pilot Light", "Signal Fade"], ["Amaru", "Tidewater"],
  ["Junco", "Everything Keeps"], ["Bright Nadir", "Held Note"]
]

// A stable hour grid, so the schedule reads sensibly whenever it is opened.
function hourMs(offsetHours) {
  var now = new Date()
  now.setMinutes(0, 0, 0)
  return now.getTime() + offsetHours * 3600000
}

var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]

// Search results carry a rendered date rather than a timestamp, the same as
// the real endpoint ("03 Jun 2024").
function localDate(ms) {
  var d = new Date(ms)
  var day = d.getDate()
  return (day < 10 ? "0" + day : day) + " " + MONTHS[d.getMonth()] + " " + d.getFullYear()
}

function iso(ms) {
  return new Date(ms).toISOString().replace(/\.\d+Z$/, "+00:00")
}

function show(index) {
  return SHOWS[((index % SHOWS.length) + SHOWS.length) % SHOWS.length]
}

// Which cover a thing gets. Deterministic from its alias, so a show keeps the
// same artwork across every page it appears on.
function coverIndex(key) {
  var text = String(key || "")
  var sum = 0
  for (var i = 0; i < text.length; i++) sum = (sum * 31 + text.charCodeAt(i)) % 100000
  return (sum % 8) + 1
}

// `base` is the plugin directory as a URL, from Qt.resolvedUrl(".") — not the
// injected pluginDir, which is assigned after Component.onCompleted and is
// therefore still empty during the first schedule refresh.
function artPath(base, key) {
  return String(base).replace(/\/$/, "") + "/demo/art/cover-" + coverIndex(key) + ".png"
}

// ------------------------------------------------------------------ builders

function episodeEntry(showIndex, n) {
  var s = show(showIndex)
  var alias = s.alias + "-episode-" + (n + 1)
  var start = hourMs(-24 * (n + 1))
  return {
    name: s.name + " " + suffix(s.name, showIndex + n),
    description: s.description,
    location_long: s.location,
    genres: s.genres.map(function(g) { return { value: g } }),
    media: {},
    episode_alias: alias,
    show_alias: s.alias,
    broadcast: iso(start),
    // Deliberately absent on one episode per show, so the "No audio" state is
    // always reachable in a screenshot.
    audio_sources: n === 3 ? [] : [{ url: "https://soundcloud.com/demo/" + alias, source: "soundcloud" }]
  }
}

function episodeList(showIndex, count, total) {
  var results = []
  for (var n = 0; n < count; n++) results.push(episodeEntry(showIndex, n))
  return JSON.stringify({ metadata: { resultset: { count: total, offset: 0, limit: count } },
    results: results })
}

function liveBody() {
  var results = []
  for (var channel = 1; channel <= 2; channel++) {
    var base = channel === 1 ? 0 : 3
    var entry = { channel_name: String(channel) }
    for (var slot = 0; slot <= 4; slot++) {
      var s = show(base + slot)
      var block = {
        broadcast_title: s.name + (slot === 0 ? "" : " " + suffix(s.name, slot)),
        start_timestamp: iso(hourMs(slot)),
        end_timestamp: iso(hourMs(slot + 1)),
        embeds: { details: {
          name: s.name, description: s.description, location_long: s.location,
          genres: s.genres.map(function(g) { return { value: g } }),
          media: {}, show_alias: s.alias, episode_alias: s.alias + "-live"
        } }
      }
      entry[slot === 0 ? "now" : (slot === 1 ? "next" : "next" + slot)] = block
    }
    results.push(entry)
  }
  return JSON.stringify({ results: results })
}

function showBody(alias) {
  var index = 0
  for (var i = 0; i < SHOWS.length; i++) if (SHOWS[i].alias === alias) index = i
  var s = SHOWS[index]
  var episodes = []
  for (var n = 0; n < 12; n++) episodes.push(episodeEntry(index, n))
  return JSON.stringify({
    name: s.name, description: s.description, location_long: s.location,
    genres: s.genres.map(function(g) { return { value: g } }),
    external_links: ["https://example.invalid/" + s.alias],
    media: {}, show_alias: s.alias,
    embeds: { episodes: { results: episodes } }
  })
}

function tracklistBody() {
  var results = []
  for (var i = 0; i < 14; i++) {
    results.push({ artist: TRACKS[i % TRACKS.length][0], title: TRACKS[i % TRACKS.length][1] })
  }
  return JSON.stringify({ results: results })
}

function collectionBody(limit) {
  var results = []
  for (var n = 0; n < limit; n++) results.push(episodeEntry(n, n % 5))
  return JSON.stringify({ metadata: { resultset: { count: limit, offset: 0, limit: limit } },
    results: results })
}

function searchBody(query) {
  var q = String(query || "").toLowerCase()
  var results = []
  var popular = ["Tape Hiss", "Concrete Garden", "Night Ferry", "Low Orbit", "Paper Radio"]

  for (var i = 0; i < SHOWS.length; i++) {
    var s = SHOWS[i]
    if (q !== "" && s.name.toLowerCase().indexOf(q) === -1
      && s.genres.join(" ").toLowerCase().indexOf(q) === -1) continue
    results.push({ article_type: "show", title: s.name, artists: [],
      article: { path: "/shows/" + s.alias }, audio_sources: [],
      description: { highlight_plain: s.description },
      image: {}, related_episode: {}, local_date: "", location: s.location,
      genres: s.genres.map(function(g) { return { name: g } }), moods: [] })
    for (var n = 0; n < 2; n++) {
      var e = episodeEntry(i, n)
      results.push({ article_type: "episode", title: e.name, artists: [],
        article: { path: "/shows/" + s.alias + "/episodes/" + e.episode_alias },
        audio_sources: e.audio_sources,
        description: { highlight_plain: s.description },
        image: {}, related_episode: {},
        local_date: localDate(Date.parse(e.broadcast)), location: s.location,
        genres: s.genres.map(function(g) { return { name: g } }), moods: [] })
    }
  }

  return JSON.stringify({
    metadata: { popular_terms: popular, resultset: { count: results.length, offset: 0, limit: 12 } },
    results: results
  })
}

// -------------------------------------------------------------------- routing

// Matches the URL NtsApi built and answers with the same shape the real
// endpoint would. Returns "" for anything unrecognised, which the caller
// reports as a failed request — the same as a 404 in production.
function bodyFor(url) {
  var target = String(url || "")

  if (target.indexOf("/api/v2/live") !== -1) return liveBody()

  var tracklist = target.match(/\/shows\/([^/?]+)\/episodes\/([^/?]+)\/tracklist/)
  if (tracklist) return tracklistBody()

  var episode = target.match(/\/shows\/([^/?]+)\/episodes\/([^/?]+)$/)
  if (episode) {
    var showIndex = 0
    for (var i = 0; i < SHOWS.length; i++) if (SHOWS[i].alias === episode[1]) showIndex = i
    var n = parseInt(String(episode[2]).replace(/^.*-episode-/, ""), 10)
    return JSON.stringify(episodeEntry(showIndex, isFinite(n) ? n - 1 : 0))
  }

  var episodes = target.match(/\/shows\/([^/?]+)\/episodes\?/)
  if (episodes) {
    var listIndex = 0
    for (var j = 0; j < SHOWS.length; j++) if (SHOWS[j].alias === episodes[1]) listIndex = j
    return episodeList(listIndex, 16, 104)
  }

  var one = target.match(/\/shows\/([^/?]+)$/)
  if (one) return showBody(one[1])

  if (target.indexOf("/collections/nts-picks") !== -1) return collectionBody(8)
  if (target.indexOf("/collections/recently-added") !== -1) return collectionBody(8)

  if (target.indexOf("/search?") !== -1) {
    var q = target.match(/[?&]q=([^&]*)/)
    var decoded = ""
    try { decoded = decodeURIComponent(q ? q[1] : "") } catch (e) { decoded = "" }
    // Tracks and tags come from separate indexes in production; demo mode
    // answers those with nothing, which is a real state worth being able to see.
    if (target.indexOf("types%5B%5D=track") !== -1 || target.indexOf("types%5B%5D=tag") !== -1)
      return JSON.stringify({ metadata: { popular_terms: [] }, results: [] })
    return searchBody(decoded)
  }

  return ""
}

// ------------------------------------------------------------------- library
//
// Demo mode must not read or write the real library. A screenshot taken with
// somebody's actual saved shows in it leaks exactly the NTS programme artwork
// the whole demo exists to avoid — and writing to it while testing would edit
// a file the user owns.

function libraryBody() {
  var shows = []
  var episodes = []
  var resume = []

  for (var i = 0; i < 4; i++) {
    var s = show(i)
    shows.push({ alias: s.alias, name: s.name, location: s.location, savedAt: 1000 - i })
  }
  for (var n = 0; n < 3; n++) {
    var e = episodeEntry(n + 2, n)
    episodes.push({
      showAlias: e.show_alias, episodeAlias: e.episode_alias, name: e.name,
      showName: show(n + 2).name, location: show(n + 2).location,
      broadcastMs: Date.parse(e.broadcast), dateLabel: "",
      // A plausible source so saved rows do not all read "No audio". Demo mode
      // never resolves it — nothing here is meant to play.
      audioUrl: "https://soundcloud.com/demo/" + e.episode_alias,
      audioSource: "soundcloud", savedAt: 900 - n
    })
  }
  for (var r = 0; r < 2; r++) {
    var re = episodeEntry(r, r + 1)
    resume.push({
      showAlias: re.show_alias, episodeAlias: re.episode_alias, name: re.name,
      showName: show(r).name, broadcastMs: Date.parse(re.broadcast),
      audioUrl: "https://soundcloud.com/demo/" + re.episode_alias,
      audioSource: "soundcloud",
      positionSec: r === 0 ? 2410 : 780, durationSec: 7200, updatedAt: 800 - r
    })
  }
  return JSON.stringify({ version: 1, shows: shows, episodes: episodes, resume: resume })
}

function paintLibrary(library, base) {
  if (!library) return library
  var lists = [library.shows, library.episodes, library.resume]
  for (var i = 0; i < lists.length; i++) {
    var list = lists[i]
    for (var j = 0; list && j < list.length; j++) {
      var entry = list[j]
      entry.artworkSmall = artPath(base, entry.alias || entry.showAlias || entry.name)
      entry.artworkLarge = entry.artworkSmall
    }
  }
  return library
}

// ------------------------------------------------------------------- artwork
//
// Cover art is attached after parsing rather than inside the fixtures. The
// parsers only accept artwork from NTS's own media hosts — correctly, since in
// production that string is attacker-influenced — and demo mode has no business
// loosening that rule just to show a picture. So the fixtures carry no artwork
// at all, and it is painted on here, where the values are known to be ours.

function paintShow(show, dir) {
  if (!show) return show
  show.artworkSmall = artPath(dir, show.alias || show.name)
  show.artworkLarge = show.artworkSmall
  return show
}

function paintEpisode(episode, dir) {
  if (!episode) return episode
  episode.artworkSmall = artPath(dir, episode.showAlias || episode.name)
  episode.artworkLarge = episode.artworkSmall
  return episode
}

// Walks whatever a parser returned and fills in the covers.
function paint(result, dir) {
  if (!result || typeof result !== "object") return result

  if (result.kind === "episode") return paintEpisode(result, dir)
  if (result.kind === "show") return paintShow(result, dir)

  if (Array.isArray(result.episodes)) {
    for (var i = 0; i < result.episodes.length; i++) paintEpisode(result.episodes[i], dir)
  }
  if (Array.isArray(result.shows)) {
    for (var j = 0; j < result.shows.length; j++) paintShow(result.shows[j], dir)
  }
  if (result.show) paintShow(result.show, dir)
  return result
}

// The live schedule is parsed into { 1: channel, 2: channel } rather than a
// list, so it gets its own pass.
function paintLive(live, dir) {
  if (!live) return live
  for (var channel in live) {
    var state = live[channel]
    if (!state) continue
    if (state.now) {
      state.now.artworkSmall = artPath(dir, state.now.showName || state.now.title)
      state.now.artworkLarge = state.now.artworkSmall
    }
    for (var i = 0; state.upNext && i < state.upNext.length; i++) {
      var entry = state.upNext[i]
      entry.artworkSmall = artPath(dir, entry.showName || entry.title)
      entry.artworkLarge = entry.artworkSmall
    }
  }
  return live
}

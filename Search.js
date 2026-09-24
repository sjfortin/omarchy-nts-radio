// Search state is independent of QML so pagination and matching can be tested.
var types = { shows: ["show"], episodes: ["episode"], tracks: ["track"], tags: ["tag"] }

function emptyGroup() {
  return { total: 0, offset: 0, loading: false, failed: false, more: true }
}

function finishGroup(previous, result, ok) {
  if (!ok || !result) return Object.assign({}, previous, { loading: false, failed: true })
  // Advance by raw rows, not displayed rows: malformed and duplicate records
  // still occupy positions in the upstream index.
  var offset = previous.offset + result.received
  return { total: result.total, offset: offset, loading: false, failed: false,
    more: result.received > 0 && offset < result.total && offset <= 5000 }
}

function merge(previous, incoming, kind) {
  var seen = {}
  var result = []
  var all = previous.concat(incoming)
  for (var i = 0; i < all.length; i++) {
    var item = all[i]
    var key = kind === "shows" ? item.alias : kind === "tags" ? item.name
      : item.showAlias + "/" + item.episodeAlias
    if (kind === "tracks") key += "/" + item.artist + "/" + item.title
    key = "$" + key
    if (seen[key]) continue
    seen[key] = true
    result.push(item)
  }
  return result
}

// Keep non-Latin letters; normalize presentation differences before scoring.
function normalize(value) {
  return String(value || "").normalize("NFKD").toLowerCase()
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[’']/g, "")
    .replace(/[\u2000-\u206f\u3000-\u303f]/g, " ")
    .replace(/[^a-z0-9\u00c0-\uffff]+/g, " ").trim().replace(/\s+/g, " ")
}

function fieldScore(value, query) {
  var text = normalize(value)
  if (!text || !query) return 0
  if (text === query) return 1000
  if ((" " + text + " ").indexOf(" " + query + " ") >= 0) return 800
  var words = query.split(" ")
  var matched = words.filter(function(word) {
    return (" " + text + " ").indexOf(" " + word + " ") >= 0
  }).length
  if (matched === words.length) return 600
  return Math.floor(200 * matched / words.length)
}

function score(item, kind, query) {
  var q = normalize(query)
  if (!q) return 0
  if (kind === "tracks") {
    var artists = item.artists || [item.artist]
    var artist = artists.reduce(function(best, name) {
      return Math.max(best, fieldScore(name, q))
    }, 0)
    // Exact artists lead exact titles; a full title still beats a partial artist.
    return Math.max(artist ? artist + 50 : 0, fieldScore(item.title, q),
      Math.min(600, fieldScore(item.artist + " " + item.title, q)))
  }
  return Math.max(fieldScore(item.name, q), fieldScore(item.description, q) / 4)
}

function rank(items, kind, query) {
  return items.map(function(item, index) {
    return { item: item, index: index, score: score(item, kind, query) }
  }).sort(function(a, b) {
    return b.score - a.score || a.index - b.index
  }).map(function(entry) { return entry.item })
}

// Supplement the OR-like upstream search with a bounded candidate lookup.
// Only full-query matches from this lookup are displayed.
function candidateQuery(query) {
  var words = normalize(query).split(" ")
  if (words.length < 2) return ""
  var stop = ["the", "and", "with", "from", "feat"]
  for (var i = 0; i < words.length; i++)
    if (words[i].length >= 3 && stop.indexOf(words[i]) < 0) return words[i]
  return ""
}

function strongTracks(items, query) {
  return items.filter(function(item) { return score(item, "tracks", query) >= 600 })
}

// Suggestions only: never silently replace the user's search. Common genres
// also provide useful starting points when a short fragment misses NTS's index.
var genres = ["Reggae", "Dub", "Dancehall", "Lovers Rock", "Ska", "Rocksteady",
  "Jazz", "Soul", "Funk", "Disco", "House", "Techno", "Ambient", "Hip Hop",
  "Electronic", "Experimental", "Classical", "Folk", "Blues", "Gospel",
  "Rock", "Pop", "Punk", "Metal", "Jungle", "Drum and Bass", "Garage"]

function distance(a, b) {
  var row = []
  for (var j = 0; j <= b.length; j++) row[j] = j
  for (var i = 1; i <= a.length; i++) {
    var next = [i]
    for (var k = 1; k <= b.length; k++)
      next[k] = Math.min(next[k - 1] + 1, row[k] + 1,
        row[k - 1] + (a[i - 1] === b[k - 1] ? 0 : 1))
    row = next
  }
  return row[b.length]
}

function genreSuggestions(query) {
  var q = String(query || "").trim().toLowerCase()
  if (q.length < 3 || q.length > 24) return []
  var matches = []
  for (var i = 0; i < genres.length; i++) {
    var name = genres[i].toLowerCase()
    if (name === q) return []
    var score = distance(q, name)
    if (name.indexOf(q) === 0 || score <= (q.length >= 4 ? 2 : 1))
      matches.push({ name: genres[i], score: score })
  }
  matches.sort(function(a, b) { return a.score - b.score })
  return matches.slice(0, 3).map(function(item) { return item.name })
}

if (typeof module !== "undefined")
  module.exports = { types: types, emptyGroup: emptyGroup, finishGroup: finishGroup,
    merge: merge, rank: rank, score: score, candidateQuery: candidateQuery,
    strongTracks: strongTracks, genreSuggestions: genreSuggestions }

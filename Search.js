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
    merge: merge, genreSuggestions: genreSuggestions }

import QtQuick
import Quickshell.Io

import "NtsApi.js" as NtsApi

// Turns an NTS episode's SoundCloud or Mixcloud page into a URL a Chromecast
// can fetch for itself.
//
// Local playback does not need this: mpv's own ytdl hook resolves the page as
// it loads. A cast device cannot — it is handed a URL and expects audio at the
// other end — so for casting the resolution has to happen here first.
//
// Two things matter about which format is picked. It must be *progressive*
// HTTP rather than HLS or DASH, because a Chromecast fed a manifest URL as
// plain media sits at IDLE and never reports an error. And the container
// varies by host — SoundCloud publishes MP3, Mixcloud MP4/AAC — so the content
// type is read from what was actually selected rather than assumed.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // Resolved URLs are good for hours (SoundCloud signs about four ahead) and
  // resolution costs a subprocess and a few seconds, so a repeat of the same
  // episode — replaying it, or moving it between outputs — is served from here.
  property var cache: ({})
  property int cacheTtlMs: 45 * 60 * 1000

  readonly property bool busy: resolve.running
  property string pendingSource: ""

  // url is "" when nothing castable could be found.
  signal resolved(string source, string url, string contentType)
  signal failed(string source, string reason)

  // Only a progressive stream is any use to a device. `protocol=https|http`
  // excludes m3u8 and http_dash_segments, which is exactly the distinction
  // that matters; without it yt-dlp's "best" picks HLS on SoundCloud and DASH
  // on Mixcloud, and neither plays.
  readonly property string formatSelector: "bestaudio[protocol=https]/bestaudio[protocol=http]"

  function contentTypeFor(ext) {
    switch (String(ext || "").toLowerCase()) {
      case "mp3": return "audio/mpeg"
      case "m4a":
      case "mp4":
      case "aac": return "audio/mp4"
      case "opus":
      case "webm": return "audio/webm"
      case "ogg":
      case "oga": return "audio/ogg"
      case "flac": return "audio/flac"
      case "wav": return "audio/wav"
    }
    return ""
  }

  function cached(source) {
    var entry = cache[source]
    if (!entry) return null
    if (Date.now() - entry.atMs > cacheTtlMs) return null
    return entry
  }

  function start(source) {
    var target = NtsApi.safeAudioUrl(source)
    if (target === "") {
      failed(String(source || ""), "This episode has no audio on NTS")
      return false
    }

    var hit = cached(target)
    if (hit) {
      // Never answer synchronously: callers set their own state around this.
      Qt.callLater(function() { root.resolved(target, hit.url, hit.contentType) })
      return true
    }

    if (resolve.running) return false

    pendingSource = target
    resolveOutput = ""
    resolve.command = [
      "yt-dlp",
      "--no-warnings",
      "--no-playlist",
      // Bounded: a resolver that hangs would leave the UI on "Connecting"
      // with nothing to time it out.
      "--socket-timeout", "15",
      "-f", formatSelector,
      "--print", "%(ext)s\t%(url)s",
      target
    ]
    resolve.running = true
    return true
  }

  function abort() {
    if (resolve.running) resolve.running = false
    pendingSource = ""
  }

  property string resolveOutput: ""

  Process {
    id: resolve
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.resolveOutput = String(text || "")
    }

    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode, exitStatus) {
      var source = root.pendingSource
      root.pendingSource = ""
      if (source === "") return

      if (exitCode !== 0) {
        // yt-dlp is present (the service probes for it separately), so a
        // failure here is about this episode: taken down, private, or a host
        // change. Either way it is not something the user can fix.
        root.failed(source, "This episode could not be loaded")
        return
      }

      var line = String(root.resolveOutput || "").split("\n")[0]
      var parts = line.split("\t")
      var contentType = root.contentTypeFor(parts[0])
      var url = parts.length > 1 ? String(parts[1]).trim() : ""

      // The device is handed this URL directly, so it gets the same treatment
      // as anything else that crosses a process boundary: https only, bounded,
      // and a container the device can actually decode.
      if (url === "" || url.indexOf("https://") !== 0 || url.length > 2000 || contentType === "") {
        root.failed(source, "This episode cannot be cast — playing here instead")
        return
      }

      root.cache[source] = { url: url, contentType: contentType, atMs: Date.now() }
      root.resolved(source, url, contentType)
    }
  }

  Component.onDestruction: abort()
}

import QtQuick
import qs.Commons

import "../components" as Nts
import "../NtsApi.js" as NtsApi
import "../Library.js" as Library

// One archived episode: the artwork large, the description, and the tracklist.
//
// The page is opened from rows that already hold most of an episode, so it
// renders what it was given immediately and refetches in the background for
// the fields a list row does not carry — the full description, and the audio
// URL on rows that came from search. That is what stops opening an episode
// feeling like a page load.
Item {
  id: root

  property var service: null
  property bool active: true
  property color ink: Color.foreground

  // The episode as the caller knew it. Replaced by the full record once the
  // detail request lands.
  property var episode: null

  signal showRequested(string alias)

  readonly property var api: service ? service.api : null

  // The episode endpoint carries the show's alias but not its name, so a
  // page opened from search shows a slug until this resolves. One extra
  // request, served from the API cache the moment the show has been visited.
  property string resolvedShowName: ""
  readonly property string showLabel: {
    if (!episode) return ""
    if (episode.showName) return episode.showName
    if (resolvedShowName) return resolvedShowName
    return episode.showAlias
  }

  property var tracks: []
  property bool loadingTracks: false
  property bool tracksFailed: false
  property bool detailLoaded: false

  readonly property bool saved: service && episode ? service.isEpisodeSaved(episode) : false
  readonly property bool isCurrent: service && episode ? service.isCurrentEpisode(episode) : false
  readonly property bool isPlaying: isCurrent && service.playing
  readonly property bool hasAudio: episode && episode.audioUrl !== ""
  readonly property int resumeAt: service && episode ? service.resumePositionFor(episode) : 0

  // ---- keyboard cursor over the tracklist. Activating a track seeks to it,
  // which is the same thing clicking its timestamp does.
  property int cursor: -1
  readonly property int cursorCount: tracks.length

  function resetCursor() { cursor = -1 }

  function moveCursor(delta) {
    if (cursorCount === 0) return
    var next = cursor < 0 ? (delta > 0 ? 0 : cursorCount - 1) : cursor + delta
    cursor = Math.max(0, Math.min(cursorCount - 1, next))
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= tracks.length || !service) return
    var track = tracks[cursor]
    if (track.offsetSec < 0) return
    // Seeking only means anything once this episode is the one playing, so
    // activating a timestamp on an idle page starts it there.
    if (!isCurrent) service.playEpisode(episode, track.offsetSec)
    else service.seekTo(track.offsetSec)
  }

  function playCursor() { playOrToggle() }
  function saveCursor() { if (service) service.toggleSaveEpisode(episode) }

  onEpisodeChanged: load()
  Component.onCompleted: load()

  function load() {
    cursor = -1
    resolvedShowName = ""
    tracks = []
    tracksFailed = false
    detailLoaded = false
    if (!api || !episode || !episode.showAlias || !episode.episodeAlias) return

    var show = episode.showAlias
    var slot = episode.episodeAlias

    // Fill in whatever the calling row did not have.
    api.episode(show, slot, function(result, ok) {
      if (!root.episode || root.episode.showAlias !== show
        || root.episode.episodeAlias !== slot) return
      root.detailLoaded = true
      if (ok && result) root.episode = result
    })

    if (!episode.showName) {
      api.show(show, function(result, ok) {
        if (!root.episode || root.episode.showAlias !== show) return
        if (ok && result && result.show) root.resolvedShowName = result.show.name
      })
    }

    loadingTracks = true
    api.tracklist(show, slot, function(result, ok) {
      if (!root.episode || root.episode.showAlias !== show
        || root.episode.episodeAlias !== slot) return
      root.loadingTracks = false
      if (!ok || !result) {
        // Plenty of episodes genuinely have no tracklist. That is an absence,
        // not a failure, so it gets no error treatment — the section is simply
        // not there.
        root.tracksFailed = false
        return
      }
      root.tracks = result
    })
  }

  function playFromStart() {
    if (!service || !episode) return
    service.playEpisode(episode, 0)
  }

  function playOrToggle() {
    if (!service || !episode) return
    if (isCurrent) service.togglePlayback()
    else service.playEpisode(episode, -1)
  }

  Nts.Scroller {
    id: scroller
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight + Style.space(32)

    Column {
      id: column
      x: Style.space(20)
      y: Style.space(18)
      width: scroller.width - Style.space(40)
      spacing: Style.space(20)

      // ---- hero

      Row {
        width: parent.width
        spacing: Style.space(20)

        Nts.ArtFrame {
          id: hero
          width: Math.min(Style.space(200), column.width * 0.32)
          height: width
          source: root.episode ? (root.episode.artworkLarge || root.episode.artworkSmall) : ""
          active: root.active
          ink: root.ink
          decodeWidth: 700
          showPlayAffordance: root.hasAudio
          hovered: heroHover.hovered
          playing: root.isPlaying

          HoverHandler { id: heroHover }

          MouseArea {
            anchors.fill: parent
            enabled: root.hasAudio
            cursorShape: Qt.PointingHandCursor
            onClicked: root.playOrToggle()
          }
        }

        Column {
          width: column.width - hero.width - Style.space(20)
          spacing: Style.space(9)

          Nts.Caption {
            ink: root.ink
            dim: 0.4
            text: root.isCurrent ? "Now playing · Archive" : "Archive"
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.episode ? root.episode.name : ""
            color: root.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            font.letterSpacing: -0.4
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          // The show this came from, and a way back to it.
          Row {
            spacing: Style.space(6)
            visible: root.episode && root.episode.showAlias !== ""

            Nts.Caption {
              anchors.verticalCenter: parent.verticalCenter
              ink: root.ink
              dim: 0.4
              text: "From"
            }

            Text {
              id: showLink
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.showLabel
              color: Util.alpha(root.ink, showLinkHover.hovered ? 1.0 : 0.75)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.underline: showLinkHover.hovered

              HoverHandler { id: showLinkHover }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showRequested(root.episode.showAlias)
              }
            }
          }

          Nts.Caption {
            width: parent.width
            ink: root.ink
            dim: 0.5
            visible: text !== ""
            text: root.episode ? NtsApi.episodeMeta(root.episode) : ""
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.episode ? root.episode.description : ""
            visible: text !== ""
            color: Util.alpha(root.ink, 0.72)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            lineHeight: 1.35
            wrapMode: Text.Wrap
            maximumLineCount: 8
            elide: Text.ElideRight
          }

          // ---- actions
          //
          // A Flow, not a Row: at the minimum window width four buttons do not
          // fit on one line, and a Row would push the last one off the edge
          // instead of wrapping it.

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Nts.BlockButton {
              label: root.isPlaying ? "Pause" : (root.resumeAt > 0 && !root.isCurrent ? "Resume" : "Play")
              filled: root.isPlaying
              ink: root.ink
              enabledAction: root.hasAudio
              onActivated: root.playOrToggle()
            }

            // Only worth offering when resuming is what Play would do.
            Nts.BlockButton {
              visible: root.resumeAt > 0 && !root.isCurrent
              label: "From start"
              ink: root.ink
              enabledAction: root.hasAudio
              onActivated: root.playFromStart()
            }

            Nts.BlockButton {
              label: root.saved ? "Saved" : "Save"
              filled: root.saved
              ink: root.ink
              enabledAction: root.episode !== null
              onActivated: if (root.service) root.service.toggleSaveEpisode(root.episode)
            }

            Nts.BlockButton {
              label: "Open on nts.live"
              ink: root.ink
              enabledAction: root.episode !== null
              onActivated: if (root.service) root.service.openExternal(root.episode.url)
            }
          }

          // Why the play button is dead, when it is.
          Nts.Caption {
            width: parent.width
            ink: root.ink
            dim: 0.5
            visible: text !== ""
            text: {
              if (!root.episode) return ""
              if (root.hasAudio) {
                if (root.service && !root.service.ytdlAvailable)
                  return "yt-dlp is not installed — sudo pacman -S yt-dlp"
                return ""
              }
              return root.detailLoaded
                ? "NTS has no audio for this broadcast" : "Checking for audio…"
            }
          }

          Nts.Caption {
            width: parent.width
            ink: root.ink
            dim: 0.45
            visible: root.resumeAt > 0 && !root.isCurrent
            text: "Picks up at " + NtsApi.clockFromSeconds(root.resumeAt)
          }
        }
      }

      // ---- tracklist

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.tracks.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Tracklist"
          ink: root.ink
          aside: root.isCurrent && root.service && root.service.canSeek
            ? "Click a time to jump" : (root.tracks.length + " tracks")
        }

        Nts.TrackList {
          width: parent.width
          selectedIndex: root.cursor
          tracks: root.tracks
          service: root.service
          episode: root.episode
          ink: root.ink
        }
      }

      Nts.StateNote {
        width: parent.width
        ink: root.ink
        text: root.loadingTracks ? "Loading tracklist" : ""
      }
    }
  }
}

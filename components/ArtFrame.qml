import QtQuick
import qs.Commons
import qs.Commons as Commons
import "../Model.js" as Model

// Show artwork in a square, bordered frame.
//
// Artwork is the only colour anywhere in this plugin, so it is left to stand
// on its own: no wash, no tint, no gradient behind type. A missing image stays
// an empty frame with the station mark in it rather than a placeholder icon —
// absence is information too, and a glyph here would shout.
Rectangle {
  id: root

  property string source: ""
  // Images are only given a source while something can actually see them.
  // Nothing should be fetching over the network for an off-screen row.
  property bool active: true
  property color ink: Commons.Color.foreground
  property int decodeWidth: 400
  // Drawn over the artwork on hover; the parent decides what it does.
  property bool showPlayAffordance: false
  property bool hovered: false
  property bool playing: false

  property int artworkOwner: 0
  property string requestedArtwork: ""
  property string localArtwork: ""
  property bool artworkAdmitted: false
  property bool artworkFailed: false
  property bool syncingArtwork: false

  function syncArtwork() {
    if (!artworkOwner || syncingArtwork) return
    syncingArtwork = true
    var next = active && visible ? Model.safeArtwork(source) : ""
    if (next !== requestedArtwork) {
      var old = requestedArtwork
      requestedArtwork = next
      localArtwork = ""
      artworkAdmitted = false
      artworkFailed = false
      if (old) ArtworkStore.release(old, artworkOwner)
    }
    if (next && !localArtwork && !artworkAdmitted && !artworkFailed) {
      var result = ArtworkStore.acquire(next, artworkOwner)
      artworkAdmitted = result.accepted
      localArtwork = result.uri
    }
    syncingArtwork = false
  }
  onSourceChanged: syncArtwork()
  onActiveChanged: syncArtwork()
  onVisibleChanged: syncArtwork()
  Component.onCompleted: { artworkOwner = ArtworkStore.newOwner(); syncArtwork() }
  Component.onDestruction: if (requestedArtwork) ArtworkStore.release(requestedArtwork, artworkOwner)
  Connections {
    target: ArtworkStore
    function onReady(url, uri) {
      if (root.artworkAdmitted && root.active && root.visible && root.requestedArtwork === url) {
        root.localArtwork = uri
        root.artworkAdmitted = false
      }
    }
    function onRejected(url) {
      if (root.artworkAdmitted && root.requestedArtwork === url) {
        root.artworkAdmitted = false
        root.artworkFailed = true
        root.localArtwork = ""
      }
    }
    function onCapacityAvailable() { root.syncArtwork() }
  }

  radius: 0
  color: Util.alpha(ink, 0.06)
  border.width: 1
  border.color: Util.alpha(ink, 0.28)
  clip: true

  Image {
    id: art
    objectName: "normalizedArtwork"
    anchors.fill: parent
    anchors.margins: 1
    source: root.active && root.localArtwork.indexOf("data:image/x-portable-pixmap;base64,") === 0
      && root.localArtwork.length <= 600000 ? root.localArtwork : ""
    visible: status === Image.Ready
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: false
    // Only a normalized fixed-size raster is decoded in the shared shell.
    // Inactive artwork releases its source and previous decoded frame.
    retainWhileLoading: false
    sourceSize: Qt.size(Math.max(1, Math.min(384, root.decodeWidth)), Math.max(1, Math.min(384, root.decodeWidth)))
  }

  Caption {
    anchors.centerIn: parent
    visible: art.status !== Image.Ready
    text: "NTS"
    ink: root.ink
    dim: 0.3
    font.bold: true
  }

  // A scrim and a mark, only while the pointer is over the card.
  Rectangle {
    anchors.fill: parent
    anchors.margins: 1
    visible: root.showPlayAffordance && (root.hovered || root.playing)
    color: Util.alpha(Commons.Color.background, root.playing ? 0.45 : 0.6)

    // A solid square while this is the thing on air, a triangle otherwise —
    // the same on-air language the bar widget uses.
    Rectangle {
      anchors.centerIn: parent
      visible: root.playing
      width: Math.max(8, root.width * 0.14)
      height: width
      radius: 0
      color: Commons.Color.foreground
    }

    Canvas {
      anchors.centerIn: parent
      visible: !root.playing
      width: Math.max(10, root.width * 0.16)
      height: width
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.fillStyle = Commons.Color.foreground
        ctx.beginPath()
        ctx.moveTo(0, 0)
        ctx.lineTo(width, height / 2)
        ctx.lineTo(0, height)
        ctx.closePath()
        ctx.fill()
      }
    }
  }
}

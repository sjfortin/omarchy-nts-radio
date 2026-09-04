import QtQuick
import qs.Commons

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
  property color ink: Color.foreground
  property int decodeWidth: 400
  // Drawn over the artwork on hover; the parent decides what it does.
  property bool showPlayAffordance: false
  property bool hovered: false
  property bool playing: false

  radius: 0
  color: Util.alpha(ink, 0.06)
  border.width: 1
  border.color: Util.alpha(ink, 0.28)
  clip: true

  Image {
    id: art
    anchors.fill: parent
    anchors.margins: 1
    source: root.active && root.source !== "" ? root.source : ""
    visible: status === Image.Ready
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    // Hold the previous cover while the next decodes, so moving between shows
    // does not blink an empty frame.
    retainWhileLoading: true
    sourceSize.width: root.decodeWidth
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
    color: Util.alpha(Color.background, root.playing ? 0.45 : 0.6)

    // A solid square while this is the thing on air, a triangle otherwise —
    // the same on-air language the bar widget uses.
    Rectangle {
      anchors.centerIn: parent
      visible: root.playing
      width: Math.max(8, root.width * 0.14)
      height: width
      radius: 0
      color: Color.foreground
    }

    Canvas {
      anchors.centerIn: parent
      visible: !root.playing
      width: Math.max(10, root.width * 0.16)
      height: width
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.fillStyle = Color.foreground
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

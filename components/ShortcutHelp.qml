import QtQuick
import qs.Commons

// What the keyboard does, for the one moment somebody wonders.
//
// The browser is almost entirely keyboard-drivable — moving a cursor through
// results, playing what it is on, saving it, jumping between channels — and
// none of that leaves any mark on screen. A single-key surface nobody can find
// is the same as no surface at all, so this exists purely to be found once.
//
// Drawn like everything else here: a rule-separated table on the paper colour,
// keys set as bordered blocks rather than as glyphs. No icons, no shadow.
Item {
  id: root

  property color ink: Color.foreground
  property color paper: Color.background

  signal dismissed()

  // Column of { section, rows: [[keys, meaning]] }. Ordered the way somebody
  // would actually learn them: where you are, then how you move, then what
  // happens to the audio.
  readonly property var groups: [
    {
      title: "Going places",
      rows: [
        ["H", "Home"],
        ["/", "Search"],
        ["S", "Saved"],
        ["Esc", "Back, then close"],
        ["Ctrl W", "Close the window"]
      ]
    },
    {
      title: "Moving around",
      rows: [
        ["J  K   ↓  ↑", "Move down / up"],
        ["PgDn  PgUp", "Five at a time"],
        ["Tab", "Switch shelf, on Saved"],
        ["Enter", "Open what is selected"]
      ]
    },
    {
      title: "Listening",
      rows: [
        ["Space", "Play or pause"],
        ["P", "Play what is selected"],
        ["B", "Save what is selected"],
        ["1  2", "Live NTS 1 / NTS 2"],
        ["←  →", "Skip 30s, in an archive"]
      ]
    }
  ]

  // A scrim over the whole window, and a click anywhere on it closes.
  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.paper, 0.86)

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismissed()
    }
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(80), Style.space(720))
    height: Math.min(parent.height - Style.space(60), body.implicitHeight + Style.space(44))
    color: root.paper
    radius: 0
    border.width: 1
    border.color: Util.alpha(root.ink, 0.45)

    // Swallow clicks that land on the card, so reading it does not close it.
    MouseArea { anchors.fill: parent }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(22)
      spacing: Style.space(16)

      Item {
        width: parent.width
        height: heading.implicitHeight

        Text {
          id: heading
          anchors.left: parent.left
          textFormat: Text.PlainText
          text: "Keyboard"
          color: root.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
          font.letterSpacing: 0.4
        }

        Caption {
          anchors.right: parent.right
          anchors.verticalCenter: heading.verticalCenter
          ink: root.ink
          dim: 0.4
          text: "? or Esc to close"
        }
      }

      Rule { ink: root.ink; dim: 0.3 }

      Row {
        width: parent.width
        spacing: Style.space(24)

        Repeater {
          model: root.groups

          Column {
            required property var modelData

            width: (body.width - Style.space(24) * 2) / 3
            spacing: Style.space(9)

            Caption {
              ink: root.ink
              dim: 0.45
              font.bold: true
              text: modelData.title
            }

            Repeater {
              model: modelData.rows

              Item {
                required property var modelData

                width: parent.width
                height: Math.max(keyCap.implicitHeight, meaning.implicitHeight) + Style.space(6)

                // The keys, set as one block rather than one block per key:
                // "PgDn  PgUp" reads as a pair, and splitting it into two
                // bordered chips would be louder than the thing it labels.
                Rectangle {
                  id: keyCap
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: keyLabel.implicitWidth + Style.space(10)
                  height: keyLabel.implicitHeight + Style.space(5)
                  radius: 0
                  color: "transparent"
                  border.width: 1
                  border.color: Util.alpha(root.ink, 0.4)

                  Text {
                    id: keyLabel
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: modelData[0]
                    color: Util.alpha(root.ink, 0.9)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  id: meaning
                  anchors.left: keyCap.right
                  anchors.leftMargin: Style.space(9)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData[1]
                  color: Util.alpha(root.ink, 0.62)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }
    }
  }
}

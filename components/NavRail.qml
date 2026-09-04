import QtQuick
import qs.Commons

// The station mark lives at the plugin root next to the bar widget that
// also uses it. A qualified directory import keeps one copy of it rather
// than a second drawn the same way.
import ".." as Plugin
import "../Model.js" as Model

// The left rail: where you are, and the two live channels.
//
// Three destinations and a station mark. Anything deeper — a show, an episode
// — is reached from content and returns with Escape or the back action, so the
// rail never grows a tree.
Item {
  id: root

  property string current: "home"
  property var service: null
  property color ink: Color.foreground
  property color paper: Color.background

  signal navigated(string page)
  signal liveRequested(int channel)

  readonly property var pages: [
    { id: "home", label: "Home" },
    { id: "search", label: "Search" },
    { id: "saved", label: "Saved" }
  ]

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.ink, 0.03)
  }

  Rule {
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: 1
    height: undefined
    ink: root.ink
    dim: 0.22
  }

  Column {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(14)
    spacing: Style.space(18)

    Plugin.NtsMark {
      ink: root.ink
      paper: root.paper
      filled: root.service ? root.service.playing : false
      fontSize: Style.font.bodySmall
    }

    Column {
      width: parent.width
      spacing: Style.space(2)

      Repeater {
        model: root.pages

        Item {
          id: navItem
          required property var modelData

          readonly property bool selected: root.current === modelData.id

          width: parent.width
          height: Style.space(30)

          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: -Style.space(6)
            anchors.rightMargin: -Style.space(6)
            color: navItem.selected ? Util.alpha(root.ink, 0.12)
              : (navHover.hovered ? Util.alpha(root.ink, 0.06) : "transparent")
          }

          // A filled tick against the selected destination — the same square
          // that means "on air" elsewhere, here meaning "you are here".
          Rectangle {
            id: tick
            anchors.left: parent.left
            anchors.leftMargin: -Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(3)
            height: parent.height * 0.55
            radius: 0
            color: navItem.selected ? root.ink : "transparent"
          }

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: navItem.modelData.label
            color: Util.alpha(root.ink, navItem.selected ? 1.0 : 0.62)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: navItem.selected
            elide: Text.ElideRight
          }

          HoverHandler { id: navHover }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.navigated(navItem.modelData.id)
          }
        }
      }
    }

    // The two live channels, always one click away from anywhere in the
    // browser. This is the mini-player's "back to live radio".
    Column {
      width: parent.width
      spacing: Style.space(6)

      Caption {
        text: "On air"
        ink: root.ink
        dim: 0.4
        font.bold: true
      }

      Repeater {
        model: [1, 2]

        Item {
          id: channelItem
          required property int modelData

          readonly property bool selected: root.service
            && !root.service.archiveMode && root.service.channel === modelData
          readonly property var state: root.service
            ? root.service.channelState(modelData) : null

          width: parent.width
          height: channelColumn.implicitHeight + Style.space(10)

          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: -Style.space(6)
            anchors.rightMargin: -Style.space(6)
            color: channelHover.hovered ? Util.alpha(root.ink, 0.06) : "transparent"
          }

          Column {
            id: channelColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Row {
              spacing: Style.space(6)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(6)
                height: width
                radius: 0
                color: channelItem.selected && root.service && root.service.playing
                  ? root.ink : "transparent"
                border.width: 1
                border.color: Util.alpha(root.ink, channelItem.selected ? 0.9 : 0.4)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: Model.channelLabel(channelItem.modelData)
                color: Util.alpha(root.ink, channelItem.selected ? 1.0 : 0.72)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: channelItem.selected
              }
            }

            Caption {
              width: parent.width
              text: channelItem.state ? Model.barTitle(channelItem.state.now) : ""
              visible: text !== ""
              ink: root.ink
              dim: 0.38
            }
          }

          HoverHandler { id: channelHover }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.liveRequested(channelItem.modelData)
          }
        }
      }
    }
  }
}

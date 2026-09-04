import QtQuick
import Quickshell
import qs.Commons

import "components" as Nts
import "pages" as Pages

// The full NTS browser: a real window, not a stretched dropdown.
//
// It is an `overlay` entry point on the same plugin as the bar widget, which
// is the whole trick behind Phase 2's playback requirement. The shell injects
// `service` here from the same singleton the bar widget resolves, so this
// window is a *view* onto playback rather than an owner of it. Closing it
// destroys every page in it and playback does not so much as stutter, because
// mpv is parented to the service, not to anything on screen.
//
// Layout is three fixed regions: a rail that says where you are, a content
// area that lazy-loads one page at a time, and a transport across the bottom
// that never changes. Detail pages (a show, an episode) are pushed onto a back
// stack rather than added to the rail, so navigation stays two levels deep.
Item {
  id: root

  // ---- host injections
  property var shell: null
  property var service: null
  property var manifest: null

  // ---- lifecycle, as the shell's panel loader expects
  property bool opened: false
  property bool closingFromHost: false

  function open(payloadJson) {
    closingFromHost = false
    var wasOpen = opened
    opened = true
    window.visible = true

    // Summoning a window that is already up should bring it to the front, not
    // silently do nothing — a launcher entry picked twice must not feel dead.
    // Re-mapping is the only lever a FloatingWindow gives us for that, and the
    // compositor focuses the window as it comes back.
    if (wasOpen) {
      closingFromHost = true
      window.visible = false
      window.visible = true
      closingFromHost = false
    }
    // A payload can name a destination, so a keybinding can open the browser
    // straight onto search:
    //   omarchy-shell shell summon sjfortin.nts-radio '{"page":"search"}'
    var requested = ""
    if (payloadJson) {
      try {
        var parsed = JSON.parse(String(payloadJson))
        if (parsed && typeof parsed.page === "string") requested = parsed.page
      } catch (e) { /* an unparseable payload just opens the browser */ }
    }
    if (requested === "search" || requested === "saved" || requested === "home") navigate(requested)
    Qt.callLater(function() {
      keyScope.forceActiveFocus()
      if (root.page === "search" && searchLoader.item) searchLoader.item.focusInput()
    })
  }

  // Host-initiated close. Visibility flips without telling the host back — it
  // is the one that asked.
  function close() {
    closingFromHost = true
    opened = false
    window.visible = false
    closingFromHost = false
  }

  // User-initiated close. The shell's openPanelIds has to learn about it or
  // the next toggle would think the window is still up.
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "sjfortin.nts-radio"

  // ---- theme
  readonly property color ink: Color.foreground
  readonly property color paper: Color.background

  // ---- routing

  property string page: "home"
  property string showAlias: ""
  property var currentEpisode: null

  // Where Escape goes. Entries are { page, showAlias, episode }.
  property var backStack: []

  readonly property bool onDetail: page === "show" || page === "episode"
  // Which rail entry lights up while a detail page is open: the one it was
  // reached from, so the rail does not go blank two levels down.
  property string railPage: "home"

  function pushState() {
    var next = backStack.slice()
    next.push({ page: page, showAlias: showAlias, episode: currentEpisode })
    // A deep browse should not grow without limit.
    if (next.length > 24) next.shift()
    backStack = next
  }

  function navigate(target) {
    if (page === target && !onDetail) return
    backStack = []
    page = target
    railPage = target
    if (target === "search") {
      Qt.callLater(function() {
        if (searchLoader.item) searchLoader.item.focusInput()
      })
    }
  }

  function openShow(alias) {
    var wanted = String(alias || "")
    if (wanted === "") return
    if (page === "show" && showAlias === wanted) return
    pushState()
    showAlias = wanted
    page = "show"
  }

  function openEpisode(episode) {
    if (!episode) return
    pushState()
    currentEpisode = episode
    page = "episode"
  }

  function back() {
    if (backStack.length === 0) {
      requestClose()
      return
    }
    var next = backStack.slice()
    var previous = next.pop()
    backStack = next
    showAlias = previous.showAlias
    currentEpisode = previous.episode
    page = previous.page
  }

  // The browser counts as a UI watcher, so the schedule refreshes at the fast
  // cadence while it is open — the same contract the bar panel uses.
  property bool watching: false

  function syncWatcher(shouldWatch) {
    if (!service || shouldWatch === watching) return
    watching = shouldWatch
    if (shouldWatch) service.addWatcher()
    else service.removeWatcher()
  }

  onOpenedChanged: syncWatcher(opened)
  onServiceChanged: syncWatcher(opened)
  Component.onDestruction: syncWatcher(false)

  // True while a text field owns the keyboard, so single-key shortcuts do not
  // eat what is being typed.
  // The `=== true` is load-bearing: before the search page's Loader resolves,
  // `item` is null and the && chain yields null rather than false.
  readonly property bool typing: page === "search" && searchLoader.item
    ? searchLoader.item.hasFocus === true : false

  // The page currently on screen. Every page implements the same small cursor
  // contract — moveCursor / activateCursor / playCursor / saveCursor — so the
  // window can drive the keyboard without knowing which page it is driving.
  readonly property var currentPage: {
    if (page === "home") return homeLoader.item
    if (page === "search") return searchLoader.item
    if (page === "saved") return savedLoader.item
    return detailLoader.item
  }

  function pageCall(method, arg) {
    var target = currentPage
    if (!target || typeof target[method] !== "function") return false
    if (arg === undefined) target[method]()
    else target[method](arg)
    return true
  }

  FloatingWindow {
    id: window

    title: "NTS"
    visible: false
    color: root.paper
    implicitWidth: 1080
    implicitHeight: 760
    minimumSize: Qt.size(720, 520)

    onVisibleChanged: {
      if (visible || root.closingFromHost) return
      // The window manager closed it. Tell the shell so toggle stays honest.
      root.opened = false
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    FocusScope {
      id: keyScope
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        // Escape always works, typing or not: it clears the query first (the
        // field handles that itself) and otherwise walks back.
        if (event.key === Qt.Key_Escape) {
          root.back()
          event.accepted = true
          return
        }

        if (event.modifiers & Qt.ControlModifier) {
          if (event.key === Qt.Key_F) {
            root.navigate("search")
            event.accepted = true
          } else if (event.key === Qt.Key_W) {
            root.requestClose()
            event.accepted = true
          }
          return
        }

        // Cursor movement works even while typing: pressing Down out of the
        // search field and into the results is the whole point of a search
        // box, and an arrow key is never part of a word.
        if (event.key === Qt.Key_Down) {
          root.pageCall("moveCursor", 1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Up) {
          root.pageCall("moveCursor", -1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_PageDown) {
          root.pageCall("moveCursor", 5)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_PageUp) {
          root.pageCall("moveCursor", -5)
          event.accepted = true
          return
        }

        // Tab switches between a page's own sub-views where it has any (the
        // saved shelves); pages without a nextTab() ignore it.
        if (event.key === Qt.Key_Tab) {
          if (root.pageCall("nextTab")) event.accepted = true
          return
        }

        // Everything below is a bare key, so it must not fire mid-word.
        if (root.typing) return

        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.pageCall("activateCursor")
          event.accepted = true
          return
        }

        switch (event.key) {
          // vi movement alongside the arrows, the way the rest of the shell's
          // panels behave.
          case Qt.Key_J:
            root.pageCall("moveCursor", 1)
            event.accepted = true
            break
          case Qt.Key_K:
            root.pageCall("moveCursor", -1)
            event.accepted = true
            break
          // Play what the cursor is on, rather than what is on air.
          case Qt.Key_P:
            root.pageCall("playCursor")
            event.accepted = true
            break
          // Save/unsave what the cursor is on.
          case Qt.Key_B:
            root.pageCall("saveCursor")
            event.accepted = true
            break
          case Qt.Key_Slash:
            root.navigate("search")
            event.accepted = true
            break
          case Qt.Key_Space:
            if (root.service) root.service.togglePlayback()
            event.accepted = true
            break
          case Qt.Key_1:
            if (root.service) root.service.playLive(1)
            event.accepted = true
            break
          case Qt.Key_2:
            if (root.service) root.service.playLive(2)
            event.accepted = true
            break
          case Qt.Key_H:
            root.navigate("home")
            event.accepted = true
            break
          case Qt.Key_S:
            root.navigate("saved")
            event.accepted = true
            break
          // Scrubbing, for archives only. The service ignores these on live.
          case Qt.Key_Left:
            if (root.service) root.service.seekBy(-30)
            event.accepted = true
            break
          case Qt.Key_Right:
            if (root.service) root.service.seekBy(30)
            event.accepted = true
            break
        }
      }

      // ---- rail

      Nts.NavRail {
        id: rail
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: transport.top
        width: Style.space(172)
        current: root.railPage
        service: root.service
        ink: root.ink
        paper: root.paper
        onNavigated: function(target) { root.navigate(target) }
        onLiveRequested: function(channel) {
          if (root.service) root.service.playLive(channel)
        }
      }

      // ---- content

      Item {
        id: content
        anchors.left: rail.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: transport.top
        clip: true

        // A back affordance for the pointer; Escape does the same thing.
        Item {
          id: crumb
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.onDetail ? backButton.height + Style.space(20) : 0
          visible: root.onDetail
          z: 2

          Nts.BlockButton {
            id: backButton
            anchors.left: parent.left
            anchors.leftMargin: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            label: "Back"
            ink: root.ink
            onActivated: root.back()
          }
        }

        Item {
          id: pageHost
          anchors.top: crumb.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom

          // Home, search and saved each keep their own Loader so that state —
          // a query, a scroll position, a chosen tab — survives moving between
          // them. They are created on first visit and never destroyed while
          // the window lives, which is what "lazy-load pages" buys here.
          Loader {
            id: homeLoader
            anchors.fill: parent
            active: root.page === "home" || visited
            visible: root.page === "home"
            asynchronous: true
            property bool visited: false

            sourceComponent: Pages.HomePage {
              service: root.service
              active: root.opened && root.page === "home"
              ink: root.ink
              paper: root.paper
              onShowRequested: function(alias) { root.openShow(alias) }
              onEpisodeRequested: function(episode) { root.openEpisode(episode) }
              onSearchRequested: root.navigate("search")
            }
          }

          Loader {
            id: searchLoader
            anchors.fill: parent
            active: root.page === "search" || visited
            visible: root.page === "search"
            asynchronous: false
            property bool visited: false

            sourceComponent: Pages.SearchPage {
              service: root.service
              active: root.opened && root.page === "search"
              ink: root.ink
              onShowRequested: function(alias) { root.openShow(alias) }
              onEpisodeRequested: function(episode) { root.openEpisode(episode) }
            }
          }

          Loader {
            id: savedLoader
            anchors.fill: parent
            active: root.page === "saved" || visited
            visible: root.page === "saved"
            asynchronous: true
            property bool visited: false

            sourceComponent: Pages.SavedPage {
              service: root.service
              active: root.opened && root.page === "saved"
              ink: root.ink
              onShowRequested: function(alias) { root.openShow(alias) }
              onEpisodeRequested: function(episode) { root.openEpisode(episode) }
              onBrowseRequested: root.navigate("home")
            }
          }

          // Detail pages share one Loader: only ever one is on screen, and
          // leaving one should genuinely release it rather than pile up a
          // window full of half-scrolled shows.
          Loader {
            id: detailLoader
            anchors.fill: parent
            active: root.onDetail
            visible: root.onDetail
            asynchronous: false

            sourceComponent: root.page === "show" ? showComponent
              : (root.page === "episode" ? episodeComponent : null)
          }

          Component {
            id: showComponent

            Pages.ShowPage {
              service: root.service
              active: root.opened
              ink: root.ink
              alias: root.showAlias
              onEpisodeRequested: function(episode) { root.openEpisode(episode) }
            }
          }

          Component {
            id: episodeComponent

            Pages.EpisodePage {
              service: root.service
              active: root.opened
              ink: root.ink
              episode: root.currentEpisode
              onShowRequested: function(alias) { root.openShow(alias) }
            }
          }
        }

        // A single quiet line for anything the whole window needs to say.
        Nts.Caption {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: Style.space(8)
          horizontalAlignment: Text.AlignHCenter
          ink: Color.urgent
          dim: 0.85
          visible: text !== ""
          text: {
            if (!root.service) return ""
            if (root.service.archiveError !== "") return root.service.archiveError
            if (root.service.playbackError !== "" && !root.service.playing)
              return root.service.playbackError
            return ""
          }
        }
      }

      // ---- transport

      Nts.PlaybackBar {
        id: transport
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        service: root.service
        ink: root.ink
        paper: root.paper
        onShowRequested: function(showAlias, episodeAlias) {
          if (root.service && root.service.archiveEpisode)
            root.openEpisode(root.service.archiveEpisode)
        }
      }
    }
  }

  // Mark a page visited once it has been shown, so its Loader stays active
  // and keeps its state for the rest of the session.
  onPageChanged: {
    if (page === "home") homeLoader.visited = true
    else if (page === "search") searchLoader.visited = true
    else if (page === "saved") savedLoader.visited = true
  }

  Component.onCompleted: homeLoader.visited = true
}

import QtQuick
import QtTest
import "../../pages" as Pages
import "../.." as Plugin

TestCase {
  id: test
  name: "ListeningUI"
  when: windowShown
  width: 800
  height: 700
  visible: true
  Rectangle { anchors.fill: parent; color: "#111111" }
  Plugin.Service { id: service; libraryLoaded: true }
  Pages.ListeningPage { id: page; anchors.fill: parent; service: service }
  function test_tabsAndQueueNavigation() {
    compare(page.tab, "queue")
    page.nextTab()
    compare(page.tab, "history")
    page.nextTab()
    compare(page.tab, "library")
    page.nextTab()
    compare(page.tab, "queue")
    service.enqueueEpisode({ valid: true, showAlias: "show", episodeAlias: "a", name: "A", audioUrl: "https://soundcloud.com/nts/a" }, false)
    page.moveCursor(1)
    compare(page.cursor, 0)
    compare(page.items.length, 1)
    wait(20)
    grabImage(test).save("/tmp/nts-listening-queue.png")
    page.tab = "library"
    wait(20)
    grabImage(test).save("/tmp/nts-listening-library.png")
    test.width = 548
    test.height = 410
    wait(20)
    grabImage(test).save("/tmp/nts-listening-small.png")
  }
}

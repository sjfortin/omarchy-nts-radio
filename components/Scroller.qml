import QtQuick
import qs.Commons

// A Flickable with a mouse wheel that behaves like a mouse wheel.
//
// Flickable routes a wheel notch through its flick physics — the same easing
// built for a finger dragging a touchscreen. Content coasts in and coasts out,
// and under a mouse a long list feels heavy: a notch travels a short distance
// and then spends time decelerating. Qt exposes the tuning only as a
// process-wide environment variable (QT_QUICK_FLICKABLE_WHEEL_DECELERATION),
// which is not a plugin's to set on the whole shell.
//
// So the wheel is handled here instead: a notch moves the content a fixed
// distance immediately, with no physics in between. A touchpad is left alone —
// its pixel deltas already arrive fine-grained and continuous, and running
// those through a per-notch step would make them worse, not better.
Flickable {
  id: root

  // How far one wheel notch travels. Roughly three list rows: enough that a
  // long archive is quick to get through, not so much that the eye loses its
  // place between notches.
  property real wheelStep: Style.space(140)

  clip: true
  boundsBehavior: Flickable.StopAtBounds
  // Only ever vertical here; letting it drift sideways in a column layout is
  // a way to get lost, not a feature.
  flickableDirection: Flickable.VerticalFlick
  // Rounds the content to whole pixels, so text does not shimmer mid-scroll.
  pixelAligned: true

  readonly property real maxContentY: Math.max(0, contentHeight - height)

  function scrollBy(delta) {
    if (maxContentY <= 0) return
    // A flick still in progress would keep writing contentY underneath us and
    // undo the jump; stop it before taking over.
    if (flicking || moving) cancelFlick()
    contentY = Math.max(0, Math.min(maxContentY, contentY + delta))
  }

  function scrollToTop() { contentY = 0 }

  WheelHandler {
    // Both, because the two are told apart by which delta they carry rather
    // than by which device Qt says they are — a touchpad reports as a mouse
    // often enough that filtering on the device is unreliable.
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    // acceptedButtons is deliberately left alone. A wheel event carries no
    // button at all, so constraining it here can only ever exclude the events
    // this handler exists for.

    onWheel: function(event) {
      // A touchpad sends real pixels. Use them as they are — that is already
      // one-to-one with the fingers, and the whole point of a smooth surface.
      var delta = event.pixelDelta.y
      if (delta === 0) {
        // A mouse sends eighths of a degree, 120 per notch on every mouse
        // anyone owns. Partial values come from high-resolution wheels and
        // scale down correctly on their own.
        delta = (event.angleDelta.y / 120) * root.wheelStep
      }
      if (delta === 0) return

      // Positive delta means "scroll up", which moves the viewport toward the
      // top of the content — the opposite sign to contentY.
      root.scrollBy(-delta)
      event.accepted = true
    }
  }
}

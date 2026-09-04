import QtQuick
import qs.Commons

// A Flickable that scrolls the way the rest of the desktop does.
//
// Two separate problems, and both have to be solved or scrolling still feels
// heavy:
//
// 1. Flickable routes a wheel notch through its flick physics — the easing
//    built for a finger dragging a touchscreen. A notch travels a short
//    distance and then spends time decelerating. Qt exposes the tuning only as
//    a process-wide environment variable
//    (QT_QUICK_FLICKABLE_WHEEL_DECELERATION), which is not a plugin's to set on
//    the whole shell. So the wheel is handled here: a fixed distance per notch,
//    immediately, with no physics in between.
//
// 2. A touchpad does not send notches at all. It sends pixel deltas that are
//    close to raw finger travel, because libinput does not accelerate them the
//    way a desktop expects. Passing those through untouched — which is what
//    this component did at first — moves the content about as far as the
//    fingers moved, so a long list takes a dozen swipes. Every toolkit scales
//    them, and so does this.
//
// A mouse and a touchpad are told apart by which delta they carry, not by what
// the device claims to be.
Flickable {
  id: root

  // Scroll distance as a percentage, so one number covers both devices and can
  // be exposed as a plugin setting. 100 is the tuned default.
  property int speedPercent: 100
  readonly property real speed: Math.max(10, Math.min(500, speedPercent)) / 100

  // How far one wheel notch travels at 100%. Roughly three list rows: enough
  // that a long archive is quick to get through, not so much that the eye
  // loses its place between notches.
  readonly property real wheelStep: Style.space(140) * speed

  // What a touchpad's pixel deltas are multiplied by at 100%.
  readonly property real touchpadScale: 3.0 * speed

  // Raised for every wheel event with the raw deltas that arrived. Scroll feel
  // cannot be judged from outside the machine it is running on, and the two
  // devices are only distinguishable by which delta they carry — so the numbers
  // are reported rather than guessed at. The service records the last of them
  // and `nts-radio status` prints it.
  signal wheelObserved(real pixelDelta, real angleDelta)

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
      root.wheelObserved(event.pixelDelta.y, event.angleDelta.y)

      // A touchpad sends real pixels — finger travel, unaccelerated — so they
      // get scaled. A mouse sends eighths of a degree, 120 per notch, and gets
      // a fixed step per notch. Which one arrived is the only reliable way to
      // tell the two apart.
      var delta = event.pixelDelta.y * root.touchpadScale
      if (event.pixelDelta.y === 0) {
        // Partial angle values come from high-resolution wheels and scale
        // down correctly on their own.
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

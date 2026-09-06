import QtQuick
import QtQuick.Shapes
import qs.Commons

// A thin circular progress ring. `progress` (0..1) draws a themed arc that
// fills clockwise from 12 o'clock; a negative value spins a short arc as an
// indeterminate loader. Used for the playlist-detection indicator.
Item {
  id: root

  property color color: Color.foreground
  property color accent: Color.accent
  property real progress: -1
  property real lineWidth: Math.max(1.5, Math.round(Style.space(2)))

  implicitWidth: 18
  implicitHeight: 18

  readonly property real cx: width / 2
  readonly property real cy: height / 2
  readonly property real r: Math.max(1, Math.min(width, height) / 2 - lineWidth / 2)

  // Arc sweep in degrees for the progress arc; a quarter ring for the
  // indeterminate spin so the moving gap reads clearly.
  readonly property real sweep: (root.progress >= 0 ? root.progress : 0.25) * 360

  readonly property real endX: cx + r * Math.sin(sweep * Math.PI / 180)
  readonly property real endY: cy - r * Math.cos(sweep * Math.PI / 180)

  Shape {
    anchors.fill: parent
    antialiasing: true
    transformOrigin: Item.Center
    rotation: 0

    RotationAnimation on rotation {
      running: root.progress < 0
      from: 0
      to: 360
      duration: 900
      loops: Animation.Infinite
    }

    ShapePath {
      strokeColor: Util.alpha(root.color, 0.15)
      strokeWidth: root.lineWidth
      fillColor: "transparent"
      startX: root.cx - root.r
      startY: root.cy
      PathArc { x: root.cx + root.r; y: root.cy; radiusX: root.r; radiusY: root.r }
      PathArc { x: root.cx - root.r; y: root.cy; radiusX: root.r; radiusY: root.r }
    }

    ShapePath {
      strokeColor: root.accent
      strokeWidth: root.lineWidth
      fillColor: "transparent"
      startX: root.cx
      startY: root.cy - root.r
      PathArc {
        x: root.endX
        y: root.endY
        radiusX: root.r
        radiusY: root.r
        direction: PathArc.Clockwise
        useLargeArc: root.sweep > 180
      }
    }
  }
}
import QtQuick
import QtQuick.Shapes
import qs.Commons

// OmaVideos bar mark: an Omarchy-styled play button — three nested triangles
// drawn as a single even-odd path, so it reads as a crisp play glyph. The
// color follows the theme (foreground at rest, accent when lighting up).
//
// While a download runs (`busy`) the mark dims and the accent version is
// progressively revealed from the bottom as `progress` climbs from 0 to 1,
// so the bar icon lights up with the download. Unknown progress (< 0) sweeps
// a lit band instead.
//
// The path keeps its original 24×24 coordinates; the Shape is exactly 24×24
// and scaled as a unit to the requested size for vector-crisp rendering.
Item {
  id: root

  property color color: Color.foreground
  property color accent: Color.accent
  property bool busy: false
  property real progress: -1 // 0..1 determinate; <0 indeterminate

  readonly property string playPath: "M3.2 1.6H12.8L22.4 12L12.8 22.4H3.2V1.6ZM6.4 4.8V19.2H11.2L17.6 12L11.2 4.8H6.4ZM9.6 8V16H11.2L14.8 12L11.2 8H9.6Z"

  implicitWidth: 24
  implicitHeight: 24

  // Dim base while busy; the normal bright mark when idle.
  Shape {
    x: 0
    y: 0
    width: 24
    height: 24
    antialiasing: true
    transform: Scale { xScale: root.width / 24; yScale: root.height / 24 }

    ShapePath {
      fillColor: root.busy ? Util.alpha(root.color, 0.30) : root.color
      strokeColor: "transparent"
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill
      PathSvg { path: root.playPath }
    }
  }

  // Lit overlay, visible only while busy: the accent mark clipped to a band
  // that grows from the bottom with progress, or sweeps when unknown.
  Item {
    id: litWindow
    visible: root.busy
    anchors.fill: parent
    clip: true

    Item {
      id: litBand
      width: parent.width
      height: root.progress >= 0
        ? Math.max(1, parent.height * root.progress)
        : Math.round(parent.height * 0.4)
      y: parent.height - height

      Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      clip: true

      Shape {
        x: 0
        y: 0
        width: 24
        height: 24
        antialiasing: true
        transform: Scale { xScale: root.width / 24; yScale: root.height / 24 }

        ShapePath {
          fillColor: root.accent
          strokeColor: "transparent"
          strokeWidth: 0
          fillRule: ShapePath.OddEvenFill
          PathSvg { path: root.playPath }
        }
      }

      SequentialAnimation on y {
        running: root.busy && root.progress < 0
        loops: Animation.Infinite
        NumberAnimation { to: 0; duration: 1100; easing.type: Easing.InOutCubic }
        NumberAnimation { to: litWindow.height - litBand.height; duration: 1100; easing.type: Easing.InOutCubic }
      }
    }
  }
}
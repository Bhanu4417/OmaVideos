import QtQuick
import QtQuick.Shapes
import qs.Commons

// OmaVideos brand mark: the Omarchy ring with a play triangle dropped into its
// open center — "videos on Omarchy". Colors follow the live theme: the ring is
// the foreground color and the play triangle is the accent color.
//
// The Omarchy path keeps its original 24×24 coordinates; the Shape is exactly
// 24×24 and is scaled as a unit to the requested size, so the mark stays
// vector-crisp at any size (bar 16px, panel hero 44px).
//
// While a download runs (`busy`), the mark dims and the bright accent version
// is progressively revealed from the bottom as `progress` climbs from 0 to 1,
// so the icon literally lights up with the download. When progress is unknown
// (< 0) a lit band sweeps the mark instead.
Item {
  id: root

  property color color: Color.foreground
  property color accent: Color.accent
  property bool showPlay: true
  property bool busy: false
  property real progress: -1 // 0..1 determinate; <0 indeterminate

  readonly property string ringPath: "M0 0v24h12.8v-3.2h8V3.2h-3.2v1.6h1.6v14.4H4.8V4.8h8V1.6h9.6v20.8h-8V24H24V0Zm1.6 1.6h9.6v1.6h-8v8H1.6Zm0 11.2h1.6v8h8v1.6H1.6Z"

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
      PathSvg { path: root.ringPath }
    }

    ShapePath {
      fillColor: root.showPlay ? (root.busy ? Util.alpha(root.accent, 0.35) : root.accent) : "transparent"
      strokeColor: "transparent"
      strokeWidth: 0
      startX: 9.5
      startY: 7.5
      PathLine { x: 17; y: 12 }
      PathLine { x: 9.5; y: 16.5 }
      PathLine { x: 9.5; y: 7.5 }
    }
  }

  // Lit overlay, visible only while busy: the bright accent mark clipped to a
  // band that grows from the bottom with progress, or sweeps when unknown.
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
          PathSvg { path: root.ringPath }
        }

        ShapePath {
          fillColor: root.accent
          strokeColor: "transparent"
          strokeWidth: 0
          startX: 9.5
          startY: 7.5
          PathLine { x: 17; y: 12 }
          PathLine { x: 9.5; y: 16.5 }
          PathLine { x: 9.5; y: 7.5 }
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
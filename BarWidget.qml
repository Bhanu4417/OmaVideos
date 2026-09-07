import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmaVideos — a download arrow in the bar. Click to open the paste-and-download
// panel, right-click to open it prefilled from the clipboard, middle-click to
// reveal the omavideos folder.
//
// The bar-widget root hosts the nested Panel and owns the lifecycle contract
// Quattro uses to route shell.summon/hide: `opened`, `open()`, `close()`, and
// the popout-switch helpers, exactly like the built-in clock.
BarWidget {
  id: root
  moduleName: "bhanu.omavideos"

  readonly property string pluginId: moduleName

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // everything the bar identifies a panel by has to be this widget.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Shell summon is the panel's own hotkey path; payloads are dropped for
  // bar-widget panels, so direct downloads go through the IPC target below.
  function openWithUrl(url) {
    open()
    if (panelLoader.item) panelLoader.item.startWithUrl(String(url || ""))
  }

  function pasteFromClipboard() {
    open()
    if (panelLoader.item) panelLoader.item.pasteFromClipboard()
  }

  function openFolder() {
    if (panelLoader.item) panelLoader.item.openFolder()
  }

  // ---- popout coordination, mirroring the clock ---------------------------
  readonly property real openPanelIndicatorWidth: Style.bar.iconCanvas
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Glow the icon while a download runs, so the bar is a live status dot even
  // with the panel closed.
  readonly property bool busy: panelLoader.item ? panelLoader.item.running === true : false
  readonly property real dlProgress: panelLoader.item ? panelLoader.item.dlProgress / 100 : 0
  readonly property bool dlIndeterminate: panelLoader.item ? panelLoader.item.dlIndeterminate === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "bhanu.omavideos"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function download(url: string): void { root.openWithUrl(url) }
    function paste(): void { root.pasteFromClipboard() }
    function sel(pos: string): void { if (panelLoader.item) panelLoader.item.selItem(String(pos)) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    tooltipText: "OmaVideos — download any video"

    OmaPlayButton {
      anchors.centerIn: parent
      width: Style.bar.iconFont
      height: Style.bar.iconFont
      color: button.foreground
      accent: Color.accent
      busy: root.busy
      progress: root.busy ? (root.dlIndeterminate ? -1 : root.dlProgress) : -1
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.pasteFromClipboard()
      else if (b === Qt.MiddleButton) root.openFolder()
      else root.togglePanel()
    }
  }
}
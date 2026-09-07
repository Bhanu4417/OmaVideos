import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaVideos download panel. The bar widget owns the button; this panel owns
// the paste-a-URL flow: options (quality cap, audio-only), a live yt-dlp
// progress line, a done/error state, and a compact recent list.
//
// Pasting a URL that points at a YouTube playlist automatically lists its
// videos so you can grab all of them or just the ones you pick. Downloads
// keep running while the panel is closed — closing only hides the surface,
// and the bar icon lights up for as long as a download is in flight.
Panel {
  id: root
  moduleName: "bhanu.omavideos"
  ipcTarget: "bhanu.omavideos"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot (BarWidget.qml), not this
  // nested panel, so anything the bar identifies a panel by has to be that
  // widget — same rule as the built-in clock.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- theme --------------------------------------------------------------
  readonly property color contentForeground: bar ? bar.barForeground : Color.popups.text
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent

  // ---- settings-backed state ---------------------------------------------
  property string quality: setting("quality", "best")
  property bool audioOnly: boolSetting("audioOnly", false)
  property bool trim: boolSetting("trim", false)
  property string trimStart: setting("trimStart", "")
  property string trimEnd: setting("trimEnd", "")
  property string ytClient: setting("ytClient", "web_embedded")

  // ---- playlist state -----------------------------------------------------
  property bool playlistMode: false
  property bool playlistLoading: false
  property int playlistLoaded: 0
  property int playlistTotal: 0
  property int playlistCount: 0
  property int playlistSelectedCount: 0
  property string lastListedUrl: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string defaultDir: home + "/Videos/omavideos"
  readonly property string downloadDir: {
    var d = String(setting("downloadDir", "") || "").trim()
    if (!d) return defaultDir
    if (d.indexOf("~/") === 0) d = home + d.substr(1)
    return d
  }

  // ---- download state -----------------------------------------------------
  property bool running: false
  property bool expectedStop: false
  property bool autoPaste: false
  property int dlPass: 0
  property real dlProgress: 0
  property bool dlIndeterminate: true
  property string dlPhase: ""
  property int dlPlaylistDone: 0
  property int dlPlaylistTotal: 0
  property string dlFile: ""
  property string dlError: ""
  property string dlState: "idle"   // idle | running | done | error
  property var pendingDlArgs: []
  property var dlQueue: []
  property int dlQueueIndex: 0
  property var recent: []

  function boolSetting(name, fallback) {
    var v = root.setting(name, undefined)
    if (v === undefined || v === null) return fallback
    var t = String(v).toLowerCase()
    if (t === "true" || t === "on" || t === "1" || t === "yes") return true
    if (t === "false" || t === "off" || t === "0" || t === "no") return false
    return fallback
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value.
  function persist(values) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleAudio() {
    root.audioOnly = !root.audioOnly
    persist({ audioOnly: root.audioOnly })
  }

  function toggleTrim() {
    root.trim = !root.trim
    // Switching trim off also clears the saved range, so a later download
    // can never pick up a leftover start/end pair.
    persist(root.trim
      ? { trim: true }
      : { trim: false, trimStart: "", trimEnd: "" })
    if (!root.trim) { root.trimStart = ""; root.trimEnd = "" }
  }

  // ---- panel lifecycle -----------------------------------------------------
  function open() {
    root.controller.show()
    Qt.callLater(function() {
      if (!root.opened) return
      root.autoPaste = true
      if (!String(urlField.text).trim()) root.pasteFromClipboard()
      urlField.forceActiveFocus()
      playlistDebounce.restart()
    })
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- clipboard ------------------------------------------------------------
  function pasteFromClipboard() {
    if (pasteProc.running) return
    pasteProc.running = true
  }

  // ---- actions ---------------------------------------------------------------
  function startWithUrl(url) {
    urlField.text = String(url || "")
    root.startDownload()
  }

  function startDownload() {
    if (root.running) return
    var url = String(urlField.text || "").trim()
    if (!url) {
      root.dlState = "idle"
      root.statusHint = "Enter a video URL first."
      return
    }

    // Playlist: build the item list from the selection. All selected means a
    // plain full-playlist download; a partial selection downloads each picked
    // video by its own ID so a dynamic playlist (auto-mix) can't reorder and
    // swap a different one in.
    var items = ""
    var playlistMode = false
    if (root.dlQueueIndex === 0) {
      playlistMode = root.playlistMode && root.playlistCount > 0
      if (playlistMode) {
        if (root.playlistLoading) {
          root.dlState = "idle"
          root.statusHint = "Loading playlist…"
          return
        }
        if (root.playlistSelectedCount === 0) {
          root.dlState = "idle"
          root.statusHint = "Select at least one video."
          return
        }
        if (root.playlistSelectedCount < root.playlistCount) {
          var pickedUrls = []
          for (var i = 0; i < playlistModel.count; i++) {
            var row = playlistModel.get(i)
            if (row.selected && row.videoId) {
              var vurl = "https://www.youtube.com/watch?v=" + row.videoId
              if (pickedUrls.indexOf(vurl) === -1) pickedUrls.push(vurl)
            }
          }
          if (pickedUrls.length > 0) {
            root.dlQueue = pickedUrls
            root.dlQueueIndex = 0
            url = pickedUrls[0]
            playlistMode = false
          } else {
            root.dlQueue = []
            root.dlQueueIndex = 0
          }
        } else {
          root.dlQueue = []
          root.dlQueueIndex = 0
        }
      }
    }

    // Trim: normalize the optional start/end timestamps.
    var ts = { start: null, end: null }
    if (root.trim) {
      var startText = String(root.trimStart || "").trim()
      var endText = String(root.trimEnd || "").trim()
      if (startText) ts.start = Model.normalizeTimestamp(startText)
      if (endText) ts.end = Model.normalizeTimestamp(endText)
      if (startText && !ts.start) { root.dlState = "idle"; root.statusHint = "Start time looks off — try 1:30."; return }
      if (endText && !ts.end) { root.dlState = "idle"; root.statusHint = "End time looks off — try 2:45."; return }
      if (ts.start && ts.end && ts.start >= ts.end) { root.dlState = "idle"; root.statusHint = "End must come after start."; return }
    }

    root.statusHint = ""
    root.dlState = "running"
    root.running = true
    root.expectedStop = false
    root.dlPass = 0
    root.dlProgress = 0
    root.dlIndeterminate = true
    root.dlPhase = ""
    root.dlPlaylistDone = 0
    root.dlPlaylistTotal = 0
    root.dlFile = ""
    root.dlError = ""
    root.dlStatus = "Starting…"

    root.pendingDlArgs = Model.buildArgs({
      url: url,
      quality: root.quality,
      audioOnly: root.audioOnly,
      playlistMode: playlistMode,
      playlistItems: items,
      trim: root.trim,
      trimStart: ts.start,
      trimEnd: ts.end,
      downloadDir: root.downloadDir,
      ytClient: root.ytClient
    })

    mkdirProc.command = ["mkdir", "-p", root.downloadDir]
    mkdirProc.running = true
  }

  function launchDownload() {
    dlProc.command = root.pendingDlArgs
    dlProc.running = true
  }

  function cancelDownload() {
    if (!root.running) return
    root.expectedStop = true
    root.dlStatus = "Cancelling…"
    dlProc.running = false
  }

  function openFolder() {
    Util.execDetached("mkdir -p " + Util.shellQuote(root.downloadDir) + " && xdg-open " + Util.shellQuote(root.downloadDir))
  }

  function openFile(path) {
    if (!path) { root.openFolder(); return }
    Util.execDetached("xdg-open " + Util.shellQuote(path))
  }

  function openRecent(entry) {
    if (entry && entry.file) root.openFile(entry.file)
    else root.openFolder()
  }

  // ---- playlist detection ---------------------------------------------------
  function maybeRefreshPlaylist() {
    // While a download runs the playlist context stays frozen — re-listing
    // would hide the in-flight download behind a fresh "Detecting…" state.
    if (root.running) return
    var url = String(urlField.text || "").trim()
    if (url === root.lastListedUrl && playlistModel.count > 0) return
    if (Model.looksLikePlaylist(url)) {
      root.lastListedUrl = url
      root.playlistMode = true
      root.playlistLoading = true
      root.playlistLoaded = 0
      root.playlistTotal = 0
      playlistModel.clear()
      root.playlistCount = 0
      root.playlistSelectedCount = 0
      if (!listProc.running) {
        listProc.command = ["yt-dlp", "--flat-playlist", "--no-warnings", "--print", "%(playlist_index)03d\t%(playlist_count)s\t%(title)s\t%(id)s", url]
        listProc.running = true
      }
    } else {
      root.lastListedUrl = url
      root.playlistMode = false
      root.playlistLoading = false
      root.playlistLoaded = 0
      root.playlistTotal = 0
      playlistModel.clear()
      root.playlistCount = 0
      root.playlistSelectedCount = 0
    }
  }

  function addPlaylistLine(line) {
    var entry = Model.parsePlaylistEntryLine(line)
    if (!entry) return
    if (entry.playlistCount > 0 && root.playlistTotal === 0) root.playlistTotal = entry.playlistCount
    playlistModel.append({ entryIndex: entry.entryIndex, title: entry.title, videoId: entry.videoId, selected: true })
    root.playlistLoaded = playlistModel.count
  }

  function countSelectedPlaylist() {
    var n = 0
    for (var i = 0; i < playlistModel.count; i++) if (playlistModel.get(i).selected) n++
    return n
  }

  function togglePlaylistEntry(position) {
    // The delegate's built-in `index` is unreliable with required-property
    // delegates (always 0), so rows carry their playlist position and we look
    // the model row up by it.
    for (var i = 0; i < playlistModel.count; i++) {
      var row = playlistModel.get(i)
      if (row.entryIndex !== position) continue
      playlistModel.set(i, {
        entryIndex: row.entryIndex,
        title: row.title,
        videoId: row.videoId,
        selected: !row.selected
      })
      break
    }
    root.playlistSelectedCount = root.countSelectedPlaylist()
  }

  function selItem(pos) {
    var p = parseInt(String(pos || ""), 10)
    if (!isFinite(p)) return
    root.togglePlaylistEntry(p)
    var found = -1
    for (var i = 0; i < playlistModel.count; i++) if (playlistModel.get(i).entryIndex === p) found = i
    console.log("omavideos SEL toggled entry", p, "selected", found >= 0 ? playlistModel.get(found).selected : "?")
  }

  function selectAllPlaylist() {
    for (var i = 0; i < playlistModel.count; i++) {
      var row = playlistModel.get(i)
      if (!row.selected) {
        playlistModel.set(i, {
          entryIndex: row.entryIndex,
          title: row.title,
          videoId: row.videoId,
          selected: true
        })
      }
    }
    root.playlistSelectedCount = playlistModel.count
  }

  function selectNonePlaylist() {
    for (var i = 0; i < playlistModel.count; i++) {
      var row = playlistModel.get(i)
      if (row.selected) {
        playlistModel.set(i, {
          entryIndex: row.entryIndex,
          title: row.title,
          videoId: row.videoId,
          selected: false
        })
      }
    }
    root.playlistSelectedCount = 0
  }

  // ---- yt-dlp output parsing ----------------------------------------------
  function handleDlLine(line) {
    line = String(line || "").trim()
    if (!line) return

    if (Model.isErrorLine(line)) {
      root.dlError = line.replace(/^ERROR:\s*/, "")
      return
    }
    if (Model.isMergerLine(line)) {
      root.dlPhase = "Merging"
      root.dlIndeterminate = true
      var merged = Model.extractFilePath(line)
      if (merged) root.dlFile = merged
      return
    }
    if (Model.isExtractAudioLine(line)) {
      root.dlPhase = "Audio"
      root.dlIndeterminate = true
      var audio = Model.extractFilePath(line)
      if (audio) root.dlFile = audio
      return
    }
    if (Model.isDestinationLine(line)) {
      root.dlPass = root.dlPass + 1
      root.dlPhase = root.audioOnly ? "Audio" : (root.dlPass === 1 ? "Video" : "Audio")
      root.dlProgress = 0
      root.dlIndeterminate = false
      var dest = Model.extractFilePath(line)
      if (dest) root.dlFile = dest
      return
    }
    var prog = Model.parseProgressLine(line)
    if (prog) {
      root.dlProgress = prog.percent
      root.dlIndeterminate = false
      if (!root.dlPhase) root.dlPhase = root.audioOnly ? "Audio" : "Video"
      return
    }
    var pl = Model.parsePlaylistProgress(line)
    if (pl) {
      root.dlPlaylistTotal = pl.total
      root.dlPlaylistDone = Math.max(0, pl.current - 1)
    }
  }

  function handleDlExit(exitCode) {
    root.dlPass = 0

    if (root.expectedStop) {
      root.running = false
      root.dlState = "idle"
      root.dlProgress = 0
      root.dlIndeterminate = true
      root.dlStatus = "Cancelled."
      return
    }

    if (exitCode !== 0) {
      root.running = false
      root.dlState = "error"
      root.dlIndeterminate = false
      root.dlStatus = Model.friendlyError(root.dlError) || "Download failed (exit " + exitCode + ")."
      return
    }

    root.running = false
    root.dlState = "done"
    root.dlProgress = 100
    root.dlIndeterminate = false
    if (root.dlPlaylistTotal > 0) root.dlPlaylistDone = root.dlPlaylistTotal
    root.dlStatus = "Saved — " + (root.dlFile ? Model.fileBaseName(root.dlFile) : "to " + root.downloadDir)

    var file = root.dlFile || ""
    var entry = { file: file, dir: root.downloadDir, title: Model.fileBaseName(file) || "Download", time: Date.now() }
    root.recent = Model.addRecent(root.recent, entry, 8)
    recentFile.setText(Model.recentToJson(root.recent))

    root.notifyComplete(file)

    // Continue through the selected-video queue, if any.
    if (root.dlQueueIndex < root.dlQueue.length - 1) {
      root.dlQueueIndex++
      urlField.text = root.dlQueue[root.dlQueueIndex]
      Qt.callLater(root.startDownload)
      return
    }
    root.dlQueue = []
    root.dlQueueIndex = 0
  }

  function notifyComplete(file) {
    var om = Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
    var icon = String(Qt.resolvedUrl("preview.png")).replace(/^file:\/\//, "")
    var title = Model.fileBaseName(file) || "Playlist saved"
    var body = root.downloadDir
    Quickshell.execDetached([om + "/bin/omarchy-notification-send",
      "--app-name", "OmaVideos", "-u", "normal", "--image", icon,
      "Download complete", title + " — " + body])
  }

  function clearRecent() {
    root.recent = []
    recentFile.setText(Model.recentToJson(root.recent))
  }

  function removeRecentAt(index) {
    root.recent = Model.removeRecent(root.recent, index)
    recentFile.setText(Model.recentToJson(root.recent))
  }

  // ---- status line ----------------------------------------------------------
  property string statusHint: ""
  property string dlStatus: ""
  readonly property string statusLine: {
    if (root.dlState === "idle") return root.statusHint !== "" ? root.statusHint : ("Saves to " + root.downloadDir)
    if (root.dlState === "running") {
      var parts = []
      if (root.dlPlaylistTotal > 0) parts.push("Playlist " + root.dlPlaylistDone + "/" + root.dlPlaylistTotal + " done")
      parts.push(root.dlPhase || "Downloading")
      if (!root.dlIndeterminate && root.dlProgress > 0) parts.push(Math.round(root.dlProgress) + "%")
      return parts.join(" · ")
    }
    if (root.dlState === "done") return root.dlStatus
    if (root.dlState === "error") return root.dlStatus
    return ""
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) {
      root.close()
      event.accepted = true
    } else if (!root.running && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      root.startDownload()
      event.accepted = true
    }
  }

  // ---- sub-processes ---------------------------------------------------------
  Process {
    id: mkdirProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.launchDownload()
      else {
        root.running = false
        root.dlState = "error"
        root.dlIndeterminate = false
        root.dlStatus = "Could not create " + root.downloadDir
      }
    }
  }

  Process {
    id: dlProc
    stdout: SplitParser { onRead: function(data) { root.handleDlLine(String(data)) } }
    stderr: SplitParser { onRead: function(data) { root.handleDlLine(String(data)) } }
    onExited: function(exitCode) { root.handleDlExit(exitCode) }
  }

  Process {
    id: pasteProc
    command: ["timeout", "3", "wl-paste", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t && (!root.autoPaste || Model.looksLikeUrl(t))) urlField.text = t
        root.autoPaste = false
        urlField.forceActiveFocus()
        urlField.selectAll()
        playlistDebounce.restart()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  // Flat-lists the videos of a pasted playlist URL so the panel can offer
  // "all or pick". Runs only when the URL looks like a playlist.
  Process {
    id: listProc
    stdout: SplitParser { onRead: function(data) { root.addPlaylistLine(String(data)) } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.playlistLoading = false
      root.playlistCount = playlistModel.count
      root.playlistSelectedCount = playlistModel.count
      if (root.playlistTotal === 0) root.playlistTotal = root.playlistCount
      if (exitCode !== 0 || playlistModel.count === 0) {
        root.playlistMode = false
        root.lastListedUrl = ""
        playlistModel.clear()
        root.playlistLoaded = 0
        root.playlistTotal = 0
        root.playlistCount = 0
        root.playlistSelectedCount = 0
        root.statusHint = "Could not read the playlist."
      }
    }
  }

  Timer {
    id: playlistDebounce
    interval: 500
    repeat: false
    onTriggered: root.maybeRefreshPlaylist()
  }

  ListModel {
    id: playlistModel
  }

  FileView {
    id: recentFile
    path: root.home + "/.local/state/omarchy/omavideos-recent.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.recent = Model.parseRecent(text())
    onFileChanged: reload()
    onLoadFailed: root.recent = []
  }

  // ---- surface ----------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: urlField
    contentWidth: panel.fittedContentWidth(Style.space(372))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      width: parent.width
      spacing: Style.spacing.md

      // ---- hero ---------------------------------------------------------------
      Row {
        width: parent.width
        spacing: Style.space(14)

        OmaVideoMark {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(44)
          height: Style.space(44)
          color: root.contentForeground
          accent: root.accent
          busy: root.running
          progress: root.running ? (root.dlIndeterminate ? -1 : root.dlProgress / 100) : -1
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(44) - parent.spacing
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: "OmaVideos"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: "YOUTUBE · REDDIT · X · ANY VIDEO"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
          }
        }
      }

      // ---- url row -------------------------------------------------------------
      Row {
        width: parent.width
        height: Style.spacing.controlHeight
        spacing: Style.spacing.md

        TextField {
          id: urlField
          width: parent.width - pasteButton.width - parent.spacing
          height: parent.height
          foreground: root.contentForeground
          accent: root.accent
          placeholderText: "Paste a video URL…"
          verticalPadding: 6
          onTextChanged: playlistDebounce.restart()
          onAccepted: if (!root.running) root.startDownload()
        }

        PanelActionButton {
          id: pasteButton
          width: parent.height
          height: parent.height
          iconText: "󰋈"
          tooltipText: "Paste from clipboard"
          foreground: root.contentForeground
          hoverColor: root.accent
          fontFamily: root.contentFontFamily
          onClicked: {
            root.autoPaste = false
            root.pasteFromClipboard()
          }
        }
      }

      // ---- options ---------------------------------------------------------------
      Row {
        width: parent.width
        height: Style.spacing.controlHeight
        spacing: Style.spacing.md

        Dropdown {
          id: qualityDropdown
          width: Style.space(132)
          height: parent.height
          showLabel: false
          options: Model.qualityOptions()
          value: root.quality
          foreground: root.contentForeground
          accent: root.accent
          onChanged: function(v) {
            root.quality = v
            root.persist({ quality: v })
          }
        }

        // Audio-only chip
        BorderSurface {
          width: parent.width - qualityDropdown.width - parent.spacing
          height: parent.height
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", root.contentForeground, root.accent)
          color: chipMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, root.accent) : "transparent"

          Behavior on color { ColorAnimation { duration: 90 } }

          MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleAudio()
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "󰐇"
            color: root.accent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.iconSmall
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX + Style.font.iconSmall + Style.spacing.xs
            anchors.right: audioSwitch.left
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            text: "Audio only"
            color: Qt.darker(root.contentForeground, 1.3)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          ToggleSwitch {
            id: audioSwitch
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            checked: root.audioOnly
            interactive: false
            foreground: root.contentForeground
            accent: root.accent
            trackHeight: Math.round(Style.spacing.controlHeight * 0.5)
          }
        }
      }

      // ---- trim chip ---------------------------------------------------------------
      BorderSurface {
        width: parent.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        borderSpec: Border.controlSpec("normal", root.contentForeground, root.accent)
        color: trimMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, root.accent) : "transparent"

        Behavior on color { ColorAnimation { duration: 90 } }

        MouseArea {
          id: trimMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleTrim()
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.verticalCenter: parent.verticalCenter
          text: "󰑰"
          color: root.accent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.iconSmall
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.controlPaddingX + Style.font.iconSmall + Style.spacing.xs
          anchors.right: trimSwitch.left
          anchors.rightMargin: Style.spacing.xs
          anchors.verticalCenter: parent.verticalCenter
          text: "Trim range"
          color: Qt.darker(root.contentForeground, 1.3)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        ToggleSwitch {
          id: trimSwitch
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.controlPaddingX
          anchors.verticalCenter: parent.verticalCenter
          checked: root.trim
          interactive: false
          foreground: root.contentForeground
          accent: root.accent
          trackHeight: Math.round(Style.spacing.controlHeight * 0.5)
        }
      }

      // ---- trim fields (when trim on) ------------------------------------------------
      Row {
        visible: root.trim
        width: parent.width
        height: visible ? Style.spacing.controlHeight : 0
        spacing: Style.spacing.md

        TextField {
          width: (parent.width - parent.spacing) / 2
          height: parent.height
          foreground: root.contentForeground
          accent: root.accent
          text: root.trimStart
          placeholderText: "start · 1:30"
          verticalPadding: 6
          onEditingFinished: root.persist({ trimStart: text })
        }

        TextField {
          width: (parent.width - parent.spacing) / 2
          height: parent.height
          foreground: root.contentForeground
          accent: root.accent
          text: root.trimEnd
          placeholderText: "end · 2:45"
          verticalPadding: 6
          onEditingFinished: root.persist({ trimEnd: text })
        }
      }

      // ---- playlist (auto-detected from a playlist URL) ------------------------------
      Column {
        visible: root.playlistMode
        width: parent.width
        spacing: Style.spacing.xs

        Row {
          visible: root.playlistLoading
          width: parent.width
          spacing: Style.spacing.sm

          ProgressRing {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(18)
            height: Style.space(18)
            color: root.contentForeground
            accent: root.accent
            progress: root.playlistTotal > 0 ? root.playlistLoaded / root.playlistTotal : -1
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.playlistTotal > 0
              ? "Loading playlist · " + root.playlistLoaded + "/" + root.playlistTotal
              : "Loading playlist…"
            color: Qt.darker(root.contentForeground, 1.3)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          visible: !root.playlistLoading
          width: parent.width
          spacing: Style.spacing.xs

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            PanelSectionHeader {
              text: "PLAYLIST · " + root.playlistCount + " VIDEOS"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Item { width: 1; height: 1 }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.playlistSelectedCount + "/" + root.playlistCount + " selected"
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              width: Style.space(34)
              height: Style.space(20)
              text: "All"
              foreground: root.contentForeground
              accent: root.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: root.selectAllPlaylist()
            }

            Button {
              width: Style.space(42)
              height: Style.space(20)
              text: "None"
              foreground: root.contentForeground
              accent: root.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: root.selectNonePlaylist()
            }
          }

          ListView {
            id: playlistList
            width: parent.width
            height: Math.min(playlistModel.count, 6) * Style.space(30)
            model: playlistModel
            clip: true
            spacing: Style.spacing.xs
            boundsBehavior: Flickable.StopAtBounds
            interactive: playlistModel.count > 6

            delegate: Rectangle {
              required property int entryIndex
              required property string title
              required property bool selected

              width: ListView.view.width
              height: Style.space(30)
              radius: Style.cornerRadius
              color: rowMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, root.accent) : "transparent"

              Behavior on color { ColorAnimation { duration: 90 } }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.togglePlaylistEntry(entryIndex)
              }

              ToggleSwitch {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                checked: selected
                interactive: false
                foreground: root.contentForeground
                accent: root.accent
                trackHeight: Math.round(Style.space(14))
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX + Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
                text: entryIndex < 10 ? "0" + entryIndex : String(entryIndex)
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX + Style.space(30) + Style.space(30)
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: title
                color: selected ? root.contentForeground : Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }
          }
        }
      }

      // ---- save folder ----------------------------------------------------------------
      Row {
        width: parent.width
        spacing: Style.spacing.xs

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰎃"
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width - folderBtn.width - parent.spacing * 2
          anchors.verticalCenter: parent.verticalCenter
          text: root.downloadDir
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }

        PanelActionButton {
          id: folderBtn
          width: Style.space(20)
          height: Style.space(20)
          iconText: "󰎃"
          tooltipText: "Open save folder"
          foreground: root.contentForeground
          hoverColor: root.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.caption
          onClicked: root.openFolder()
        }
      }

      // ---- progress / status ------------------------------------------------------------
      Column {
        visible: root.dlState !== "idle"
        width: parent.width
        spacing: Style.spacing.sm

        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: Style.cornerRadius > 0 ? height / 2 : 0
          color: Util.alpha(root.contentForeground, 0.12)

          Rectangle {
            width: root.dlIndeterminate ? parent.width : Math.max(Style.space(2), parent.width * root.dlProgress / 100)
            height: parent.height
            radius: parent.radius
            color: root.dlState === "error" ? Color.urgent : root.accent
            opacity: root.dlIndeterminate ? 0.45 : 1

            Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            SequentialAnimation on opacity {
              running: root.dlIndeterminate && root.dlState === "running"
              loops: Animation.Infinite
              NumberAnimation { to: 0.15; duration: 700; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 0.55; duration: 700; easing.type: Easing.InOutQuad }
            }
          }
        }

        Text {
          width: parent.width
          text: root.statusLine
          color: root.dlState === "error" ? Color.urgent : Qt.darker(root.contentForeground, 1.3)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }

      // ---- actions ------------------------------------------------------------------------
      Row {
        width: parent.width
        height: Style.spacing.controlHeight
        spacing: Style.spacing.md

        Button {
          id: downloadBtn
          width: parent.width - (cancelBtn.visible ? cancelBtn.width + parent.spacing : 0)
          height: parent.height
          text: root.running ? "Downloading…" : "Download"
          foreground: root.accent
          accent: root.accent
          selected: !root.running
          enabled: !root.running && !(root.playlistMode && root.playlistLoading)
          fontFamily: root.contentFontFamily
          onClicked: root.startDownload()
        }

        Button {
          id: cancelBtn
          visible: root.running
          width: Style.space(84)
          height: parent.height
          text: "Cancel"
          foreground: root.contentForeground
          accent: root.accent
          bordered: true
          fontFamily: root.contentFontFamily
          onClicked: root.cancelDownload()
        }
      }

      // ---- recent downloads ----------------------------------------------------------------
      Column {
        visible: root.recent.length > 0
        width: parent.width
        spacing: Style.spacing.xs

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          PanelSectionHeader {
            text: "RECENT"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Item { width: 1; height: 1 }

          PanelActionButton {
            width: Style.space(20)
            height: Style.space(20)
            iconText: "󰑣"
            tooltipText: "Clear recent"
            foreground: Qt.darker(root.contentForeground, 1.5)
            hoverColor: root.accent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.caption
            onClicked: root.clearRecent()
          }
        }

        Repeater {
          model: root.recent

          delegate: Rectangle {
            required property var modelData
            required property int index

            readonly property string title: modelData.title || Model.fileBaseName(modelData.file) || "Download"

            width: parent.width
            height: Style.space(30)
            radius: Style.cornerRadius
            color: rowMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, root.accent) : "transparent"

            Behavior on color { ColorAnimation { duration: 90 } }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openRecent(modelData)
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.right: timeText.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: title
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              id: timeText
              anchors.right: trashBtn.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: Qt.formatDateTime(new Date(modelData.time), "hh:mm")
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            PanelActionButton {
              id: trashBtn
              width: Style.space(22)
              height: Style.space(22)
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.xs
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑣"
              tooltipText: "Remove"
              foreground: Qt.darker(root.contentForeground, 1.5)
              hoverColor: root.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: root.removeRecentAt(index)
            }
          }
        }
      }
    }
  }
}
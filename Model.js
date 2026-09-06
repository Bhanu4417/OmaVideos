.pragma library

// Shared helpers for the OmaVideos downloader. Keeps the QML files focused
// on presentation; every yt-dlp decision lives here.

var QUALITY_OPTIONS = [
  { value: "best", label: "Best" },
  { value: "2160p", label: "2160p" },
  { value: "1440p", label: "1440p" },
  { value: "1080p", label: "1080p" },
  { value: "720p", label: "720p" }
]

function qualityOptions() { return QUALITY_OPTIONS }

// Format selector for the quality cap. Best merges the highest video and
// audio streams; capped variants filter by height first. Audio-only keeps
// just the best audio stream, which yt-dlp then converts to m4a.
function qualitySelector(quality, audioOnly) {
  if (audioOnly) return "ba/b"
  switch (String(quality || "").toLowerCase()) {
    case "2160p": return "bv*[height<=2160]+ba/b[height<=2160]"
    case "1440p": return "bv*[height<=1440]+ba/b[height<=1440]"
    case "1080p": return "bv*[height<=1080]+ba/b[height<=1080]"
    case "720p":  return "bv*[height<=720]+ba/b[height<=720]"
    default:      return "bv*+ba/b"
  }
}

// Output file name. Playlist downloads prefix the position so order survives
// the folder; a single video keeps a clean "<title> [id].<ext>".
function outputTemplate(playlistMode) {
  var stem = playlistMode ? "%(playlist_index)03d - %(title).160B" : "%(title).200B"
  return stem + " [%(id)s].%(ext)s"
}

function joinPath(dir, name) {
  var d = String(dir || "").replace(/\/+$/, "")
  return d.length > 0 ? d + "/" + name : name
}

// True when the URL points at a YouTube playlist (a list= query param or a
// /playlist path), the signal we use to auto-list its videos in the panel.
function looksLikePlaylist(url) {
  var u = String(url || "")
  return /[?&]list=[A-Za-z0-9_-]+/.test(u) || /\/playlist(\?|$)/.test(u)
}

// "001\t141\tTitle\tID" -> { entryIndex, playlistCount, title, videoId } or null.
// playlistCount is the total number of entries, printed by --flat-playlist, so
// the panel can show how much of the listing has loaded.
function parsePlaylistEntryLine(line) {
  var parts = String(line || "").split("\t")
  if (parts.length < 4) return null
  var idx = parseInt(parts[0], 10)
  if (!isFinite(idx)) return null
  var total = parseInt(parts[1], 10)
  return {
    entryIndex: idx,
    playlistCount: isFinite(total) && total > 0 ? total : 0,
    title: parts[2] || "Untitled",
    videoId: parts[3] || ""
  }
}

function pad2(n) {
  n = Math.floor(n)
  return n < 10 ? "0" + n : String(n)
}

function padSeconds(s) {
  s = Math.floor(s)
  return s < 10 ? "0" + s : String(s)
}

// Accepts plain seconds ("90", "1.5"), m:ss ("1:30") or h:mm:ss ("1:02:03")
// and normalizes to the zero-padded hh:mm:ss yt-dlp expects. Returns null
// when the input is not a recognizable timestamp.
function normalizeTimestamp(text) {
  var t = String(text || "").trim()
  if (!t) return null

  if (/^\d+(\.\d+)?$/.test(t)) {
    var secs = parseFloat(t)
    if (secs < 0) return null
    return pad2(secs / 3600) + ":" + pad2((secs % 3600) / 60) + ":" + padSeconds(secs % 60)
  }

  var parts = t.split(":")
  if (parts.length === 3) {
    var hh = parseInt(parts[0], 10)
    var mm = parseInt(parts[1], 10)
    var ss = parseInt(parts[2], 10)
    if (!isFinite(hh) || !isFinite(mm) || !isFinite(ss)) return null
    if (hh < 0 || mm < 0 || ss < 0 || mm >= 60 || ss >= 60) return null
    return pad2(hh) + ":" + pad2(mm) + ":" + pad2(ss)
  }
  if (parts.length === 2) {
    var mn = parseInt(parts[0], 10)
    var sc = parseInt(parts[1], 10)
    if (!isFinite(mn) || !isFinite(sc)) return null
    if (mn < 0 || sc < 0 || sc >= 60) return null
    return "00:" + pad2(mn) + ":" + pad2(sc)
  }
  return null
}

function looksLikeUrl(text) {
  var t = String(text || "").trim()
  if (!t) return false
  if (/^(https?:\/\/|ftp:\/\/)/i.test(t)) return true
  if (/^www\.[^\s]+/i.test(t)) return true
  if (/^(youtu\.be\/|youtube\.com\/|vimeo\.com\/|twitch\.tv\/|x\.com\/|twitter\.com\/|reddit\.com\/|v\.redd\.it\/)/i.test(t)) return true
  return false
}

// Full yt-dlp command for a download. `o` fields:
//   url, quality, audioOnly, playlistMode, playlistItems, trim, trimStart, trimEnd,
//   downloadDir, ytClient
function buildArgs(o) {
  var args = ["yt-dlp", "--newline"]

  // YouTube's media CDN is prone to 403 blocks for many player clients. The
  // embedded-web client serves the full resolution range and downloads
  // reliably, and the selector is scoped to the youtube extractor, so other
  // sites are unaffected.
  if (o.ytClient) args.push("--extractor-args", "youtube:player_client=" + o.ytClient)

  if (o.playlistMode) {
    args.push("--yes-playlist")
    if (o.playlistItems) args.push("--playlist-items", o.playlistItems)
  } else {
    args.push("--no-playlist")
  }

  args.push("-f", qualitySelector(o.quality, o.audioOnly))

  if (o.audioOnly) {
    args.push("-x", "--audio-format", "m4a", "--audio-quality", "0")
  }

  if (o.trim && o.trimStart && o.trimEnd) {
    // The `*` prefix cuts every downloaded stream, not just the best one, so
    // the merged video+audio pair stays in sync. Keyframe-forcing re-encodes
    // to cut at the exact requested timestamps; audio-only sections are cut
    // natively so no re-encode is needed there.
    args.push("--download-sections", "*" + o.trimStart + "-" + o.trimEnd)
    if (!o.audioOnly) args.push("--force-keyframes-at-cuts")
  }

  args.push("--embed-metadata")
  args.push("-o", joinPath(o.downloadDir, outputTemplate(o.playlistMode)))
  args.push(String(o.url || ""))
  return args
}

// ---- progress / status line parsing -------------------------------------

function parseProgressLine(line) {
  var m = /^\[download\]\s+([\d.]+)%\s+of\s+\S+(?:\s+at\s+(\S+)\s+ETA\s+(\S+))?/.exec(line)
  if (!m) return null
  return {
    percent: parseFloat(m[1]),
    speed: m[2] && m[2] !== "Unknown" ? m[2] : "",
    eta: m[3] && m[3] !== "Unknown" ? m[3] : ""
  }
}

function isDestinationLine(line) {
  return line.indexOf("[download] Destination:") !== -1
}

function isMergerLine(line) {
  return line.indexOf("[Merger]") !== -1
}

function isExtractAudioLine(line) {
  return line.indexOf("[ExtractAudio]") !== -1
}

function isErrorLine(line) {
  return line.indexOf("ERROR:") !== -1
}

function parsePlaylistProgress(line) {
  var m = /\[Playlist\] Downloading item (\d+) of (\d+)/.exec(line)
  return m ? { current: parseInt(m[1], 10), total: parseInt(m[2], 10) } : null
}

function extractFilePath(line) {
  var m = /"([^"]+)"/.exec(line)
  if (m) return m[1]
  m = /\[(?:Merger|ExtractAudio|download)\]\s*(?:Merging formats into|Destination):\s*(.+?)\s*$/.exec(line)
  return m ? m[1].replace(/^"|"$/g, "") : ""
}

function fileBaseName(path) {
  var p = String(path || "")
  var base = p.split("/").pop()
  var dot = base.lastIndexOf(".")
  return dot > 0 ? base.substr(0, dot) : base
}

// ---- recent-downloads persistence ----------------------------------------

function parseRecent(raw) {
  try {
    var list = JSON.parse(raw || "[]")
    return Array.isArray(list) ? list : []
  } catch (e) {
    return []
  }
}

function addRecent(list, entry, max) {
  var out = list.slice()
  out.unshift(entry)
  var seen = {}
  var deduped = []
  for (var i = 0; i < out.length; i++) {
    var key = out[i].file || out[i].title
    if (!key || seen[key]) continue
    seen[key] = true
    deduped.push(out[i])
  }
  return deduped.slice(0, max)
}

function removeRecent(list, index) {
  return list.slice(0, index).concat(list.slice(index + 1))
}

function recentToJson(list) {
  return JSON.stringify(list, null, 2) + "\n"
}
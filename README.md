# OmaVideos

A minimal bar-widget for Omarchy that turns a pasted URL into a finished
download. Paste a YouTube, Reddit, X, Vimeo, Twitch — or any other yt-dlp
supported URL — and it lands in your `omavideos` folder at the best quality
with audio, while the bar arrow glows until it is done.

![OmaVideos preview](preview.png)

## Features

- **One-click grab** — click the download arrow in the bar, paste a URL, hit
  Enter. Right-click the arrow to open the panel prefilled from your clipboard.
- **Best quality with audio** — downloads merge the highest video and audio
  streams (yt-dlp `bv*+ba/b`) with metadata embedded.
- **The icon lights up** — the Omarchy-style play bar icon progressively fills
  with accent color as the download progresses, then returns to normal on finish.
- **Quality cap** — Best / 2160p / 1440p / 1080p / 720p.
- **Audio only** — extracts the best audio track as high-bitrate m4a.
- **Playlists** — grab the whole playlist, or pick entries by number/range
  (`1,3,5-8`).
- **Trim** — download only a slice of a video (`1:30` → `2:45`), cut exactly
  via keyframe-aware re-encoding.
- **Progress & status** — live progress bar, stream phase (video/audio/merging),
  playlist position, cancel, error surfacing.
- **Finish notification** — a desktop notification when each download completes.
- **Recent list** — the last eight downloads with one-click play / folder reveal.

## Requirements

- `yt-dlp` — the download engine (`omarchy pkg add yt-dlp` if missing).
- `ffmpeg` — required for merging, audio extraction, and trimming.

The plugin runs inside the long-running Omarchy shell and executes yt-dlp with
**your** user permissions, unsandboxed. It never starts a second Quickshell
process. Review any change to `Model.js` (which builds the yt-dlp command line)
before running it.

Site access varies: YouTube bot-checks can reject some IPs/networks, and X
sometimes needs cookies for certain content. Keep `yt-dlp` updated for new
site breakage.

> **YouTube 403 ("unable to download video data: Forbidden")** — YouTube's
> anti-bot now rejects the media CDN for most player clients. OmaVideos
> defaults to the `web_embedded` client (full resolutions, downloads
> reliably). If a video still fails, try another client in the widget
> settings → **YouTube client** (`tv_embedded`, `web_safari`, …), or export
> your browser cookies and point yt-dlp at them with `--cookies`.

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy-omavideos.git --enable --yes
# or, by hand:
#   copy this folder to ~/.config/omarchy/plugins/bhanu.omavideos/
omarchy-shell shell rescanPlugins
omarchy plugin enable bhanu.omavideos
```

Move the widget where you like it:

```bash
omarchy bar move bhanu.omavideos --section center
```

## Usage

- **Left-click** the arrow — panel opens. Paste a URL (or press the paste
  button), tweak options, press Enter or **Download**.
- **Right-click** the arrow — panel opens prefilled from the clipboard.
- **Middle-click** the arrow — opens the save folder.
- From a terminal or hotkey:

```bash
omarchy-shell bhanu.omavideos open          # open the panel
omarchy-shell bhanu.omavideos paste         # open + paste from clipboard
omarchy-shell bhanu.omavideos download 'https://youtu.be/…'   # grab directly
omarchy-shell shell summon bhanu.omavideos '{}'
omarchy-shell shell hide bhanu.omavideos
```

## Configuration

Right-click the widget → settings, or edit the widget's entry in
`~/.config/omarchy/shell.json`:

| Key            | Default                | Meaning                                |
|----------------|------------------------|----------------------------------------|
| `quality`      | `best`                 | Quality cap (`best`/`2160p`/…/`720p`)  |
| `audioOnly`    | `false`                | Extract best audio as m4a              |
| `playlist`     | `false`                | Download whole playlist                |
| `playlistItems`| `""`                   | e.g. `1,3,5-8` (empty = all)           |
| `trim`         | `false`                | Enable time-range trimming             |
| `trimStart`    | `""`                   | Start timestamp, e.g. `1:30`           |
| `trimEnd`      | `""`                   | End timestamp, e.g. `2:45`             |
| `downloadDir`  | `~/Videos/omavideos`   | Where downloads land                   |
| `ytClient`     | `web_embedded`         | YouTube player client                 |

Downloads keep running while the panel is closed; the bar icon lights up
until the last one finishes.

## Layout

```
manifest.json   Plugin contract (kind bar-widget, settings schema)
BarWidget.qml   Bar button (Omarchy-style play mark) + open/close lifecycle + IPC routes
Panel.qml       URL field, options, progress, recent list
OmaPlayButton.qml Theme-aware bar icon that lights up with download progress
OmaVideoMark.qml Theme-aware Omarchy+play mark (panel hero)
Model.js        yt-dlp command builder, parsers, recent-store helpers
assets/logo.svg Brand mark
preview.png     Notification icon / README preview
```

## License

MIT — see [LICENSE](LICENSE). `yt-dlp` is its own project under Unlicense/GPL.
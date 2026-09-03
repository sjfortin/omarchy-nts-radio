# NTS Radio for Omarchy

A compact [NTS Radio](https://www.nts.live) player for the Omarchy top bar.

![The NTS Radio panel](preview.png)

The bar shows the station mark, which channel you are on, and whether audio is
flowing. Click it for the full panel: channel selector, the live broadcast with
artwork and show details, transport controls, and what is coming up next.

Audio plays locally through **mpv** and PipeWire. There is no embedded browser
and no background daemon — mpv runs only while something is playing, and it
exposes MPRIS, so media keys and any other desktop media client control it like
any other player.

## Requirements

| Dependency | Required | What it does |
|------------|----------|--------------|
| `mpv` | for local playback | plays the stream on this machine |
| `curl` | yes | fetches the schedule (already present on Omarchy) |
| `mpv-mpris` | optional | media-key and MPRIS control |
| `python-pychromecast` | optional | casting to Chromecast / Google Home / Nest devices |

On Arch / Omarchy:

```bash
sudo pacman -S --needed mpv mpv-mpris python-pychromecast
```

Every one of those is in the official repos; nothing here needs the AUR. Each
optional piece degrades quietly on its own: without `mpv-mpris` you lose media
keys, without `python-pychromecast` the panel simply does not offer casting,
and without `mpv` the panel says so and points at the install command instead
of failing with a stream error.

Without `mpv-mpris` everything still works; you just lose media-key control.
The plugin looks for the script at `/etc/mpv/scripts/mpris.so`,
`/usr/lib/mpv/mpris.so`, `/usr/local/lib/mpv/mpris.so`,
`/usr/lib/x86_64-linux-gnu/mpv/mpris.so`, `~/.config/mpv/scripts/mpris.so` and
`~/.local/share/mpv/scripts/mpris.so`. `omarchy-shell nts-radio status` reports
`"mpris": true` when it found one.

## Install

```bash
omarchy plugin add https://github.com/sjfortin/omarchy-nts-radio.git --enable --yes
```

Or by hand:

```bash
git clone https://github.com/sjfortin/omarchy-nts-radio.git \
  ~/.config/omarchy/plugins/sjfortin.nts-radio
omarchy-shell shell rescanPlugins
omarchy plugin enable sjfortin.nts-radio
```

The widget lands on the right of the bar. Move it with `omarchy bar move`:

```bash
omarchy bar move sjfortin.nts-radio --section right --after omarchy.tray
```

## Using it

**In the bar**

| Action | Result |
|--------|--------|
| Click | open / close the panel |
| Middle-click | play / pause |
| Right-click | switch between NTS 1 and NTS 2 |
| Scroll | volume up / down |

**In the panel**

Click either channel block to switch — the selected one is inverted, and each
block shows what is on that channel right now so you can choose without
switching first. `PLAY` / `PAUSE` starts and stops the stream, `VOL` sets the
stream's own volume (independent of your system volume), and `OPEN` opens the
current episode on nts.live in your browser.

Playback is not tied to the panel. Closing the panel, moving the widget, or
opening a different bar panel all leave the stream running.

**Casting**

The `OUTPUT` section of the panel lists *This computer* plus any
Chromecast-protocol device on your network — Chromecast, Chromecast Audio,
Google Home, Nest speakers and displays. Pick one and the audio moves; pick
*This computer* and it comes back. If something was playing, it keeps playing
across the move.

Casting is not "route this laptop's audio elsewhere". The device fetches the
NTS stream itself, so nothing is decoded or re-encoded here and **your laptop
can sleep without interrupting the radio**. The plugin keeps a control
connection only to start, stop, set volume, and report status.

Two consequences worth knowing:

- The volume slider controls whichever output is active — the device's own
  volume when casting, mpv's when local. They are separate levels.
- Media keys and MPRIS apply to local playback only. A cast session is running
  on the device, not on this machine, so there is no local player for them to
  talk to.

The device shows the programme that was on air when casting started. Refreshing
that would mean reloading the stream on the device, and a gap in the audio
every time a show changes is worse than a stale title.

Your chosen device is remembered between sessions and reconnected
automatically when it is back on the network.

**Media keys**

While something is playing, mpv registers as
`org.mpris.MediaPlayer2.mpv.ntsradio`. Play/pause keys work, and the track
title reported to your OSD is the current NTS show rather than the raw stream
name. Resuming rejoins the live edge instead of replaying whatever was left in
the buffer.

**From the command line / keybindings**

```bash
omarchy-shell nts-radio toggle       # play or pause
omarchy-shell nts-radio play
omarchy-shell nts-radio pause
omarchy-shell nts-radio next         # other channel
omarchy-shell nts-radio channel 2
omarchy-shell nts-radio volume 60
omarchy-shell nts-radio status       # JSON: channel, playback, output, show, up next
omarchy-shell nts-radio devices      # discover cast devices, as JSON
omarchy-shell nts-radio output local            # play here
omarchy-shell nts-radio output cast             # play on the remembered device
omarchy-shell nts-radio output <device-uuid>    # play on a specific device
```

Bind them in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER SHIFT, N, NTS play/pause, exec, omarchy-shell nts-radio toggle
bindd = SUPER SHIFT, M, NTS channel,    exec, omarchy-shell nts-radio next
```

`omarchy-shell shell toggle sjfortin.nts-radio` opens and closes the panel.

## Settings

Under **Setup → Plugins → NTS Radio**, or as keys on the widget's entry in
`~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|-----|---------|---------|
| `channel` | `NTS 1` | Channel to start on. Switching in the panel updates this, so the plugin comes back on the channel you left it on. |
| `showTitleInBar` | `When playing` | `Always`, `When playing`, or `Never` for the broadcast title in the bar. |
| `maxBarTextWidth` | `160` | Pixel cap on that title. `0` hides it. |
| `volume` | `70` | Stream volume, remembered between sessions. |
| `refreshMinutes` | `1` | Minutes between schedule refreshes while the panel is open or audio is playing. |
| `output` | `local` | `local` or `cast`. Set by picking an output in the panel. |
| `castDevice` | — | UUID of the remembered cast device. |
| `castDeviceName` | — | Its friendly name, so the panel can name it before discovery finishes. |

Editing these takes effect immediately — no restart.

## How it behaves

**Network.** One `curl` to `https://www.nts.live/api/v2/live` per refresh,
capped at 12 seconds and run in a subprocess, so the shell's UI thread never
waits on the network. While a panel is open or audio is playing, that is once
per `refreshMinutes`; otherwise once every 15 minutes. A refresh is also
scheduled to land just after the current broadcast ends, so the panel changes
over with the schedule instead of drifting up to a minute behind.

**Failures.** A failed fetch keeps the last good schedule on screen and shows a
single quiet line in the panel — never a notification. A dropped stream
reconnects on a 5s / 15s / 45s / 60s backoff. Nothing here can take the shell
down: every response is parsed defensively, every string is stripped of markup
and length-capped before it reaches the UI, and artwork is only loaded from
NTS's own media hosts.

**Resources.** mpv exists only while playing, and is stopped five minutes after
you pause. The cast bridge is a Python process that runs only while the panel is
open or a cast is in progress. Disabling or removing the plugin stops both
immediately and removes mpv's IPC socket. The panel's clock only ticks while a
panel is actually on screen.

## Removal

```bash
omarchy plugin remove sjfortin.nts-radio
```

Or, for a manual install:

```bash
omarchy plugin disable sjfortin.nts-radio
rm -rf ~/.config/omarchy/plugins/sjfortin.nts-radio
omarchy-shell shell rescanPlugins
```

Disabling stops playback and leaves nothing running. The plugin writes no state
outside its entry in `~/.config/omarchy/shell.json`, which `omarchy plugin
disable` removes for you.

## Troubleshooting

**Nothing plays and the panel says "Stream unavailable".** Check that mpv is
installed and can reach the stream:

```bash
mpv --no-video https://stream-relay-geo.ntslive.net/stream
```

**No devices appear under Output.** Confirm the backend is present with
`omarchy-shell nts-radio status` — `"castAvailable": true` means the bridge
loaded. Then `omarchy-shell nts-radio devices` runs a discovery and prints what
it found. Devices must be on the same network segment as this machine; mDNS
does not cross most VLANs or guest networks.

**Media keys do nothing.** Install `mpv-mpris` and confirm
`omarchy-shell nts-radio status` reports `"mpris": true`. Media keys only reach
this plugin while it is actually playing; when it is stopped there is no player
to control, and the keys fall through to whatever else is running.

**The panel looks stale after editing the plugin.** Saving a file under
`~/.config/omarchy/plugins/` reloads the plugin, but QML files loaded by URL are
cached for the life of the process. `omarchy restart shell` picks them up.

**Playback state looks wrong.** `omarchy-shell nts-radio status` reports what
the plugin believes; comparing it with mpv directly usually settles it:

```bash
echo '{"command":["get_property","core-idle"]}' \
  | socat - "$XDG_RUNTIME_DIR/omarchy-nts-radio.mpv.sock"
```

## Layout

```
manifest.json    plugin manifest (bar-widget + service)
Service.qml      shared state: schedule polling, channel, playback, IPC
Player.qml       the mpv child process and its JSON IPC socket
Caster.qml       playback on a Chromecast device, and device discovery
Model.js         every NTS endpoint, all response parsing and sanitization
scripts/cast.py  the Chromecast bridge, newline JSON on stdin/stdout
BarWidget.qml    the collapsed bar presence, and host for the panel popup
Panel.qml        the expanded panel
NtsMark.qml      the station mark
```

`Model.js` is the only file that knows an NTS URL or the shape of an NTS
response. If NTS changes their service, that is the file to change.

## Notes

This is an unofficial, unaffiliated plugin. It is not endorsed by NTS Live, and
it ships none of their artwork or trademarks — the station mark is drawn from
your Omarchy theme's own two colours. It plays the same public streams the
nts.live website plays, using the same public endpoint the site's own player
uses. Please support NTS at [nts.live/supporters](https://www.nts.live/supporters).

## License

MIT. See [LICENSE](LICENSE).

# NTS Radio for Omarchy

An unofficial [NTS Radio](https://www.nts.live) client: live NTS 1 and NTS 2 in
the top bar, and a browser window for the archive.

![The NTS browser window](browser.png)

- Live radio in the bar, with the current broadcast title and playback controls.
- A browser window for the archive: search, show pages, episode pages,
  tracklists.
- A local library of saved shows and episodes, with resume positions.
- Audio plays locally through mpv, or on a Chromecast device that fetches the
  stream itself.
- Media keys and MPRIS, a scriptable IPC surface, and an optional launcher
  entry.

![The NTS Radio panel](preview.png)

## Requirements

| Package | Needed for | Without it |
|---------|------------|------------|
| `mpv` | playing anything locally | the panel says so instead of failing with a stream error |
| `curl` | the schedule and the browser | already present on Omarchy |
| `yt-dlp` | archived episodes | live radio still works, the archive goes quiet |
| `mpv-mpris` | media keys and MPRIS | everything else works, you lose media keys |
| `python-pychromecast` | casting | the panel does not offer casting |

```bash
omarchy pkg add mpv yt-dlp mpv-mpris python-pychromecast
```

All four are in the official repos. Nothing here needs the AUR.

The plugin needs no elevated privileges. Nothing it runs requires sudo or
pkexec, it writes only inside your home directory, and it never edits system
configuration.

## Install

```bash
omarchy plugin add https://github.com/sjfortin/omarchy-nts-radio.git --enable --yes
```

The widget lands on the right of the bar. Move it with `omarchy bar move`.

## In the bar

| Action | Result |
|--------|--------|
| Click | open or close the panel |
| Middle-click | play or pause |
| Right-click | switch NTS 1 / NTS 2, or return to live from an archived show |
| Scroll | volume |

The bar shows what is actually playing. On live radio that is the channel
number and the broadcast title. On an archived show the channel is replaced by
`ARC` and the title is the episode.

The panel has both channels (each showing what is on it right now), play/pause,
volume, output selection, and what is coming up next. `BROWSE` opens the
browser window, `OPEN` opens the current show on nts.live, and `LIVE` returns
to live radio from an archived show.

Playback is not tied to the panel. Closing it, moving the widget, or opening a
different bar panel all leave audio running.

## The browser window

```bash
omarchy-shell nts-radio browser
```

Three destinations in the left rail, with both live channels always one click
away:

- **Home**: what is on air, what you were part way through, your saved shows,
  and NTS Picks / Recently added.
- **Search**: grouped results across shows, episodes, tracks and tags.
- **Saved**: your library, in two tabs.

Clicking a row opens it. Clicking its artwork plays it.

Press `?` in the window, or click **? Keyboard** at the foot of the rail, for
this table:

| Key | Action |
|-----|--------|
| `/` or `Ctrl-F` | search |
| `↑` `↓` or `k` `j` | move the cursor |
| `PgUp` `PgDn` | move five at a time |
| `Enter` | open what the cursor is on |
| `p` | play what the cursor is on |
| `b` | save or unsave what the cursor is on |
| `Tab` | switch tabs on Saved |
| `Space` | play or pause |
| `1` `2` | live NTS 1 / NTS 2 |
| `h` `s` | Home / Saved |
| `←` `→` | scrub an archived show by 30s |
| `Esc` | back, then close |
| `Ctrl-W` | close |

In search, `↓` moves out of the query field into the results, and `↑` from the
first result puts you back in the field.

The window is an ordinary XDG toplevel, not a layer-shell overlay. It tiles,
moves between workspaces, and answers your window bindings. The card grids grow
a column rather than stretching, so a wider window shows more shows rather than
bigger ones.

## The archive and your library

Show pages carry the back catalogue, the host's biography, and their external
links. Episode pages carry the description, the broadcast date, and the
tracklist where NTS has one. Where you got to in a part-heard episode is
remembered, so it appears under *Continue listening* and the episode page
offers `RESUME` alongside `FROM START`.

`SAVE` on any show or episode adds it to your library, which lives at
`~/.local/state/omarchy/nts-radio/library.json`. It is a plain file you own and
can edit or sync yourself. It is not your NTS account: NTS authenticates
through Firebase with email and password and publishes no third-party
integration surface, so a login here could only mean taking your real NTS
password. Saves made here do not appear on nts.live or in the NTS app, and
favourites there do not appear here.

Two things are worth knowing about archived playback.

**It needs `yt-dlp`.** NTS does not host archived audio. Every episode points
at a SoundCloud or Mixcloud upload, which is what nts.live plays too, and mpv's
ytdl hook is what resolves those. Live radio does not use it. Episodes NTS
never uploaded are listed with *No audio*.

**Tracklists are shown without timestamps, on purpose.** NTS sells those as a
[Supporter](https://www.nts.live/supporters) benefit. Their API returns them
without asking who is calling, so the plugin discards them at the parser.

## Casting

Radio always starts on this computer. Casting is a deliberate choice each
session, so the plugin never begins by playing on a speaker in another room.

The `OUTPUT` section of the panel lists *This computer* plus any
Chromecast-protocol device on your network: Chromecast, Chromecast Audio,
Google Home, Nest speakers and displays. Pick one and the audio moves. If
something was playing, it keeps playing across the move. Your chosen device is
remembered so switching back is one click.

The device fetches the NTS stream itself, so nothing is re-encoded here and
your laptop can sleep without interrupting the radio. Archived shows cast too
and stay seekable on the device.

- The volume slider controls whichever output is active. The device and mpv
  keep separate levels.
- Media keys and MPRIS apply to local playback only, since a cast session runs
  on the device.
- The device shows the programme that was on air when casting started.
  Refreshing it would mean reloading the stream and a gap in the audio.
- A few episodes only publish formats no Chromecast can decode. Those fall back
  to playing here, and the panel says so.

A cast outlives the shell, so if the last session ended while casting, the
plugin asks that device once whether it is still playing. If it is, the panel
takes the session back so you can stop it. It only ever adopts a stream it
recognises, so it will not take over someone else's music.

## Command line and keybindings

```bash
omarchy-shell nts-radio toggle       # play or pause
omarchy-shell nts-radio play
omarchy-shell nts-radio pause
omarchy-shell nts-radio next         # other channel
omarchy-shell nts-radio channel 2
omarchy-shell nts-radio volume 60
omarchy-shell nts-radio live         # back to live radio
omarchy-shell nts-radio live 2       # back to live, on NTS 2
omarchy-shell nts-radio seek 1500    # jump to 25:00 in an archived show
omarchy-shell nts-radio seek +30     # forward 30s, or -30 for back

omarchy-shell nts-radio browser      # open or close the browser (toggle)
omarchy-shell nts-radio open home    # open without closing again
omarchy-shell nts-radio open search  # or straight onto search
omarchy-shell nts-radio open saved   # or your library

omarchy-shell nts-radio output local          # play here
omarchy-shell nts-radio output cast           # play on the remembered device
omarchy-shell nts-radio output <device-uuid>  # play on a specific device
omarchy-shell nts-radio devices               # discover devices, as JSON

omarchy-shell nts-radio status       # JSON: playback, output, show, archive, library
omarchy-shell nts-radio episode <show-alias> <episode-alias>
```

The two aliases `episode` takes are the last two path segments of the nts.live
URL. For
`https://www.nts.live/shows/floating-points/episodes/floating-points-27th-july-2026`
that is `floating-points floating-points-27th-july-2026`.

Bind them in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER SHIFT, N, NTS play/pause, exec, omarchy-shell nts-radio toggle
bindd = SUPER SHIFT, M, NTS channel,    exec, omarchy-shell nts-radio next
bindd = SUPER SHIFT, B, NTS browser,    exec, omarchy-shell nts-radio browser
```

`browser` toggles, which is what a keybinding wants. `open` does not, which is
what a launcher wants.

## Launcher entry

Optional. Puts the browser window in the Omarchy menu (`SUPER + SPACE`) and any
launcher that reads XDG desktop entries, with right-click actions for **Search
NTS** and **Saved shows**:

```bash
~/.config/omarchy/plugins/sjfortin.nts-radio/desktop/install-app.sh
```

It writes a `.desktop` file and two icons under `~/.local/share`, and nothing
else. `omarchy plugin add` does not run install hooks, so this step is manual
by design, and so is undoing it.

## Settings

Under **Setup → Plugins → NTS Radio**, or as keys on the widget's entry in
`~/.config/omarchy/shell.json`. All take effect immediately.

| Key | Default | Meaning |
|-----|---------|---------|
| `channel` | `NTS 1` | Channel to start on. Switching in the panel updates this. |
| `showTitleInBar` | `When playing` | `Always`, `When playing`, or `Never`. |
| `maxBarTextWidth` | `160` | Pixel cap on the bar title. `0` hides it. |
| `volume` | `70` | Stream volume, independent of system volume. |
| `refreshMinutes` | `1` | Minutes between schedule refreshes while a panel or the browser is open, or audio is playing. Otherwise every 15 minutes. |
| `scrollSpeed` | `100` | How far a swipe or wheel notch scrolls in the browser, as a percentage. Raise it if scrolling feels heavy. |
| `output` | `local` | Records what the last session was doing. Not restored as a starting output. |
| `castDevice` | | UUID of the remembered cast device. |
| `castDeviceName` | | Its name, so the panel can label it before discovery finishes. |

## Removal

If you installed the launcher entry, remove it first: `omarchy plugin remove`
deletes the plugin directory, and the uninstaller lives inside it.

```bash
~/.config/omarchy/plugins/sjfortin.nts-radio/desktop/install-app.sh --remove
omarchy plugin remove sjfortin.nts-radio
```

Disabling stops playback and leaves nothing running. Your library at
`~/.local/state/omarchy/nts-radio/library.json` is left alone, so reinstalling
gets your saved shows back. Delete it yourself if you want it gone.

## Troubleshooting

Start with `omarchy-shell nts-radio status`, which reports what the plugin
believes about playback, dependencies and the schedule.

**Nothing plays, "Stream unavailable".** Check mpv can reach the stream:

```bash
mpv --no-video https://stream-relay-geo.ntslive.net/stream
```

**An archived show will not play.** `status` reports `"ytdlAvailable": false`
when `yt-dlp` is missing. If it is installed and one episode still fails, the
upload may be gone:

```bash
yt-dlp -f bestaudio --get-url "$(omarchy-shell nts-radio status | jq -r .archive.url)"
```

**No devices under Output.** `"castAvailable": true` in `status` means the
bridge loaded, and `omarchy-shell nts-radio devices` runs a discovery. Devices
must be on the same network segment, since mDNS does not cross most VLANs or
guest networks.

**Media keys do nothing.** Install `mpv-mpris` and check `"mpris": true`. Media
keys only reach the plugin while it is playing.

**Search returns nothing for everything.** NTS's `/search` requires
`version=2`; without it the endpoint returns HTTP 200 and a permanently empty
result set. If this happens, they changed the endpoint, and `NtsApi.js` is the
file to look at.

**Stale UI after editing the plugin.** Saving a file under
`~/.config/omarchy/plugins/` reloads the plugin, but QML loaded by URL is
cached for the life of the process. Run `omarchy restart shell`.

## How it is put together

```
Service.qml     shared state: schedule, playback mode, library, IPC
Player.qml      the mpv child process and its JSON IPC socket
Caster.qml      Chromecast playback and device discovery
Api.qml         API client: queue, concurrency, retries, cache
Fetcher.qml     one HTTP GET, in a subprocess
Resolver.qml    turns an episode page into a URL a cast device can fetch
Model.js        live schedule endpoints, parsing, sanitization
NtsApi.js       archive endpoints: search, shows, episodes, tracklists
Library.js      saved shows, episodes, resume positions
scripts/cast.py the Chromecast bridge, newline JSON on stdin/stdout
BarWidget.qml   the bar presence, and host for the panel popup
Panel.qml       the bar panel
Browser.qml     the browser window: routing, keyboard, layout
pages/          Home, Search, Saved, Show, Episode
components/     shared kit: cards, rows, tracklist, transport, rail
desktop/        launcher entry, icon, installer
```

Three rules hold it together.

**One service owns playback.** `Service.qml` is created once by the shell, and
the same object is handed to the bar widget and to the browser window. Neither
owns the player, so opening or closing the browser cannot interrupt audio.

**One client owns the network.** Pages never fetch. They ask `Api.qml` for a
parsed result and get a callback.

**The `.js` files are pure.** No QML types, no IO, no side effects. Every NTS
URL, response shape and piece of sanitization lives in them, so they are the
files to change when NTS changes something.

There is no public NTS API. Everything here was worked out from the endpoints
the nts.live player itself calls, so they are unversioned and can change
without notice. The code comments carry the details.

## Notes

Unofficial, unaffiliated, and not endorsed by NTS. It includes none of NTS's
logo assets: the station mark is a typographic stand-in drawn from your Omarchy
theme's own colours. It plays the same public streams and reads the same public
endpoints the website does, with no borrowed credentials.

Please support NTS at [nts.live/supporters](https://www.nts.live/supporters).

## License

MIT. See [LICENSE](LICENSE).

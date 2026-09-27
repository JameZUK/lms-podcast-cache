# Design

## The one-line version

Subclass the built-in `Slim::Plugin::Podcast` protocol handler and register it for the
`podcast://` scheme, add a download manager that fetches episodes to disk with `Range:`
resume, and play the local file instead of the remote URL.

## Decisions already taken

| Decision | Choice | Why |
|---|---|---|
| Cache location (default) | `<first music folder>/.podcast-cache` | The music folder is already network storage with plenty of space. The leading dot keeps it out of the library scan with no server pref changes — see below. Configurable. |
| Library visibility | **Plugin browse only** | Keeps Artists/Albums clean. Achieved by the hidden directory. |
| Retention default | Newest **3** per feed | Configurable: integer N, `all`, or `current-only`; global default + per-feed override. |
| Fork vs subclass | **Subclass the protocol handler; no fork** | Decided 2026-09-27. See "Why a subclass" below. |
| Downloader | **Shell out to `curl -C -`** for v1 | See "Why curl" below. |

### Keeping episodes out of the library

Verified against the LMS 9.1.1 source (2026-09-27):

- **`ignoreInAudioScan` cannot do it.** `Slim::Utils::Misc::getMediaDirs` removes entries
  of `mediadirs` that *exactly equal* an entry in the ignore list. It is a per-media-folder
  switch (e.g. `ignoreInImageScan: [<music folder>]`), not a subdirectory
  exclusion. `<music folder>/Podcasts` would never match anything.
- **`ignoreDirRE`** would work, but it is matched against each directory's *basename*
  anywhere in the tree (`Misc::fileFilter`), and it's a global server pref.
- **`Misc::fileFilter` already skips hidden entries** (`/^\.[^\.]+/` on non-Windows). So a
  cache root of `<music folder>/.podcast-cache` is never scanned, and the plugin has nothing
  to register on install or undo on uninstall.

Playing a cached episode doesn't add it to the library either. The track stays a
`podcast://` `RemoteTrack`, which is never written to the library DB (see "Play path").

## Why a subclass, not a fork

The only behaviour that changes is **how an episode is played**. The built-in plugin already
provides everything else: the feed list (`preferences('plugin.podcast')->get('feeds')`),
the browse menus, the RSS parser, the 30-day resume-position cache, and the search
providers that `PodcastExt` plugs into.

So `Plugin.pm` does `require Slim::Plugin::Podcast::ProtocolHandler` and then re-registers
the `podcast` scheme to our subclass:

```perl
Slim::Player::ProtocolHandlers->registerHandler('podcast', 'Plugins::PodcastCache::ProtocolHandler');
```

Registering later wins. The `require` makes sure the built-in handler has already
registered itself before we replace it.

Consequences:
- **Zero diff against upstream.** Upstream fixes to the built-in arrive with LMS updates.
- **No second feed list and no migration.** The existing subscriptions just work. (This
  also answers the old "replace or coexist" question: we coexist, by design.)
- **The built-in Podcasts plugin must stay enabled.** It provides the menus and the feeds.
- The `[cached]` / `[downloading N%]` menu badges are the only feature that might need more
  than a handler subclass (for example, wrapping `Parser::parse`). Leave them until
  playback works.

## Why `curl -C -` rather than in-process Perl

LMS is a **single-threaded event loop**. A synchronous download inside it stalls the whole
server — every player, not just this one. The options are:

1. `Slim::Networking::Async::HTTP` with a write-to-file callback. In-process, non-blocking,
   but resume-on-truncation has to be written and tested by hand.
2. **Shell out to `curl -C - --retry ...`** and poll for completion.

`curl -C -` already implements exactly the resume semantics we need, is far better tested
than anything we'd write, and cannot block the event loop. `Proc::Background` ships with
LMS (`/usr/share/squeezeboxserver/CPAN/Proc/Background.pm`) and curl 8.5.0 is installed on
the LMS host; poll the child from a `Slim::Utils::Timers` timer.

**Tested 2026-09-27 on the LMS host against the real failing episode** (curl 8.5.0, read
bridge-style: curl piped into a reader doing 1 MiB then 45 s idle):

| | result |
|---|---|
| bursty read | server closed at 11,255,953 bytes after 450 s; curl **exit 18** (`transfer closed with 74644194 bytes remaining to read`) |
| `-C -` + `If-Range: <ETag>` | `206`, `Content-Range: bytes 11255953-85900146/85900147`; the remaining 74.6 MB in 8.2 s; result **byte-identical** to a full download |
| `-C -` + wrong `If-Range` | server sends `200`; curl **exit 33** ("doesn't seem to support byte ranges") and leaves the `.part` untouched |

So: exit 18 → resume; exit 33 → the file changed, delete the `.part` and start from zero;
exit 0 → still check the size. In normal use, curl reads at full speed and is never
truncated at all; resume is the safety net.

The server truncates *silently* with a clean FIN. curl *should* exit 18 (`CURLE_PARTIAL_FILE`) when the
connection closes short of `Content-Length`, but the wrapper must still compare
bytes-written against `Content-Length` itself and re-invoke with `-C -` until they match.
Do not trust the exit code alone.

Note that an unthrottled download probably never gets truncated at all (86 MB arrives in
2.16 s), so the resume path has to be exercised deliberately: interrupt a
`--limit-rate` download, then resume it.

**Only resume the same file.** Guard every resume with `If-Range: <ETag or Last-Modified>`
from the first response. If the origin assembles responses per request (dynamic ad
insertion), a range from a different response would splice two different files into a
corrupt one. With `If-Range`, a changed file comes back as a full `200` instead of a `206`.
A full retry costs ~2 s, so restarting from zero is always an acceptable fallback.

## Architecture

```
Plugins/PodcastCache/
  install.xml
  Plugin.pm            init: require the built-in handler, register ours for podcast://,
                       prefs, prefetch timer
  ProtocolHandler.pm   subclass of Slim::Plugin::Podcast::ProtocolHandler:
                       local file if cached, else fetch-then-play, else stream as today
  Downloader.pm        NEW: queue, curl invocation, resume loop, progress
  Cache.pm             NEW: path layout, sanitisation, index, prune
  Settings.pm          web settings: cache root, default keep, per-feed keep
  Status.pm            settings-page status: health checks, cache contents, recent
                       activity (last 100 events, in memory)
  FileHandler.pm       File subclass that plays a cached episode (see "Play path")
  strings.txt
  HTML/EN/plugins/PodcastCache/settings/basic.html
```

### What the original gives you (read `reference/Podcast/` before starting)

- `Plugin.pm` — feeds live in `preferences('plugin.podcast')->get('feeds')`, an arrayref of
  `{name, value => url}`. `handleFeed` builds the browse menu. `wrapUrl`/`unwrapUrl`
  implement the `podcast://` wrapper. `registerProvider` is how search providers plug in.
- `ProtocolHandler.pm` — extends `Slim::Player::Protocols::HTTPS`. `scanUrl` unwraps the
  URL and sets `$song->streamUrl`. **`onStop` already caches playback position** as
  `podcast-$url` for 30 days via `Slim::Utils::Cache`. It is inherited, so it keeps working
  as long as `$url` stays the original enclosure URL.
- `PodcastExt/Plugin.pm` (758 bytes) shows the minimal subclass + `registerProvider`
  pattern.

### Play path

```
podcast://<real-url>
        |
        v
PodcastCache::ProtocolHandler::scanUrl
        |
   Cache::lookup(guid|url)
        |
   +----+--------------------------+----------------------------+
   |                               |                            |
 cached & complete              not cached                   download failed /
   |                               |                         cache unavailable
 play local file              Downloader::fetch, then          |
 (no network at all)          call scanUrl's cb             stream as today
                              (async, never blocks            (built-in behaviour)
                              the event loop)
```

A full 86 MB episode downloads in ~2 s on this connection, so fetch-then-play is
effectively instant and keeps the design simple. Add a "start after N MB" option only if
that ever stops being true.

**"Play the local file" is not a URL rewrite.** Verified in `Slim/Player/Song.pm`
(9.1.1):

- `Song::open` takes its handler from `currentTrackHandler`, which comes from the track's
  `podcast://` URL, **not** from `streamUrl`. Setting `streamUrl` to `file://…` alone means
  `HTTPS->new` gets called with a file URL.
- **Direct streaming must be refused for cached episodes.** `open` calls
  `$client->canDirectStream($url, $song)` first. squeeze2upnp currently fetches the origin
  itself (`reference/stream-idle-test.py` reproduces its exact request), which is the fault.
  If a cached episode is still offered for direct streaming, the bridge goes back to the
  internet.

**How it's done — proven by the spike, 2026-09-27** (`Plugins/PodcastCache/`):

1. `ProtocolHandler::scanUrl`, for a cached episode, skips the network entirely. It reads the
   audio properties from the local file (`Slim::Formats->readTags`) into a *new*
   `Slim::Schema::RemoteTrack`, sets the title the same way the built-in does, and renames
   the track to the `podcast://` URL (again as the built-in does).
2. Because that's a different object from the track Song already holds, Song calls
   `currentTrackHandler` (Song.pm:260). Ours returns `FileHandler` when the episode is
   cached.
3. `FileHandler` is `Slim::Player::Protocols::File` with `pathFromFileURL` overridden to map
   the `podcast://` URL to the cached file. `File` supplies `canDirectStream` = 0,
   `isRemote` = 0 and frame-accurate seeking. `getNextTrack`, `onStop` and `onStream` are
   passed back to our podcast handler, so `{from=N}` resume, the saved resume position and
   "Recently played" all keep working.

The track keeps its `podcast://` URL and is a `RemoteTrack`, so it's never written to the
library DB, and the built-in's menus treat it as the same episode.

Verified on a squeezelite player: LMS logged "Opening stream (no direct streaming) using
Plugins::PodcastCache::FileHandler"; the player streamed from LMS only, with no connection
to the origin; seeking to 30:00 hit a frame boundary; stopping saved the position, and the
built-in's "Play from last position (33:24)" resumed from the file; the episode didn't
appear in library searches. **Not yet tested through the UPnP bridge** (the test speaker was
offline) — that's still the acceptance test.

### Cache layout

```
<root>/<Feed Title>/<YYYY-MM-DD> - <Episode Title>.<ext>
<root>/<Feed Title>/<YYYY-MM-DD> - <Episode Title>.<ext>.json   sidecar
<root>/<Feed Title>/<YYYY-MM-DD> - <Episode Title>.<ext>.part   while downloading
```

Implemented in `Cache.pm` (2026-09-27), tested by `t/cache.t` without LMS:

- **Sidecars are the only index.** There's no `.index.json` (a change from the first
  draft): the in-memory index is rebuilt at start-up by walking the tree and reading each
  sidecar. That's one small file per episode, and there's no second copy to disagree with.
- **Names are safe on SMB too**, not just ext4/NFS, because the cache is rsynced to the
  NAS. `/`, `\` and `:` become `-` (`Episode 5: Title` becomes `Episode 5 - Title`,
  `Morning Show: Live` becomes `Morning Show - Live`); `* ? " < > |` are dropped; leading and trailing dots and
  spaces go. Each name is capped at 200 bytes, cut on a character boundary, so the longest
  derived name (with a hash suffix and `.json`) stays under 255.
- The date in the name is the pubdate in UTC. No pubdate gives `undated - <Title>`.
- **Paths are UTF-8 bytes.** Cache takes titles as characters (or UTF-8 bytes) and returns
  byte paths, so Perl never writes Latin-1 filenames by accident.
- A known episode keeps its path even if the feed is renamed later. Retention groups
  episodes by feed *url*, not by folder.
- **Mountpoint guard (`writable` / `prepare`):** stat the root, which triggers autofs, then
  find the mount holding it in `/proc/self/mountinfo`. If that's still `autofs`, the NFS
  mount isn't there: refuse, and never create anything inside the bare mountpoint. Only then
  create the root or feed folder if missing, and check it's writable.

- **Identify episodes by RSS `<guid>`**, falling back to the enclosure URL. Titles and
  dates get edited upstream; guids don't.
- Sanitise for NFS/ext4: strip `/` and control chars, collapse whitespace, no leading dot,
  cap each component (255 bytes, and remember it's bytes not chars for unicode titles).
  Two episodes can sanitise to the same name — de-duplicate with a short guid hash suffix.
- Download to `.part` and rename only once `bytes == Content-Length`. A `.part` file is
  never played.
- Sidecar holds: source URL, guid, pubdate, expected size, ETag, completion state. It makes
  the cache self-describing, so a lost index can be rebuilt by walking the tree.

### Retention

Per feed: `keep = <N> | all | current-only`, plus a global default (3). Prune deletes the
oldest beyond N **by pubdate**, and must never delete:
- the episode currently playing on any player,
- a `.part` file belonging to an active download.

`Cache::prune($feedUrl, $keep, $protect)` takes a callback that returns true for any
episode to keep regardless, and only considers complete episodes; partial downloads belong
to the downloader. The caller decides what to protect (step 5). Still to decide: whether
that includes episodes with a saved resume position. The built-in drops those after 30
days anyway. Also protect an episode that has just been downloaded *in order to play it*,
or `current`-only retention could delete it before playback starts.

## Deployment notes

The specifics of the test installation (host names, paths, players, the failing feed) are
in the local, gitignored `ACCESS.md`. What matters for the design:

- **The music folder is an NFS share mounted by autofs.** It can be *absent*, so **guard on
  the mountpoint** before writing. If it isn't mounted, fail the download cleanly (and stream
  as today). Never write into the bare mountpoint directory, and never block LMS waiting on
  it.
- While the share is mounted, `findmnt` lists both the `autofs` trigger and the `nfs4` mount
  on top of it. After autofs's idle timeout, only the `autofs` entry remains until something
  touches the path, so the guard touches the path first, then checks.
- **The file server's nightly backup copies the music share without `--delete`.** Cached
  episodes get backed up for free, but pruned ones are **not** removed from the backup and
  will accumulate indefinitely. Either accept it, exclude `.podcast-cache/` from the backup,
  or add `--delete` for that subtree. Decide before shipping.
- **The LMS host is a small VM.** Don't cache to its local disk.
- Deploy the plugin to **`/var/lib/squeezeboxserver/Plugins/`**, *not*
  `cache/InstalledPlugins/Plugins/`: the extension manager schedules anything in
  `InstalledPlugins` that didn't come from a repository for deletion on the next restart.
  Plugins elsewhere count as "manual" installs and are left alone. LMS needs a restart to
  load a changed plugin.
- The cache folder must be owned by the user LMS runs as (`squeezeboxserver`) so the
  downloader can write there.
- The failing origin (Apache) sends `ETag`, `Last-Modified` and `Accept-Ranges: bytes`, so
  `If-Range` resumes are possible. At full speed its 86 MB episode arrives in about a
  second.

## Open questions for the build session

1. Does curl exit non-zero on the silent truncation? (Wrapper compares against
   `Content-Length` regardless.)
2. Can the `[cached]` menu badges be done without copying `Parser.pm`?
3. Background prefetch schedule — on feed refresh, on a timer, or both? And does it respect
   a quiet-hours window so it doesn't collide with the file server's nightly backup?

### Resolved

- *Does `ignoreInAudioScan` exclude a subdirectory?* No — it only matches whole
  `mediadirs` entries. Use a hidden cache directory instead (2026-09-27).
- *Fork or subclass?* Subclass the protocol handler only (2026-09-27).
- *Replace the built-in plugin or coexist?* Coexist — the built-in keeps the feeds and
  menus, and we only replace playback (2026-09-27).
- *How is a cached episode handed to the File handler, and does it touch the library?* Via
  `currentTrackHandler` and a `File` subclass; no library row, because the track stays a
  `RemoteTrack` (spike, 2026-09-27 — see "Play path").

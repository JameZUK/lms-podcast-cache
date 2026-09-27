# lms-podcast-cache

An LMS (Lyrion Music Server) plugin that extends the built-in **Podcasts** plugin so that it
**downloads episodes to local storage and plays them from there**, instead of streaming
them from the internet while you listen.

## Why this exists

LMS's built-in Podcasts plugin streams every episode live from the podcast's server while
you listen. That makes playback only as good as the slowest link between you and that
server, for the whole length of the episode. An hour-long episode means holding one
internet connection open, reliably, for an hour. This plugin **enhances LMS's podcast
support** by downloading episodes to local storage first and playing them from there:

- **Slow or unreliable connections.** A download that stalls or drops can resume where it
  left off, instead of the episode stopping mid-way. Once it's on disk, playback doesn't
  depend on the internet at all.
- **Unreliable podcast servers.** Some hosts time out, throttle, or cut off clients that
  read slowly. Fetching the whole file quickly, then playing it locally, sidesteps all of
  that.
- **Players that read slowly.** Streaming bridges (such as the UPnP bridge) and small
  players only read as fast as they play, which is exactly the traffic pattern servers give
  up on.
- **Better playback.** Seeking, resuming and skipping work on a local file without
  re-requesting ranges from a remote server, and you can keep recent episodes of each show
  on disk, ready to play.

### The problem that started it

Long episodes kept stopping part way through on UPnP speakers. The cause turned out to be
**the podcast's server truncating slow readers**, proven by packet capture:

> Read at playback rate, with stalls, the server closes the connection after 8–14 MB of an
> 86 MB file. Read unthrottled, all 85,900,147 bytes arrive in **2.16 s**.

The FIN comes from the server, carries the same TTL as all 6,884 data packets (so nothing
injected), and rides a 1448-byte data segment, i.e. an application closing normally. LMS,
the network and the speaker were all fine; the server simply gives up on a client that
trickles. The server honours `Range:` requests (`206 Partial Content`), so a cut-off
download can be resumed.

**So: download fast, to disk, resume if cut, then play locally.** That takes the
long-lived internet connection out of the playback path entirely, for every player and
every feed at once.

## What it does

- Downloads episodes at full speed, **resuming with `Range:` if truncated**.
- Caches to a configurable location, one **directory per podcast**, all episodes together.
- Retention per feed: keep the newest **N**, or **all**, or **only what's playing** —
  N and the mode are both configurable, globally and per feed.
- Plays from the local file when cached; falls back to fetch-then-play when not.
- Keeps the episodes **out of the music library** by caching to a hidden directory
  (`<music folder>/.podcast-cache` by default; see `DESIGN.md`).
- Leaves the built-in plugin's feeds, menus and resume positions alone: it only replaces
  how an episode is played.

## Install

Needs Lyrion Music Server 9 or later, with the built-in **Podcasts** plugin enabled, and
`curl` on the server.

1. In LMS, go to **Settings > Plugins**, and under **Additional Repositories** add:
   ```
   https://github.com/JameZUK/lms-podcast-cache/releases/latest/download/repo.xml
   ```
2. Apply. **Podcast Cache** appears in the list; tick it, apply, and restart LMS when asked.
3. Open its **Settings** from the plugin list: check the status panel, choose where to cache
   (by default a hidden `.podcast-cache` folder in your music folder, which the library scan
   skips) and how many episodes of each podcast to keep.

LMS offers updates as new versions are released.

## Status

**Working, pre-1.0.** Downloading (with resume), playing from disk, fetch-then-play with a
streaming fallback, prefetch of new episodes, and per-podcast retention all work. Still to
come: `[cached]` labels in the podcast menus. See `DESIGN.md` for the architecture and
`TASKS.md` for progress.

## Layout

| Path | What |
|---|---|
| `DESIGN.md` | Architecture, decisions taken, and the open questions |
| `TASKS.md` | Implementation order, smallest useful thing first |
| `CLAUDE.md` | Context for a Claude Code session working in here |
| `reference/Podcast/` | The built-in `Slim::Plugin::Podcast` this extends (LMS 9.1.1) |
| `reference/PodcastExt/` | A third-party extension — the clean subclass pattern, for contrast |
| `reference/stream-idle-test.py` | The reproducer that found the root cause |
| `Plugins/PodcastCache/` | The plugin itself |
| `tools/build-release.sh` | Builds the plugin zip and `repo.xml` for a release |
| `.github/workflows/release.yml` | On a `vX.Y.Z` tag: tests, build, GitHub release |
| `tests/` | Tests for the parts that don't need LMS: `prove -I. tests/` |
| `ACCESS.md` | How to reach the test installation — **gitignored, local only** |

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

- **Plays episodes from disk.** Press play on an episode that isn't cached yet and it is
  downloaded first (at full speed, *resuming* if the server cuts it off), then played
  locally. If the download takes longer than you're willing to wait (30 s by default), it
  streams as before while the download finishes for next time.
- **Downloads new episodes ahead of time.** The feeds are checked every few hours, and the
  newest episodes of each podcast are downloaded before you ask for them.
- **Keeps what you want, per podcast:** the newest **N**, **all** episodes, or **only the
  one playing**. Nothing you're playing, have queued, or are part-way through is deleted.
- **Can fetch a back catalogue.** For a podcast set to keep everything, it can download
  every past episode too: the newest first, then the first few (for shows best heard from
  the start), then the rest.
- **Is polite to podcast servers**, and works out how polite by itself (see below).
- **Shows its state in the podcast menus:** `[cached]`, `[downloading 42%]` or `[queued]`
  next to each episode (in Material and on devices).
- **Has a status page** under its settings: whether playback is being handled, the cache
  folder and its mount, what's cached, each podcast server's state, recent activity and
  errors.
- Keeps episodes **out of the music library**, by caching to a hidden folder
  (`<music folder>/.podcast-cache` by default).
- Leaves the built-in plugin's feeds, menus and resume positions alone: it only changes
  how an episode is played.

### Being polite to podcast servers

Downloads run one at a time. Anything you've pressed play on goes first, and pauses a
background download to do so (which then resumes where it left off). Background downloads
(new episodes, back catalogues) are spaced out per server, and the spacing adjusts itself:

- it shrinks while a server's downloads go smoothly, and grows when the server pushes back;
- a server that says "slow down" (HTTP 429 or 503) is left alone for as long as it asks
  (`Retry-After`), or for a growing while (1 minute, 5, 15, an hour, 6 hours, a day) if it
  doesn't say;
- a server that refuses us twice (HTTP 403) is left alone for a day;
- a server that suddenly gets much slower than usual is treated as a hint to slow down;
- background downloads wait while live streams are using a real share of your
  connection. The plugin measures your connection's speed, so on a fast line this never
  gets in the way.

The only setting is how polite to start from: *gentle*, *normal* or *fast*. There's no
speed cap: some servers cut off clients that read slowly, which is the problem this plugin
exists to avoid.

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

**Working, pre-1.0.** Everything above works and has been tested on a real LMS 9.1
server. Still to do: the long-play acceptance test through a UPnP bridge. See `DESIGN.md`
for the architecture and `TASKS.md` for progress.

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

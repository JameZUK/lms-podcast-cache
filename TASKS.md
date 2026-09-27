# Build order

Smallest useful thing first. Each step should leave something testable.

## 0. Settle the two blockers  (do this before writing plugin code)
- [x] **Playback spike.** *(Done 2026-09-27 on a squeezelite player; see DESIGN.md "Play path". Not
      yet run through the UPnP bridge, and no full rescan was run: the hidden-directory
      exclusion is confirmed from the scanner source only.)* Hand-place one episode at
      `<cache folder>/Test/test.mp3`. Write a throwaway plugin that
      re-registers `podcast://` to a subclass of `Slim::Plugin::Podcast::ProtocolHandler`
      and plays that file whatever the URL. Play it on the UPnP test speaker and confirm:
  - it plays through the File handler (not `HTTPS->new` on a `file://` URL) — try the
    `currentTrackHandler` hook first, then overriding `new`/`isRemote` (DESIGN.md, "Play path");
  - it is **not** direct-streamed: the bridge gets it from LMS, not from the origin;
  - seeking and the inherited `onStop` resume position still work;
  - nothing from `.podcast-cache/` shows up in Artists/Albums, either after a rescan or
    just from having played it.
  The whole design rests on this. If it doesn't work, stop and rethink.
- [x] **curl truncation and resume.** *(Done 2026-09-27 — results in DESIGN.md "Why curl".
      A steady `--limit-rate` read doesn't trigger the fault; the test piped curl into a
      reader doing 1 MiB then 45 s idle, like the bridge.)* Run
      `curl --limit-rate 25k -o /tmp/x.mp3 <episode-url>` from the bridge host or the LMS host
      and check the exit code and file size when the server truncates. Then resume with
      `-C -` and `If-Range` and check you get a complete, byte-identical file.
      Reproducer for the fault: `reference/stream-idle-test.py`.

## 1. Cache.pm — standalone, no LMS needed
*(Done 2026-09-27: `Plugins/PodcastCache/Cache.pm`, 80 assertions in `tests/cache.t`, passing
on Perl 5.42 and on the LMS host's 5.38.2. Not yet used by playback; see step 4.)*
- [x] Path layout + sanitisation (see DESIGN.md). Unit-test the nasty cases: `/` in titles,
      unicode past 255 *bytes*, two episodes sanitising to the same name, leading dots.
- [x] Sidecar read/write; rebuild-index-by-walking-the-tree.
- [x] `lookup(guid)`, `is_complete(path)`, `prune(feed, keep)`.
- [x] **Mountpoint guard**: refuse to write if the cache root isn't a mountpoint when it's
      expected to be one.

## 2. Downloader.pm — standalone script first
- [x] Fetch to `.part`, resume with `Range:` + `If-Range` until `bytes == Content-Length`,
      rename on success. A `200` answering a resume means the file changed: start over.
      Bounded retries with backoff; give up loudly. *(Done 2026-09-27:
      `scripts/fetch-episode.pl`; `tests/downloader.t` runs it against a local server that
      cuts, stalls, changes the file, redirects and errors on purpose.)*
- [x] Prove it against the real failing episode — it must produce a complete 85,900,147-byte
      file despite the mid-download truncation. **This is the whole point of the project;
      don't move on until it passes.** *(Passed 2026-09-27 on the LMS host: a bridge-style
      slow read was cut by the real server at 11,711,953 bytes (curl exit 18); the script
      resumed it with a `206` and produced all 85,900,147 bytes, byte-identical to a full
      download, in 5 s. A normal run was also identical.)*
- [x] Only then wire it into LMS as a non-blocking child process (`Proc::Background`) +
      poll timer. *(Done 2026-09-27: `Downloader.pm`, CLI `podcastcache fetch <url> [title]`,
      progress on the settings page. Verified on the LMS host: an 81 MB episode in 8 s,
      recorded in the cache with its validators, and CLI round-trips stayed at 24-29 ms
      during the download.)*

## 3. Plugin skeleton
- [ ] `Plugins/PodcastCache/`: `install.xml`, `Plugin.pm` that requires the built-in
      handler and registers ours for `podcast://`, and a `ProtocolHandler.pm` subclass that
      initially changes nothing. Confirm browse, play and resume behave exactly as before.
      Commit that as the baseline.
- [x] Settings page (done 2026-09-27, v0.0.2): status panel (handler active, built-in
      enabled, cache folder writable / mount / kept out of library, activity counts),
      cached-episode folders, recent activity with errors, cache root, default keep and a
      per-podcast keep override (newest N / all / only the episode playing). Linked from
      Manage Plugins via `<optionsURL>`.
- [ ] When downloads exist, add them to the status panel (queue, progress, failures), and
      show a per-podcast cached count once Cache.pm maps feeds to folders.

## 4. Play from cache
- [x] `ProtocolHandler::scanUrl`: if `Cache::lookup` says complete, play the local file
      using the mechanism proven in step 0. *(Done 2026-09-27: looks the enclosure url up in
      Cache.pm's sidecar index, built on first use; verified on the LMS host with the
      hand-placed test episode.)*
- [x] Record feed title and pubdate per enclosure url when the built-in parser reads a
      feed (`Feeds.pm` wraps `Slim::Plugin::Podcast::Parser::parse`). LMS drops `<guid>`, so
      the enclosure url is the identity.
- [x] Otherwise fetch, then play the local file. *(Done 2026-09-27; see DESIGN.md
      "Fetch-then-play".)*
- [x] If the download fails, the cache is unavailable, or it takes longer than `playWait`,
      fall back to streaming as the built-in does today (the download carries on).
- [ ] Keep the built-in's `onStop` resume-position behaviour working (it caches
      `podcast-$url` for 30 days — inherited, don't reimplement).
- [ ] Show `[cached]` / `[downloading N%]` in the browse menu, if it can be done without
      copying `Parser.pm` (DESIGN.md open question 3).

## 5. Retention
- [x] Per-feed `keep` override in settings: integer / `all` / `current-only`.
- [x] Prune on feed refresh and after each successful download (also on stop, after saving
      the settings, and at start-up).
- [x] Never prune what's playing or an active `.part` (also: anything queued, or
      part-listened). *(Done 2026-09-27: `Retention.pm`; verified on the LMS host, see
      DESIGN.md "Retention".)*

## 6. Prefetch
- [ ] On feed refresh, queue the newest N that aren't cached.
- [ ] Serialise downloads (one at a time) — the LMS host is a small VM and the write goes
      over NFS to the file server.
- [ ] Consider a quiet-hours window so prefetch doesn't collide with the file server's
      nightly backup.

## 7. Ship
- [ ] Test on a real hour-long episode end to end on the UPnP test speaker. That is the acceptance
      test: it must play the full hour with no drop.
- [ ] Install through LMS's own plugin manager from GitHub instead of copying files: add a
      `repo.xml` (plugin id, version, zip url, sha) and a release zip (e.g. built by a GitHub
      Action on tag), point LMS at the repo.xml under Settings > Plugins > Additional
      Repositories, install from there, then remove the manual copy from
      `/var/lib/squeezeboxserver/Plugins/` so LMS doesn't see two.
- [ ] Document that the built-in Podcasts plugin must stay enabled (it provides the feeds
      and menus).
- [ ] Decide the backup question for pruned episodes (DESIGN.md, "Deployment notes").
- [ ] Note the outcome in the private runbook and changelog (see `ACCESS.md`).

# CLAUDE.md — lms-podcast-cache

An LMS plugin that downloads podcast episodes to disk (with `Range:` resume) and plays them
locally, instead of streaming while listening. Read `README.md` then `DESIGN.md` before
writing anything; `TASKS.md` has the build order.

## The thing to not lose sight of

The fault being fixed is **server-side truncation of slow readers** — proven by packet
capture, not inferred. Read slowly, the origin closes after 8–14 MB of an 86 MB file; read
unthrottled, the whole file arrives in 2.16 s. The evidence is in a private runbook (path
in `ACCESS.md`).

Everything in this project follows from that one fact: **download fast, to disk, resume if
cut, then play the local file.** If a design choice doesn't serve that, question it.

The acceptance test is a real hour-long episode playing to the end on the UPnP test speaker. Unit
tests passing is not the same thing.

## Environment

**`ACCESS.md` has the full access detail** — how to reach the LMS host, the LMS paths and CLI,
player IDs, what the neutral names in these docs refer to, and the gotchas that have already
cost time. It is **gitignored**: it exists locally and must stay out of version control.
Read it before touching a live host.

**This repo is public.** Never commit host names, addresses, local paths, player names or
IDs, feed names, or anything else specific to the test installation; put them in
`ACCESS.md` and use neutral terms here ("the LMS host", "the file server", "the UPnP test
speaker", "the failing feed"). Check what's being pushed, including author emails.

The short version:

- LMS 9.1.1, Perl 5.38.2, on the LMS host (details in `ACCESS.md`).
- **No SSH to the LMS host** — go through the hypervisor's guest agent (see `ACCESS.md`).
  Quoting through three shells breaks constantly; base64 a script in for anything
  non-trivial.
- **The plugin is installed through LMS's plugin manager** from this repo's releases (see
  "Releasing"), into `cache/InstalledPlugins/Plugins/PodcastCache/`. For a quick test of
  unreleased code, copy files over that installed copy and restart LMS
  (`systemctl restart lyrionmusicserver`); the next release replaces them. Don't also put a
  copy in `/var/lib/squeezeboxserver/Plugins/`: LMS would see two plugins with one name.
- LMS CLI on port 9090; player IDs URL-encoded (the players are listed in `ACCESS.md`).
- Cache root default `<first music folder>/.podcast-cache` — hidden so the library scan
  skips it — on an **autofs NFS automount** that can be absent. Guard on the mountpoint
  before writing.
- LMS is a **single-threaded event loop**. Nothing in the playback path may block it.

Don't commit anything pulled off the live hosts (prefs, logs, pcaps, feed data) — the
`.gitignore` covers the obvious cases, but check before adding files.

## Releasing

Set the version in `Plugins/PodcastCache/install.xml`, commit, then tag and push `vX.Y.Z`.
The release workflow runs the tests, builds `PodcastCache-X.Y.Z.zip` and `repo.xml`
(`tools/build-release.sh`, which also stamps the version into the zip's `install.xml`),
and publishes a GitHub release. LMS reads
`https://github.com/JameZUK/lms-podcast-cache/releases/latest/download/repo.xml` and offers
the update. `tools/build-release.sh X.Y.Z /tmp/out` builds the same thing locally.

## Tests

`prove -I. tests/` from the repo root (on Arch, `prove` is `/usr/bin/core_perl/prove`). Tests
cover the modules that don't need LMS (`Cache.pm` so far); keep new logic in modules like
that where possible. Everything else is tested on the live server.

## Conventions

- **Subclass, don't fork.** Only the `podcast://` protocol handler is replaced; the built-in
  plugin keeps its feeds, menus and parser. Don't copy files out of `reference/Podcast/`
  unless there's no other way, and note any such divergence in `DESIGN.md`.
- Keep plugin HTML templates ASCII: LMS double-encodes anything else (`—` renders as `â`).
  Use `&mdash;`, `&hellip;`. LMS caches compiled templates for an hour; restart to see edits.
  Don't name hash keys the page reads `last`, `next`, `first`, `size` and the like:
  Template Toolkit treats them as list methods when the value is empty.
- Prefer reusing what the built-in already does — notably its 30-day resume-position cache
  (`podcast-$url`) and its RSS parser.

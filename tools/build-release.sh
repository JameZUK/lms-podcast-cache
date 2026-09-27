#!/bin/bash
#
# build-release.sh VERSION [OUTDIR]
#
# Builds the LMS plugin zip and the repository file that points at it:
#
#   OUTDIR/PodcastCache-VERSION.zip   the plugin, as PodcastCache/... (LMS strips the folder)
#   OUTDIR/repo.xml                   an LMS extensions repository listing that zip, with its SHA-1
#
# The zip's install.xml gets VERSION, so the two always agree (LMS compares them to decide
# whether an update is available). The GitHub release workflow runs this on a vX.Y.Z tag and
# attaches both files to the release; LMS then uses
#   https://github.com/JameZUK/lms-podcast-cache/releases/latest/download/repo.xml

set -euo pipefail

VERSION=${1:?usage: $0 VERSION [OUTDIR]}
OUT=${2:-dist}
REPO=${GITHUB_REPOSITORY:-JameZUK/lms-podcast-cache}
NAME=PodcastCache

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z, got $VERSION" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

cp -r "$ROOT/Plugins/$NAME" "$STAGE/$NAME"
sed -i -E "s|<version>[^<]*</version>|<version>$VERSION</version>|" "$STAGE/$NAME/install.xml"
grep -q "<version>$VERSION</version>" "$STAGE/$NAME/install.xml" || { echo "couldn't set the version in install.xml" >&2; exit 1; }

ZIP="$NAME-$VERSION.zip"
rm -f "$OUT/$ZIP"
# reproducible: sorted entries, fixed timestamps and permissions
python3 - "$STAGE" "$NAME" "$OUT/$ZIP" <<'PY'
import os, sys, zipfile
stage, name, out = sys.argv[1:]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirs, files in os.walk(os.path.join(stage, name)):
        dirs.sort()
        for f in sorted(files):
            path = os.path.join(dirpath, f)
            info = zipfile.ZipInfo(os.path.relpath(path, stage), date_time=(2000, 1, 1, 0, 0, 0))
            info.external_attr = (0o755 if os.access(path, os.X_OK) else 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, 'rb') as fh:
                z.writestr(info, fh.read())
PY

SHA=$(sha1sum "$OUT/$ZIP" | cut -d' ' -f1)
URL="https://github.com/$REPO/releases/download/v$VERSION/$ZIP"

cat > "$OUT/repo.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<extensions>
  <details>
    <title lang="EN">Podcast Cache</title>
  </details>
  <plugins>
    <plugin name="$NAME" version="$VERSION" minTarget="9.0" maxTarget="*">
      <title lang="EN">Podcast Cache</title>
      <desc lang="EN">Downloads podcast episodes to disk and plays them from there, resuming if the server cuts a download short. Extends the built-in Podcasts plugin, which must stay enabled.</desc>
      <creator>JameZUK</creator>
      <category>musicservices</category>
      <link>https://github.com/$REPO</link>
      <url>$URL</url>
      <sha>$SHA</sha>
    </plugin>
  </plugins>
</extensions>
EOF

echo "built $OUT/$ZIP (sha1 $SHA)"
echo "wrote $OUT/repo.xml -> $URL"

#!/usr/bin/env bash
# Rebuild the latest stable upstream release with a lower gain floor and
# publish it as a release of this fork, with the zip that HACS installs.
#
# Runs from a checkout of the fork's default branch. Each build is a new
# commit on that branch holding the upstream tree, the patch and this
# fork's own .github files. Upstream's workflows are left out, so the
# push never changes a workflow file and GITHUB_TOKEN is allowed to make
# it.
#
# Set DRY_RUN=1 to build and check everything without pushing.
set -euo pipefail

: "${UPSTREAM:?}" "${FORK:?}" "${GAIN_DB_MIN:?}"
BRANCH=${BRANCH:-gain-patch}
DRY_RUN=${DRY_RUN:-0}
FILTERS=custom_components/openai_tts/audio_filters.py
MANIFEST=custom_components/openai_tts/manifest.json

export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-github-actions[bot]}
export GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

fail() {
    echo "::error::$*"
    exit 1
}

# The release GitHub marks as latest, which is never a prerelease. The
# tag check is a second guard, matching upstream's own release.yml.
tag=$(gh release view -R "$UPSTREAM" --json tagName --jq .tagName)
case $tag in
    *b* | *-* | *rc*) fail "upstream's latest release $tag looks like a prerelease" ;;
esac

if gh release view "$tag" -R "$FORK" >/dev/null 2>&1; then
    echo "$tag is already published here, nothing to do."
    exit 0
fi
echo "Building $tag from $UPSTREAM."

work=$(mktemp -d)
cp -r .github "$work/github"
base=$(git rev-parse HEAD)

git fetch --quiet --no-tags "https://github.com/$UPSTREAM.git" "refs/tags/$tag"
upstream_sha=$(git rev-parse 'FETCH_HEAD^{commit}')
git checkout --quiet --detach "$upstream_sha"
rm -rf .github
cp -r "$work/github" .github

# The patch. A sed that matched nothing would publish the stock floor
# without a word, so the result is checked twice: as text, then through
# clamp_gain_db itself.
[ "$(grep -c '^GAIN_DB_MIN = ' "$FILTERS")" = 1 ] ||
    fail "expected exactly one GAIN_DB_MIN line in $FILTERS"
stock=$(sed -n 's/^GAIN_DB_MIN = //p' "$FILTERS")
sed -i "s/^GAIN_DB_MIN = .*/GAIN_DB_MIN = $GAIN_DB_MIN/" "$FILTERS"
grep -qxF "GAIN_DB_MIN = $GAIN_DB_MIN" "$FILTERS" ||
    fail "GAIN_DB_MIN = $GAIN_DB_MIN is not in $FILTERS after patching"
python3 -I -B - "$FILTERS" "$GAIN_DB_MIN" <<'EOF' || fail "clamp_gain_db does not use the new floor"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("audio_filters", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
floor = float(sys.argv[2])
assert module.clamp_gain_db(floor) == floor
assert module.clamp_gain_db(floor - 1) == floor
EOF

version=$(jq -r .version "$MANIFEST")
[ "v$version" = "$tag" ] || fail "manifest.json says $version, the tag is $tag"

git add -A
tree=$(git write-tree)
commit=$(git commit-tree "$tree" -p "$base" -m "$tag with GAIN_DB_MIN = $GAIN_DB_MIN

Upstream $UPSTREAM@$upstream_sha, with the gain floor lowered from $stock.")

# Same layout and exclusions as upstream's release.yml: the integration's
# files at the root of the zip.
zip="$work/openai_tts.zip"
(cd custom_components/openai_tts &&
    zip -qr "$zip" . -x '*.pyc' '__pycache__/*' '.DS_Store' '*.md')
# Read into variables first: with pipefail, grep -q closing the pipe
# early would fail the check on a match.
listing=$(unzip -Z1 "$zip")
grep -qx 'manifest.json' <<<"$listing" || fail "manifest.json is not at the root of the zip"
patched=$(unzip -p "$zip" audio_filters.py)
grep -qxF "GAIN_DB_MIN = $GAIN_DB_MIN" <<<"$patched" ||
    fail "the zip does not hold the patched audio_filters.py"

notes="$work/notes.md"
{
    echo "Upstream [$tag](https://github.com/$UPSTREAM/releases/tag/$tag), with the gain floor lowered from $stock to $GAIN_DB_MIN dB (\`GAIN_DB_MIN\` in \`audio_filters.py\`). Nothing else is changed."
    echo
    gh release view "$tag" -R "$UPSTREAM" --json body --jq .body
} >"$notes"

if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run: built $commit and $zip, nothing pushed."
    echo "--- notes ---"
    cat "$notes"
    exit 0
fi

git push --quiet origin "$commit:refs/heads/$BRANCH"
# Forced, in case an earlier run pushed the tag and then failed to
# publish the release.
git push --quiet origin "+$commit:refs/tags/$tag"
gh release create "$tag" "$zip" -R "$FORK" --verify-tag --latest \
    --title "$tag" --notes-file "$notes"
echo "Published $tag."

#!/bin/zsh
# Publishes a release. Turns CHANGELOG.md's "Unreleased" section into <version>, sets the version in
# project.yml, commits, tags v<version> and pushes main and the tag. GitHub Actions then builds the DMG and
# publishes the release with that section as its notes, and Toolbox's updater offers it to everyone.
#
# Usage: scripts/publish.sh <version> [--dry-run]
# RELEASE_COMMIT_TRAILER, if set, is added at the end of the release commit's message.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?Usage: scripts/publish.sh <version> [--dry-run]}"
dry_run=false
[[ "${2:-}" == --dry-run ]] && dry_run=true
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "The version must look like 1.2.3."; exit 1; }
tag="v$version"

[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "Publish from main."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
git fetch --quiet origin main --tags
git merge-base --is-ancestor origin/main HEAD || { echo "main is behind origin/main. Pull first."; exit 1; }
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then echo "$tag already exists."; exit 1; fi

current=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
newest=$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)
if [[ "$version" == "$current" || "$newest" != "$version" ]]; then
  echo "$version isn't newer than the current version, $current."
  exit 1
fi

notes=$(awk '/^## / { if (found) exit; if ($2 == "Unreleased") { found = 1; next } } found' CHANGELOG.md)
if [[ -z "${notes//[[:space:]]/}" ]]; then
  echo "Add the changes under \"## Unreleased\" in CHANGELOG.md first."
  exit 1
fi

# A fresh, empty Unreleased section goes above the new version's.
awk -v version="$version" -v date="$(date +%Y-%m-%d)" '
  !done && /^## Unreleased/ { print "## Unreleased"; print ""; print "## " version " — " date; done = 1; next }
  { print }' CHANGELOG.md > CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md
sed -i '' "s/^\( *MARKETING_VERSION: *\)\".*\"/\1\"$version\"/" project.yml

if $dry_run; then
  git --no-pager diff
  git checkout -- CHANGELOG.md project.yml
  echo "Dry run: nothing was committed or pushed."
  exit 0
fi

message="Release $version"
[[ -n "${RELEASE_COMMIT_TRAILER:-}" ]] && message+=$'\n\n'"$RELEASE_COMMIT_TRAILER"
git add CHANGELOG.md project.yml
git commit --quiet -m "$message"
git tag -a "$tag" -m "Toolbox $version"
git push --quiet origin main "$tag"
echo "Pushed $tag. GitHub Actions is building and publishing it: https://github.com/xaif/Toolbox/actions"

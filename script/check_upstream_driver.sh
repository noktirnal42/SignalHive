#!/bin/bash
# Has the upstream SwiftRTLSDR driver moved past the copy embedded in Packages/SwiftRTLSDR?
#
# Prints (1) upstream main's commit and whether the embedded copy equals it, (2) open pull requests, (3) branches other
# than main. Only merged work on main is ever synced (CLAUDE.md): open PRs and branches are listed so you know what is
# coming, not to be taken. Always exits 0; the last line is "UP TO DATE" or "UPSTREAM HAS NEW WORK".
set -u
REPO="noktirnal42/SwiftRTLSDR"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
EMBEDDED="$HERE/Packages/SwiftRTLSDR"
verdict="UP TO DATE"

echo "== 1. Upstream main vs the embedded copy"
if ! command -v git >/dev/null; then
  echo "git is not installed; cannot compare."; echo "UPSTREAM CHECK SKIPPED"; exit 0
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/swiftrtlsdr-check.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
if git clone --quiet --depth 1 "https://github.com/$REPO.git" "$tmp/upstream" 2>"$tmp/clone.err"; then
  echo "upstream main: $(git -C "$tmp/upstream" log -1 --format='%h %ci %s')"
  differing="$(diff -rq --exclude=.git --exclude=.build --exclude=.swiftpm "$tmp/upstream" "$EMBEDDED" 2>&1)"
  if [ -z "$differing" ]; then
    echo "Packages/SwiftRTLSDR is identical to upstream main."
  else
    echo "Packages/SwiftRTLSDR differs from upstream main in $(printf '%s\n' "$differing" | wc -l | tr -d ' ') place(s):"
    printf '%s\n' "$differing" | sed "s#$tmp/upstream#upstream#; s#$EMBEDDED#embedded#" | head -40
    verdict="UPSTREAM HAS NEW WORK"
  fi
else
  echo "Could not clone https://github.com/$REPO.git: $(head -1 "$tmp/clone.err")"
  verdict="UPSTREAM CHECK FAILED"
fi

echo
echo "== 2. Open pull requests"
if command -v gh >/dev/null; then
  prs="$(gh pr list -R "$REPO" --state open --json number,title,isDraft,headRefName --jq '.[] | "#\(.number)\t\(if .isDraft then "draft" else "ready" end)\t\(.headRefName)\t\(.title)"' 2>&1)"
  if [ -z "$prs" ]; then echo "none"; else printf '%s\n' "$prs"; verdict="UPSTREAM HAS NEW WORK"; fi
else
  echo "gh is not installed; skipping pull requests and branches (brew install gh)."
fi

echo
echo "== 3. Branches other than main"
if command -v gh >/dev/null; then
  branches="$(gh api "repos/$REPO/branches" --paginate --jq '.[].name' 2>&1 | grep -v '^main$')"
  if [ -z "$branches" ]; then echo "none"; else printf '%s\n' "$branches"; fi
fi

echo
echo "$verdict"
exit 0

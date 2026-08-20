#!/usr/bin/env bash
# Keep README.md and multi-instance-kernel-patch-plan.md from drifting.
#
# WHEN TO RUN THIS: after editing either document. It checks four things that have
# actually gone wrong in this repo: a cross-document anchor that does not resolve,
# an intra-document anchor that does not resolve, a linked file that does not
# exist, and a wsl/ script that no document describes. It also enforces that
# package revisions and hashes appear only in the plan, which owns them. It does
# not judge prose.
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOCS=$(cd -- "$HERE/.." && pwd)
cd "$DOCS"

PLAN=multi-instance-kernel-patch-plan.md
README=README.md
FAILURES=0

note_failure() { FAILURES=$((FAILURES + 1)); }

# GitHub slug rules, close enough for the headings used here: lowercase, strip
# backticks and any non-alphanumeric except spaces and hyphens, spaces to hyphens.
slugs() {
  grep -E '^#{1,6} ' "$1" \
    | sed 's/^#* //' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/`//g; s/[^a-z0-9 -]//g; s/  */ /g; s/^ //; s/ $//; s/ /-/g'
}

# Anchors in $1 that point at document $2. Empty output is a valid result, so
# every grep here tolerates no-match rather than aborting under `set -e`.
check_anchors() {
  local src=$1 target=$2 anchor
  local slugfile
  slugfile=$(mktemp)
  slugs "$target" > "$slugfile"

  while read -r anchor; do
    [ -n "$anchor" ] || continue
    if grep -qxF "$anchor" "$slugfile"; then
      printf '  ok       %s -> %s#%s\n' "$src" "$target" "$anchor"
    else
      printf '  BROKEN   %s -> %s#%s\n' "$src" "$target" "$anchor"
      note_failure
    fi
  done < <(grep -oE "\]\($target#[a-z0-9-]+\)" "$src" 2>/dev/null \
             | sed "s|.*#||; s|)$||" | sort -u || true)

  rm -f "$slugfile"
}

check_self_anchors() {
  local src=$1 anchor
  local slugfile
  slugfile=$(mktemp)
  slugs "$src" > "$slugfile"

  while read -r anchor; do
    [ -n "$anchor" ] || continue
    if grep -qxF "$anchor" "$slugfile"; then
      printf '  ok       %s -> #%s\n' "$src" "$anchor"
    else
      printf '  BROKEN   %s -> #%s\n' "$src" "$anchor"
      note_failure
    fi
  done < <(grep -oE '\]\(#[a-z0-9-]+\)' "$src" 2>/dev/null \
             | sed 's|](#||; s|)$||' | sort -u || true)

  rm -f "$slugfile"
}

check_links() {
  local doc=$1 path
  while read -r path; do
    [ -n "$path" ] || continue
    if [ -e "$path" ]; then
      printf '  ok       %s -> %s\n' "$doc" "$path"
    else
      printf '  MISSING  %s -> %s\n' "$doc" "$path"
      note_failure
    fi
  done < <(grep -oE '\]\([A-Za-z0-9_][A-Za-z0-9_/.-]*\.(sh|py|patch|md|deb|log|txt)\)' "$doc" 2>/dev/null \
             | sed 's|^](||; s|)$||' | sort -u || true)
}

echo "=== cross-document anchors ==="
check_anchors "$PLAN" "$README"
check_anchors "$README" "$PLAN"

echo "=== intra-document anchors ==="
check_self_anchors "$PLAN"
check_self_anchors "$README"

echo "=== linked files exist ==="
check_links "$PLAN"
check_links "$README"

echo "=== every wsl/ script is described in at least one document ==="
for script in wsl/*.sh wsl/*.py; do
  name=$(basename "$script")
  if grep -qF "$name" "$README" || grep -qF "$name" "$PLAN"; then
    printf '  ok       %s\n' "$name"
  else
    printf '  UNDOC    %s\n' "$name"
    note_failure
  fi
done

echo "=== package revisions and hashes belong only to the plan ==="
if grep -qE '6\.8\.12-[0-9]+_arm64\.deb|[0-9a-f]{64}' "$README"; then
  printf '  WARNING  %s restates a package revision or hash; the plan owns those\n' "$README"
  note_failure
else
  printf '  ok       %s does not restate revisions or hashes\n' "$README"
fi

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "DOC_CHECK_FAILED ($FAILURES problem(s))"
  exit 1
fi
echo DOC_CHECK_PASSED

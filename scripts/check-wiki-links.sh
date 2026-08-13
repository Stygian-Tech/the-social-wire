#!/usr/bin/env bash
set -euo pipefail

wiki_dir="${1:-docs/wiki}"

if [[ ! -d "$wiki_dir" ]]; then
  echo "Wiki directory not found: $wiki_dir" >&2
  exit 1
fi

check_failed=0

while IFS= read -r token; do
  [[ -n "$token" ]] || continue
  target="${token#\[\[}"
  target="${target%\]\]}"
  target="${target%%|*}"
  target="${target%%#*}"
  target="${target%.md}"

  if [[ ! -f "$wiki_dir/$target.md" ]]; then
    echo "Unresolved wiki link: $token (expected $wiki_dir/$target.md)" >&2
    check_failed=1
  fi
done < <(grep -rhoE '\[\[[^][]+\]\]' "$wiki_dir"/*.md 2>/dev/null | sort -u || true)

for page in "$wiki_dir"/*.md; do
  base="$(basename "$page" .md)"
  if [[ "$base" == "_Sidebar" ]]; then
    continue
  fi

  title="$(grep -m1 '^# ' "$page" | sed 's/^# //' || true)"

  if [[ -z "$title" ]]; then
    echo "Wiki page has no level-one title: $page" >&2
    check_failed=1
  fi

  case "$base" in
    Home) continue ;;
  esac

  if ! grep -Fq "[[$base" "$wiki_dir/Home.md" "$wiki_dir/_Sidebar.md"; then
    echo "Wiki page is not linked from Home or _Sidebar: $page" >&2
    check_failed=1
  fi
done

duplicate_titles="$({
  for page in "$wiki_dir"/*.md; do
    [[ "$(basename "$page" .md)" == "_Sidebar" ]] && continue
    grep -m1 '^# ' "$page" | sed 's/^# //' || true
  done
} | sed '/^$/d' | sort | uniq -d)"

if [[ -n "$duplicate_titles" ]]; then
  echo "Duplicate wiki page titles:" >&2
  echo "$duplicate_titles" >&2
  check_failed=1
fi

if [[ "$check_failed" -ne 0 ]]; then
  exit "$check_failed"
fi

echo "Wiki links are valid and every public page is indexed."

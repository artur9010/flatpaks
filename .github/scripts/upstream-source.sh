#!/usr/bin/env bash
# Fetch the upstream source changes of every source bumped between two commits, for the
# update-review workflow. A bump whose source can't be fetched (not on GitHub, missing
# tag, failed clone) doesn't stop the review: it is recorded in <manifest>.missing and
# <out>/upstream.md, and the PR comment reports it.
#
# Sources are read from every .yml and .json in each changed app folder (manifests and
# helper modules) and paired by file and position. The upstream comes from the source
# itself:
#   type: git                                           clone url, diff old..new commit
#   github.com/<o>/<r>/releases/download/<tag>/<file>   clone, diff the tags
#   github.com/<o>/<r>/archive/[refs/tags/]<ref>.<ext>  clone, diff the refs
#   raw.githubusercontent.com/<o>/<r>/<commit>/<path>   clone, diff the commits
# When two release tags point at the same commit (RecompLauncher tags every release on
# one old commit) or a tag is missing, an archive source is downloaded at both URLs and
# the unpacked trees are diffed instead. The trees stay in <out>/<app>/src/{old,new}.
# .github/upstream-sources.yaml can scope a repo's git diff to some paths (monorepos).
#
# Each bump is written to <out>/<app>/upstream/<name>/part-NNN.txt: the commit list, the
# diffstat and the source diff (no vendored code, lockfiles or tests), split so one part
# fits in a single tool call. GitHub release notes of both tags go to
# release-notes-NNN.txt next to it. <out>/upstream.md lists all parts for the model.
#
# <manifest> and <manifest>.parts must be kept out of <out>: every part starts and ends
# with a random token listed there, and review-check.sh looks for those tokens in the
# tool output to prove that the model read the whole part.
#
# review_source and friends run under `||`, where set -e is off, so they check each step.
#
# Usage: upstream-source.sh <base-rev> <head-rev> <out-dir> <manifest>   (from the repo root)
# Release notes need GH_TOKEN (gh api); without it they are skipped.
set -euo pipefail

base=$(git rev-parse "$1")
head=$(git rev-parse "$2")
out=$3
manifest=$4
map=.github/upstream-sources.yaml
# Parts are smaller than opencode's tool output limit (2000 lines, 50 KB)
part_bytes=${PART_BYTES:-40000}
part_lines=${PART_LINES:-1500}
# Upper limit per bump, the rest is reported as not reviewed in the PR comment
max_bytes=${MAX_SOURCE_BYTES:-1200000}

mkdir -p "$out"
: >"$manifest"
: >"$manifest.parts"
: >"$manifest.missing"
: >"$out/upstream.md"

# "path<US>type<US>url<US>commit" of every source in a manifest or module file at a revision.
# Fields are split on the unit separator (\x1f), not tabs: read merges empty tab fields.
sources() {
  local format=yaml
  case $2 in *.json) format=json ;; esac
  git show "$1:$2" 2>/dev/null |
    yq -p "$format" -N '.. | select(tag == "!!map" and has("type") and has("url"))
      | (path | join(".")) + "	" + .type + "	" + .url + "	" + (.commit // "")' 2>/dev/null |
    tr '\t' '\037' || true
}

clone() {
  local url=$1 dest=$2
  [ -d "$dest" ] || git clone -q --filter=blob:none "$url" "$dest"
}

urldecode() {
  printf '%b' "${1//%/\\x}"
}

# Version for the web search check: the tag without a leading "v" or "<name>@"
version_of() {
  local v=${1##*@}
  echo "${v#v}"
}

# Split <file> into numbered, token-wrapped parts named <dir>/<prefix>-NNN.txt
emit_parts() {
  local file=$1 dir=$2 prefix=$3 part start end tmp
  mkdir -p "$dir"
  # Long lines are cut (minified files), a part must never exceed one tool output
  head -c "$max_bytes" "$file" | cut -c1-4000 | LC_ALL=C awk -v dir="$dir" -v prefix="$prefix" -v max_bytes="$part_bytes" -v max_lines="$part_lines" '
    function part() { return sprintf("%s/%s-%03d.txt", dir, prefix, n) }
    NR == 1 || bytes + length($0) + 1 > max_bytes || lines >= max_lines {
      if (NR > 1) close(part())
      n++; bytes = 0; lines = 0
    }
    { print > part(); bytes += length($0) + 1; lines++ }'
  for part in "$dir/$prefix"-*.txt; do
    [ -e "$part" ] || continue
    start=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    end=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    tmp=$(mktemp)
    { echo "<<< part start $start"; cat "$part"; echo; echo "<<< part end $end"; } >"$tmp"
    mv "$tmp" "$part"
    chmod 644 "$part"
    printf '%s\t%s\t%s\n' "${part#"$out"/}" "$start" "$end" >>"$manifest.parts"
    echo "- \`${part#"$out"/}\`" >>"$out/upstream.md"
  done
}

# Excluded from source diffs: vendored code, lockfiles, generated files and tests
excludes=(
  ':(exclude,glob)**/vendor/**' ':(exclude,glob)**/node_modules/**' ':(exclude,glob)**/testdata/**'
  ':(exclude,glob)**/test/**' ':(exclude,glob)**/tests/**' ':(exclude,glob)**/*_test.go'
  ':(exclude,glob)**/go.sum' ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/yarn.lock'
  ':(exclude,glob)**/pnpm-lock.yaml' ':(exclude,glob)**/Cargo.lock' ':(exclude,glob)**/*.pb.go'
  ':(exclude,glob)**/*.snap'
)

# Pathspecs of a repo at a ref, from .github/upstream-sources.yaml: its paths, the path
# dependencies of its cargo manifests (recursively), and its excludes. Nothing for a repo
# that isn't listed, so it is diffed whole.
scope() {
  local repo=$1 git_dir=$2 ref=$3 dir dep resolved
  local -a paths queue
  local -A seen=()
  mapfile -t paths < <(REPO=$repo yq -r '.repos[strenv(REPO)].paths // [] | .[]' "$map")
  mapfile -t queue < <(REPO=$repo yq -r '.repos[strenv(REPO)].cargo // [] | .[] | sub("/?Cargo\.toml$"; "")' "$map")
  while [ "${#queue[@]}" -gt 0 ]; do
    dir=${queue[0]}
    queue=("${queue[@]:1}")
    while read -r dep; do
      resolved=$(realpath -m --relative-to=/ "/$dir/$dep")
      [ -z "${seen[$resolved]:-}" ] || continue
      seen[$resolved]=1
      paths+=("$resolved")
      queue+=("$resolved")
    done < <(git -C "$git_dir" show "$ref:$dir/Cargo.toml" 2>/dev/null | grep -oE 'path *= *"[^"]+"' | sed -E 's/.*"(.*)"/\1/')
  done
  [ "${#paths[@]}" = 0 ] || printf '%s\n' "${paths[@]}"
  REPO=$repo yq -r '.repos[strenv(REPO)].exclude // [] | .[] | ":(exclude)" + .' "$map"
}

# Record one bump in the manifest:
# app, label, old, new, commits, files, kept bytes, total bytes, link, version
record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$manifest"
}

# Diff two refs of a cloned repo. Prints nothing and fails when they are the same commit.
git_parts() {
  local app=$1 label=$2 git_dir=$3 old=$4 new=$5 link=$6 version=$7 name all commits files total kept
  name=$(basename "$git_dir")
  reason="git failed on $old..$new"
  [ "$(git -C "$git_dir" rev-parse "$old^{commit}")" != "$(git -C "$git_dir" rev-parse "$new^{commit}")" ] || return 2
  local -a spec
  local p includes=0
  mapfile -t spec < <(scope "$label" "$git_dir" "$new" | grep -v '^$')
  for p in "${spec[@]}"; do
    [[ $p == ':(exclude)'* ]] || includes=$((includes + 1))
  done
  # Only excludes (or nothing): everything else
  [ "$includes" -gt 0 ] || spec=(. "${spec[@]}")
  all=$(mktemp)
  commits=$(git -C "$git_dir" rev-list --no-merges --count "$old..$new" -- "${spec[@]}") || return 1
  files=$(git -C "$git_dir" diff --name-only "$old" "$new" -- "${spec[@]}" | wc -l)
  {
    echo "# $label $old..$new: $commits commits, $files files changed"
    if [ "${spec[0]}" != . ]; then
      echo "# Scoped by .github/upstream-sources.yaml to: ${spec[*]}"
    fi
    echo
    echo "## Commits"
    git -C "$git_dir" log --no-merges --format='%h %s' "$old..$new" -- "${spec[@]}" || return 1
    echo
    echo "## Changed files (all)"
    git -C "$git_dir" diff --stat=120 "$old" "$new" -- "${spec[@]}" || return 1
    echo
    echo "## Source diff (no vendored code, lockfiles or tests)"
    git -C "$git_dir" diff "$old" "$new" -- "${spec[@]}" "${excludes[@]}" || return 1
  } >"$all"
  total=$(wc -c <"$all")
  kept=$(head -c "$max_bytes" "$all" | wc -c)
  emit_parts "$all" "$out/$app/upstream/$name" part
  rm "$all"
  record "$app" "$label" "$old" "$new" "$commits" "$files" "$kept" "$total" "$link" "$version"
  echo "  $label $old..$new: $commits commits, $files files, $kept of $total bytes"
}

# Download and unpack an archive source into <dest>
unpack() {
  local url=$1 dest=$2 file
  file=$(mktemp)
  curl -fsSL -o "$file" "$url" || return 1
  mkdir -p "$dest"
  case $url in
    *.zip) unzip -q "$file" -d "$dest" ;;
    *) tar -xf "$file" -C "$dest" ;;
  esac || return 1
  rm "$file"
  # One top-level folder, like a source zip: diff its contents
  if [ "$(find "$dest" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ] && [ -d "$(find "$dest" -mindepth 1 -maxdepth 1)" ]; then
    local top
    top=$(find "$dest" -mindepth 1 -maxdepth 1)
    find "$top" -mindepth 1 -maxdepth 1 -exec mv -t "$dest" {} +
    rmdir "$top"
  fi
  # The same exclusions as git_parts
  find "$dest" \( -name vendor -o -name node_modules -o -name testdata -o -name test -o -name tests \) -type d -prune -exec rm -rf {} +
  find "$dest" \( -name go.sum -o -name package-lock.json -o -name yarn.lock -o -name pnpm-lock.yaml \
    -o -name Cargo.lock -o -name '*_test.go' -o -name '*.pb.go' -o -name '*.snap' \) -type f -delete
}

# Diff the unpacked contents of two archive URLs
archive_parts() {
  local app=$1 label=$2 old_url=$3 new_url=$4 old=$5 new=$6 link=$7 version=$8 name src all files total kept
  name=${label##*/}
  src="$out/$app/src"
  reason="downloading or unpacking $old_url failed"
  rm -rf "$src"
  unpack "$old_url" "$src/old" || return 1
  reason="downloading or unpacking $new_url failed"
  unpack "$new_url" "$src/new" || return 1
  all=$(mktemp)
  files=$(git diff --no-index --name-only "$src/old" "$src/new" | wc -l || true)
  {
    echo "# $label $old..$new: archive diff, $files files changed"
    echo "# (the git tags don't hold this source; unpacked trees are in $app/src/old and $app/src/new)"
    echo
    echo "## Changed files (all)"
    git diff --no-index --stat=120 "$src/old" "$src/new" || true
    echo
    echo "## Source diff (no vendored code, lockfiles or tests)"
    git diff --no-index "$src/old" "$src/new" || true
  } >"$all"
  # Paths relative to the review dir, not this runner's temp dir
  sed -i "s|$out/||g" "$all"
  total=$(wc -c <"$all")
  kept=$(head -c "$max_bytes" "$all" | wc -c)
  emit_parts "$all" "$out/$app/upstream/$name" part
  rm "$all"
  record "$app" "$label" "$old" "$new" "-" "$files" "$kept" "$total" "$link" "$version"
  echo "  $label $old..$new (archive): $files files, $kept of $total bytes"
}

# GitHub release notes of both tags, for the model to read
release_notes() {
  local app=$1 repo=$2 old=$3 new=$4 notes
  [ -n "${GH_TOKEN:-}" ] || return 0
  notes=$(mktemp)
  local tag
  for tag in "$new" "$old"; do
    echo "# Release notes of $repo $tag"
    echo
    gh api "repos/$repo/releases/tags/$(printf %s "$tag" | jq -sRr @uri)" --jq '.body // "(empty)"' 2>/dev/null || echo "(no GitHub release for this tag)"
    echo
  done >"$notes"
  emit_parts "$notes" "$out/$app/upstream/${repo##*/}" release-notes
  rm "$notes"
}

# Review one changed source: type, old url, new url, old commit, new commit
review_source() {
  local app=$1 type=$2 old_url=$3 new_url=$4 old_commit=$5 new_commit=$6 repo old new kind git_dir rc
  if [ "$type" = git ]; then
    reason="git source without a pinned commit"
    [ -n "$old_commit" ] && [ -n "$new_commit" ] || return 1
    repo=${new_url#https://github.com/}
    repo=${repo%.git}
    git_dir="$out/repos/$(basename "${new_url%.git}")"
    reason="cloning $new_url failed"
    clone "$new_url" "$git_dir" || return 1
    reason="commit $old_commit or $new_commit not in $new_url"
    git -C "$git_dir" cat-file -e "$old_commit^{commit}" && git -C "$git_dir" cat-file -e "$new_commit^{commit}" || return 1
    git_parts "$app" "$repo" "$git_dir" "$old_commit" "$new_commit" "https://github.com/$repo/compare/$old_commit...$new_commit" ""
    return
  fi

  local re_release='^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/'
  local re_archive='^https://github\.com/([^/]+/[^/]+)/archive/(refs/tags/|refs/heads/)?(.+)\.(tar\.gz|tar\.xz|tar\.bz2|zip)$'
  local re_raw='^https://raw\.githubusercontent\.com/([^/]+/[^/]+)/([^/]+)/'
  if [[ $old_url =~ $re_release ]]; then
    kind=release
    repo=${BASH_REMATCH[1]}
    old=$(urldecode "${BASH_REMATCH[2]}")
    [[ $new_url =~ $re_release ]] || { reason="the new URL is not a GitHub release"; return 1; }
    new=$(urldecode "${BASH_REMATCH[2]}")
  elif [[ $old_url =~ $re_archive ]]; then
    kind=archive
    repo=${BASH_REMATCH[1]}
    old=$(urldecode "${BASH_REMATCH[3]}")
    [[ $new_url =~ $re_archive ]] || { reason="the new URL is not a GitHub archive"; return 1; }
    new=$(urldecode "${BASH_REMATCH[3]}")
  elif [[ $old_url =~ $re_raw ]]; then
    kind=raw
    repo=${BASH_REMATCH[1]}
    old=${BASH_REMATCH[2]}
    [[ $new_url =~ $re_raw ]] || { reason="the new URL is not a GitHub raw file"; return 1; }
    new=${BASH_REMATCH[2]}
  else
    reason="not a GitHub source"
    return 1
  fi
  [ "$old" != "$new" ] || { reason="same ref ($new) at a different URL"; return 1; }

  git_dir="$out/repos/${repo##*/}"
  reason="cloning $repo failed"
  clone "https://github.com/$repo" "$git_dir" || return 1
  [ "$kind" = raw ] || release_notes "$app" "$repo" "$old" "$new"

  local link="https://github.com/$repo/compare/$old...$new" version
  version=$([ "$kind" = raw ] || version_of "$new")
  if git -C "$git_dir" rev-parse -q --verify "$old^{commit}" >/dev/null && git -C "$git_dir" rev-parse -q --verify "$new^{commit}" >/dev/null; then
    rc=0
    git_parts "$app" "$repo" "$git_dir" "$old" "$new" "$link" "$version" || rc=$?
    [ "$rc" = 2 ] || return "$rc"
    echo "  $repo: $old and $new are the same commit, diffing the archives"
  fi
  reason="no tag for $old or $new in $repo"
  [ "$type" = archive ] || return 1
  archive_parts "$app" "$repo" "$old_url" "$new_url" "$old" "$new" "https://github.com/$repo/releases/tag/$new" "$version"
}

# Record a bump whose source couldn't be fetched
report_missing() {
  echo "  source not available for $2 -> $3: $reason"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$reason" >>"$manifest.missing"
  echo "- source NOT available for $2 -> $3 ($1): $reason" >>"$out/upstream.md"
}

mapfile -t apps < <(git diff --name-only "$base" "$head" -- '*/*' | cut -d/ -f1 | sort -u)
for app in "${apps[@]}"; do
  git cat-file -e "$head:$app/$app.yml" 2>/dev/null || continue
  echo "== $app"
  before=$(mktemp)
  after=$(mktemp)
  while read -r file; do
    sources "$base" "$file" | sed "s|^|$file:|" >>"$before"
    sources "$head" "$file" | sed "s|^|$file:|" >>"$after"
  done < <(git diff --name-only "$base" "$head" -- "$app" | grep -E '\.(yml|json)$' || true)

  # "path<US>old type<US>old url<US>old commit<US>new type<US>new url<US>new commit" of changed sources
  while IFS=$'\x1f' read -r _ _ old_url old_commit type new_url new_commit; do
    review_source "$app" "$type" "$old_url" "$new_url" "$old_commit" "$new_commit" ||
      report_missing "$app" "$old_url${old_commit:+@$old_commit}" "$new_url${new_commit:+@$new_commit}"
  done < <(join -t $'\x1f' <(sort "$before") <(sort "$after") | awk -F'\x1f' '$3 != $6 || $4 != $7')

  rm "$before" "$after"
done

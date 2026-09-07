#!/usr/bin/env bash
# BRIDGE - inbox watcher, POSIX variant. Same contract as bridge-monitor.ps1:
# one "BRIDGE NEW: <file>" line per new .md in ~/.claude/bridge/inbox/<id>; silent otherwise.
#
# Usage: bridge-monitor.sh [-p <project-root>] [-i <id>] [-r <state-root>]
# Identity: 1) .claude-bridge-id marker in -p or an ancestor; 2) participants.json path prefix
# (needs jq); 3) none -> not a participant: stay idle silently (auto-gate). Do NOT exit: the harness
# reports a finished monitor to the session and that costs a model turn on every start.
set -u
project="$PWD"; id=""; root="$HOME/.claude/bridge"
while getopts "p:i:r:" opt; do
	case "$opt" in
		p) project="$OPTARG" ;;
		i) id="$OPTARG" ;;
		r) root="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

norm() { printf '%s' "$1" | tr 'A-Z\\' 'a-z/' | sed 's:/*$::'; }

resolve_id() {
	local d="$project"
	while [ -n "$d" ]; do
		if [ -f "$d/.claude-bridge-id" ]; then tr -d '[:space:]' < "$d/.claude-bridge-id"; return; fi
		[ "$d" = "/" ] && break
		d="$(dirname "$d")"
	done
	[ -f "$root/participants.json" ] || return
	command -v jq >/dev/null 2>&1 || return
	local np; np="$(norm "$project")"
	jq -r 'to_entries[] | "\(.key)\t\(.value.path)"' "$root/participants.json" \
	| while IFS="$(printf '\t')" read -r k p; do
		pp="$(norm "$p")"
		case "$np" in
			"$pp"|"$pp"/*) printf '%s\t%s\n' "${#pp}" "$k" ;;
		esac
	done | sort -rn | head -1 | cut -f2
}

[ -z "$id" ] && id="$(resolve_id)"
if [ -z "$id" ]; then
	while true; do sleep 3600; done   # auto-gate: idle, no output, no exit
fi

dir="$root/inbox/$id"
if [ ! -d "$dir" ]; then
	echo "BRIDGE ERROR: inbox for '$id' not found: $dir (run /bridge:bridge-init)"
	exit 1
fi

# One watcher per inbox: the lock dies with the process.
mkdir -p "$root/tmp"
exec 9>"$root/tmp/watch-$id.lock"
if ! flock -n 9; then
	echo "BRIDGE WARN: inbox '$id' already has a watcher (duplicate session or plugin reload); this one exits"
	exit 0
fi

echo "bridge: watching $dir as '$id'" >&2

# initial sweep: what was already there
for f in "$dir"/*.md; do [ -e "$f" ] && echo "BRIDGE NEW: $(basename "$f")"; done

if command -v inotifywait >/dev/null 2>&1; then
	# '\.md$' excludes the *.md.tmp of the atomic write
	inotifywait -m -q -e create -e moved_to --format 'BRIDGE NEW: %f' "$dir" | grep --line-buffered '\.md$'
else
	# no inotify: poll every 5 s with dedup
	seen="$(ls -1 "$dir"/*.md 2>/dev/null | sort)"
	while true; do
		sleep 5
		now="$(ls -1 "$dir"/*.md 2>/dev/null | sort)"
		comm -13 <(printf '%s\n' "$seen") <(printf '%s\n' "$now") | while read -r f; do
			[ -n "$f" ] && echo "BRIDGE NEW: $(basename "$f")"
		done
		seen="$now"
	done
fi

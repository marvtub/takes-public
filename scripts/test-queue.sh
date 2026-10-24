# Sourced by test.sh and build.sh (2026-10-11). Several agents test Takes from their own worktrees,
# and four full runs at once made the Mac crawl and the timed tests fail. So:
#   queue_wait    one full test run at a time on this Mac, first come first served
#   tree_now      the work tree as a git tree hash (uncommitted and new files too)
#   passed_mark   remember that a full run passed on a tree
#   passed_has    did a full run pass on this tree? build.sh install then skips its own run
TAKES_CACHE="$HOME/Library/Caches"

# What a run removes when it ends, however it ends: its queue ticket and its temp folder.
TAKES_EXIT_PATHS=()
takes_on_exit() {
  TAKES_EXIT_PATHS+=("$1")
  trap 'rm -rf "${TAKES_EXIT_PATHS[@]}"' EXIT
}

# A ticket per run in the queue folder, named by the time it came. The oldest ticket whose
# process still lives goes; a ticket whose process died is removed. A run inside a run (the
# public copy's test.sh) holds no ticket of its own: TAKES_QUEUE_HELD.
queue_wait() {
  [[ "${TAKES_QUEUE_HELD:-}" == 1 ]] && return 0
  local q="$TAKES_CACHE/takes-test-queue" said="" mine first f pid ahead
  mkdir -p "$q"
  mine="$(python3 -c 'import time; print(time.time_ns())')-$$"
  printf '%s\n%s at %s\n' "$$" "$(basename "$PWD")" "$(git rev-parse --short HEAD 2>/dev/null)" > "$q/$mine"
  takes_on_exit "$q/$mine"
  while :; do
    first="" ahead=0
    for f in $(ls "$q" | sort); do
      pid="$(head -1 "$q/$f" 2>/dev/null || true)"
      if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then rm -f "$q/$f"; continue; fi
      [[ -z "$first" ]] && first="$f"
      [[ "$f" == "$mine" ]] && break
      ahead=$((ahead + 1))
    done
    [[ "$first" == "$mine" ]] && break
    local msg="Waiting: $ahead test run(s) ahead on this Mac (now: $(sed -n 2p "$q/$first" 2>/dev/null))."
    [[ "$msg" != "$said" ]] && { echo "$msg" >&2; said="$msg"; }
    sleep 5
  done
  export TAKES_QUEUE_HELD=1
}

# took NAME: one line with the time and CPU since the last took (or since this file was sourced).
# CPU counts the commands this shell waited for, with their children. Times alone mislead on a
# busy Mac: a run waits for CPU that other work holds (2026-10-22).
TAKES_TOOK_T=$SECONDS
TAKES_TOOK_CPU=0
took() {
  # times into a file, never in $( ) or a pipe: there it runs in a subshell, which has no children.
  local f="${TMPDIR:-/tmp}/takes-times.$$" cpu
  times > "$f"
  cpu="$(tail -1 "$f" | awk '{n = 0; for (i = 1; i <= 2; i++) { split($i, a, "m"); sub("s", "", a[2]); n += a[1] * 60 + a[2] } printf "%d", n}')"
  rm -f "$f"
  echo "Took $((SECONDS - TAKES_TOOK_T)) s, CPU $((cpu - TAKES_TOOK_CPU)) s: $1" >&2
  TAKES_TOOK_T=$SECONDS
  TAKES_TOOK_CPU=$cpu
}

# LOW: run a build or the parallel tests at utility priority, so macOS serves the apps the user uses
# first (the full run took all 18 cores, 2026-10-22). The timed tests run without it: they time real
# playback and fail on a busy Mac. A clamped process cannot lift its children, so a test.sh started
# under LOW keeps it everywhere. TAKES_FULL_SPEED=1 turns it off.
LOW=(env)  # never empty: bash 3.2 with set -u calls an empty array unbound
if [[ "${TAKES_FULL_SPEED:-}" != 1 && -x /usr/sbin/taskpolicy ]]; then LOW=(/usr/sbin/taskpolicy -c utility); fi

tree_now() {
  local idx
  idx="$(mktemp)"
  cp "$(git rev-parse --git-path index)" "$idx"
  GIT_INDEX_FILE="$idx" git add -A
  GIT_INDEX_FILE="$idx" git write-tree
  rm -f "$idx"
}

passed_mark() {
  local d="$TAKES_CACHE/takes-tests-passed"
  mkdir -p "$d" && touch "$d/$1"
  find "$d" -type f -mtime +7 -delete 2>/dev/null || true
}
passed_has() { [[ -n "$1" && -f "$TAKES_CACHE/takes-tests-passed/$1" ]]; }

#!/usr/bin/env bash
# macdrive — inspect & drive a running macOS app UI without stealing the user's focus or cursor.
# Backend: compiled Swift AX/CGEvent helper (.helper-bin), screencapture, osascript for menus.
# All coordinates are GLOBAL POINTS (top-left of main display; negative on displays left/above).
# `dump` element centers feed straight into `click x y` — same space, no conversion.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/.helper-bin"

usage() {
  cat <<'USAGE'
macdrive <command> [args]     # App = process name from `macdrive apps` (case-insensitive ok)

READ (always safe, never touches focus/cursor):
  apps                          GUI apps: pid, name; flags duplicate instances (+ bundle path).
  pid <App>                     Resolve a name to a single pid (errors on duplicate instances).
  winid <App>                   Windows: id, pid, owner, "x,y WxH" (points), title.
                                Warns when windows span multiple same-named processes.
  snap <App> [out.png] [--id N] Screenshot a window by id -> PNG path + a px->point mapping line.
                                Captures even occluded / other-display windows. Read the PNG after.
  dump <App> [--all] [--window <winid>]   AX tree: role, id='AXIdentifier', 'label', center x,y.
                                Header gives window origin/size. --all includes every element.
                                --window pins a specific window id (bypasses the flaky focused-
                                window lookup — use it if `dump` starts returning a huge menu tree).

<App> is a process name (case-insensitive) OR a pid. If several instances of the same app are
running (worktree builds, xcodebuild test hosts), name lookup refuses to guess — kill the strays
or pass the pid you mean. EVERY command (incl. menu/--steal) targets exactly the pid you resolve.

ACT — semantic, background-safe (PREFER THESE):
  press <App> "<query>"         AXPress first pressable element matching query (matches identifier,
                                label, or value; case-insensitive substring). Lists candidates on miss.
  setval <App> "<query>" "<t>"  Set a text field/area's value directly. query '-' = first text field.
  focus <App> "<query>"         Give an element keyboard focus (inside the app; no focus steal).
  menu <App> "<Menu>" "<Item>" ["<Subitem>"]   Click a menu-bar item on THIS pid (background-safe).
  waitfor <App> "<query>" [--timeout N] [--gone]   Poll until an element appears (or --gone:
                                disappears). Replaces guessed sleeps; default timeout 10s.
  move <App> <x> <y>            Reposition the front window (AX; no focus steal). Use to pull a
                                window off a sleeping/secondary display onto the main one (0,0).
  openfile <App> <path>...      Send an open-documents Apple Event to THIS pid (no NSOpenPanel).
                                Only works if the app implements a document-open handler — verify.

ACT — synthetic input, background-safe but with caveats:
  type <App> "<text>"           Post text to the app's pid. Lands in the app's focused field —
                                run `focus` first to pick the field. Works while app is backgrounded.
  key <App> "cmd+shift+s"       Post a key combo to the pid. CAVEAT: backgrounded apps often ignore
                                menu shortcuts — prefer `menu` for anything that has a menu item.
  click <App> <x> <y>           Post a click at a GLOBAL POINT to the pid. Cursor does not move.
                                CAVEAT: non-frontmost windows may ignore it — verify with snap.
  drag <App> <x1> <y1> <x2> <y2>   Post a left-drag to the pid. CAVEAT: canvas/non-key windows
                                often swallow posted drags — verify with snap; may need --steal.
  hover <App> <x> <y>           Post mouse-moved to the pid (no cursor warp) to try to reveal
                                hover-only controls. CAVEAT: many reveals need the REAL cursor.
  click <App> <x> <y> --steal   Fallback: briefly activate this pid, physically click (cliclick),
                                then restore the user's previous app and cursor position (~1s of
                                disruption). Use only when the pid click was ignored.

Every action prints success even when the app ignored it — ALWAYS `snap` + Read the PNG to verify.
USAGE
}

ensure_helper() {
  if [ ! -x "$BIN" ] || [ "$DIR/helper.swift" -nt "$BIN" ]; then
    echo "(compiling helper…)" >&2
    swiftc -O "$DIR/helper.swift" -o "$BIN" || {
      echo "error: swiftc failed — is Xcode / CLT installed?" >&2; exit 1; }
  fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  apps|pid|winid|dump|press|setval|focus|waitfor|type|key|drag|hover|move|openfile)
    ensure_helper; exec "$BIN" "$cmd" "$@"
    ;;

  snap)
    ensure_helper
    [ -n "${1:-}" ] || { echo "error: <App> required" >&2; exit 2; }
    APP="$1"; shift
    OUT=""; WID=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --id) WID="${2:-}"; shift 2 ;;
        *) OUT="$1"; shift ;;
      esac
    done
    [ -n "$OUT" ] || OUT="/tmp/macdrive_$(echo "$APP" | tr ' ' '_').png"
    WINS="$("$BIN" winid "$APP" | grep -v '^#' || true)"
    "$BIN" winid "$APP" | grep '^#' >&2 || true   # surface the multi-process warning
    LINE=""
    if [ -n "$WID" ]; then
      LINE="$(printf '%s\n' "$WINS" | awk -F'\t' -v id="$WID" '$1==id {print; exit}')"
    else
      LINE="$(printf '%s\n' "$WINS" | head -1)"
      N="$(printf '%s\n' "$WINS" | grep -c . || true)"
      [ "$N" -gt 1 ] && echo "note: '$APP' has $N windows; snapping the frontmost. Use --id <winid> for another." >&2
    fi
    [ -n "$LINE" ] || { echo "error: no on-screen window for '$APP' (id $WID)" >&2; exit 1; }
    WID="$(printf '%s' "$LINE" | cut -f1)"
    GEO="$(printf '%s' "$LINE" | cut -f4)"   # "x,y WxH" in points
    screencapture -x -o -l"$WID" "$OUT"
    # Mapping line: image px -> global points, so coordinates can be computed from the PNG.
    PXW="$(sips -g pixelWidth "$OUT" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    PTW="$(printf '%s' "$GEO" | sed 's/.* //' | cut -dx -f1)"
    SCALE=2
    if [ -n "$PXW" ] && [ -n "$PTW" ] && [ "$PTW" -gt 0 ] 2>/dev/null; then
      SCALE=$(( (PXW + PTW/2) / PTW ))
    fi
    ORIGIN="$(printf '%s' "$GEO" | cut -d' ' -f1)"
    echo "$OUT"
    echo "# window origin=(${ORIGIN}) pt, image is ${SCALE}x px: global_pt = origin + image_px/${SCALE}. Prefer \`dump\` centers over pixel math."
    ;;

  menu)
    ensure_helper
    [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "error: menu <App> <Menu> <Item> [Subitem] required" >&2; exit 2; }
    # Resolve to a single pid first (errors on duplicate instances), then target THAT process by
    # its unix id — not by name. Prevents the "wrong instance / frontmost app" class of failure.
    PID="$("$BIN" pid "$1")" || exit 1
    osascript - "$PID" "$2" "$3" "${4:-}" <<'OSA'
on run argv
  set thePid to (item 1 of argv) as integer
  set menuName to item 2 of argv
  set itemName to item 3 of argv
  set subName to item 4 of argv
  tell application "System Events"
    set proc to first process whose unix id is thePid
    tell proc
      if subName is "" then
        click menu item itemName of menu menuName of menu bar item menuName of menu bar 1
      else
        click menu item subName of menu itemName of menu item itemName of menu menuName of menu bar item menuName of menu bar 1
      end if
    end tell
  end tell
  if subName is "" then
    return "clicked menu (pid " & thePid & "): " & menuName & " > " & itemName
  else
    return "clicked menu (pid " & thePid & "): " & menuName & " > " & itemName & " > " & subName
  end if
end run
OSA
    echo "(verify with \`macdrive snap\` — the click can succeed without the effect you expect)"
    ;;

  click)
    ensure_helper
    [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "error: click <App> <x> <y> [--steal]" >&2; exit 2; }
    APP="$1"; X="$2"; Y="$3"; MODE="${4:-}"
    if [ "$MODE" != "--steal" ]; then
      exec "$BIN" click "$APP" "$X" "$Y"
    fi
    command -v cliclick >/dev/null || { echo "error: --steal needs cliclick (brew install cliclick)" >&2; exit 1; }
    # Activate the exact instance by unix id — activating by name can foreground the wrong copy.
    PID="$("$BIN" pid "$APP")" || exit 1
    PREV="$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')"
    POS="$(cliclick p | tr -d ' ')"
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
    sleep 0.3
    cliclick "c:$X,$Y"
    sleep 0.2
    if [ -n "$PREV" ] && [ "$PREV" != "$APP" ]; then
      osascript -e "tell application \"$PREV\" to activate" 2>/dev/null || true
    fi
    cliclick "m:$POS"
    echo "clicked $X,$Y in '$APP' (focus and cursor restored to '$PREV' @ $POS)"
    ;;

  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac

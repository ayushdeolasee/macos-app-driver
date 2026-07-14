---
name: macos-app-driver
description: Inspect and drive a running macOS app's UI without computer-use. Screenshot windows, dump the accessibility hierarchy with identifiers, press/type/set values, run menus, all without stealing the user's focus or cursor. Use when asked to verify, test, click through, screenshot, or "see" a running Mac app (not iOS), or to check a macOS UI change end-to-end.
license: MIT
---

# macOS App Driver

Drive and observe a **running macOS app** with free local tooling (Accessibility API + `screencapture` + CGEvent). The user keeps working the whole time: every command here leaves their focus and cursor alone unless you explicitly opt into `--steal`.

TRIGGER when: verify/test/click-through/screenshot a running **macOS** (not iOS) app; "does the Mac app work", "check this UI change", drive a flow end-to-end.
DO NOT TRIGGER for: iOS/iPad apps (use your iOS device/simulator tools); pure build/test/log tasks (use your Xcode-provided build/test tools); single SwiftUI view snapshots (use a preview-rendering tool if you have one).

## Commands

Everything is `scripts/macdrive.sh` (in this skill's directory; compiles its Swift helper on first run). `App` = process name from `macdrive apps` (case-insensitive prefix ok) **or a pid**. If several instances of the app are running — stale worktree builds, xcodebuild test hosts — name lookup refuses to guess and lists pids + bundle paths: kill the strays (usually right) or pass the pid.

```
# READ — always safe
macdrive apps                          # pid + name; flags duplicate instances + bundle path
macdrive pid   <App>                   # resolve a name to ONE pid (errors on duplicates)
macdrive winid <App>                   # id | pid | owner | "x,y WxH" (points) | title
macdrive snap  <App> [out.png] [--id N]# screenshot -> PNG path + px->point mapping line
macdrive dump  <App> [--all] [--window <winid>]  # role | id='AXIdentifier' | 'label' | center @ x,y

# ACT — semantic, background-safe. PREFER THESE.
macdrive press  <App> "<query>"        # AXPress element matching query; lists candidates on miss
macdrive setval <App> "<query>" "<t>"  # set a text field's value directly ('-' = first field)
macdrive focus  <App> "<query>"        # give an element keyboard focus (within the app)
macdrive menu   <App> "<Menu>" "<Item>" ["<Subitem>"]   # clicks THIS pid, not the frontmost app
macdrive waitfor <App> "<query>" [--timeout N] [--gone] # poll until it appears/disappears
macdrive move   <App> <x> <y>          # reposition front window (no focus steal); prints old origin
macdrive openfile <App> <path>...      # open-documents Apple Event to THIS pid (app-dependent!)

# ACT — synthetic input to the app's pid. Background-safe, but see Reliability table.
macdrive type  <App> "<text>"          # lands in the app's focused field (run `focus` first)
macdrive key   <App> "cmd+shift+s"     # named keys: return/tab/space/delete/escape/arrows/f1-12
macdrive click <App> <x> <y>           # global-point click posted to pid; cursor never moves
macdrive drag  <App> <x1> <y1> <x2> <y2>  # left-drag posted to pid; cursor never moves
macdrive hover <App> <x> <y>           # mouse-moved posted to pid (try to reveal hover-only controls)
macdrive click <App> <x> <y> --steal   # LAST RESORT: real click; restores user's app+cursor after
```

**Targeting is resolved per-pid.** `menu` and `--steal` resolve to one pid first (via `pid`, which errors on duplicates) and act on exactly that process. With duplicate builds running, a name still refuses to guess — pass the pid.

`<query>` matches AXIdentifier, label, or value — case-insensitive substring. Identifiers (`id='welcome.openPdf'`) are the most durable targets; prefer them over labels.

## The loop

1. **Launch/find** - Either build the application via the preferred method for that application, or if asked to work with a already running application find it's PID using the `macdrive apps` to confirm the exact process name — and that there's exactly ONE instance. Dev setups routinely have a second copy running (old worktree build, `xcodebuild test` host): kill it before doing anything else, or every tool may silently talk to a different instance than the one you're screenshotting.
2. **Observe** — `macdrive snap <App> <out.png>`, then **Read the PNG**. Captures by window id, so occluded/other-display windows work.
3. **Locate** — `macdrive dump <App>`, grep for the control (by identifier when possible). The header line gives the window origin/size.
4. **Act** — `press` / `setval` / `menu` first; `focus`+`type` for text entry; `click <App> x y` only when the target has no identifier/label; `--steal` only if the pid click was ignored.
5. **Verify** — `snap` again and Read it. **Every action prints success even when the app ignored it** — a screenshot is the only proof. Never chain two actions without a snap between them unless the first is trivially safe. When an action triggers async UI (a sheet, a loaded document, a spinner clearing), use `waitfor <App> "<query>"` instead of guessing a `sleep` — it polls and returns the moment the element appears (`--gone` to wait for one to vanish).

## Reliability (measured, not theoretical)

| Action | Works while app is backgrounded? |
|---|---|
| `snap` `dump` `winid` `pid` `waitfor` `press` `setval` `focus` `menu` | ✅ always |
| `type` (after `focus`) | ✅ — unicode events land in the app's focused field |
| `key` with modifiers (`cmd+s`…) | ⚠️ often ignored — menu shortcuts need the app frontmost. Use `menu` instead; it presses the same item reliably. |
| `click <App> x y` (pid-posted) | ⚠️ non-key windows may ignore it. Verify with snap; escalate to `--steal`. |
| `drag` (pid-posted) | ⚠️ **worst reliability.** Canvas/selection/non-key windows commonly swallow posted drags — verify with snap. If ignored, the flow needs a real cursor. |
| `hover` (pid-posted) | ⚠️ best-effort. Reveals that key off movement deltas may fire; reveals gated on the *real* NSTrackingArea cursor won't. Verify with `dump`. |
| `click --steal` | ✅ but flashes the app frontmost ~1s (focus+cursor restored). Warn in your summary if you used it. |

Consequence: for "select all then retype", don't send `cmd+a` — use `setval` (replaces the whole value in one call). For menu-equivalent shortcuts, call `menu`.

### The focus ceiling — say it up front, don't rediscover it

On a machine the user is actively using, nothing that requires the app to be key/frontmost is reliably drivable background-safe. That includes: text-selection→highlight and other drags on a canvas, hover-reveal controls (tab ✕, annotation-delete), typed input into a non-key sheet/panel, and file-open panels (`NSOpenPanel`). `drag`/`hover` exist so you can *try* and cheaply confirm from a `snap`, but if the first attempt is swallowed, do not grind through 15 variations — you've hit the ceiling. Two ways past it, both explicit trade-offs:
- **Accept focus theft** — `--steal` a click to make the window key, drive the flow, restore. ~1s of visible disruption; warn the user.
- **Write an XCUITest** — for anything repeatable, or any drag/canvas/file-panel/hover flow, this is the right tool, run via your Xcode-provided test tools (or `xcodebuild test`). It gets a real event stream.

The read/verify half (does this panel render, does this toggle flip, does this banner appear) is genuinely good and non-disruptive — that's the sweet spot. Match the tool to the flow.

## Coordinates — one space, one rule

- `dump` centers, `winid` geometry, `move`, and `click` all use **GLOBAL POINTS**: origin at top-left of the *main* display, **negative** x/y on displays left/above. Dump centers feed straight into `click` — no conversion, ever. Negative coordinates are normal, not a bug.
- A `snap` PNG is in pixels; its second output line gives the exact mapping (`global_pt = window_origin + image_px/scale` — scale is 2 on retina, 1 on external 1x displays, and is computed for you). Only do pixel math when the target appears in the screenshot but not in `dump`; otherwise always use dump centers.
- **Trust only macdrive's origins.** Never mix in `osascript … get position of front window` — with multiple app instances it can read a *different process's* window and you'll conclude the window is "teleporting between displays". If two origin readings disagree, you have two instances running (see playbook), not two coordinate systems.

## Multi-monitor setups

- Reads (`snap`, `dump`) work on any display, awake or not — drive from those whenever possible.
- Synthetic clicks and AXPress can fail on windows sitting on a sleeping or secondary display (black snap, grey traffic lights, AXPress error -25204, clicks silently ignored). Don't fight it with scale-factor archaeology: `macdrive move <App> 100 100` pulls the window onto the main display background-safely; drive it there; `move` it back to the origin it printed when done.
- If coordinate clicks still miss twice after `move`, stop and escalate to a computer-use tool if you have one (they have per-display coordinates and their own screenshots). Do not keep deriving conversion formulas.

## Failure playbook

- **`press` says "no … matching"** — it prints the actual candidates: pick one, or use its `@ x,y` with `click`. If candidates are all unlabeled (`'button'`, `'text'`), add `.accessibilityIdentifier("…")` in the app source and rebuild — 1 line, makes automation durable. (SwiftUI toolbars/segments are the usual offenders.)
- **`dump` shows nothing / errors** — don't pipe to `2>/dev/null`; the error tells you whether it's a missing Accessibility permission vs. a still-loading window.
- **Multiple app instances** (`apps` flags them; `winid` warns; name lookup errors) — this is the classic cause of "impossible" behavior: dump/snap/osascript each silently talking to a different instance. Kill the strays (`kill <pid>` of old worktree builds and xcodebuild test hosts), or pass the pid you mean as `<App>`. Multiple *windows* of one instance: `winid` lists geometry, `snap --id <N>` targets one; the dump header names its window.
- **Opening a file** — try `openfile <App> /path` FIRST: it sends a document-open Apple Event straight to the pid, no panel, no focus steal. But it only works if the app registers document types / handles opens (many document apps do; some — e.g. apps that open files *only* through their own `NSOpenPanel` — do not). Verify with `snap`; if nothing opened, the app has no open handler and you must drive the panel. Panel path (focus-dependent, unreliable in background): don't click welcome-screen/recents rows; copy the path (`printf '%s' /path | pbcopy`), `menu <App> File "Open…"`, then `key <App> cmd+shift+g`, `key <App> cmd+v`, `key <App> return`, `key <App> return`. If the panel swallows the keys because it isn't key, you've hit the focus ceiling — `--steal` or write an XCUITest.
- **`dump` returns a huge (~7000-line) menu-bar tree / hangs for a long time** — the AX focused-window lookup has wandered into the menu-bar tree (the corruption trap, triggered by driving a sheet/popover on a backgrounded instance). AX calls now time out in ~8s instead of ~90s and `dump`/`collect` print a `# WARNING` when the front element isn't a real window. Recover by pinning a real window: `winid <App>` for the ids, then `dump <App> --window <winid>` (bypasses the focused-window lookup entirely). If that still returns garbage, the instance is wedged — relaunch it.
- **Drag / selection / canvas interactions** — `drag <App> x1 y1 x2 y2`, then `snap` to check. Posted drags are the least reliable primitive; if the canvas didn't respond, it's not driveable background-safe (see the focus-ceiling section) — `--steal` a click to make it key first, or write an XCUITest.
- **Hover-only controls invisible to `dump`** (tab ✕, delete-on-hover buttons) — `hover <App> x y` then re-`dump`. If the control still isn't in the tree, its reveal is gated on the real cursor; `--steal` or XCUITest.
- **`press` fails with AXPress error -25204** — the window is unfocused or on an inactive display; `move` it to the main display (see Multi-monitor) or activate the app once via `click --steal`.
- **Action "succeeded" but nothing changed** — normal; see the Reliability table. Re-snap, then try the semantic alternative (`menu` for keys, `--steal` for clicks).
- **Modal sheet blocking** — sheets appear inside `dump`; `press <App> "Cancel"` (or the right button) dismisses them background-safely.
- **App-level AppleScript (`tell application "TextEdit" to get text of document 1`) hangs** — apps can be unresponsive to Apple Events while showing suggestion popovers/dialogs; wrap in `with timeout of 5 seconds` or just use `dump`, which reads via AX and doesn't hang.
- **Fallback to computer-use for one action** — after you've tried all the debugging steps and are sure the action can't be done with this skill, and you have a computer-use tool available: delegate just that one action to it (a sub-agent is ideal — give it exact instructions, let it perform the action, then discard it), then pick up with this skill again. Try this before falling back to computer-use for the entire task.

## Permissions (one-time)

The controlling terminal needs, in System Settings → Privacy & Security: **Accessibility** (dump/press/setval/focus/type/key/click) and **Screen Recording** (snap). Missing permission looks like: empty AX tree (the error says so), event-creation failures, or a black/tiny snap. Ask the user to grant it to their terminal app; it can't be granted non-interactively.

## When to escalate

- Repeatable regression instead of a one-off drive → write an **XCUITest**, run via your Xcode-provided test tools (or `xcodebuild test`).
- No identifiers/labels AND coordinates too fragile (canvas/animated UI) → a computer-use tool, if available, is the (paid) fallback.

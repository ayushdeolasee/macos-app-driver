// macdrive helper — compiled once by macdrive.sh (ensure_helper).
// All commands are focus-safe: no app activation, no physical cursor movement.
// Coordinates are GLOBAL POINTS (top-left of main display; negative left/above).
//
//   apps                       GUI apps: pid<TAB>name (duplicates flagged)
//   pid <App>                  resolve a name to a single pid (errors on ambiguity)
//   winid [App]                windows: id<TAB>owner<TAB>x,y w x h<TAB>title
//   dump <App> [--all] [--window N]   AX tree of a window: role, id, label, center
//   press <App> <query>        AXPress the first actionable element matching query
//   setval <App> <query> <txt> Set AXValue of the text field/area matching query
//   focus <App> <query>        Set AXFocused on the element matching query (then use `type`)
//   waitfor <App> <query> [--timeout N] [--gone]   poll until an element appears/disappears
//   type <App> <text>          Post unicode text to the app's pid (lands in its focused field)
//   key <App> <combo>          Post key combo to pid (see SKILL.md caveat re background apps)
//   click <App> <x> <y>        Post mouse down/up at global point to pid (see caveat)
//   drag <App> <x1> <y1> <x2> <y2>    Post a left-drag to pid (see caveat)
//   hover <App> <x> <y>        Post mouse-moved to pid (best-effort hover-reveal)
//   move <App> <x> <y>         Reposition the front window (AX; no focus steal)
//   openfile <App> <path>...   Send an open-documents Apple Event to the pid (app-dependent)
import AppKit
import ApplicationServices
import Carbon.OpenScripting
import CoreGraphics
import Foundation

// Private AX SPI: map an AX window element to its CGWindowID (the id `winid`/`snap` use).
// Lets `dump --window <winid>` pin a specific window instead of the flaky focused-window lookup.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

// AX requests to a wedged app can otherwise block ~90s. Cap them so a bad state fails fast
// (the menu-bar-tree corruption trap) instead of hanging the whole run.
let axTimeout: Float = 8.0

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func warn(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func runningApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
}

func resolveApp(_ name: String) -> NSRunningApplication {
    let apps = runningApps()
    // A numeric arg is a pid — the unambiguous way to target one of several same-named instances.
    if let pid = Int32(name) {
        if let a = apps.first(where: { $0.processIdentifier == pid }) { return a }
        die("no running GUI app with pid \(name). Run `macdrive apps` for the list.")
    }
    let lower = name.lowercased()
    let tiers: [(NSRunningApplication) -> Bool] = [
        { $0.localizedName == name },
        { ($0.localizedName ?? "").lowercased() == lower },
        { ($0.localizedName ?? "").lowercased().hasPrefix(lower) },
    ]
    for tier in tiers {
        let hits = apps.filter(tier)
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 {
            // Same-named instances (e.g. dev builds from different worktrees, xcodebuild
            // test hosts) are the #1 source of "teleporting window" confusion — refuse to guess.
            let list = hits.map {
                "  pid \($0.processIdentifier)  \($0.bundleURL?.path ?? "?")"
            }.joined(separator: "\n")
            die("\(hits.count) running instances of '\(name)' — pass a pid instead of the name:\n\(list)\nUsually you want to quit/kill the stale ones (old worktree builds, xcodebuild test hosts) first.")
        }
    }
    let names = apps.compactMap { $0.localizedName }.sorted().joined(separator: ", ")
    die("no running app matching '\(name)'. Running: \(names)")
}

// One app-level AX element, with a bounded messaging timeout. Setting the timeout on the
// application element applies to all requests to that app, so child queries inherit it.
func axApp(_ app: NSRunningApplication) -> AXUIElement {
    let e = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(e, axTimeout)
    return e
}

// ---------- AX plumbing ----------

struct El {
    let ax: AXUIElement
    let role: String
    let subrole: String
    let identifier: String
    let label: String       // description > title > value(short) > help
    let value: String
    let frame: CGRect?
    let actions: [String]
    let depth: Int
}

func axStr(_ e: AXUIElement, _ attr: String) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func axFrame(_ e: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success
    else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

func axChildren(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return [] }
    return arr
}

func axActions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(e, &names) == .success,
          let arr = names as? [String] else { return [] }
    return arr
}

func makeEl(_ ax: AXUIElement, depth: Int) -> El {
    let value = axStr(ax, kAXValueAttribute as String)
    var label = axStr(ax, kAXDescriptionAttribute as String)
    if label.isEmpty { label = axStr(ax, kAXTitleAttribute as String) }
    if label.isEmpty { label = String(value.prefix(60)) }
    if label.isEmpty { label = axStr(ax, kAXHelpAttribute as String) }
    return El(
        ax: ax,
        role: axStr(ax, kAXRoleAttribute as String),
        subrole: axStr(ax, kAXSubroleAttribute as String),
        identifier: axStr(ax, kAXIdentifierAttribute as String),
        label: label,
        value: value,
        frame: axFrame(ax),
        actions: axActions(ax),
        depth: depth
    )
}

let windowRole = kAXWindowRole as String  // "AXWindow"

func isWindow(_ e: AXUIElement) -> Bool {
    axStr(e, kAXRoleAttribute as String) == windowRole
}

// Return the app's front window, or nil (non-dying — used by polling).
// Guards the menu-bar-tree corruption trap: kAXFocusedWindowAttribute can start returning a
// non-window element on a backgrounded instance driving a sheet/popover; validate the role and
// fall back to the explicit window list instead of trusting it.
func frontWindowOpt(_ app: NSRunningApplication) -> AXUIElement? {
    let a = axApp(app)
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(a, kAXFocusedWindowAttribute as CFString, &v) == .success,
       let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() {
        let w = el as! AXUIElement
        if isWindow(w) { return w }
        // Focused-window lookup returned a non-window: fall through to the real window list.
    }
    if AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &v) == .success,
       let wins = v as? [AXUIElement] {
        if let w = wins.first(where: isWindow) { return w }
        if let first = wins.first { return first }
    }
    return nil
}

func frontWindow(_ app: NSRunningApplication) -> AXUIElement {
    if let w = frontWindowOpt(app) { return w }
    die("'\(app.localizedName ?? "?")' has no accessible windows. If the app is definitely showing a window, the terminal may be missing the Accessibility permission (System Settings > Privacy & Security > Accessibility).")
}

// Find the app's AX window whose CGWindowID matches `wid` (the id from `winid`/`snap`).
func windowByID(_ app: NSRunningApplication, _ wid: CGWindowID) -> AXUIElement? {
    let a = axApp(app)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &v) == .success,
          let wins = v as? [AXUIElement] else { return nil }
    for w in wins {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(w, &id) == .success, id == wid { return w }
    }
    return nil
}

func traverse(_ root: AXUIElement, depth: Int = 0, into out: inout [El], maxDepth: Int = 40) {
    guard depth <= maxDepth, out.count < 8000 else { return }
    out.append(makeEl(root, depth: depth))
    for c in axChildren(root) {
        traverse(c, depth: depth + 1, into: &out, maxDepth: maxDepth)
    }
}

func matches(_ el: El, _ query: String) -> Bool {
    if query.isEmpty { return true }
    let q = query.lowercased()
    return el.identifier.lowercased().contains(q)
        || el.label.lowercased().contains(q)
        || el.value.lowercased().contains(q)
}

func describe(_ el: El) -> String {
    var parts = [el.role + (el.subrole.isEmpty ? "" : "/\(el.subrole)")]
    if !el.identifier.isEmpty { parts.append("id='\(el.identifier)'") }
    parts.append("'\(el.label)'")
    if let f = el.frame {
        parts.append("@ \(Int(f.midX)),\(Int(f.midY))")
    }
    return parts.joined(separator: "  ")
}

let interactiveRoles: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXPopUpButton",
    "AXMenuButton", "AXRadioButton", "AXSlider", "AXComboBox", "AXLink",
    "AXDisclosureTriangle", "AXSegmentedControl", "AXTab", "AXSearchField",
    "AXStaticText", "AXIncrementor", "AXStepper", "AXColorWell", "AXCell",
]

func windowHeader(_ win: AXUIElement) -> String {
    let el = makeEl(win, depth: 0)
    if let f = el.frame {
        return "# window '\(el.label)' origin=(\(Int(f.minX)),\(Int(f.minY))) size=\(Int(f.width))x\(Int(f.height)) pt — element centers below are GLOBAL POINTS; pass straight to `click`"
    }
    return "# window '\(el.label)'"
}

func collectWindow(_ appName: String, winid: CGWindowID? = nil) -> (NSRunningApplication, AXUIElement, [El]) {
    let app = resolveApp(appName)
    let win: AXUIElement
    if let wid = winid {
        guard let w = windowByID(app, wid) else {
            die("no AX window with id \(wid) for '\(appName)'. Run `macdrive winid \(appName)` for current window ids (they change across relaunches).")
        }
        win = w
    } else {
        win = frontWindow(app)
    }
    var els: [El] = []
    traverse(win, into: &els)
    if els.count <= 1 {
        die("AX returned an empty tree for '\(appName)' — usually the Accessibility permission is missing for the terminal (System Settings > Privacy & Security > Accessibility), or the window is still loading.")
    }
    // Corruption-trap detection: if the "front window" isn't a window, or the tree is almost
    // entirely menu items, the focused-window lookup has wandered into the menu-bar tree.
    let menuish = els.filter { $0.role == "AXMenuItem" || $0.role == "AXMenuBarItem" || $0.role == "AXMenu" }.count
    if winid == nil, (!isWindow(win) || (els.count > 200 && menuish > els.count / 2)) {
        warn("# WARNING: the front element looks like the menu-bar tree, not a window (role=\(axStr(win, kAXRoleAttribute as String)), \(menuish)/\(els.count) menu nodes). This is the known AX corruption trap when driving a sheet/popover on a backgrounded instance. Pin a real window with `dump \(appName) --window <winid>` (get ids from `winid \(appName)`), or relaunch this instance.")
    }
    return (app, win, els)
}

func findOrDie(_ appName: String, _ query: String, roleFilter: (El) -> Bool, what: String) -> (NSRunningApplication, El) {
    let (app, _, els) = collectWindow(appName)
    let candidates = els.filter(roleFilter)
    if let hit = candidates.first(where: { matches($0, query) }) { return (app, hit) }
    var msg = "no \(what) matching '\(query)' in the front window of '\(appName)'."
    let named = candidates.filter { !$0.label.isEmpty || !$0.identifier.isEmpty }
    if named.isEmpty {
        msg += " No labeled candidates at all — run `macdrive dump` and use element centers with `click`, or add .accessibilityIdentifier in the app source."
    } else {
        msg += " Candidates:\n" + named.prefix(40).map { "  " + describe($0) }.joined(separator: "\n")
    }
    die(msg)
}

// ---------- key/typing plumbing ----------

let keycodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "forwarddelete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

let modifierCodes: [(String, CGEventFlags, CGKeyCode)] = [
    ("cmd", .maskCommand, 55), ("shift", .maskShift, 56),
    ("opt", .maskAlternate, 58), ("ctrl", .maskControl, 59),
]

func postKey(_ pid: pid_t, code: CGKeyCode, flags: CGEventFlags) {
    let mods = modifierCodes.filter { flags.contains($0.1) }
    var held: CGEventFlags = []
    for (_, flag, mcode) in mods {
        held.insert(flag)
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: mcode, keyDown: true)
        else { die("could not create key event (missing Accessibility permission?)") }
        e.flags = held
        e.postToPid(pid)
        usleep(15_000)
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    else { die("could not create key event (missing Accessibility permission?)") }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid)
    usleep(20_000)
    up.postToPid(pid)
    usleep(20_000)
    for (_, flag, mcode) in mods.reversed() {
        held.remove(flag)
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: mcode, keyDown: false)
        else { die("could not create key event") }
        e.flags = held
        e.postToPid(pid)
        usleep(15_000)
    }
}

func postMouse(_ pid: pid_t, _ type: CGEventType, _ p: CGPoint, clickState: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    else { die("could not create mouse event (missing Accessibility permission?)") }
    e.setIntegerValueField(.mouseEventClickState, value: clickState)
    e.postToPid(pid)
}

// ---------- main ----------

let args = CommandLine.arguments.dropFirst()
guard let cmd = args.first else { die("usage: helper <apps|pid|winid|dump|press|setval|focus|waitfor|type|key|click|drag|hover|move|openfile> ...") }
let rest = Array(args.dropFirst())

switch cmd {
case "apps":
    var seen: [String: Int] = [:]
    for a in runningApps() { seen[a.localizedName ?? "?", default: 0] += 1 }
    for a in runningApps() {
        let n = a.localizedName ?? "?"
        let dup = (seen[n] ?? 0) > 1
            ? "\t[\(seen[n]!) instances — use the pid, and check: \(a.bundleURL?.path ?? "?")]"
            : ""
        print("\(a.processIdentifier)\t\(n)\(dup)")
    }

case "pid":
    guard let appName = rest.first else { die("usage: helper pid <App>") }
    print(resolveApp(appName).processIdentifier)

case "winid":
    let target = rest.first
    let targetPid: pid_t? = target.flatMap { Int32($0) }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { die("CGWindowListCopyWindowInfo failed") }
    var any = false
    var ownerPids = Set<pid_t>()
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let pid = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)
        if let tp = targetPid {
            if pid != tp { continue }
        } else if let t = target, !t.isEmpty, owner.lowercased() != t.lowercased() {
            continue
        }
        any = true
        if let t = target, !t.isEmpty { ownerPids.insert(pid) }
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        let name = w[kCGWindowName as String] as? String ?? ""
        var geo = ""
        if let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
            geo = "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))"
        }
        print("\(num)\t\(pid)\t\(owner)\t\(geo)\t\(name)")
    }
    if ownerPids.count > 1 {
        print("# WARNING: these windows belong to \(ownerPids.count) different '\(target ?? "")' processes (pids \(ownerPids.sorted().map(String.init).joined(separator: ", "))) — stale worktree builds or test hosts. Kill the strays, or target one by passing its pid instead of the name.")
    }
    if !any, let t = target {
        die("no on-screen windows for '\(t)'. Check `macdrive apps` for the exact process name/pid; the window may also be minimized or on another Space.")
    }

case "dump":
    guard let appName = rest.first else { die("usage: helper dump <App> [--all] [--window <winid>]") }
    let all = rest.contains("--all")
    var wid: CGWindowID? = nil
    if let i = rest.firstIndex(of: "--window") {
        guard i + 1 < rest.count, let n = UInt32(rest[i + 1]) else {
            die("--window needs a numeric window id (from `macdrive winid \(appName)`)")
        }
        wid = n
    }
    let (_, win, els) = collectWindow(appName, winid: wid)
    print(windowHeader(win))
    for el in els {
        let interesting = all
            || interactiveRoles.contains(el.role)
            || !el.identifier.isEmpty
            || el.actions.contains("AXPress")
        guard interesting, el.frame != nil else { continue }
        print(describe(el))
    }

case "press":
    guard rest.count >= 2 else { die("usage: helper press <App> <query>") }
    let (_, el) = findOrDie(rest[0], rest[1],
                            roleFilter: { $0.actions.contains("AXPress") },
                            what: "pressable element")
    let err = AXUIElementPerformAction(el.ax, "AXPress" as CFString)
    guard err == .success else { die("AXPress failed (\(err.rawValue)) on \(describe(el))") }
    print("pressed: \(describe(el))")
    print("(verify with `macdrive snap` — a press can succeed without doing what you expect)")

case "setval":
    guard rest.count >= 3 else { die("usage: helper setval <App> <query> <text>  (query '-' = first text field)") }
    let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    let q = rest[1] == "-" ? "" : rest[1]
    let (_, el) = findOrDie(rest[0], q,
                            roleFilter: { textRoles.contains($0.role) },
                            what: "text field")
    let err = AXUIElementSetAttributeValue(el.ax, kAXValueAttribute as CFString, rest[2] as CFString)
    guard err == .success else { die("set value failed (\(err.rawValue)) on \(describe(el)) — field may be read-only; try `focus` + `type`") }
    print("set value of \(describe(el))")

case "focus":
    guard rest.count >= 2 else { die("usage: helper focus <App> <query>") }
    let (_, el) = findOrDie(rest[0], rest[1], roleFilter: { _ in true }, what: "element")
    let err = AXUIElementSetAttributeValue(el.ax, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard err == .success else { die("focus failed (\(err.rawValue)) on \(describe(el))") }
    print("focused: \(describe(el)) — `type` will now land here")

case "waitfor":
    guard rest.count >= 2 else { die("usage: helper waitfor <App> <query> [--timeout N] [--gone]") }
    let appName = rest[0], query = rest[1]
    var timeout = 10.0
    if let i = rest.firstIndex(of: "--timeout"), i + 1 < rest.count, let t = Double(rest[i + 1]) { timeout = t }
    let wantGone = rest.contains("--gone")
    let app = resolveApp(appName)
    let start = Date()
    var lastMatch: El? = nil
    while Date().timeIntervalSince(start) < timeout {
        if let win = frontWindowOpt(app) {
            var els: [El] = []
            traverse(win, into: &els)
            let hit = els.first { matches($0, query) && $0.frame != nil }
            lastMatch = hit ?? lastMatch
            let present = hit != nil
            if present != wantGone {
                if wantGone {
                    print("gone: '\(query)' no longer in '\(appName)' after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                } else if let h = hit {
                    print("appeared: \(describe(h))  (after \(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
                }
                exit(0)
            }
        }
        usleep(400_000)
    }
    die("timed out after \(Int(timeout))s waiting for '\(query)' to \(wantGone ? "disappear" : "appear") in '\(appName)'. Verify with `snap`; the element may need an identifier, or the app may be wedged (try `dump --window <winid>`).")

case "type":
    guard rest.count >= 2 else { die("usage: helper type <App> <text>") }
    let pid = resolveApp(rest[0]).processIdentifier
    for ch in rest[1].unicodeScalars {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { die("could not create key event (missing Accessibility permission?)") }
        var units = Array(String(ch).utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.postToPid(pid)
        usleep(12_000)
        up.postToPid(pid)
        usleep(12_000)
    }
    print("typed \(rest[1].count) chars -> pid \(pid) (into the app's focused field; use `focus` first to pick the field, `snap` after to verify)")

case "key":
    guard rest.count >= 2 else { die("usage: helper key <App> <combo>") }
    let pid = resolveApp(rest[0]).processIdentifier
    let combo = rest[1].lowercased()
    var parts = combo.split(separator: "+").map(String.init)
    guard let keyName = parts.popLast() else { die("empty combo") }
    var flags: CGEventFlags = []
    for m in parts {
        switch m {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default: die("unknown modifier '\(m)' (use cmd/shift/opt/ctrl/fn)")
        }
    }
    guard let code = keycodes[keyName] else {
        die("unknown key '\(keyName)'. Named keys: return, tab, space, delete, escape, left/right/up/down, home/end/pageup/pagedown, f1-f12, plus a-z 0-9 punctuation")
    }
    postKey(pid, code: code, flags: flags)
    if !flags.isEmpty {
        print("sent \(combo) -> pid \(pid) (NOTE: background apps often ignore menu shortcuts — if nothing happened, use `macdrive menu` instead)")
    } else {
        print("sent \(combo) -> pid \(pid)")
    }

case "move":
    // Reposition the front window via AX — background-safe, no focus steal. Useful to pull a
    // window off a sleeping/secondary display onto the main one (origin 0,0) before driving it.
    guard rest.count >= 3, let x = Double(rest[1]), let y = Double(rest[2])
    else { die("usage: helper move <App> <x> <y>  (new top-left, global points; main display starts at 0,0)") }
    let app = resolveApp(rest[0])
    let win = frontWindow(app)
    let old = axFrame(win)
    var pt = CGPoint(x: x, y: y)
    guard let axPt = AXValueCreate(.cgPoint, &pt) else { die("AXValueCreate failed") }
    let err = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPt)
    guard err == .success else { die("move failed (\(err.rawValue)) — window may be fullscreen or non-movable") }
    let oldStr = old.map { "(\(Int($0.minX)),\(Int($0.minY)))" } ?? "(?)"
    print("moved front window of '\(app.localizedName ?? rest[0])' \(oldStr) -> (\(Int(x)),\(Int(y))). Restore with `move` back to \(oldStr) when done; re-run `dump` — all element centers changed.")

case "click":
    guard rest.count >= 3, let x = Double(rest[1]), let y = Double(rest[2])
    else { die("usage: helper click <App> <x> <y>  (global points)") }
    let pid = resolveApp(rest[0]).processIdentifier
    let pt = CGPoint(x: x, y: y)
    postMouse(pid, .mouseMoved, pt)
    usleep(30_000)
    postMouse(pid, .leftMouseDown, pt)
    usleep(30_000)
    postMouse(pid, .leftMouseUp, pt)
    print("clicked \(Int(x)),\(Int(y)) -> pid \(pid) (cursor did not move; background windows may ignore this — verify with `snap`, escalate to `click --steal` if ignored)")

case "drag":
    guard rest.count >= 5,
          let x1 = Double(rest[1]), let y1 = Double(rest[2]),
          let x2 = Double(rest[3]), let y2 = Double(rest[4])
    else { die("usage: helper drag <App> <x1> <y1> <x2> <y2>  (global points)") }
    let pid = resolveApp(rest[0]).processIdentifier
    let steps = 24
    postMouse(pid, .mouseMoved, CGPoint(x: x1, y: y1))
    usleep(20_000)
    postMouse(pid, .leftMouseDown, CGPoint(x: x1, y: y1))
    usleep(30_000)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        postMouse(pid, .leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t))
        usleep(16_000)
    }
    postMouse(pid, .leftMouseUp, CGPoint(x: x2, y: y2))
    print("dragged (\(Int(x1)),\(Int(y1))) -> (\(Int(x2)),\(Int(y2))) -> pid \(pid) (cursor did not move; non-key/canvas windows may swallow posted drags — verify with `snap`. If ignored, this flow needs a real cursor: `--steal` a click first to make the window key, or write an XCUITest.)")

case "hover":
    guard rest.count >= 3, let x = Double(rest[1]), let y = Double(rest[2])
    else { die("usage: helper hover <App> <x> <y>  (global points)") }
    let pid = resolveApp(rest[0]).processIdentifier
    let pt = CGPoint(x: x, y: y)
    // A few nudges so tracking areas that key off movement deltas have a chance to fire.
    for _ in 0..<3 {
        postMouse(pid, .mouseMoved, pt)
        usleep(40_000)
    }
    print("hovered \(Int(x)),\(Int(y)) -> pid \(pid) (posts mouse-moved without warping the real cursor). Re-`dump`/`snap` to see if hover-reveal controls (tab ✕, delete buttons) entered the tree. HONEST CAVEAT: many NSTrackingArea reveals only fire for the *real* cursor and won't respond to posted events — if the control never appears, it is not driveable background-safe; use `--steal` or an XCUITest.")

case "openfile":
    guard rest.count >= 2 else { die("usage: helper openfile <App> <path> [<path>...]") }
    let app = resolveApp(rest[0])
    let paths = Array(rest.dropFirst())
    let urls: [URL] = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    for u in urls where !FileManager.default.fileExists(atPath: u.path) {
        die("no such file: \(u.path)")
    }
    // Send a standard open-documents ('odoc') Apple Event straight to the target pid — no
    // NSOpenPanel, no focus steal, and it hits THIS instance (not the frontmost same-named one).
    let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass),
        eventID: AEEventID(kAEOpenDocuments),
        targetDescriptor: target,
        returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID))
    let list = NSAppleEventDescriptor.list()
    for (idx, u) in urls.enumerated() {
        guard let data = u.absoluteString.data(using: .utf8),
              let d = NSAppleEventDescriptor(descriptorType: DescType(typeFileURL), data: data)
        else { die("could not encode url \(u.path)") }
        list.insert(d, at: idx + 1)
    }
    event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
    do {
        _ = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 10)
        print("sent open-documents event for \(urls.count) file(s) -> pid \(app.processIdentifier) (\(app.localizedName ?? rest[0])). VERIFY with `snap` — this only works if the app implements a document-open handler. If nothing opened, the app opens files only via its own NSOpenPanel: drive that (see SKILL.md) or write an XCUITest.")
    } catch {
        die("open-documents event failed: \(error.localizedDescription). The app likely doesn't handle document-open events — drive its NSOpenPanel (see SKILL.md 'Opening a file') or use an XCUITest.")
    }

default:
    die("unknown subcommand '\(cmd)'")
}

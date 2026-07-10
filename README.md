# macos-app-driver

An [Agent Skill](https://skills.sh) that lets a coding agent **inspect and drive a running macOS app's UI without computer-use** — screenshot windows, dump the accessibility hierarchy with identifiers, press buttons, type text, set field values, click menus — all **without stealing your focus or cursor**. You keep working while the agent verifies your Mac app end-to-end.

Built on free local tooling: the macOS Accessibility API, `screencapture`, and CGEvent — no paid computer-use API, no VM, no screen takeover.

## Install

```bash
# Claude Code (project-scoped)
npx skills add ayushdeolasee/macos-app-driver

# or globally
npx skills add ayushdeolasee/macos-app-driver -g
```

Works with any agent supported by the [skills CLI](https://github.com/vercel-labs/skills) (Claude Code, Cursor, Codex, etc.).

## What the agent can do

```
macdrive apps                       # list running GUI apps (flags duplicate instances)
macdrive snap  MyApp out.png        # screenshot a window — even occluded / on another display
macdrive dump  MyApp                # accessibility tree: roles, identifiers, labels, coordinates
macdrive press MyApp "Save"         # press a button by identifier/label — background-safe
macdrive setval MyApp "-" "hello"   # set a text field's value directly
macdrive menu  MyApp File "Open…"   # click a menu item on the exact pid, app stays backgrounded
macdrive waitfor MyApp "Done"       # poll until an element appears (or --gone)
```

The `SKILL.md` teaches the agent the full loop — observe (screenshot) → locate (AX dump) → act (semantic press/type) → verify (screenshot again) — plus a measured reliability table for what works while an app is backgrounded, a failure playbook, and multi-monitor handling.

## Requirements

- macOS (Apple Silicon or Intel) with Xcode Command Line Tools (`swiftc` — the Swift helper compiles itself on first run)
- One-time permissions for your terminal app in **System Settings → Privacy & Security**: **Accessibility** and **Screen Recording**
- Optional: [`cliclick`](https://github.com/BlueM/cliclick) (`brew install cliclick`) for the `--steal` last-resort real click

## Why not computer-use?

Computer-use screenshots the whole screen, moves your real cursor, and needs the target app frontmost — you can't touch your machine while it runs. This skill posts events to a specific **pid** and captures specific **window ids**, so the app under test can stay in the background on any display while you keep typing in your editor. When something genuinely needs a real cursor (canvas drags, hover-reveal controls, file-open panels), the skill says so explicitly and escalates deliberately instead of flailing.

## License

MIT

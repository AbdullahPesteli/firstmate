---
name: firefox-marionette
description: >-
  Agent-only guide for driving an isolated, disposable Firefox over Marionette through bin/fm-firefox.sh.
  Load before choosing or using this route for a task: installing a caller-supplied WebExtension the supported Mozilla way, or driving Firefox web content or extension/browser context without pixel automation, in a fresh profile that never touches the captain's live Firefox/Zen.
  Covers when to prefer this over Playwright/CDP/FoxMCP, the browser-vs-OS boundary, the no-live-profile safety contract, dependency checks, receipts, cleanup, and the native-host cookie caveat.
user-invocable: false
metadata:
  internal: true
---

# firefox-marionette

`bin/fm-firefox.sh` owns the lifecycle of one isolated, disposable Firefox process driven over Marionette (the W3C WebDriver protocol Firefox speaks natively).
It exists because Firefox extension work and Gecko-specific behavior cannot be reproduced by Chrome-based tools, and because the supported install/control path must never touch the captain's live browser.
Read `bin/fm-firefox.sh --help` for the exact commands and flags; this skill is only the judgment layer around them, and never restates the flags.

## When to choose this route

Pick this route only when the task genuinely needs the Gecko engine or a Firefox WebExtension:

- Installing or exercising a caller-supplied Firefox WebExtension through the supported Mozilla temporary-add-on route.
- Reproducing or verifying Firefox-extension behavior, including extension background/browser context and native-messaging-adjacent flows.
- Driving real web content in Firefox (DOM read/write, navigation, script) without any pixel automation.

Prefer another tool when the task is not Firefox-specific:

- `chrome-devtools-axi` (and Playwright when configured) own Chrome/Chromium/CDP work and disposable headless Chromium verification.
- FoxMCP drives the captain's own live, logged-in Zen/Firefox and is only for reading that real session under high trust; never use it for disposable automation, and never point this tool at that live browser.
- If the work does not need Firefox at all, do not launch Firefox.

## Browser-vs-OS boundary

This tool controls the browser, not the operating system.
All control flows over Marionette's loopback TCP endpoint: content DOM, extension/browser context, and add-on install.
It never synthesizes clicks or keystrokes and never needs macOS Accessibility, Screen Recording, or any TCC grant.
If a task genuinely requires OS-level GUI interaction, this is the wrong tool; do not try to bolt pixel automation onto it.

## No-live-profile safety contract

The tool always creates a fresh, empty, task-owned profile and launches exactly one `-no-remote` Firefox it owns.
It never attaches to, copies, or enumerates the captain's Firefox/Zen profiles, refuses the shared default endpoint `127.0.0.1:2828`, and applies privileged system access only to its own disposable process.
`stop` tears down only the process, profile, and port it created, after proving the recorded PID is still our Firefox by its profile path; it refuses ambiguous PID/port/profile ownership rather than killing or deleting anything it cannot prove it created.
Trust the tool's refusals: an ownership refusal is a stop-and-look signal, never an obstacle to force past.

## Dependencies, receipts, and cleanup

Run `doctor` first; it reports whether a Firefox binary and python3 (both required) resolve, and notes web-ext as an optional unmanaged alternative that this tool does not use.
Every `start`, `receipt`, and `stop` prints a truthful machine-readable JSON receipt: the owned profile, the avoided shared port, the actual Marionette endpoint, whether the extension installed and its real add-on id, and exactly which resources were created or removed.
Read the receipt as evidence rather than assuming success, and always `stop` the session when done so no Firefox child, profile, or port is left behind.
A caller drives the browser by connecting its own WebDriver client to the Marionette endpoint the receipt reports; the tool owns lifecycle and install, not the caller's automation logic.

## Native-host cookie caveat

Profile isolation constrains only this tool's own Firefox profile.
It does not and cannot constrain a project-specific native messaging host, which can independently discover unrelated Gecko cookie profiles (for example Zen) on the machine.
When a task drives a project whose native host reads browser cookies and that privacy scope matters, the project must supply its own independently verified cookie-off contract; forward it with the tool's cookie-off/env hook, which passes it through without interpreting it and records it in the receipt as caller-asserted.
Never claim that this tool's generic browser isolation controls a project native host's cookie behavior; state the boundary honestly and point at the receipt's caveat.

# Isolated Firefox over Marionette

`bin/fm-firefox.sh` is a harness-agnostic CLI that owns the lifecycle of one isolated, disposable Firefox process driven over Marionette, the W3C WebDriver protocol Firefox speaks natively.
Any Firstmate worker, on any harness, invokes it through the shell to install a caller-supplied WebExtension and drive Firefox web content or extension context without pixel automation, TCC prompts, or touching a live browser.
The script header and `bin/fm-firefox.sh --help` own the exact commands and flags; this page is the operator overview and does not restate them.
Agents choosing between this and other browser tools load the `firefox-marionette` skill; current verification evidence lives in [verification/firefox-marionette.md](verification/firefox-marionette.md).

## What it does

- `doctor` diagnoses dependencies: a Firefox binary and python3 are required, and web-ext is reported as an optional, unmanaged alternative this tool does not use.
- `start` creates a fresh task-owned profile, self-allocates a loopback Marionette endpoint, launches exactly one `-no-remote` Firefox, optionally enables privileged system access for that process, installs a supplied extension through the supported Mozilla temporary-add-on route, and prints a machine-readable receipt.
- `receipt` and `list` report owned sessions and their live state; `stop` tears down only what that session created.

The one supported install route is Marionette's `Addon:Install` with `temporary` set, which is why the tool can own exactly one Firefox process rather than delegating the launch to an external runner.

## Safety guarantees operators can rely on

- It always creates a fresh, empty profile and never attaches to, copies, or enumerates the machine's real Firefox/Zen profiles.
- It refuses the shared default endpoint `127.0.0.1:2828` and allocates its own loopback port instead.
- It applies `-remote-allow-system-access` only to its own disposable process, only when asked.
- `stop` proves ownership by the recorded PID's profile path before terminating anything, and refuses ambiguous PID/port/profile ownership rather than killing or deleting resources it cannot prove it created.

## Platform boundary

macOS and Linux are supported; Windows is unsupported.
The tool needs a resolvable Firefox binary (`FM_FIREFOX_BIN`, then `PATH`, then the platform default install location) and python3.
Control is entirely in-browser over a loopback TCP endpoint, so it never requires macOS Accessibility or Screen Recording permission.

## Native-host cookie caveat

Profile isolation here constrains only this tool's own Firefox profile.
It does not and cannot constrain a project-specific native messaging host, which can independently discover unrelated Gecko cookie profiles such as Zen on the same machine.
When a project's native host reads browser cookies and that scope matters, the project must supply its own independently verified cookie-off contract; forward it with the tool's cookie-off/env hook, which passes it through unchanged and records it in the receipt as caller-asserted.
The receipt's cookie block carries the authoritative caveat wording; never describe generic browser isolation as controlling a project native host's cookie behavior.

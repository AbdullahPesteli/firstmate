# Verification: isolated Firefox over Marionette

Active empirical evidence for `bin/fm-firefox.sh`.
Operator overview is [../firefox-marionette.md](../firefox-marionette.md); refresh this record after a Firefox upgrade or a change to the tool's launch, install, or cleanup behavior by re-running the commands below.

## Environment (2026-08-09)

- Firefox: `Mozilla Firefox 153.0.3` at `/Applications/Firefox.app/Contents/MacOS/firefox` (macOS, Darwin 25.4.0).
- python3: `Python 3.12.10`.
- marionette_driver (WebDriver client used only by the live proof, not by the tool): `3.7.1`.
- web-ext (optional, unmanaged, not used by the tool): `10.1.0`.

An earlier Firefox `152.0.6` on the same machine proved the same route during the originating investigation (`data/scout-mg-firefox-deploy/report.md`).

## Hermetic command-surface behavior (runs in standard CI)

```
$ bash tests/fm-firefox-marionette.test.sh
ok - dependency failure is diagnosed and refused
ok - start creates a clean owned profile, avoids 2828, and emits a truthful receipt
ok - cookie caveat is truthful and the caller cookie-off contract is recorded by key only
ok - stop removes exactly the profile, state, and process it created
ok - extension is optional and absent cookie contract is reported honestly
ok - extension paths are validated before any launch
ok - the shared 127.0.0.1:2828 endpoint is refused
ok - ambiguous pid ownership is refused instead of guessing
ok - a profile path outside the state root is never removed
ok - a Firefox that dies before readiness is cleaned up with no leftovers
ok - a Firefox that never opens the endpoint is killed and cleaned up
ok - an extension install failure is cleaned up with no leftovers
ok - fm-firefox.sh hermetic command-surface behavior
```

This test drives the tool against a fake Firefox that speaks the real Marionette (protocol v3) wire format the tool's client emits, so it needs no real browser, no network, and no third-party WebDriver client.

## Live proof (opt-in, self-skipping)

`tests/fm-firefox-marionette-live-e2e.test.sh` self-skips unless `FM_FIREFOX_LIVE_E2E=1` and Firefox, python3, and marionette_driver are all present, so standard CI stays hermetic.
Run it after a Firefox upgrade to refresh this record:

```
$ FM_FIREFOX_LIVE_E2E=1 bash tests/fm-firefox-marionette-live-e2e.test.sh
ok - fm-firefox live E2E (Mozilla Firefox 153.0.3): real add-on install, web-content and extension-context control, no unrelated browser touched, no leftovers
```

It installs a synthetic local extension, serves a page over loopback HTTP (no external URL), and through an independent Marionette client proves: the add-on is installed and active, the extension is controllable in the browser context (its `WebExtensionPolicy` name), its content script ran on the page, and Marionette drives the page DOM directly - all without pixel clicks.
It then proves `stop` left no Firefox child, profile, or port behind, and that every unrelated Firefox/Zen process and the shared `127.0.0.1:2828` endpoint were unchanged.

## doctor

```
$ bin/fm-firefox.sh doctor
fm-firefox doctor
  [ok]      firefox        /Applications/Firefox.app/Contents/MacOS/firefox
  [ok]      python3        /Library/Frameworks/Python.framework/Versions/3.12/bin/python3
  [ok]      web-ext        /Users/pestly/.npm-global/bin/web-ext (10.1.0; optional, not used by this tool)
  install route  marionette:Addon:Install(temporary)
  platform       macOS and Linux supported; Windows unsupported
```

## Representative receipts

`start` with a supplied extension, privileged system access, and a caller cookie-off contract (values elided by design; only keys are recorded):

```
"cookie": {
  "native_host_scope": "out-of-scope",
  "profile_isolated": true,
  "project_contract": "caller-asserted",
  "project_contract_env_keys": ["MG_COOKIE_SOURCE"]
},
"extension": {
  "id": "fm-evidence@firstmate.local",
  "installed": true,
  "route": "marionette:Addon:Install(temporary)"
},
"firefox": {"headless": true, "no_remote": true, "system_access": true},
"marionette": {"host": "127.0.0.1", "port": 50922, "reserved_shared_port_avoided": 2828}
```

`stop` teardown receipt:

```
{
  "process": "terminated",
  "removed": {"pid": 310, "profile_dir": ".../profile.ff-evidence.L0tay6", "state_file": true},
  "schema": "fm-firefox.cleanup.v1",
  "touched_only_owned_resources": true
}
```

## What is proven live vs. documented

- Proven live on this Mac: dependency diagnosis, fresh owned-profile creation, loopback endpoint allocation avoiding 2828, single `-no-remote` launch, temporary add-on install over Marionette, real web-content and extension-context control, and exact teardown that leaves unrelated browsers and the shared endpoint untouched.
- Documented, not exercised here: Linux is a supported platform by binary resolution and the same Marionette route, but the live receipts above are macOS only. Windows is unsupported.

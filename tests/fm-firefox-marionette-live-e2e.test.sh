#!/usr/bin/env bash
# Opt-in live proof for bin/fm-firefox.sh against a real Firefox. It installs a
# synthetic local extension, drives a loopback-served page (no external URL) and
# the extension's browser context over Marionette without pixel automation, and
# proves it changed no existing Firefox/Zen process, profile, or endpoint and
# left nothing behind. Standard CI stays hermetic because this self-skips unless
# FM_FIREFOX_LIVE_E2E=1 and Firefox + python3 + a WebDriver (marionette_driver)
# client are all present.
set -u

if [ "${FM_FIREFOX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_FIREFOX_LIVE_E2E=1 to run the live isolated-Firefox proof"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/bin/fm-firefox.sh"

skip() { echo "skip: $1"; exit 0; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || skip "python3 is required for the live proof"
python3 -c 'import marionette_driver' 2>/dev/null || skip "marionette_driver (WebDriver client) is not installed"
"$TOOL" doctor >/dev/null 2>&1 || skip "no Firefox binary resolved for the live proof"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-ff-live.XXXXXX")
export FM_FIREFOX_STATE_DIR="$LAB/state"
SESSION="ff-live-$$"
HTTP_PID=""

# Snapshot every unrelated Firefox/Zen main process so we can prove none of them
# was restarted or killed. Our own disposable process lives under $LAB and is
# excluded by path.
snapshot_browsers() {
  pgrep -lf 'Applications/(Firefox|Zen)\.app/Contents/MacOS/(firefox|zen)' 2>/dev/null |
    grep -v "$LAB" | awk '{print $1}' | sort -n
}
BROWSERS_BEFORE=$(snapshot_browsers)
PORT_2828_BEFORE=$(lsof -nP -iTCP:2828 -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -n)

cleanup() {
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
  "$TOOL" stop "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Synthetic local extension: a content script that marks any page it runs on,
# plus a background message listener. No remote code, no external URL.
EXT="$LAB/ext"
mkdir -p "$EXT"
cat > "$EXT/manifest.json" <<'JSON'
{
  "manifest_version": 2,
  "name": "fm-firefox live-e2e probe",
  "version": "0.0.1",
  "browser_specific_settings": { "gecko": { "id": "fm-live-e2e-probe@firstmate.local" } },
  "permissions": ["<all_urls>"],
  "background": { "scripts": ["bg.js"] },
  "content_scripts": [ { "matches": ["<all_urls>"], "js": ["cs.js"], "run_at": "document_idle" } ]
}
JSON
printf '%s\n' 'browser.runtime.onMessage.addListener((m) => Promise.resolve({ pong: m && m.ping }));' > "$EXT/bg.js"
printf '%s\n' 'document.documentElement.setAttribute("data-fm-firefox-probe", "content-script-ran");' > "$EXT/cs.js"

# Loopback page server: a real page over http://127.0.0.1, never an external URL.
WWW="$LAB/www"
mkdir -p "$WWW"
printf '%s\n' '<!doctype html><html><head><title>fm-firefox live probe</title></head><body><h1 id="marker">initial</h1></body></html>' > "$WWW/probe.html"
HTTP_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
( cd "$WWW" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!
sleep 0.5

# --- launch the disposable Firefox and install the extension through the tool.
RECEIPT=$("$TOOL" start --session "$SESSION" --extension "$EXT" --system-access) \
  || fail "fm-firefox start failed"
FF_PORT=$(FF_JSON="$RECEIPT" python3 -c 'import json,os;print(json.loads(os.environ["FF_JSON"])["marionette"]["port"])')
FF_PROFILE=$(FF_JSON="$RECEIPT" python3 -c 'import json,os;print(json.loads(os.environ["FF_JSON"])["profile"]["path"])')
FF_PID=$(FF_JSON="$RECEIPT" python3 -c 'import json,os;print(json.loads(os.environ["FF_JSON"])["pid"])')
FF_EXT_ID=$(FF_JSON="$RECEIPT" python3 -c 'import json,os;print(json.loads(os.environ["FF_JSON"])["extension"]["id"])')

[ "$FF_PORT" != 2828 ] || fail "the tool must never allocate the shared 2828 endpoint"
[ "$FF_EXT_ID" = "fm-live-e2e-probe@firstmate.local" ] || fail "receipt add-on id did not match the synthetic extension"
case "$FF_PROFILE" in "$LAB"/state/profile.*) : ;; *) fail "profile is not a task-owned disposable directory: $FF_PROFILE" ;; esac

# --- independent verification over Marionette (no pixel clicks): a fresh
# WebDriver client the tool did not use for install, proving real add-on install,
# web-content control, and extension/browser-context control.
VERIFY=$(FF_PORT="$FF_PORT" FF_URL="http://127.0.0.1:$HTTP_PORT/probe.html" FF_EXT_ID="$FF_EXT_ID" python3 - <<'PY'
import os, time
from marionette_driver.marionette import Marionette

m = Marionette(host="127.0.0.1", port=int(os.environ["FF_PORT"]))
m.start_session()
out = {}
try:
    m.set_context("chrome")
    addons = m.execute_async_script(
        """
        let wanted = arguments[0];
        let cb = arguments[arguments.length-1];
        const { AddonManager } = ChromeUtils.importESModule("resource://gre/modules/AddonManager.sys.mjs");
        AddonManager.getAllAddons().then(list => cb(
          list.filter(a => a.id === wanted).map(a => a.isActive)
        ));
        """,
        script_args=[os.environ["FF_EXT_ID"]],
    )
    out["addon_active"] = bool(addons) and addons[0] is True
    policy = m.execute_script(
        "const p = WebExtensionPolicy.getByID(arguments[0]); return p ? p.name : null;",
        script_args=[os.environ["FF_EXT_ID"]],
    )
    out["ext_context_name"] = policy

    m.set_context("content")
    m.navigate(os.environ["FF_URL"])
    time.sleep(0.6)
    out["content_script_effect"] = m.execute_script(
        'return document.documentElement.getAttribute("data-fm-firefox-probe");'
    )
    m.execute_script('document.getElementById("marker").textContent = "driven-by-marionette";')
    out["direct_dom_control"] = m.execute_script('return document.getElementById("marker").textContent;')
finally:
    m.delete_session()

print("addon_active=%s" % out.get("addon_active"))
print("ext_context_name=%s" % out.get("ext_context_name"))
print("content_script_effect=%s" % out.get("content_script_effect"))
print("direct_dom_control=%s" % out.get("direct_dom_control"))
PY
) || fail "Marionette verification failed"

grep -q '^addon_active=True$' <<<"$VERIFY" || fail "the add-on was not installed and active: $VERIFY"
grep -q '^ext_context_name=fm-firefox live-e2e probe$' <<<"$VERIFY" || fail "extension browser-context control failed: $VERIFY"
grep -q '^content_script_effect=content-script-ran$' <<<"$VERIFY" || fail "the extension's content script did not run on the page: $VERIFY"
grep -q '^direct_dom_control=driven-by-marionette$' <<<"$VERIFY" || fail "direct web-content control failed: $VERIFY"

# --- tear down through the tool and prove exact cleanup.
CLEAN=$("$TOOL" stop "$SESSION") || fail "fm-firefox stop failed"
grep -q '"touched_only_owned_resources": true' <<<"$CLEAN" || fail "cleanup did not assert owned-only teardown"

[ ! -d "$FF_PROFILE" ] || fail "the disposable profile was left behind: $FF_PROFILE"
[ ! -f "$LAB/state/$SESSION.json" ] || fail "the session state file was left behind"
kill -0 "$FF_PID" 2>/dev/null && fail "the disposable Firefox process was left running (pid $FF_PID)"
pgrep -f "$LAB" >/dev/null 2>&1 && fail "a Firefox child referencing our lab was left behind"
python3 -c "import socket,sys
try:
    s=socket.create_connection(('127.0.0.1',$FF_PORT),timeout=1); s.close(); sys.exit(1)
except OSError:
    sys.exit(0)" || fail "the Marionette port $FF_PORT was left bound after cleanup"

# --- prove no unrelated browser or the shared endpoint changed.
BROWSERS_AFTER=$(snapshot_browsers)
[ "$BROWSERS_BEFORE" = "$BROWSERS_AFTER" ] || fail "an unrelated Firefox/Zen process changed:"$'\n'"before: $BROWSERS_BEFORE"$'\n'"after:  $BROWSERS_AFTER"
PORT_2828_AFTER=$(lsof -nP -iTCP:2828 -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -n)
[ "$PORT_2828_BEFORE" = "$PORT_2828_AFTER" ] || fail "the shared 127.0.0.1:2828 endpoint owner changed"

FF_VERSION=$("$(FM_FIREFOX_BIN="${FM_FIREFOX_BIN:-}" bash -c 'command -v firefox 2>/dev/null || echo /Applications/Firefox.app/Contents/MacOS/firefox')" --version 2>/dev/null | head -1 || echo "Firefox")
echo "ok - fm-firefox live E2E ($FF_VERSION): real add-on install, web-content and extension-context control, no unrelated browser touched, no leftovers"

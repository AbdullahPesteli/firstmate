#!/usr/bin/env bash
# Hermetic behavior tests for bin/fm-firefox.sh. A fake Firefox binary speaks the
# real Marionette (protocol v3) wire format the tool's client emits, so these
# tests exercise the tool's public command surface end to end with no real
# browser, no network, and no third-party WebDriver client. They assert observed
# behavior and receipt fields only, never implementation source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-firefox.sh"
TMP_ROOT=$(fm_test_tmproot fm-firefox)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STATE_DIR="$TMP_ROOT/state"
ENV_ECHO="$TMP_ROOT/env-echo"
EXT_DIR="$TMP_ROOT/ext"

export FM_FIREFOX_STATE_DIR="$STATE_DIR"
export FM_FIREFOX_BIN="$FAKEBIN/firefox"
export FM_FAKE_FF_ENV_ECHO="$ENV_ECHO"

# Track any real background pid a case starts, so a mid-test failure still leaves
# no fake Firefox or stray sleep behind.
STRAY_PIDS=()
cleanup() {
  local p
  for p in "${STRAY_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- fake Firefox: reads marionette.port from the profile, serves the wire
# protocol, honors FM_FAKE_FF_MODE for the failure paths.
cat > "$FAKEBIN/firefox" <<'PY'
#!/usr/bin/env python3
import json, os, re, socket, sys, time

mode = os.environ.get("FM_FAKE_FF_MODE", "serve")
echo = os.environ.get("FM_FAKE_FF_ENV_ECHO")
if echo:
    with open(echo, "w") as fh:
        fh.write(os.environ.get("FMFF_TEST_FWD", ""))

if mode == "exit-immediately":
    sys.stderr.write("fake firefox: exiting before marionette\n")
    sys.exit(1)

profile = None
argv = sys.argv[1:]
for i, a in enumerate(argv):
    if a == "-profile" and i + 1 < len(argv):
        profile = argv[i + 1]
if not profile:
    sys.exit(2)

port = None
try:
    with open(os.path.join(profile, "user.js")) as fh:
        m = re.search(r'marionette\.port"\s*,\s*(\d+)', fh.read())
        if m:
            port = int(m.group(1))
except OSError:
    pass
if not port:
    sys.exit(3)

if mode == "stall":
    # Alive but never opens the endpoint: exercises the readiness timeout.
    time.sleep(600)
    sys.exit(0)


def read_frame(conn, buf):
    while b":" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return None, buf
        buf += chunk
    length, _, rest = buf.partition(b":")
    need = int(length)
    body = rest
    while len(body) < need:
        chunk = conn.recv(4096)
        if not chunk:
            return None, body
        body += chunk
    return json.loads(body[:need].decode("utf-8")), body[need:]


def send(conn, obj):
    payload = json.dumps(obj).encode("utf-8")
    conn.sendall(str(len(payload)).encode("ascii") + b":" + payload)


def addon_id_for(path):
    try:
        with open(os.path.join(path, "manifest.json")) as fh:
            data = json.load(fh)
        return data["browser_specific_settings"]["gecko"]["id"]
    except (OSError, KeyError, ValueError):
        return "unknown@fake"


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(8)

while True:
    try:
        conn, _ = srv.accept()
    except OSError:
        continue
    # A single dropped or reset connection (e.g. the tool's readiness probe that
    # connects and closes) must never take down the whole fake server.
    try:
        send(conn, {"applicationType": "gecko", "marionetteProtocol": 3})
        buf = b""
        while True:
            frame, buf = read_frame(conn, buf)
            if frame is None:
                break
            _, msg_id, name, params = frame
            if name == "Addon:Install" and mode == "install-fail":
                send(conn, [1, msg_id, {"error": "unknown error", "message": "fake install refusal"}, None])
            elif name == "Addon:Install":
                send(conn, [1, msg_id, None, {"value": addon_id_for(params.get("path", ""))}])
            else:
                send(conn, [1, msg_id, None, {}])
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass
PY
chmod +x "$FAKEBIN/firefox"

mkdir -p "$EXT_DIR"
cat > "$EXT_DIR/manifest.json" <<'JSON'
{
  "manifest_version": 2,
  "name": "fm-firefox hermetic probe",
  "version": "0.0.1",
  "browser_specific_settings": { "gecko": { "id": "fm-hermetic-probe@firstmate.local" } }
}
JSON

json_field() { # <json> <python-expr on data>
  FF_JSON="$1" python3 -c "import json,os;data=json.loads(os.environ['FF_JSON']);print($2)"
}

# --- 1) dependency failure ---------------------------------------------------
out=$(FM_FIREFOX_BIN=/nonexistent/firefox "$TOOL" doctor --json 2>/dev/null); code=$?
expect_code 1 "$code" "doctor --json must fail when Firefox is unresolved"
[ "$(json_field "$out" 'data["ok"]')" = "False" ] || fail "doctor must report ok=false when Firefox is missing"
[ "$(json_field "$out" 'data["firefox"]["resolved"]')" = "False" ] || fail "doctor must report firefox unresolved"
out=$(FM_FIREFOX_BIN=/nonexistent/firefox "$TOOL" start --label dep 2>&1); code=$?
expect_code 1 "$code" "start must refuse when no Firefox binary resolves"
assert_contains "$out" "no Firefox binary found" "start must name the missing Firefox dependency"
pass "dependency failure is diagnosed and refused"

# --- 2) clean profile + 3) loopback allocation + 6) truthful receipt ---------
recv=$("$TOOL" start --session ff-recv --extension "$EXT_DIR" --system-access --no-headless \
  --env FMFF_TEST_FWD=forwarded-value --cookie-off MG_COOKIE_SOURCE=none) || fail "start with extension failed"
port=$(json_field "$recv" 'data["marionette"]["port"]')
pid=$(json_field "$recv" 'data["pid"]')
profile=$(json_field "$recv" 'data["profile"]["path"]')
STRAY_PIDS+=("$pid")

[ -d "$profile" ] || fail "start must create the profile directory"
case "$profile" in "$STATE_DIR"/profile.ff-recv.*) : ;; *) fail "profile must live under the task-owned state root: $profile" ;; esac
[ -f "$profile/user.js" ] || fail "start must write a fresh profile user.js"
# A fresh profile has no cookies/history the tool copied in.
assert_absent "$profile/cookies.sqlite" "a fresh profile must not carry a copied cookie store"
grep -Fq "marionette.port\", $port" "$profile/user.js" || fail "profile user.js must pin the allocated Marionette port"
[ "$port" != 2828 ] || fail "allocated port must never be the shared default 2828"
[ "$(json_field "$recv" 'data["marionette"]["reserved_shared_port_avoided"]')" = "2828" ] || fail "receipt must record the avoided shared port"
[ "$(json_field "$recv" 'data["profile"]["fresh"]')" = "True" ] || fail "receipt must mark the profile fresh"
[ "$(json_field "$recv" 'data["profile"]["owned"]')" = "True" ] || fail "receipt must mark the profile owned"
[ "$(json_field "$recv" 'data["firefox"]["no_remote"]')" = "True" ] || fail "receipt must record -no-remote"
[ "$(json_field "$recv" 'data["firefox"]["system_access"]')" = "True" ] || fail "receipt must reflect --system-access"
[ "$(json_field "$recv" 'data["firefox"]["headless"]')" = "False" ] || fail "receipt must reflect --no-headless"
[ "$(json_field "$recv" 'data["extension"]["installed"]')" = "True" ] || fail "receipt must record the extension as installed"
[ "$(json_field "$recv" 'data["extension"]["id"]')" = "fm-hermetic-probe@firstmate.local" ] || fail "receipt must carry the real installed add-on id"
[ "$(json_field "$recv" 'data["extension"]["route"]')" = "marionette:Addon:Install(temporary)" ] || fail "receipt must name the supported install route"
[ "$(cat "$ENV_ECHO")" = "forwarded-value" ] || fail "--env values must be forwarded into the launched process"
pass "start creates a clean owned profile, avoids 2828, and emits a truthful receipt"

# --- 6b) receipt command re-reports live state -------------------------------
rc=$("$TOOL" receipt ff-recv) || fail "receipt must succeed for a known session"
[ "$(json_field "$rc" 'data["state"]')" = "running" ] || fail "receipt must show a live session as running"

# --- 9) native-host cookie caveat + caller-hook contract ---------------------
[ "$(json_field "$recv" 'data["cookie"]["native_host_scope"]')" = "out-of-scope" ] || fail "cookie scope must be truthfully out-of-scope"
caveat=$(json_field "$recv" 'data["cookie"]["caveat"]')
assert_contains "$caveat" "does not and cannot constrain" "caveat must not claim control over native-host cookies"
assert_contains "$caveat" "native messaging host" "caveat must name the native host as the uncontrolled surface"
[ "$(json_field "$recv" 'data["cookie"]["project_contract"]')" = "caller-asserted" ] || fail "supplying --cookie-off must mark the contract caller-asserted"
[ "$(json_field "$recv" 'data["cookie"]["project_contract_env_keys"][0]')" = "MG_COOKIE_SOURCE" ] || fail "cookie contract must list the caller key"
# Values are never recorded, only keys.
assert_not_contains "$recv" "MG_COOKIE_SOURCE=none" "receipt must not echo cookie-off values"
assert_not_contains "$recv" '"none"' "receipt must not echo cookie-off values"
pass "cookie caveat is truthful and the caller cookie-off contract is recorded by key only"

# --- 7) exact cleanup --------------------------------------------------------
clean=$("$TOOL" stop ff-recv) || fail "stop must succeed for an owned session"
[ "$(json_field "$clean" 'data["process"]')" = "terminated" ] || fail "stop must terminate the owned process"
[ "$(json_field "$clean" 'data["touched_only_owned_resources"]')" = "True" ] || fail "cleanup receipt must assert only owned resources were touched"
assert_absent "$profile" "stop must remove the owned profile directory"
assert_absent "$(printf '%s/ff-recv.json' "$STATE_DIR")" "stop must remove the session state file"
kill -0 "$pid" 2>/dev/null && fail "stop must terminate the fake Firefox process"
pass "stop removes exactly the profile, state, and process it created"

# --- 5) start with no extension is valid (extension optional) ----------------
recv2=$("$TOOL" start --session ff-noext) || fail "start without an extension must succeed"
pid2=$(json_field "$recv2" 'data["pid"]')
STRAY_PIDS+=("$pid2")
[ "$(json_field "$recv2" 'data["extension"]')" = "None" ] || fail "no-extension receipt must record extension=null"
[ "$(json_field "$recv2" 'data["cookie"]["project_contract"]')" = "absent" ] || fail "without --cookie-off the contract must be absent"
"$TOOL" stop ff-noext >/dev/null || fail "stop must clean up the no-extension session"
pass "extension is optional and absent cookie contract is reported honestly"

# --- 4) extension-path validation --------------------------------------------
out=$("$TOOL" start --session ff-badext --extension "$TMP_ROOT/does-not-exist" 2>&1); code=$?
expect_code 2 "$code" "start must reject a nonexistent extension path"
assert_contains "$out" "does not exist" "start must explain the missing extension path"
mkdir -p "$TMP_ROOT/empty-ext"
out=$("$TOOL" start --session ff-badext2 --extension "$TMP_ROOT/empty-ext" 2>&1); code=$?
expect_code 2 "$code" "start must reject an extension directory without manifest.json"
assert_contains "$out" "no manifest.json" "start must explain the invalid extension directory"
assert_absent "$(printf '%s/ff-badext.json' "$STATE_DIR")" "a rejected extension must leave no session state"
pass "extension paths are validated before any launch"

# --- 3b) refuse the shared default endpoint ----------------------------------
out=$("$TOOL" start --session ff-2828 --port 2828 2>&1); code=$?
expect_code 2 "$code" "start must refuse an explicit --port 2828"
assert_contains "$out" "2828" "refusal must name the shared default endpoint"
pass "the shared 127.0.0.1:2828 endpoint is refused"

# --- 8) ownership refusal ----------------------------------------------------
recv3=$("$TOOL" start --session ff-own) || fail "start for the ownership case failed"
own_pid=$(json_field "$recv3" 'data["pid"]')
own_profile=$(json_field "$recv3" 'data["profile"]["path"]')
STRAY_PIDS+=("$own_pid")
sleep 600 &
stray=$!
disown "$stray" 2>/dev/null || true
STRAY_PIDS+=("$stray")
# Rewrite the recorded pid to an unrelated live process the tool never created.
python3 - "$STATE_DIR/ff-own.json" "$stray" <<'PY'
import json, sys
f = sys.argv[1]
data = json.load(open(f))
data["pid"] = int(sys.argv[2])
json.dump(data, open(f, "w"))
PY
out=$("$TOOL" stop ff-own 2>&1); code=$?
expect_code 1 "$code" "stop must refuse a pid it cannot prove it created"
assert_contains "$out" "ownership unproven" "refusal must explain the unproven ownership"
kill -0 "$stray" 2>/dev/null || fail "stop must never kill an unrelated live process"
assert_present "$own_profile" "stop must not delete the profile when it refuses on ownership"
# The refusal happened; tidy the real fake and stray directly.
kill -KILL "$own_pid" 2>/dev/null || true
kill -KILL "$stray" 2>/dev/null || true
rm -rf "$own_profile" "$STATE_DIR/ff-own.json"
pass "ambiguous pid ownership is refused instead of guessing"

# --- 8b) refuse deleting a profile outside the state root --------------------
cat > "$STATE_DIR/ff-foreign.json" <<JSON
{"pid": null, "profile": {"path": "/tmp/not-a-fm-firefox-profile"}, "marionette": {"port": 40000}}
JSON
out=$("$TOOL" stop ff-foreign 2>&1); code=$?
expect_code 1 "$code" "stop must refuse a profile outside its own state root"
assert_contains "$out" "outside the tool's state root" "refusal must explain the foreign profile path"
assert_present "$STATE_DIR/ff-foreign.json" "a refused foreign stop must not delete state it did not prove it owns"
rm -f "$STATE_DIR/ff-foreign.json"
pass "a profile path outside the state root is never removed"

# --- 8c) interruption / error cleanup: Firefox never opens the endpoint -------
out=$(FM_FAKE_FF_MODE=exit-immediately "$TOOL" start --session ff-earlyexit 2>&1); code=$?
expect_code 1 "$code" "start must fail when Firefox exits before Marionette opens"
assert_absent "$STATE_DIR/ff-earlyexit.json" "an aborted start must leave no session state"
ls -d "$STATE_DIR"/profile.ff-earlyexit.* >/dev/null 2>&1 && fail "an aborted start must leave no profile directory"
pass "a Firefox that dies before readiness is cleaned up with no leftovers"

# --- 8d) readiness timeout cleanup -------------------------------------------
out=$(FM_FAKE_FF_MODE=stall "$TOOL" start --session ff-stall --timeout 2 2>&1); code=$?
expect_code 1 "$code" "start must fail when the Marionette endpoint never opens"
assert_contains "$out" "did not open" "a readiness timeout must be reported"
assert_absent "$STATE_DIR/ff-stall.json" "a timed-out start must leave no session state"
ls -d "$STATE_DIR"/profile.ff-stall.* >/dev/null 2>&1 && fail "a timed-out start must leave no profile directory"
pass "a Firefox that never opens the endpoint is killed and cleaned up"

# --- 8e) install failure cleanup ---------------------------------------------
out=$(FM_FAKE_FF_MODE=install-fail "$TOOL" start --session ff-instfail --extension "$EXT_DIR" 2>&1); code=$?
expect_code 1 "$code" "start must fail when the extension install is refused"
assert_contains "$out" "install over Marionette failed" "an install failure must be reported"
assert_absent "$STATE_DIR/ff-instfail.json" "a failed install must leave no session state"
ls -d "$STATE_DIR"/profile.ff-instfail.* >/dev/null 2>&1 && fail "a failed install must leave no profile directory"
pass "an extension install failure is cleaned up with no leftovers"

# --- 8f) interruption cleanup: SIGTERM during the readiness window -----------
# stall mode keeps the launched Firefox alive but never opens the endpoint, so
# start sits in its readiness window with a fresh profile and a live child. A
# SIGTERM to the start process (as a supervisor terminating a fleet worker would
# send) must tear both down and commit nothing.
FM_FAKE_FF_MODE=stall "$TOOL" start --session ff-sigterm --timeout 60 >/dev/null 2>&1 &
sig_start_pid=$!
STRAY_PIDS+=("$sig_start_pid")

# Wait until the launched fake Firefox is actually running: its argv carries the
# session profile path, which nothing else in this suite does, so its presence
# proves we are inside the interruptible launch->commit window.
waited=0
sig_ff_up=0
while [ "$waited" -lt 100 ]; do
  if pgrep -f 'profile[.]ff-sigterm[.]' >/dev/null 2>&1; then sig_ff_up=1; break; fi
  kill -0 "$sig_start_pid" 2>/dev/null || break
  sleep 0.1
  waited=$((waited + 1))
done
[ "$sig_ff_up" = 1 ] || fail "fake Firefox never entered the readiness window for the SIGTERM case"

kill -TERM "$sig_start_pid" 2>/dev/null || true
waited=0
while kill -0 "$sig_start_pid" 2>/dev/null; do
  [ "$waited" -lt 100 ] || fail "interrupted start did not exit after SIGTERM"
  sleep 0.1
  waited=$((waited + 1))
done

# The launched Firefox must be gone (give the in-flight teardown a beat to reap).
waited=0
while pgrep -f 'profile[.]ff-sigterm[.]' >/dev/null 2>&1; do
  [ "$waited" -lt 100 ] || fail "an interrupted start left a Firefox process referencing the session profile"
  sleep 0.1
  waited=$((waited + 1))
done
ls -d "$STATE_DIR"/profile.ff-sigterm.* >/dev/null 2>&1 && fail "an interrupted start must leave no profile directory"
assert_absent "$STATE_DIR/ff-sigterm.json" "an interrupted start must leave no session state file"
pass "a SIGTERM during the readiness window orphans no process and leaves no profile or state"

echo "ok - fm-firefox.sh hermetic command-surface behavior"

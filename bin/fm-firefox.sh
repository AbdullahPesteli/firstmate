#!/usr/bin/env bash
# fm-firefox.sh - own the lifecycle of one isolated, disposable Firefox process
# driven over Marionette (W3C WebDriver), so any Firstmate worker can install a
# supplied extension and drive web content without pixel automation, TCC
# prompts, or touching a live browser profile.
#
# Usage:
#   fm-firefox.sh doctor [--json]
#   fm-firefox.sh start [--extension <dir|xpi>] [--session <name>] [--label <l>]
#                       [--system-access] [--headless|--no-headless]
#                       [--port <n>] [--timeout <seconds>]
#                       [--env KEY=VALUE ...] [--cookie-off KEY=VALUE ...]
#   fm-firefox.sh receipt <session>
#   fm-firefox.sh list
#   fm-firefox.sh stop <session>
#
# What this owner guarantees, and what it refuses:
#   - It always creates a fresh, empty, task-owned profile directory. It never
#     attaches to, copies, or reuses a live Firefox/Zen profile, and never
#     enumerates unrelated browser profiles.
#   - It self-allocates a fresh loopback Marionette endpoint and refuses the
#     shared default 127.0.0.1:2828 outright.
#   - It launches exactly one -no-remote Firefox process it owns, and applies
#     -remote-allow-system-access only to that disposable process, only when
#     --system-access is requested.
#   - stop tears down only the process, profile, and port this tool created for
#     that session, after proving the recorded PID is still our own Firefox by
#     its profile path. It refuses ambiguous PID/port/profile ownership rather
#     than killing or deleting anything it cannot prove it created.
#
# Cookie / privacy scope (truthful boundary, not a guarantee this tool can make):
#   This tool isolates only its own Firefox profile. It does NOT and CANNOT
#   constrain a project-specific native messaging host, which can independently
#   discover unrelated Gecko cookie profiles (e.g. Zen) on the machine. A project
#   that needs its native host's cookie scanning disabled must supply its own
#   verified cookie-off contract; forward it with --cookie-off KEY=VALUE (or the
#   generic --env), which this tool passes into the launched process without
#   interpreting it, and reports as a caller-asserted contract in the receipt.
#
# Dependencies: a Firefox binary (resolved from FM_FIREFOX_BIN, then PATH, then
# the platform default) and python3 (the embedded Marionette client and receipt
# serializer). web-ext is an optional, unmanaged alternative route, reported by
# doctor but never required. Windows is unsupported.
#
# Test seams (never used in production paths): FM_FIREFOX_BIN overrides the
# resolved binary, FM_FIREFOX_STATE_DIR overrides the per-user session/state root.
set -u

FM_FIREFOX_DEFAULT_TIMEOUT=45
FM_FIREFOX_MARIONETTE_DEFAULT_PORT=2828

ff_err() { printf 'fm-firefox: %s\n' "$*" >&2; }

ff_python() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi
  return 1
}

ff_state_dir() {
  printf '%s' "${FM_FIREFOX_STATE_DIR:-${TMPDIR:-/tmp}/fm-firefox-${UID}}"
}

ff_state_file() { printf '%s/%s.json' "$(ff_state_dir)" "$1"; }

# Resolve the Firefox binary without ever scanning a user's profiles. Order:
# explicit override, PATH, then the well-known platform install location.
ff_resolve_bin() {
  local candidate
  if [ -n "${FM_FIREFOX_BIN:-}" ]; then
    if [ -x "$FM_FIREFOX_BIN" ] || command -v "$FM_FIREFOX_BIN" >/dev/null 2>&1; then
      command -v "$FM_FIREFOX_BIN" 2>/dev/null || printf '%s\n' "$FM_FIREFOX_BIN"
      return 0
    fi
    return 1
  fi
  if command -v firefox >/dev/null 2>&1; then
    command -v firefox
    return 0
  fi
  for candidate in \
    /Applications/Firefox.app/Contents/MacOS/firefox \
    /Applications/Firefox\ Developer\ Edition.app/Contents/MacOS/firefox \
    /usr/bin/firefox \
    /usr/local/bin/firefox \
    /snap/bin/firefox; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

ff_validate_session_name() {
  case "$1" in
    ff-[a-z0-9] | ff-[a-z0-9]*) : ;;
    *) ff_err "session name must start with 'ff-' and contain only lowercase letters, digits, underscores, or dashes: $1"; return 1 ;;
  esac
  case "$1" in
    *[!a-z0-9_-]*) ff_err "session name must contain only lowercase letters, digits, underscores, or dashes: $1"; return 1 ;;
  esac
  return 0
}

ff_sanitize_label() {
  local raw=${1:-session} out
  out=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')
  out=${out:0:24}
  [ -n "$out" ] || out=session
  printf '%s' "$out"
}

# Allocate a free loopback TCP port and refuse the shared default. Bind :0, read
# the assigned port, release it; Firefox (or a fake) then claims it.
ff_alloc_port() {
  local py port
  py=$(ff_python) || { ff_err "python3 is required to allocate a loopback endpoint"; return 1; }
  port=$("$py" - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
  ) || { ff_err "could not allocate a loopback endpoint"; return 1; }
  case "$port" in
    '' | *[!0-9]*) ff_err "loopback endpoint allocation returned a non-numeric port"; return 1 ;;
  esac
  if [ "$port" = "$FM_FIREFOX_MARIONETTE_DEFAULT_PORT" ]; then
    ff_err "refusing the shared default Marionette endpoint 127.0.0.1:$FM_FIREFOX_MARIONETTE_DEFAULT_PORT"
    return 1
  fi
  printf '%s\n' "$port"
}

ff_port_connectable() { # host port
  local py=$1 host=$2 port=$3
  FF_HOST="$host" FF_PORT="$port" "$py" - <<'PY'
import os, socket, sys
try:
    s = socket.create_connection((os.environ["FF_HOST"], int(os.environ["FF_PORT"])), timeout=1)
    s.close()
    sys.exit(0)
except OSError:
    sys.exit(1)
PY
}

# Minimal Marionette (protocol v3) client: connect, read the hello frame, create
# a session, install the supplied add-on as a temporary extension, delete the
# session. Prints the installed add-on id on success. No third-party client
# needed - only python3's stdlib - so the tool stays dependency-light.
ff_marionette_install() { # py host port ext_path
  local py=$1 host=$2 port=$3 ext=$4
  FF_HOST="$host" FF_PORT="$port" FF_EXT="$ext" "$py" - <<'PY'
import json, os, socket, sys

host = os.environ["FF_HOST"]
port = int(os.environ["FF_PORT"])
ext = os.environ["FF_EXT"]


def recv_frame(sock, buf):
    while b":" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise IOError("marionette closed the connection during framing")
        buf += chunk
    length, _, rest = buf.partition(b":")
    need = int(length)
    body = rest
    while len(body) < need:
        chunk = sock.recv(4096)
        if not chunk:
            raise IOError("marionette closed the connection mid-frame")
        body += chunk
    return json.loads(body[:need].decode("utf-8")), body[need:]


def send(sock, msg_id, name, params):
    payload = json.dumps([0, msg_id, name, params]).encode("utf-8")
    sock.sendall(str(len(payload)).encode("ascii") + b":" + payload)


def command(sock, buf, msg_id, name, params):
    send(sock, msg_id, name, params)
    while True:
        frame, buf = recv_frame(sock, buf)
        if isinstance(frame, list) and len(frame) >= 4 and frame[0] == 1 and frame[1] == msg_id:
            err, result = frame[2], frame[3]
            if err is not None:
                raise RuntimeError(json.dumps(err))
            return result, buf


try:
    sock = socket.create_connection((host, port), timeout=30)
    sock.settimeout(30)
    _, buf = recv_frame(sock, b"")  # server hello
    _, buf = command(sock, buf, 1, "WebDriver:NewSession", {"capabilities": {}})
    result, buf = command(sock, buf, 2, "Addon:Install", {"path": ext, "temporary": True})
except Exception as exc:  # noqa: BLE001 - surface any protocol failure verbatim
    sys.stderr.write("marionette install failed: %s\n" % exc)
    sys.exit(1)

addon_id = result.get("value") if isinstance(result, dict) else result
try:
    command(sock, buf, 3, "WebDriver:DeleteSession", {})
except Exception:  # noqa: BLE001 - best-effort teardown of the install session
    pass
finally:
    sock.close()

print(addon_id if addon_id is not None else "")
PY
}

# Serialize a receipt object from environment-provided scalars plus the caller
# env-key and cookie-off-key lists. python3 owns escaping so the JSON is always
# valid.
ff_emit_receipt() { # writes JSON to stdout
  local py=$1
  "$py" - <<'PY'
import json, os

def as_bool(name):
    return os.environ.get(name, "") == "1"

def key_list(name):
    raw = os.environ.get(name, "")
    return [k for k in raw.split("\x1f") if k]

cookie_off_keys = key_list("FF_COOKIE_OFF_KEYS")
receipt = {
    "tool": "fm-firefox",
    "schema": "fm-firefox.receipt.v1",
    "session": os.environ.get("FF_SESSION", ""),
    "state": os.environ.get("FF_STATE", ""),
    "pid": int(os.environ["FF_PID"]) if os.environ.get("FF_PID", "").isdigit() else None,
    "firefox": {
        "binary": os.environ.get("FF_BIN", ""),
        "no_remote": True,
        "headless": as_bool("FF_HEADLESS"),
        "system_access": as_bool("FF_SYSTEM_ACCESS"),
    },
    "profile": {
        "path": os.environ.get("FF_PROFILE", ""),
        "fresh": True,
        "owned": True,
    },
    "marionette": {
        "host": os.environ.get("FF_MHOST", "127.0.0.1"),
        "port": int(os.environ["FF_PORT"]) if os.environ.get("FF_PORT", "").isdigit() else None,
        "reserved_shared_port_avoided": 2828,
    },
    "extension": None,
    "cookie": {
        "profile_isolated": True,
        "profile_owned": True,
        "native_host_scope": "out-of-scope",
        "caveat": (
            "This tool isolates only its own Firefox profile. A project-specific "
            "native messaging host can independently discover unrelated Gecko "
            "cookie profiles (e.g. Zen); this tool does not and cannot constrain "
            "that behavior. Supply a project cookie-off contract via "
            "--cookie-off/--env to disable it."
        ),
        "project_contract": "caller-asserted" if cookie_off_keys else "absent",
        "project_contract_env_keys": cookie_off_keys,
    },
    "caller_env_keys": key_list("FF_ENV_KEYS"),
    "created_resources": {
        "profile_dir": os.environ.get("FF_PROFILE", ""),
        "marionette_port": int(os.environ["FF_PORT"]) if os.environ.get("FF_PORT", "").isdigit() else None,
        "pid": int(os.environ["FF_PID"]) if os.environ.get("FF_PID", "").isdigit() else None,
    },
    "owner_token": os.environ.get("FF_TOKEN", ""),
}
ext_path = os.environ.get("FF_EXT_PATH", "")
if ext_path:
    receipt["extension"] = {
        "path": ext_path,
        "installed": as_bool("FF_EXT_INSTALLED"),
        "id": os.environ.get("FF_EXT_ID", "") or None,
        "route": "marionette:Addon:Install(temporary)",
    }
print(json.dumps(receipt, indent=2, sort_keys=True))
PY
}

ff_write_profile_prefs() { # profile port
  local profile=$1 port=$2
  cat > "$profile/user.js" <<PREFS
// Task-owned, disposable Firefox profile created by fm-firefox.sh.
user_pref("marionette.port", $port);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage", "about:blank");
user_pref("browser.startup.page", 0);
user_pref("startup.homepage_welcome_url", "about:blank");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("app.update.enabled", false);
user_pref("app.update.auto", false);
user_pref("extensions.update.enabled", false);
user_pref("extensions.autoDisableScopes", 0);
user_pref("extensions.enabledScopes", 15);
user_pref("xpinstall.signatures.required", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.sessionstore.resume_from_crash", false);
PREFS
}

ff_kill_pid() { # pid
  local pid=$1 i=0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Ownership proof: the recorded PID must still be a live process whose command
# line references the exact profile directory this tool created. Anything else
# (dead PID, or a reused PID that is not our Firefox) is reported honestly and
# never killed.
ff_pid_is_our_firefox() { # pid profile
  local pid=$1 profile=$2 command
  kill -0 "$pid" 2>/dev/null || return 2 # dead
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$profile"*) return 0 ;;
    *) return 1 ;; # alive but not ours
  esac
}

ff_cmd_doctor() {
  local json=0 py bin webext webext_ver missing=0
  [ "${1:-}" = "--json" ] && json=1
  py=$(ff_python || true)
  bin=$(ff_resolve_bin || true)
  webext=$(command -v web-ext 2>/dev/null || true)
  webext_ver=""
  [ -n "$webext" ] && webext_ver=$(web-ext --version 2>/dev/null | head -1 || true)
  [ -n "$bin" ] || missing=1
  [ -n "$py" ] || missing=1
  if [ "$json" = 1 ]; then
    [ -n "$py" ] || { ff_err "python3 is required to render the doctor JSON"; return 1; }
    FF_BIN="$bin" FF_WEBEXT="$webext" FF_WEBEXT_VER="$webext_ver" \
      FF_MISSING="$missing" "$py" - <<'PY'
import json, os
ok = os.environ.get("FF_MISSING", "1") != "1"
print(json.dumps({
    "tool": "fm-firefox",
    "schema": "fm-firefox.doctor.v1",
    "ok": ok,
    "firefox": {"resolved": bool(os.environ.get("FF_BIN")), "path": os.environ.get("FF_BIN", "") or None,
                "required": True},
    "python3": {"resolved": True, "path": None, "required": True},
    "web_ext": {"resolved": bool(os.environ.get("FF_WEBEXT")), "path": os.environ.get("FF_WEBEXT", "") or None,
                "version": os.environ.get("FF_WEBEXT_VER", "") or None, "required": False,
                "note": "optional, unmanaged alternative install route; not used by this tool"},
    "install_route": "marionette:Addon:Install(temporary)",
    "platform_boundary": "macOS and Linux supported; Windows unsupported",
}, indent=2, sort_keys=True))
PY
    [ "$missing" = 1 ] && return 1
    return 0
  fi
  printf 'fm-firefox doctor\n'
  if [ -n "$bin" ]; then printf '  [ok]      firefox        %s\n' "$bin"; else printf '  [MISSING] firefox        set FM_FIREFOX_BIN or install Firefox\n'; fi
  if [ -n "$py" ]; then printf '  [ok]      python3        %s\n' "$(command -v python3)"; else printf '  [MISSING] python3        required for the Marionette client and receipts\n'; fi
  if [ -n "$webext" ]; then printf '  [ok]      web-ext        %s (%s; optional, not used by this tool)\n' "$webext" "${webext_ver:-unknown}"; else printf '  [--]      web-ext        absent (optional alternative route)\n'; fi
  printf '  install route  marionette:Addon:Install(temporary)\n'
  printf '  platform       macOS and Linux supported; Windows unsupported\n'
  [ "$missing" = 1 ] && { ff_err "required dependencies are missing"; return 1; }
  return 0
}

# In-flight teardown for a start that is interrupted or fails before its session
# is committed: kill the Firefox we launched (only when the recorded pid is still
# our own, proven by profile path via ff_pid_is_our_firefox) and remove the fresh
# profile we created under the state root. Bound to INT/TERM/ERR from just after
# launch until the state file is written, then cleared, so an interrupted start
# never orphans a process or leaves a profile/state behind, while a signal after
# commit never tears down a live, recorded session.
ff_start_abort() { # exit_code
  trap - INT TERM ERR
  local code=${1:-1}
  if [ -n "${pid:-}" ] && ff_pid_is_our_firefox "$pid" "${profile:-}"; then
    ff_kill_pid "$pid" || true
  fi
  if [ -n "${profile:-}" ] && [ -n "${state_dir:-}" ]; then
    case "$profile" in
      "$state_dir"/profile.*) rm -rf "$profile" ;;
    esac
  fi
  exit "$code"
}

ff_cmd_start() {
  local session="" label="" extension="" system_access=0 headless=1 port="" timeout=$FM_FIREFOX_DEFAULT_TIMEOUT
  local -a env_pairs=() cookie_pairs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session=${2:-}; shift 2 ;;
      --label) label=${2:-}; shift 2 ;;
      --extension) extension=${2:-}; shift 2 ;;
      --system-access) system_access=1; shift ;;
      --headless) headless=1; shift ;;
      --no-headless) headless=0; shift ;;
      --port) port=${2:-}; shift 2 ;;
      --timeout) timeout=${2:-}; shift 2 ;;
      --env) env_pairs+=("${2:-}"); shift 2 ;;
      --cookie-off) cookie_pairs+=("${2:-}"); shift 2 ;;
      *) ff_err "unknown start option: $1"; return 2 ;;
    esac
  done

  local py bin
  py=$(ff_python) || { ff_err "python3 is required"; return 1; }
  bin=$(ff_resolve_bin) || { ff_err "no Firefox binary found (set FM_FIREFOX_BIN, add firefox to PATH, or install Firefox)"; return 1; }

  case "$timeout" in '' | *[!0-9]*) ff_err "--timeout must be a positive integer of seconds"; return 2 ;; esac

  if [ -n "$extension" ]; then
    if [ -d "$extension" ]; then
      [ -f "$extension/manifest.json" ] || { ff_err "extension directory has no manifest.json: $extension"; return 2; }
    elif [ -f "$extension" ]; then
      case "$extension" in *.xpi | *.zip) : ;; *) ff_err "extension file must be an .xpi/.zip: $extension"; return 2 ;; esac
    else
      ff_err "extension path does not exist: $extension"; return 2
    fi
    extension=$(cd "$(dirname "$extension")" && printf '%s/%s' "$(pwd)" "$(basename "$extension")")
  fi

  if [ -n "$port" ]; then
    case "$port" in '' | *[!0-9]*) ff_err "--port must be numeric"; return 2 ;; esac
    [ "$port" != "$FM_FIREFOX_MARIONETTE_DEFAULT_PORT" ] || { ff_err "refusing the shared default Marionette endpoint 127.0.0.1:$FM_FIREFOX_MARIONETTE_DEFAULT_PORT"; return 2; }
  else
    port=$(ff_alloc_port) || return 1
  fi

  if [ -z "$session" ]; then
    session="ff-$(ff_sanitize_label "${label:-session}")-$$-${RANDOM}"
  fi
  ff_validate_session_name "$session" || return 2
  local state_file
  state_file=$(ff_state_file "$session")
  [ -e "$state_file" ] && { ff_err "session already exists: $session"; return 2; }

  local state_dir
  state_dir=$(ff_state_dir)
  mkdir -p "$state_dir" || { ff_err "cannot create state directory: $state_dir"; return 1; }
  chmod 700 "$state_dir" 2>/dev/null || true

  local profile
  profile=$(mktemp -d "$state_dir/profile.$session.XXXXXX") || { ff_err "cannot create a fresh profile directory"; return 1; }
  ff_write_profile_prefs "$profile" "$port"

  local token
  token=$("$py" -c 'import secrets;print(secrets.token_hex(16))')

  # Build env-key manifests (keys only; values never recorded).
  local env_keys="" cookie_keys="" pair
  local -a launch_env=()
  for pair in "${env_pairs[@]:-}"; do
    [ -n "$pair" ] || continue
    launch_env+=("$pair")
    env_keys="${env_keys}${env_keys:+$'\x1f'}${pair%%=*}"
  done
  for pair in "${cookie_pairs[@]:-}"; do
    [ -n "$pair" ] || continue
    launch_env+=("$pair")
    cookie_keys="${cookie_keys}${cookie_keys:+$'\x1f'}${pair%%=*}"
  done

  local -a args=(-no-remote -profile "$profile" -marionette)
  [ "$headless" = 1 ] && args+=(-headless)
  [ "$system_access" = 1 ] && args+=(-remote-allow-system-access)
  args+=(about:blank)

  local pid
  # Launch exactly one -no-remote Firefox we own; detach it so it survives this
  # command and the caller can drive the reported endpoint.
  env "${launch_env[@]:+${launch_env[@]}}" "$bin" "${args[@]}" >"$profile/firefox.log" 2>&1 &
  pid=$!
  disown 2>/dev/null || true

  # Until the session is committed, any interruption or unexpected failure must
  # tear down the process and profile we just created (ff_start_abort).
  trap 'ff_start_abort 130' INT
  trap 'ff_start_abort 143' TERM
  trap 'ff_start_abort $?' ERR

  # Bounded readiness wait; on failure, clean up everything we created.
  local deadline waited=0 ready=0
  deadline=$((timeout * 4)) # 0.25s ticks
  while [ "$waited" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      ff_err "Firefox exited before its Marionette endpoint opened; see $profile/firefox.log"
      rm -rf "$profile"
      return 1
    fi
    if ff_port_connectable "$py" 127.0.0.1 "$port"; then ready=1; break; fi
    sleep 0.25
    waited=$((waited + 1))
  done
  if [ "$ready" != 1 ]; then
    ff_err "Firefox Marionette endpoint 127.0.0.1:$port did not open within ${timeout}s"
    ff_kill_pid "$pid" || true
    rm -rf "$profile"
    return 1
  fi

  local ext_installed=0 ext_id=""
  if [ -n "$extension" ]; then
    if ext_id=$(ff_marionette_install "$py" 127.0.0.1 "$port" "$extension"); then
      ext_installed=1
    else
      ff_err "extension install over Marionette failed"
      ff_kill_pid "$pid" || true
      rm -rf "$profile"
      return 1
    fi
  fi

  FF_SESSION="$session" FF_STATE="running" FF_PID="$pid" FF_BIN="$bin" \
    FF_HEADLESS="$headless" FF_SYSTEM_ACCESS="$system_access" FF_PROFILE="$profile" \
    FF_MHOST="127.0.0.1" FF_PORT="$port" FF_TOKEN="$token" \
    FF_EXT_PATH="$extension" FF_EXT_INSTALLED="$ext_installed" FF_EXT_ID="$ext_id" \
    FF_ENV_KEYS="$env_keys" FF_COOKIE_OFF_KEYS="$cookie_keys" \
    ff_emit_receipt "$py" | tee "$state_file" >/dev/null
  # Session is committed; a later signal must not tear down a recorded session.
  trap - INT TERM ERR
  chmod 600 "$state_file" 2>/dev/null || true
  cat "$state_file"
  return 0
}

ff_cmd_receipt() {
  local session=${1:-} py state_file
  [ -n "$session" ] || { ff_err "receipt requires a session id"; return 2; }
  state_file=$(ff_state_file "$session")
  [ -f "$state_file" ] || { ff_err "no such session: $session"; return 2; }
  py=$(ff_python) || { ff_err "python3 is required"; return 1; }
  local pid profile port live_state
  pid=$(FF_FILE="$state_file" "$py" -c 'import json,os;print(json.load(open(os.environ["FF_FILE"])).get("pid") or "")')
  profile=$(FF_FILE="$state_file" "$py" -c 'import json,os;print(json.load(open(os.environ["FF_FILE"]))["profile"]["path"])')
  port=$(FF_FILE="$state_file" "$py" -c 'import json,os;print(json.load(open(os.environ["FF_FILE"]))["marionette"]["port"] or "")')
  live_state="stopped"
  if [ -n "$pid" ] && ff_pid_is_our_firefox "$pid" "$profile"; then
    if ff_port_connectable "$py" 127.0.0.1 "$port"; then live_state="running"; else live_state="starting"; fi
  fi
  FF_FILE="$state_file" FF_LIVE="$live_state" "$py" - <<'PY'
import json, os
data = json.load(open(os.environ["FF_FILE"]))
data["state"] = os.environ["FF_LIVE"]
print(json.dumps(data, indent=2, sort_keys=True))
PY
}

ff_cmd_list() {
  local state_dir f
  state_dir=$(ff_state_dir)
  [ -d "$state_dir" ] || return 0
  for f in "$state_dir"/*.json; do
    [ -e "$f" ] || continue
    basename "$f" .json
  done
}

ff_cmd_stop() {
  local session=${1:-} py state_file
  [ -n "$session" ] || { ff_err "stop requires a session id"; return 2; }
  state_file=$(ff_state_file "$session")
  [ -f "$state_file" ] || { ff_err "no such session: $session"; return 2; }
  py=$(ff_python) || { ff_err "python3 is required"; return 1; }
  local pid profile state_dir
  pid=$(FF_FILE="$state_file" "$py" -c 'import json,os;print(json.load(open(os.environ["FF_FILE"])).get("pid") or "")')
  profile=$(FF_FILE="$state_file" "$py" -c 'import json,os;print(json.load(open(os.environ["FF_FILE"]))["profile"]["path"])')
  state_dir=$(ff_state_dir)

  # Refuse to delete a profile path outside the state root this tool owns.
  case "$profile" in
    "$state_dir"/profile.*) : ;;
    *) ff_err "refusing to remove a profile outside the tool's state root: $profile"; return 1 ;;
  esac

  local killed="none"
  if [ -n "$pid" ]; then
    if ff_pid_is_our_firefox "$pid" "$profile"; then
      if ff_kill_pid "$pid"; then
        killed="terminated"
      else
        ff_err "could not terminate our Firefox pid $pid"
        return 1
      fi
    else
      local rc=$?
      if [ "$rc" = 2 ]; then
        killed="already-dead"
      else
        ff_err "refusing to kill pid $pid: it is alive but not the Firefox this tool started (profile ownership unproven)"
        return 1
      fi
    fi
  fi

  [ -d "$profile" ] && rm -rf "$profile"
  rm -f "$state_file"

  FF_SESSION="$session" FF_KILLED="$killed" FF_PROFILE="$profile" FF_PID="$pid" "$py" - <<'PY'
import json, os
print(json.dumps({
    "tool": "fm-firefox",
    "schema": "fm-firefox.cleanup.v1",
    "session": os.environ["FF_SESSION"],
    "process": os.environ["FF_KILLED"],
    "removed": {
        "profile_dir": os.environ["FF_PROFILE"],
        "state_file": True,
        "pid": int(os.environ["FF_PID"]) if os.environ.get("FF_PID", "").isdigit() else None,
    },
    "touched_only_owned_resources": True,
}, indent=2, sort_keys=True))
PY
}

ff_usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift || true
  case "$cmd" in
    doctor) ff_cmd_doctor "$@" ;;
    start) ff_cmd_start "$@" ;;
    receipt) ff_cmd_receipt "$@" ;;
    list) ff_cmd_list "$@" ;;
    stop) ff_cmd_stop "$@" ;;
    -h | --help | help | '') ff_usage ;;
    *) ff_err "unknown command: $cmd"; ff_usage >&2; return 2 ;;
  esac
}

main "$@"

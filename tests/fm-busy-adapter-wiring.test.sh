#!/usr/bin/env bash
# Behavior tests for the per-adapter semantic busy-state wiring that
# bin/fm-spawn.sh installs under the contract owned by bin/fm-busy-lib.sh.
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated
# git worktree, then drive the generated adapter artifact (the Pi extension,
# the OpenCode plugin) in a plain Node host, so the artifact, the real
# bin/fm-busy-event.sh writer, and the real classifier are exercised together
# with no live harness session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi opencode claude codex
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  set -- "$@" --mode no-mistakes --yolo off
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

# drive_pi_ext <ext-path> <mode>: load the generated Pi extension in a plain
# Node host and fire one lifecycle handler. Modes: agent-start, settle-idle,
# settle-continuing, turn-end.
drive_pi_ext() {
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const ctx = { isIdle: () => process.env.MODE !== "settle-continuing" };
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({}, ctx); break;
  case "settle-idle": await handlers["agent_settled"]({}, ctx); break;
  case "settle-continuing": await handlers["agent_settled"]({}, ctx); break;
  case "settle-then-start":
    await handlers["agent_settled"]({}, ctx);
    await handlers["agent_start"]({}, ctx);
    break;
  case "turn-end": await handlers["turn_end"]({}, ctx); break;
  case "session-start": {
    const sctx = { isIdle: () => process.env.SESSION_IDLE === "1" };
    await handlers["session_start"]({ reason: process.env.SESSION_REASON }, sctx);
    break;
  }
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_pi_extension_semantic_lifecycle() {
  local rec id=busy-pi-1 out state ext
  rec=$(make_spawn_case pi-lifecycle pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"

  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "agent_settled drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "agent_settled with isIdle must classify 'idle pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "agent_start must classify 'busy pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" settle-continuing) || fail "continuing settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a settle while another run continues must stay busy, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "final settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "the final settle must classify idle, got '$out'"
  pass "pi extension reports agent_start busy, settles idle only via ctx.isIdle(), and keeps turn_end a notification"
}

test_pi_extension_serializes_settle_before_next_start() {
  local rec id=busy-pi-order out state ext
  rec=$(make_spawn_case pi-order pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  out=$(drive_pi_ext "$ext" settle-then-start) || fail "settle/start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a fresh agent_start after agent_settled must win, got '$out'"
  pass "pi extension awaits agent_settled before the next agent_start without a test delay"
}

# drive_pi_ext_ui <ext-path> <scenario>: load the generated Pi extension in a
# plain Node host that provides pi.events (capturing every herdr:blocked emit)
# and a shared ctx.ui whose dialog methods we control, then exercise a dialog
# scenario. Prints one JSON line per herdr:blocked emit plus RESULT/ERROR lines,
# so the test asserts the OBSERVABLE contract, never extension source bytes.
drive_pi_ext_ui() {
  EXT_PATH="$1" SCENARIO="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
const log = [];
const pi = {
  on: (name, fn) => { handlers[name] = fn; },
  events: { emit: (name, data) => { if (name === "herdr:blocked") log.push(data); } },
};
mod.default(pi);
// A shared ctx.ui exactly as Pi hands the SAME object to every extension/tool.
let resolvers = {};
const mkDialog = (name) => (...args) => {
  // Record the raw args so the test can prove only the method label leaks.
  log.push({ call: name, args });
  if (process.env.SCENARIO === "sync-throw" && name === "confirm") {
    throw new Error("boom-" + JSON.stringify(args));
  }
  return new Promise((resolve, reject) => { resolvers[name] = { resolve, reject }; });
};
const ui = {};
for (const m of ["confirm", "select", "input", "editor", "custom"]) ui[m] = mkDialog(m);
const ctx = { isIdle: () => false, ui };
// session_start installs the wrapper on the shared ui object.
await handlers["session_start"]({ reason: "startup" }, ctx);
// A reload re-runs the extension and re-enters session_start on the SAME ui
// object: the wrapper must stay idempotent (no double emit per dialog).
if (process.env.SCENARIO === "idempotent") {
  await handlers["session_start"]({ reason: "reload" }, ctx);
}

const emit = () => log.filter((e) => e && typeof e.active === "boolean");
const dump = () => { for (const e of emit()) process.stdout.write(JSON.stringify(e) + "\n"); };
const calls = () => log.filter((e) => e && e.call);

switch (process.env.SCENARIO) {
  case "resolve": {
    const p = ctx.ui.confirm("Delete production DB?", "secret-body-value");
    process.stdout.write("AFTER_OPEN active_count=" + emit().filter(e=>e.active).length + "\n");
    resolvers.confirm.resolve(true);
    await p;
    dump();
    // Prove no sensitive text leaked into any emitted label.
    const leaked = emit().some((e) => JSON.stringify(e).includes("secret-body-value") || JSON.stringify(e).includes("production"));
    process.stdout.write("LEAKED=" + leaked + "\n");
    break;
  }
  case "nested": {
    const p1 = ctx.ui.confirm("outer");
    const p2 = ctx.ui.select("inner", ["a", "b"]);
    process.stdout.write("BOTH_OPEN actives=" + emit().filter(e=>e.active).length + "\n");
    resolvers.select.resolve("a");
    await p2;
    process.stdout.write("AFTER_INNER inactives=" + emit().filter(e=>!e.active).length + "\n");
    resolvers.confirm.resolve(true);
    await p1;
    dump();
    break;
  }
  case "cancel-reject": {
    const p = ctx.ui.input("name?");
    resolvers.input.reject(new Error("cancelled"));
    let threw = false;
    try { await p; } catch { threw = true; }
    process.stdout.write("REJECTED=" + threw + "\n");
    dump();
    break;
  }
  case "sync-throw": {
    let threw = false;
    try { ctx.ui.confirm("boom?"); } catch { threw = true; }
    process.stdout.write("THREW=" + threw + "\n");
    dump();
    break;
  }
  case "idempotent": {
    const p = ctx.ui.confirm("only once?");
    resolvers.confirm.resolve(true);
    await p;
    process.stdout.write("ACTIVES=" + emit().filter(e=>e.active).length + " INACTIVES=" + emit().filter(e=>!e.active).length + "\n");
    dump();
    break;
  }
  default: throw new Error("unknown scenario " + process.env.SCENARIO);
}
EOF
}

test_pi_extension_session_start_reconciles_reload() {
  local rec id=busy-pi-reload out state ext
  rec=$(make_spawn_case pi-reload pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  # Drive a stale busy record (agent-start recorded, settle never delivered).
  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  [ "$(classify pi "$id" "$state")" = "busy pi-ext" ] || fail "precondition: record must be busy"

  # A /reload while the agent is actually idle: session_start(reason=reload)
  # with isIdle=true must reconcile the stale busy record to idle (the incident
  # recovery herdr:pi v8 performs and our old extension did not).
  out=$(SESSION_REASON=reload SESSION_IDLE=1 drive_pi_ext "$ext" session-start) \
    || fail "session-start reload-idle drive failed: $out"
  [ "$(classify pi "$id" "$state")" = "idle pi-ext" ] \
    || fail "session_start(reload,isIdle) must reconcile a stale busy record to idle, got '$(classify pi "$id" "$state")'"

  # A reload mid-run (isIdle=false) reconciles busy.
  out=$(SESSION_REASON=reload SESSION_IDLE=0 drive_pi_ext "$ext" session-start) \
    || fail "session-start reload-busy drive failed: $out"
  [ "$(classify pi "$id" "$state")" = "busy pi-ext" ] \
    || fail "session_start(reload,!isIdle) must reconcile to busy, got '$(classify pi "$id" "$state")'"

  # A fresh startup session_start must NOT clobber the record: the arm seed and
  # agent_start own the initial busy, so reason=startup is a no-op even at isIdle.
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --current-gen --source pi-ext --event agent-start
  out=$(SESSION_REASON=startup SESSION_IDLE=1 drive_pi_ext "$ext" session-start) \
    || fail "session-start startup drive failed: $out"
  [ "$(classify pi "$id" "$state")" = "busy pi-ext" ] \
    || fail "session_start(startup) must not reconcile away the launch-brief busy, got '$(classify pi "$id" "$state")'"
  pass "pi extension reconciles a stale record on reload and leaves the startup launch-brief busy intact"
}

test_pi_extension_blocked_wrapper_emits_and_clears() {
  command -v node >/dev/null 2>&1 || { pass "pi blocked wrapper skipped without node"; return; }
  local rec id=busy-pi-block out ext state
  rec=$(make_spawn_case pi-block pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  # A dialog that opens then resolves: exactly one active then one inactive,
  # both labelled by the method only, with no title/body ever leaking.
  out=$(drive_pi_ext_ui "$ext" resolve) || fail "resolve scenario failed: $out"
  printf '%s\n' "$out" | grep -q 'AFTER_OPEN active_count=1' || fail "a dialog must emit exactly one herdr:blocked active on open: $out"
  printf '%s\n' "$out" | grep -q '{"active":true,"label":"confirm"}' || fail "active emit must carry only the method label: $out"
  printf '%s\n' "$out" | grep -q '{"active":false,"label":"confirm"}' || fail "a resolved dialog must clear blocked: $out"
  printf '%s\n' "$out" | grep -q 'LEAKED=false' || fail "the dialog title/body must never leak into a herdr:blocked emit: $out"

  # Nested / overlapping dialogs: two actives, two inactives (herdr's own
  # blockedCount handles the nesting depth).
  out=$(drive_pi_ext_ui "$ext" nested) || fail "nested scenario failed: $out"
  printf '%s\n' "$out" | grep -q 'BOTH_OPEN actives=2' || fail "overlapping dialogs must each emit active: $out"
  printf '%s\n' "$out" | grep -q 'AFTER_INNER inactives=1' || fail "resolving one dialog must clear exactly one: $out"

  # A cancelled/rejected dialog still clears blocked exactly once and propagates.
  out=$(drive_pi_ext_ui "$ext" cancel-reject) || fail "cancel-reject scenario failed: $out"
  printf '%s\n' "$out" | grep -q 'REJECTED=true' || fail "a rejected dialog must still reject to the caller: $out"
  printf '%s\n' "$out" | grep -q '{"active":false,"label":"input"}' || fail "a rejected dialog must clear blocked: $out"

  # A synchronously-throwing dialog clears blocked and re-throws.
  out=$(drive_pi_ext_ui "$ext" sync-throw) || fail "sync-throw scenario failed: $out"
  printf '%s\n' "$out" | grep -q 'THREW=true' || fail "a throwing dialog must propagate its error: $out"
  printf '%s\n' "$out" | grep -q '{"active":false,"label":"confirm"}' || fail "a throwing dialog must clear blocked: $out"

  # Idempotent wrap: a reload re-enters session_start on the same ui object, but
  # one dialog must still emit exactly one active and one inactive (no dup).
  out=$(drive_pi_ext_ui "$ext" idempotent) || fail "idempotent scenario failed: $out"
  printf '%s\n' "$out" | grep -q 'ACTIVES=1 INACTIVES=1' || fail "a re-wrapped ui must not double-emit per dialog: $out"
  pass "pi extension emits herdr:blocked around ctx.ui dialogs, clears once on resolve/cancel/throw, stays idempotent across reload, and leaks only the method label"
}

test_pi_extension_stale_incarnation_rejected() {
  local rec id=busy-pi-2 out state ext
  rec=$(make_spawn_case pi-stale pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  # A re-arm (a rewired incarnation) supersedes the gen embedded in the old
  # extension file: its late events must be rejected and never change state.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_pi_ext "$ext" settle-idle) || fail "stale settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  pass "pi extension events from a superseded incarnation are rejected as stale"
}

# drive_oc_plugin <plugin-path> <events-json-lines...>: load the generated
# OpenCode plugin in a plain Node host and feed it one event per argument, in
# order, through the same hooks.event entry OpenCode calls.
drive_oc_plugin() {
  local plugin=$1
  shift
  PLUGIN_PATH="$plugin" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmBusyState({});
for (const arg of process.argv.slice(2)) {
  await hooks.event({ event: JSON.parse(arg) });
}
EOF
}

oc_status() {  # <sessionID> <type>
  printf '{"type":"session.status","properties":{"sessionID":"%s","status":{"type":"%s"}}}' "$1" "$2"
}

oc_idle() {  # <sessionID>
  printf '{"type":"session.idle","properties":{"sessionID":"%s"}}' "$1"
}

test_opencode_plugin_semantic_lifecycle() {
  local rec id=busy-oc-1 out state plugin
  rec=$(make_spawn_case oc-lifecycle opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode spawn did not write the busy-state plugin"

  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)") || fail "busy drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "session busy must classify 'busy opencode-plugin', got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_status ses_child busy)" \
    "$(oc_status ses_child idle)") || fail "child-session drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "a child session's idle must not clear the worker, got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main retry)" \
    "$(oc_status ses_main idle)") || fail "retry/idle drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "the latched session's idle must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_idle ses_main)") || fail "session.idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "session.idle no longer touches the notification marker"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "session.idle for the latched session must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses2 busy)" \
    "$(oc_idle ses_other)") || fail "other-session idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "the marker touch must stay a notification for every session.idle"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "another session's idle must not clear the latched busy, got '$out'"
  pass "opencode plugin classifies from session.status, scoped to the latched worker session"
}

run_claude_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_claude_hooks_semantic_lifecycle() {
  local rec id=busy-cl-1 out state settings
  rec=$(make_spawn_case claude-lifecycle claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "claude hook settings are not valid JSON"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "claude hook settings lack $ev"
  done

  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  run_claude_hook "$settings" Stop || fail "Stop hook command failed"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "Stop must classify 'idle claude-hook', got '$out'"

  run_claude_hook "$settings" UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "UserPromptSubmit must classify 'busy claude-hook', got '$out'"

  run_claude_hook "$settings" StopFailure || fail "StopFailure hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "StopFailure must classify idle so an API error cannot strand busy, got '$out'"

  run_claude_hook "$settings" UserPromptSubmit
  run_claude_hook "$settings" SessionEnd || fail "SessionEnd hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  pass "claude hooks open on UserPromptSubmit and close on Stop, StopFailure, and SessionEnd"
}

test_claude_hooks_stale_incarnation_harmless() {
  local rec id=busy-cl-2 out state settings
  rec=$(make_spawn_case claude-stale claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_claude_hook "$settings" UserPromptSubmit \
    || fail "a stale-gen hook must still exit 0 so Claude's lifecycle is never broken"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "claude hook events from a superseded incarnation are rejected without breaking the hook"
}

test_codex_unverified_until_a_semantic_source_exists() {
  local rec id=busy-cx-1 out state
  rec=$(make_spawn_case codex-unverified codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "codex spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "codex must not arm a busy contract with no verified semantic source"
  assert_absent "$WT_DIR/.codex/hooks.json" "codex must not install unverified busy hooks"
  assert_contains "$out" 'spawned '"$id"' harness=codex' "codex spawn did not complete normally"
  out=$(classify codex "$id" "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must classify 'unknown codex-unverified', got '$out'"
  out=$(fm_busy_classify tmux fake:w codex "$id" "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "unknown codex-unverified" ] || fail "codex must not fall back to footer text, got '$out'"
  pass "codex classifies unknown until a semantic source is verified, never idle or footer-matched"
}

test_kimi_and_grok_install_no_unverified_wiring() {
  local state out
  state="$TMP_ROOT/gates/state"
  mkdir -p "$state"
  [ -z "$(fm_busy_sources_for_harness kimi)" ] \
    || fail "standalone kimi must trust no semantic source until it is verified"
  [ -z "$(fm_busy_sources_for_harness grok)" ] \
    || fail "grok must trust no semantic source while its structured path is unverified"
  out=$(fm_busy_classify tmux fake:w kimi gate-k "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must classify unknown, not from its spinner, got '$out'"
  out=$(fm_busy_classify tmux fake:w grok gate-g "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok must classify through its isolated fallback, got '$out'"
  pass "kimi and grok install no unverified semantic wiring and classify through their own gates"
}

test_pi_extension_semantic_lifecycle
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_session_start_reconciles_reload
test_pi_extension_blocked_wrapper_emits_and_clears
test_pi_extension_stale_incarnation_rejected
test_kimi_and_grok_install_no_unverified_wiring
test_opencode_plugin_semantic_lifecycle
test_claude_hooks_semantic_lifecycle
test_claude_hooks_stale_incarnation_harmless
test_codex_unverified_until_a_semantic_source_exists

echo "all fm-busy-adapter-wiring tests passed"

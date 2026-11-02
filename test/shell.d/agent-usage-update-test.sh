#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command flock
require_command pgrep

TEST_HOME=$(mktemp -d)
FAKE_OMARCHY=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$FAKE_OMARCHY"' EXIT

mkdir -p "$FAKE_OMARCHY/bin"

cat >"$FAKE_OMARCHY/bin/omarchy-agent-usage-good" <<'EOF'
#!/bin/bash
echo '{"schemaVersion":1,"id":"good","name":"Good Agent","totalPrompts":3}'
EOF

cat >"$FAKE_OMARCHY/bin/omarchy-agent-usage-noisy" <<'EOF'
#!/bin/bash
echo "this is not json"
EOF

cat >"$FAKE_OMARCHY/bin/omarchy-agent-usage-skipped" <<'EOF'
#!/bin/bash
echo '{"id":"skipped"}'
EOF

# The updater itself lives in the same namespace as the collectors it globs.
cat >"$FAKE_OMARCHY/bin/omarchy-agent-usage-update" <<'EOF'
#!/bin/bash
echo '{"id":"update"}'
EOF

chmod +x "$FAKE_OMARCHY/bin/"omarchy-agent-usage-*

usage_dir="$TEST_HOME/.local/state/omarchy/agents/usage"

HOME="$TEST_HOME" OMARCHY_PATH="$FAKE_OMARCHY" XDG_STATE_HOME="" \
  "$ROOT/bin/omarchy-agent-usage-update" --except skipped 2>/dev/null && fail "update reports a failing collector"
pass "update reports a failing collector"

[[ $(jq -r '.name' "$usage_dir/good.json") == "Good Agent" ]] ||
  fail "update writes each collector's record to the usage directory"
pass "update writes each collector's record to the usage directory"

[[ ! -e $usage_dir/noisy.json ]] ||
  fail "update refuses records that are not valid JSON"
pass "update refuses records that are not valid JSON"

[[ ! -e $usage_dir/skipped.json ]] ||
  fail "update skips agents excluded with --except"
pass "update skips agents excluded with --except"

[[ ! -e $usage_dir/update.json ]] ||
  fail "update does not treat itself as a collector"
pass "update does not treat itself as a collector"

HOME="$TEST_HOME" OMARCHY_PATH="$FAKE_OMARCHY" XDG_STATE_HOME="" \
  "$ROOT/bin/omarchy-agent-usage-update" skipped 2>/dev/null ||
  fail "update succeeds when the requested collectors all pass"
pass "update succeeds when the requested collectors all pass"

[[ -e $usage_dir/skipped.json && ! -e $usage_dir/noisy.json ]] ||
  fail "update with agent arguments only runs the named collectors"
pass "update with agent arguments only runs the named collectors"

# ---------------------------------------------------- one refresh at a time

SLOW_OMARCHY=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$FAKE_OMARCHY" "$SLOW_OMARCHY"' EXIT
mkdir -p "$SLOW_OMARCHY/bin"

export SLOW_RUNS="$SLOW_OMARCHY/runs" SLOW_STARTED="$SLOW_OMARCHY/started" SLOW_RELEASE="$SLOW_OMARCHY/release"

# Counts its runs, says it has started, and holds its refresh open until the
# test releases it. SLOW_FAIL makes it print a record the updater refuses.
cat >"$SLOW_OMARCHY/bin/omarchy-agent-usage-slow" <<'EOF'
#!/bin/bash
echo run >>"$SLOW_RUNS"
touch "$SLOW_STARTED"
for (( i = 0; i < 200; i++ )); do
  [[ -e $SLOW_RELEASE ]] && break
  sleep 0.05
done
if [[ -n ${SLOW_FAIL:-} ]]; then
  echo "not json"
else
  echo '{"schemaVersion":1,"id":"slow","name":"Slow Agent"}'
fi
EOF

cat >"$SLOW_OMARCHY/bin/omarchy-agent-usage-other" <<'EOF'
#!/bin/bash
echo '{"schemaVersion":1,"id":"other","name":"Other Agent"}'
EOF

chmod +x "$SLOW_OMARCHY/bin/"omarchy-agent-usage-*

lock_file="$usage_dir/.update.lock"

reset_slow() {
  rm -f "$SLOW_RUNS" "$SLOW_STARTED" "$SLOW_RELEASE"
}

slow_runs() {
  if [[ -e $SLOW_RUNS ]]; then
    wc -l <"$SLOW_RUNS"
  else
    echo 0
  fi
}

await() {
  local i
  for (( i = 0; i < 200; i++ )); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}

# Blocked on the lock, not merely trying it: the blocking flock has no -n.
waiting_on_lock() {
  pgrep -P "$1" -f '^flock [0-9]+$' >/dev/null
}

# A refresh that holds the lock until released; its collector has started.
start_holder() {
  HOME="$TEST_HOME" OMARCHY_PATH="$SLOW_OMARCHY" XDG_STATE_HOME="" \
    "$ROOT/bin/omarchy-agent-usage-update" "$@" 2>/dev/null &
  holder=$!
  await test -e "$SLOW_STARTED" || fail "the holding refresh started its collector"
}

# A request that arrives while the holder runs, once it is waiting on the lock.
start_waiter() {
  HOME="$TEST_HOME" OMARCHY_PATH="$SLOW_OMARCHY" XDG_STATE_HOME="" \
    "$ROOT/bin/omarchy-agent-usage-update" "$@" 2>/dev/null &
  waiter=$!
  await waiting_on_lock "$waiter" || fail "a request during a refresh waits on the refresh lock"
}

finish() {
  touch "$SLOW_RELEASE"
  wait "$holder"
  holder_status=$?
  wait "$waiter"
  waiter_status=$?
}

reset_slow
start_holder slow
start_waiter slow
finish
(( $(slow_runs) == 1 && holder_status == 0 && waiter_status == 0 )) ||
  fail "a request matching the running refresh takes its records instead of collecting again"
pass "a request matching the running refresh takes its records instead of collecting again"

reset_slow
start_holder slow
start_waiter --limits-only slow
finish
(( $(slow_runs) == 1 && waiter_status == 0 )) ||
  fail "a limits-only request is answered by a plain refresh already running"
pass "a limits-only request is answered by a plain refresh already running"

reset_slow
SLOW_FAIL=1 start_holder slow
start_waiter slow
finish
(( $(slow_runs) == 1 && waiter_status != 0 )) ||
  fail "a request answered by a failing refresh reports that failure"
pass "a request answered by a failing refresh reports that failure"

reset_slow
start_holder slow
start_waiter --force slow
finish
(( $(slow_runs) == 2 && waiter_status == 0 )) ||
  fail "a forced request runs its own refresh after a plain one finishes"
pass "a forced request runs its own refresh after a plain one finishes"

reset_slow
rm -f "$TEST_HOME/.local/state/omarchy/agents/usage/other.json"
start_holder slow
start_waiter slow other
finish
(( $(slow_runs) == 2 )) && [[ -e $TEST_HOME/.local/state/omarchy/agents/usage/other.json ]] ||
  fail "a request for collectors the running refresh skips runs its own refresh"
pass "a request for collectors the running refresh skips runs its own refresh"

# A refresh that died after taking the lock left its request without a finish.
reset_slow
rm -f "$lock_file"
flock "$lock_file" bash -c 'printf "2 slow other\n" >"$1"; until [[ -e $SLOW_RELEASE ]]; do sleep 0.05; done' _ "$lock_file" &
holder=$!
await test -s "$lock_file" || fail "the dying refresh took the lock"
start_waiter slow
finish
(( $(slow_runs) == 1 && waiter_status == 0 )) ||
  fail "a refresh that died before finishing answers no request"
pass "a refresh that died before finishing answers no request"

reset_slow
touch "$SLOW_RELEASE"
for run in 1 2; do
  HOME="$TEST_HOME" OMARCHY_PATH="$SLOW_OMARCHY" XDG_STATE_HOME="" \
    "$ROOT/bin/omarchy-agent-usage-update" slow 2>/dev/null || fail "an uncontended refresh succeeds"
done
(( $(slow_runs) == 2 )) ||
  fail "a finished refresh never answers a request that arrives after it"
pass "a finished refresh never answers a request that arrives after it"

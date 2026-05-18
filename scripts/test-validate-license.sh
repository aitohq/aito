#!/bin/bash
# Behavioral test for validate-license.sh.
# Runs the real script against a stubbed `curl` so we can drive every
# branch (success, network failure, invalid response, cache hit/miss/stale)
# without spinning up a real HTTP server.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATE_SCRIPT="${SCRIPT_DIR}/../validate-license.sh"

if [ ! -x "${VALIDATE_SCRIPT}" ]; then
  echo "FATAL: ${VALIDATE_SCRIPT} not executable" >&2
  exit 2
fi

for cmd in jq openssl sha256sum; do
  command -v "${cmd}" >/dev/null || { echo "FATAL: ${cmd} not installed" >&2; exit 2; }
done

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

STUB_DIR="${WORK_DIR}/stubs"
CACHE_DIR="${WORK_DIR}/cache"
mkdir -p "${STUB_DIR}" "${CACHE_DIR}"

# curl stub. Behaviour controlled via env from each test case:
#   CURL_STUB_OUTPUT — printed verbatim to stdout
#   CURL_STUB_EXIT   — exit code (default 0)
cat > "${STUB_DIR}/curl" <<'STUB'
#!/bin/bash
printf '%s' "${CURL_STUB_OUTPUT:-}"
exit "${CURL_STUB_EXIT:-0}"
STUB
chmod +x "${STUB_DIR}/curl"

PASS=0
FAIL=0

# run_validate <stdout_var> <stderr_var> — sets named variables to captured streams.
run_validate() {
  local _out _err
  local _out_file="${WORK_DIR}/.out.$$"
  local _err_file="${WORK_DIR}/.err.$$"

  PATH="${STUB_DIR}:${PATH}" \
  AITO_LICENSE_CACHE_DIR="${CACHE_DIR}" \
  AITO_LICENSE_BACKGROUND_REFRESH=false \
  bash "${VALIDATE_SCRIPT}" >"${_out_file}" 2>"${_err_file}"

  _out=$(cat "${_out_file}")
  _err=$(cat "${_err_file}")
  rm -f "${_out_file}" "${_err_file}"

  printf -v "$1" '%s' "${_out}"
  printf -v "$2" '%s' "${_err}"
}

reset_cache() { rm -f "${CACHE_DIR}/.aito-license-cache"; }

assert_stdout_contains() {
  local label="$1" needle="$2" out="$3"
  if printf '%s' "${out}" | grep -qF -- "${needle}"; then
    echo "  PASS — ${label}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — ${label}"
    echo "    expected stdout to contain: ${needle}"
    echo "    actual stdout: ${out}"
    FAIL=$((FAIL + 1))
  fi
}

assert_stderr_contains() {
  local label="$1" needle="$2" err="$3"
  if printf '%s' "${err}" | grep -qF -- "${needle}"; then
    echo "  PASS — ${label}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — ${label}"
    echo "    expected stderr to contain: ${needle}"
    echo "    actual stderr: ${err}"
    FAIL=$((FAIL + 1))
  fi
}

# ---- Tests ----

echo "Test 1: no license key → free mode"
reset_cache
unset AITO_LICENSE_KEY 2>/dev/null || true
unset CURL_STUB_OUTPUT CURL_STUB_EXIT
run_validate out err
assert_stdout_contains "free per-table cap"     "AITO_ROW_LIMIT_PER_TABLE=10000" "${out}"
assert_stdout_contains "free total cap"         "AITO_ROW_LIMIT_TOTAL=50000"     "${out}"
assert_stderr_contains "free-mode log"          "no AITO_LICENSE_KEY"            "${err}"

echo "Test 2: valid key + valid response → licensed mode + cache written"
reset_cache
export AITO_LICENSE_KEY=test_valid_001
export CURL_STUB_OUTPUT='{"valid":true,"customerId":"cust_42","expires":"2027-01-01"}'
export CURL_STUB_EXIT=0
run_validate out err
assert_stdout_contains "licensed per-table"     "AITO_ROW_LIMIT_PER_TABLE=0" "${out}"
assert_stdout_contains "licensed total"         "AITO_ROW_LIMIT_TOTAL=0"     "${out}"
assert_stderr_contains "valid license log"      "valid — customer=cust_42"   "${err}"
if [ -f "${CACHE_DIR}/.aito-license-cache" ]; then
  echo "  PASS — cache file created"
  PASS=$((PASS + 1))
else
  echo "  FAIL — cache file should exist"
  FAIL=$((FAIL + 1))
fi

echo "Test 3: cache hit (< 24h) → no network call, licensed mode"
# Reuse cache from Test 2. Set curl to fail; we should still get licensed mode.
export CURL_STUB_EXIT=22
export CURL_STUB_OUTPUT=
run_validate out err
assert_stdout_contains "licensed via cache"     "AITO_ROW_LIMIT_PER_TABLE=0"     "${out}"
assert_stderr_contains "cache-hit log"          "using cached validation"        "${err}"

echo "Test 4: cache age forced > fresh window → network re-validated and used"
reset_cache
export AITO_LICENSE_KEY=test_valid_002
# Make cache "old" by setting a very small fresh window.
export AITO_LICENSE_CACHE_FRESH_SECONDS=0
export CURL_STUB_OUTPUT='{"valid":true,"customerId":"cust_99"}'
export CURL_STUB_EXIT=0
# First call: populates cache.
run_validate out err
# Second call with fresh-window=0: should hit network again (and succeed).
export CURL_STUB_OUTPUT='{"valid":true,"customerId":"cust_99_refreshed"}'
run_validate out err
assert_stderr_contains "re-validated log"       "valid — customer=cust_99_refreshed" "${err}"
unset AITO_LICENSE_CACHE_FRESH_SECONDS

echo "Test 5: invalid key (server rejects) → free mode"
reset_cache
export AITO_LICENSE_KEY=test_invalid
export CURL_STUB_OUTPUT='{"valid":false,"reason":"unknown_key"}'
export CURL_STUB_EXIT=0
run_validate out err
assert_stdout_contains "free per-table after reject" "AITO_ROW_LIMIT_PER_TABLE=10000" "${out}"
assert_stderr_contains "rejection log"          "rejected (unknown_key)"          "${err}"

echo "Test 6: network failure + no cache → free mode (soft downgrade)"
reset_cache
export AITO_LICENSE_KEY=test_no_network
export CURL_STUB_EXIT=22
export CURL_STUB_OUTPUT=
run_validate out err
assert_stdout_contains "free per-table when offline" "AITO_ROW_LIMIT_PER_TABLE=10000" "${out}"
assert_stderr_contains "soft-downgrade log"     "no usable cache"                 "${err}"

echo "Test 7: network failure with stale-but-valid cache → uses cache"
reset_cache
export AITO_LICENSE_KEY=test_stale
# Seed cache via a successful call first.
export CURL_STUB_OUTPUT='{"valid":true,"customerId":"cust_stale"}'
export CURL_STUB_EXIT=0
run_validate out err
# Now force re-validate (fresh window=0) but with network down. Cache age is
# still well under hard TTL (604800s) so it should be used.
export AITO_LICENSE_CACHE_FRESH_SECONDS=0
export CURL_STUB_EXIT=22
export CURL_STUB_OUTPUT=
run_validate out err
assert_stdout_contains "licensed via stale cache" "AITO_ROW_LIMIT_PER_TABLE=0"    "${out}"
assert_stderr_contains "stale-cache fallback log" "using cached response"        "${err}"
unset AITO_LICENSE_CACHE_FRESH_SECONDS

echo "Test 8: different key cannot read cache → falls back to network/free"
reset_cache
export AITO_LICENSE_KEY=key_A
export CURL_STUB_OUTPUT='{"valid":true,"customerId":"cust_A"}'
export CURL_STUB_EXIT=0
run_validate out err  # populates cache for key_A
# Now switch to a different key, simulate network down: should NOT be able
# to decrypt key_A's cache, so soft downgrade.
export AITO_LICENSE_KEY=key_B
export CURL_STUB_EXIT=22
export CURL_STUB_OUTPUT=
run_validate out err
assert_stdout_contains "no cross-key cache reuse" "AITO_ROW_LIMIT_PER_TABLE=10000" "${out}"
assert_stderr_contains "soft downgrade after key change" "no usable cache"        "${err}"

echo ""
echo "================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "================================="

if [ "${FAIL}" -gt 0 ]; then exit 1; fi

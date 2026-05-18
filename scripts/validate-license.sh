#!/bin/bash
# validate-license.sh — call console.aito.ai to validate AITO_LICENSE_KEY.
# Emits AITO_ROW_LIMIT_* env vars on stdout for the entrypoint to eval.
#
# Caching:
#   The response is AES-encrypted (aes-256-cbc + pbkdf2) and persisted at
#   ${AITO_LICENSE_CACHE_DIR}/.aito-license-cache. The cache encryption key
#   is derived from the license key itself, so a different key (or no key)
#   cannot read it.
#
#   On startup, the script's behaviour depends on cache age:
#     age <  AITO_LICENSE_CACHE_FRESH_SECONDS  (24h): use cache, skip network
#     age <  AITO_LICENSE_CACHE_MAX_AGE_SECONDS (7d): try network; cache on fail
#     no/older cache:                                 network only
#
#   Soft downgrade: any failure with no usable cache falls back to free mode.
#
# Background refresh:
#   While the container runs, a forked subshell re-validates every
#   AITO_LICENSE_CACHE_FRESH_SECONDS so the next startup has fresh data.
#   The running JVM is not touched — env vars are read once at boot.
#
# Inputs (env):
#   AITO_LICENSE_KEY                       key to validate
#   AITO_LICENSE_API                       base URL (default https://console.aito.ai)
#   AITO_LICENSE_TIMEOUT                   curl timeout seconds (default 5)
#   AITO_LICENSE_CACHE_DIR                 cache directory (default /io/state)
#   AITO_LICENSE_CACHE_FRESH_SECONDS       skip-network window (default 86400)
#   AITO_LICENSE_CACHE_MAX_AGE_SECONDS     hard cache TTL (default 604800)
#   AITO_LICENSE_BACKGROUND_REFRESH        true/false (default true)
#
# Outputs (stdout): two lines ready to eval:
#   AITO_ROW_LIMIT_PER_TABLE=N
#   AITO_ROW_LIMIT_TOTAL=N
#
# Exit code 0 always; soft-downgrade on any failure.
set -u

: "${AITO_LICENSE_KEY:=}"
: "${AITO_LICENSE_API:=https://console.aito.ai}"
: "${AITO_LICENSE_TIMEOUT:=5}"
: "${AITO_LICENSE_CACHE_DIR:=/io/state}"
: "${AITO_LICENSE_CACHE_FRESH_SECONDS:=86400}"
: "${AITO_LICENSE_CACHE_MAX_AGE_SECONDS:=604800}"
: "${AITO_LICENSE_BACKGROUND_REFRESH:=true}"

CACHE_FILE="${AITO_LICENSE_CACHE_DIR}/.aito-license-cache"

free_limits() {
  echo "AITO_ROW_LIMIT_PER_TABLE=10000"
  echo "AITO_ROW_LIMIT_TOTAL=50000"
}

licensed_limits() {
  echo "AITO_ROW_LIMIT_PER_TABLE=0"
  echo "AITO_ROW_LIMIT_TOTAL=0"
}

cache_password() {
  # Deterministic per-key password. Anyone with the license key can read
  # the cache; anyone without it sees ciphertext.
  printf '%s' "${AITO_LICENSE_KEY}" | sha256sum | head -c 64
}

write_cache() {
  # stdin: plaintext JSON. Adds _cached_at timestamp and encrypts to disk.
  local pw
  pw=$(cache_password)
  mkdir -p "${AITO_LICENSE_CACHE_DIR}" 2>/dev/null || true
  jq --arg ts "$(date -u +%s)" '. + {_cached_at: ($ts|tonumber)}' \
    | openssl enc -aes-256-cbc -salt -pbkdf2 -out "${CACHE_FILE}" -pass "pass:${pw}" 2>/dev/null
  chmod 600 "${CACHE_FILE}" 2>/dev/null || true
}

read_cache() {
  # stdout: decrypted JSON (with _cached_at field) or nothing on any failure.
  [ -f "${CACHE_FILE}" ] || return 1
  local pw
  pw=$(cache_password)
  openssl enc -aes-256-cbc -d -pbkdf2 -in "${CACHE_FILE}" -pass "pass:${pw}" 2>/dev/null
}

cache_age_seconds() {
  # Reads _cached_at from cache JSON; prints age or nothing if unreadable.
  local cached now ts
  cached=$(read_cache) || return 1
  ts=$(echo "${cached}" | jq -r '._cached_at // empty' 2>/dev/null)
  [ -n "${ts}" ] || return 1
  now=$(date -u +%s)
  echo $((now - ts))
}

fetch_validation() {
  # stdout: response JSON. Non-zero exit on network failure.
  curl -fsS --max-time "${AITO_LICENSE_TIMEOUT}" \
    -H 'content-type: application/json' \
    -X POST \
    -d "{\"key\":\"${AITO_LICENSE_KEY}\"}" \
    "${AITO_LICENSE_API%/}/public/licenses/validate"
}

apply_response() {
  # stdin: validation JSON. stdout: env vars. stderr: log.
  local response valid customer expires reason
  response=$(cat)
  valid=$(echo "${response}" | jq -r '.valid // false' 2>/dev/null)
  if [ "${valid}" = "true" ]; then
    customer=$(echo "${response}" | jq -r '.customerId // "unknown"' 2>/dev/null)
    expires=$(echo "${response}" | jq -r '.expires // "unknown"' 2>/dev/null)
    echo "[license] valid — customer=${customer} expires=${expires}" >&2
    licensed_limits
  else
    reason=$(echo "${response}" | jq -r '.reason // "invalid"' 2>/dev/null)
    echo "[license] rejected (${reason}) — free mode" >&2
    free_limits
  fi
}

start_background_refresh() {
  [ "${AITO_LICENSE_BACKGROUND_REFRESH}" = "true" ] || return 0
  (
    while true; do
      sleep "${AITO_LICENSE_CACHE_FRESH_SECONDS}"
      new_response=$(fetch_validation 2>/dev/null) || continue
      echo "${new_response}" | write_cache
    done
  ) &
  disown 2>/dev/null || true
}

# ---- main ----

if [ -z "${AITO_LICENSE_KEY}" ]; then
  echo "[license] no AITO_LICENSE_KEY set — free mode" >&2
  free_limits
  exit 0
fi

cached_response=""
age=""
if cached_response=$(read_cache); then
  age=$(cache_age_seconds)
fi

# Path 1: fresh cache (< 24h) — use without hitting the network.
if [ -n "${cached_response}" ] && [ -n "${age}" ] \
   && [ "${age}" -lt "${AITO_LICENSE_CACHE_FRESH_SECONDS}" ]; then
  echo "[license] using cached validation (age ${age}s)" >&2
  echo "${cached_response}" | apply_response
  start_background_refresh
  exit 0
fi

# Path 2: cache stale or absent — try network.
if response=$(fetch_validation 2>/dev/null); then
  echo "${response}" | write_cache
  echo "${response}" | apply_response
  start_background_refresh
  exit 0
fi

# Path 3: network failed. Use cache if still within hard TTL.
if [ -n "${cached_response}" ] && [ -n "${age}" ] \
   && [ "${age}" -lt "${AITO_LICENSE_CACHE_MAX_AGE_SECONDS}" ]; then
  echo "[license] validation request failed — using cached response (age ${age}s)" >&2
  echo "${cached_response}" | apply_response
  start_background_refresh
  exit 0
fi

# Path 4: nothing to fall back to — soft downgrade.
echo "[license] validation request failed and no usable cache — free mode (soft downgrade)" >&2
free_limits

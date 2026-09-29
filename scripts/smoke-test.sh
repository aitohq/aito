#!/usr/bin/env bash
# Smoke-test a candidate public Aito image before it is published.
#
# This exists because v1.0.1 — the image ghcr.io/aitohq/aito:latest has served
# since 2026-05-25 — shipped with authentication DISABLED, and the workflow's
# old smoke test passed it. That test booted the container and asked for
# /status/limits. Both of those succeed on an image that lets any caller on a
# published port DROP a table, so the test could not fail for the reason we
# care about.
#
# Every assertion below is therefore written to go RED on v1.0.1. Run
#   ./scripts/smoke-test.sh ghcr.io/aitohq/aito:1.0.1
# to see that happen; that is the proof the test is load-bearing rather than
# decorative.
#
# Usage: ./scripts/smoke-test.sh <image-ref>
set -uo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-ref>}"
NAME="aito-smoke-$$"
VOL="aito-smoke-vol-$$"
PORT="${SMOKE_PORT:-19005}"
PGPORT="${SMOKE_PGPORT:-15432}"

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
info() { printf '        %s\n' "$1"; }

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Smoke-testing ${IMAGE}"
echo

# ---------------------------------------------------------------- boot ------
# A dummy licence key on purpose: it exercises the licence code path (the
# server must reach console.aito.ai, be told the key is unknown, and fall back
# to free) without needing a real key in CI.
docker volume create "$VOL" >/dev/null
docker run -d --name "$NAME" \
    -p "127.0.0.1:${PORT}:9005" \
    -p "127.0.0.1:${PGPORT}:5432" \
    -v "${VOL}:/io/state" \
    -e AITO_LICENSE_KEY=smoke-test-not-a-real-key \
    "$IMAGE" >/dev/null || { echo "FATAL: container would not start"; exit 2; }

booted=0
for _ in $(seq 1 60); do
    # NB: /status does not exist on this server — it 404s. /status/limits is
    # the public one. The old workflow waited on /status, never saw it come
    # up, and simply fell out of the loop and carried on.
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/status/limits" 2>/dev/null; then booted=1; break; fi
    # A container that has already exited will never answer; stop waiting.
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then break; fi
    sleep 1
done
if [ "$booted" != "1" ]; then
    echo "FATAL: no answer on /status/limits after 60s. Last 40 log lines:"
    docker logs "$NAME" 2>&1 | tail -40
    exit 2
fi
ok "container boots and answers on :9005/status/limits"

LOGS="$(docker logs "$NAME" 2>&1)"

# ------------------------------------------------------- 1. auth is ON ------
# The headline regression. On v1.0.1 the anonymous call below returns 200 and
# the image is wide open to anyone who can reach the port.
#
# Asserted as a PAIR — the same request with and without a key — rather than
# as a single status code. A lone "not 200" would also be satisfied by a
# server that is simply broken, and this file exists because checks that pass
# for the wrong reason are how 1.0.1 got published. (This server answers an
# unauthenticated API request with 400, not the 401 you might expect, which is
# itself a reason not to hard-code the rejection code.)
anon_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/v2/schema" 2>/dev/null)"
if [ "$anon_code" = "000" ]; then
    bad "the anonymous probe could not connect at all — inconclusive, so: failed"
elif [ "$anon_code" = "200" ]; then
    bad "anonymous GET /api/v2/schema returned 200 — THIS IMAGE HAS NO AUTHENTICATION"
else
    ok "anonymous GET /api/v2/schema is refused (${anon_code})"
fi

# --------------------------------------------- 2. keys were generated -------
RW="$(printf '%s\n' "$LOGS" | sed -n 's/.*read-write:[[:space:]]*\([0-9a-f]\{32,\}\).*/\1/p' | head -1)"
RO="$(printf '%s\n' "$LOGS" | sed -n 's/.*read-only:[[:space:]]*\([0-9a-f]\{32,\}\).*/\1/p'  | head -1)"
if [ -n "$RW" ] && [ -n "$RO" ] && [ "$RW" != "$RO" ]; then
    ok "first boot generated a distinct read-write and read-only key"
else
    bad "no pair of generated API keys in the startup log (rw='${RW:-}' ro='${RO:-}')"
fi

# ------------------------------------------- 3. the generated key works -----
if [ -n "$RW" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "x-api-key: ${RW}" \
            "http://127.0.0.1:${PORT}/api/v2/schema" 2>/dev/null)"
    if [ "$code" = "200" ]; then
        ok "the same request WITH the generated key succeeds (200) — auth is real, not a broken server"
    else
        bad "the generated read-write key was refused (${code}) — keys printed but not enforced"
    fi
else
    bad "cannot test the read-write key: none was generated"
fi

# --------------------------------------- 4. read-only really is read-only ---
if [ -n "$RO" ]; then
    # PUT, not POST: table creation is a PUT on this route, and a POST returns
    # 405 before any authorisation is considered — which looks like a refusal
    # and tests nothing. The control below is what makes this meaningful: the
    # SAME request with the read-write key must succeed.
    ro_body='{"type":"table","columns":{"x":{"type":"Int"}}}'
    ro_code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
            -H "x-api-key: ${RO}" -H 'Content-Type: application/json' -d "$ro_body" \
            "http://127.0.0.1:${PORT}/api/v2/schema/smoke_ro_probe" 2>/dev/null)"
    rw_code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
            -H "x-api-key: ${RW}" -H 'Content-Type: application/json' -d "$ro_body" \
            "http://127.0.0.1:${PORT}/api/v2/schema/smoke_rw_probe" 2>/dev/null)"
    case "$rw_code" in
        200|201) : ;;
        *) bad "the read-WRITE key could not create a table either (${rw_code}) — the read-only probe below proves nothing" ;;
    esac
    case "$ro_code" in
        200|201) bad "the read-only key CREATED A TABLE (${ro_code}) — read-only is not enforced" ;;
        405)     bad "the read-only probe got 405 — wrong method, the check never reached authorisation" ;;
        *)       if [ "$rw_code" = "200" ] || [ "$rw_code" = "201" ]; then
                     ok "the read-only key is refused (${ro_code}) where the read-write key succeeds (${rw_code})"
                 fi ;;
    esac
else
    bad "cannot test the read-only key: none was generated"
fi

# ------------------------------------------------- 5. pgwire on :5432 -------
# v1.0.1 declares EXPOSE 9005 only, but it DOES run a pgwire listener — EXPOSE
# is metadata and `-p 5432:5432` reaches it regardless. So on v1.0.1 this check
# passes while the listener it finds is unauthenticated, which is worse than
# missing. It is the auth assertions above that condemn that image; this one
# guards the SQL interface against silently disappearing.
if command -v openssl >/dev/null 2>&1 \
   && openssl s_client -starttls postgres -connect "127.0.0.1:${PGPORT}" \
        -verify_return_error </dev/null >/dev/null 2>&1; then
    ok "pgwire answers a TLS handshake on :5432"
elif (exec 3<>"/dev/tcp/127.0.0.1/${PGPORT}") 2>/dev/null; then
    ok "pgwire is listening on :5432 (plaintext; no TLS offered)"
else
    bad "nothing is listening on :5432 — the SQL interface is missing"
fi

# ------------------------------------------------- 6. free-tier limits ------
limits="$(curl -s ${RW:+-H "x-api-key: ${RW}"} "http://127.0.0.1:${PORT}/status/limits" 2>/dev/null)"
# Parsed with jq, not sed: "rowsTotal" appears under BOTH .limits and .usage,
# and a greedy regex picks up .usage.rowsTotal (0 on a fresh boot) and reports
# a limit that is not there.
if ! command -v jq >/dev/null 2>&1; then
    bad "jq is not installed, so the limits cannot be checked — not treated as a pass"
else
    per="$(printf '%s' "$limits" | jq -r '.limits.rowsPerTable // empty' 2>/dev/null)"
    tot="$(printf '%s' "$limits" | jq -r '.limits.rowsTotal    // empty' 2>/dev/null)"
    mode="$(printf '%s' "$limits" | jq -r '.mode // empty' 2>/dev/null)"
    if [ "$per" = "10000" ] && [ "$tot" = "50000" ] && [ "$mode" = "free" ]; then
        ok "free-tier limits are enforced (10000/table, 50000 total, mode=free)"
    else
        bad "unexpected limits: rowsPerTable='${per:-?}' rowsTotal='${tot:-?}' mode='${mode:-?}'"
    fi
fi

# ------------------------------------------ 7. the licence path is live -----
# We passed a key that cannot be valid. The server must have ASKED and been
# told no. A run that never mentions the licence means the key was ignored,
# which is exactly what a paying customer would then hit.
if printf '%s\n' "$LOGS" | grep -qiE '\[license\].*(rejected|unknown_key|invalid)'; then
    ok "AITO_LICENSE_KEY is consumed and validated (dummy key rejected)"
elif printf '%s\n' "$LOGS" | grep -qiE '\[license\]'; then
    info "$(printf '%s\n' "$LOGS" | grep -iE '\[license\]' | head -2)"
    bad "the licence path ran but did not reject an obviously invalid key"
else
    bad "AITO_LICENSE_KEY was ignored entirely — no licence check in the log"
fi

# --------------------------------------- 8. free mode is what we shipped ----
if printf '%s\n' "$LOGS" | grep -q 'Free Mode'; then
    ok "the banner reports Free Mode"
else
    bad "the startup banner does not report Free Mode"
fi

# ------------------------------------- 9. keys survive a restart ------------
docker restart "$NAME" >/dev/null 2>&1
for _ in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/status" 2>/dev/null && break
    sleep 1
done
if [ -n "$RW" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "x-api-key: ${RW}" \
            "http://127.0.0.1:${PORT}/api/v2/schema" 2>/dev/null)"
    if [ "$code" = "200" ]; then
        ok "the generated key still works after a restart (persisted to the volume)"
    else
        bad "the key stopped working after a restart (${code}) — keys are not persisted"
    fi
fi

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1

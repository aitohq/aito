#!/usr/bin/env bash
# Ten-minute check that the image works on a real Apple Silicon Mac.
#
# The publish workflow already builds and smoke-tests linux/arm64 natively on
# GitHub's arm runner. That proves arm64 LINUX. A Mac runs the image inside
# Docker Desktop's (or OrbStack's / Colima's) Linux VM, which adds things a CI
# runner never sees: port forwarding from macOS into the VM, IPv6 `localhost`,
# virtiofs bind mounts, the VM's memory cap, and whatever the Mac already runs
# on 5432. Run this once on an M-series Mac before announcing Mac support.
#
# Needs: Docker Desktop (or OrbStack / Colima), curl, jq (`brew install jq`).
# Written for macOS's stock bash 3.2.
#
# Usage:   ./scripts/mac-check.sh [image]      (default ghcr.io/aitohq/aito:latest)
# Exit:    0 all checks passed, 1 something failed. Every result is printed.
set -uo pipefail

IMAGE="${1:-ghcr.io/aitohq/aito:latest}"
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0; warn=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  WARN  %s\n' "$1"; warn=$((warn+1)); }

cleanup() {
  docker rm -f aito-mac-check aito-mac-bind >/dev/null 2>&1 || true
  docker volume rm aito-mac-check >/dev/null 2>&1 || true
  rm -rf "${BIND_DIR:-/nonexistent-aito-mac-check}"
}
trap cleanup EXIT

echo "Mac check for ${IMAGE}"
echo "  host: $(uname -sm), docker: $(docker version --format '{{.Server.Os}}/{{.Server.Arch}} {{.Server.Version}}' 2>/dev/null || echo 'NOT REACHABLE')"
command -v jq >/dev/null 2>&1 || { echo "jq is required: brew install jq"; exit 1; }
echo

# 1. The pull must resolve to arm64 natively. An amd64 image would still run
#    under emulation, slowly and with a platform warning; that is the failure
#    this whole release exists to remove.
docker pull -q "$IMAGE" >/dev/null || { bad "cannot pull $IMAGE"; exit 1; }
ARCH=$(docker image inspect "$IMAGE" --format '{{.Architecture}}')
if [ "$ARCH" = "arm64" ]; then ok "the image resolves to arm64 on this Mac (native, no emulation)"
else bad "the image resolved to ${ARCH}, so it would run under emulation. Is this tag multi-arch?"; fi

# 2. The full public smoke test (13 checks: auth, read-only key, SQL port,
#    limits, licence path, vector search, key persistence), on this machine.
echo; echo "  running the 13-check smoke test (about 3 minutes)..."
if "$HERE/smoke-test.sh" "$IMAGE" > /tmp/aito-mac-smoke.log 2>&1; then
  ok "smoke test: $(grep -E 'passed, .* failed' /tmp/aito-mac-smoke.log | sed 's/^ *//')"
else
  bad "smoke test failed:"; grep -E 'FAIL|FATAL' /tmp/aito-mac-smoke.log | sed 's/^/          /'
fi

# 3. Port 5432. Developer Macs very often run Postgres (Postgres.app, Homebrew)
#    on 5432, and then the /docker command's `-p 127.0.0.1:5432:5432` makes
#    `docker run` fail outright: the database does not start at all.
echo
if lsof -nP -iTCP:5432 -sTCP:LISTEN >/dev/null 2>&1; then
  note "something on this Mac already listens on 5432 ($(lsof -nP -iTCP:5432 -sTCP:LISTEN | awk 'NR==2{print $1}')); the /docker command as written would FAIL here. The docs should show a different host port for SQL."
else
  ok "5432 is free on this Mac (but it often is not on developers' Macs, see the WARN text in the script)"
fi

# 4. The /docker page's own steps: named volume, 127.0.0.1 ports, key from the
#    volume, one authenticated call through `localhost`.
echo
docker run -d --name aito-mac-check -p 127.0.0.1:19105:9005 -v aito-mac-check:/io/state "$IMAGE" >/dev/null
up=0; for _ in $(seq 1 120); do curl -sf -o /dev/null http://127.0.0.1:19105/version && { up=1; break; }; sleep 1; done
if [ "$up" = 1 ]; then
  KEY=$(docker exec aito-mac-check cat /io/state/.aito-api-keys | sed -n 's/^READ_WRITE_APIKEY=//p')
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "x-api-key: $KEY" http://127.0.0.1:19105/api/v2/schema)
  [ "$code" = 200 ] && ok "the /docker steps work: key from the volume, authenticated call 200" \
                    || bad "authenticated call returned $code"

  # 5. `localhost` on macOS resolves to ::1 (IPv6) first. The port is bound
  #    to 127.0.0.1 only. curl falls back to IPv4, but some clients (notably
  #    Node.js 17+) try ::1 and give up with ECONNREFUSED. The docs say
  #    `localhost`, so check what a client actually gets.
  if curl -s -6 -o /dev/null --max-time 5 http://localhost:19105/version; then
    ok "localhost over IPv6 reaches the container too"
  else
    note "http://localhost:19105 works over IPv4 only; clients that try ::1 first (Node.js 17+) can fail. The docs should say 127.0.0.1, or bind both."
  fi
  if command -v node >/dev/null 2>&1; then
    if node -e "fetch('http://localhost:19105/version').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
      ok "Node.js fetch('http://localhost:…') reaches the container"
    else
      bad "Node.js fetch('http://localhost:…') FAILS: an SDK or app using 'localhost' will not connect"
    fi
  fi

  # 6. Restart: keys survive on the volume.
  docker restart aito-mac-check >/dev/null
  up=0; for _ in $(seq 1 120); do curl -sf -o /dev/null http://127.0.0.1:19105/version && { up=1; break; }; sleep 1; done
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "x-api-key: $KEY" http://127.0.0.1:19105/api/v2/schema)
  [ "$up" = 1 ] && [ "$code" = 200 ] && ok "after a restart the same key still works" || bad "after a restart: up=$up, auth $code"
else
  bad "the /docker steps: the container did not answer within 120 s"; docker logs aito-mac-check 2>&1 | tail -15
fi

# 7. A BIND mount instead of a named volume goes through virtiofs from macOS.
#    The container runs as uid 1000; the directory belongs to the Mac user. It
#    must still start, write its key file, and keep it.
echo
BIND_DIR="$(mktemp -d /tmp/aito-mac-bind.XXXXXX)"
docker run -d --name aito-mac-bind -p 127.0.0.1:19106:9005 -v "$BIND_DIR:/io/state" "$IMAGE" >/dev/null
up=0; for _ in $(seq 1 120); do curl -sf -o /dev/null http://127.0.0.1:19106/version && { up=1; break; }; sleep 1; done
if [ "$up" = 1 ] && [ -s "$BIND_DIR/.aito-api-keys" ]; then
  ok "a bind-mounted host directory works (key file written through virtiofs, mode $(stat -f '%Lp' "$BIND_DIR/.aito-api-keys" 2>/dev/null || stat -c '%a' "$BIND_DIR/.aito-api-keys"))"
else
  bad "a bind-mounted host directory: up=$up, key file $( [ -s "$BIND_DIR/.aito-api-keys" ] && echo present || echo MISSING)"
  docker logs aito-mac-bind 2>&1 | tail -10
fi

# 8. Memory. The VM's cap, not the Mac's RAM, is what the JVM (-Xmx 2g by
#    default) actually gets.
MEM=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
MEM_GB=$(( MEM / 1073741824 ))
if [ "$MEM_GB" -ge 4 ]; then ok "the Docker VM has ${MEM_GB} GB of memory"
else note "the Docker VM has only ${MEM_GB} GB; with the default -Xmx 2g the database can be OOM-killed. Raise it in Docker Desktop, or set JVM_XMX lower."; fi

echo
echo "  ${pass} ok, ${warn} warnings, ${fail} failed"
[ "$fail" -eq 0 ]

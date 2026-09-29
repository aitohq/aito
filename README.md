# Aito — the predictive database

Free for development and CI. Licensed for production.

```bash
docker pull ghcr.io/aitohq/aito
docker run -p 9005:9005 ghcr.io/aitohq/aito
```

…or pull from the AWS mirror:

```bash
docker pull public.ecr.aws/aitoai/aito
```

## Quickstart

```bash
docker run -d \
  --name aito \
  -p 9005:9005 \
  -p 5432:5432 \
  -v aito-state:/io/state \
  ghcr.io/aitohq/aito:latest

# On first boot the image generates an API key pair and prints it:
docker logs aito | grep -A2 'API keys'
```

The container binds `0.0.0.0` — it has to, to be reachable through `docker -p` —
and it cannot tell whether you published that port to your laptop or to the
internet. So it does not run unauthenticated. The keys are written to
`/io/state/.aito-api-keys` and reused on every later boot, so they survive a
restart as long as you keep the volume.

```bash
export AITO_KEY=<the read-write key from the log>

# Insert a row
curl -X POST http://localhost:9005/api/v1/data/companies \
  -H "x-api-key: $AITO_KEY" \
  -H 'content-type: application/json' \
  -d '{"name":"acme","revenue":1000000}'

# Predict
curl -X POST http://localhost:9005/api/v1/_predict \
  -H "x-api-key: $AITO_KEY" \
  -H 'content-type: application/json' \
  -d '{"from":"companies","predict":"revenue"}'
```

The read-only key queries but cannot `INSERT`/`UPDATE`/`DELETE`/`DROP`. Give
that one to anything that only reads.

For a throwaway local container you can opt out entirely with
`-e AITO_DISABLE_AUTH=true`. Do not do that on a published port.

### SQL

The same server speaks the PostgreSQL wire protocol on `5432`, with the API key
as the password:

```bash
PGPASSWORD="$AITO_KEY" psql -h localhost -p 5432 -U aito -d aito
```

Full docs: <https://aito.ai/docs>

## Free-tier limits

The default image is free for development and CI:

| Limit | Default |
|---|---|
| Rows per table | 10,000 |
| Rows total | 50,000 |

Going over either limit returns HTTP 429 with `{"error":"row_limit_exceeded"}`. The server keeps serving queries against existing data; only inserts past the limit are rejected.

To remove the limits, set `AITO_LICENSE_KEY` to a key issued by [console.aito.ai](https://console.aito.ai):

```bash
docker run -d \
  -e AITO_LICENSE_KEY=ak_live_… \
  -p 9005:9005 \
  -p 5432:5432 \
  -v aito-state:/io/state \
  ghcr.io/aitohq/aito:latest
```

The image phones home to `console.aito.ai/public/licenses/validate` on startup. The response is cached (AES-encrypted on the `/io/state` volume) for up to 7 days, so the image keeps working through network outages. If validation cannot complete, the server starts in free mode and says so in the log rather than refusing to start.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `9005` | HTTP listen port |
| `PGWIRE_PORT` | `5432` | PostgreSQL wire protocol port |
| `BIND_ADDRESS` | `0.0.0.0` | Listen address |
| `STATE_PATH` | `/io/state` | Where the database persists |
| `READ_WRITE_APIKEY` | _(generated)_ | Full-access key; set it to pin your own |
| `APIKEY` | _(generated)_ | Read-only key; set it to pin your own |
| `AITO_DISABLE_AUTH` | `false` | `true` disables all authentication. Local use only |
| `JVM_XMX` | `2g` | JVM max heap |
| `JVM_XMS` | `512m` | JVM initial heap |
| `AITO_LICENSE_KEY` | _(unset)_ | License key for production use |
| `AITO_LICENSE_API` | `https://console.aito.ai` | License validation endpoint |
| `AITO_LICENSE_CACHE_FRESH_SECONDS` | `86400` (24h) | Skip-network window |
| `AITO_LICENSE_CACHE_MAX_AGE_SECONDS` | `604800` (7d) | Hard cache TTL |
| `AITO_LICENSE_TIMEOUT` | `60` | Seconds to wait for validation before starting in free mode |

## Upgrading from 1.0.1

Two things change, and the first one will break client code that predates it:

- **Authentication is on.** `1.0.1` shipped with `DISABLE_API_KEY_AUTH=true`, so
  any caller that could reach the port had full read-write access, including
  `DROP TABLE`. Requests now need `x-api-key`. Read the generated key out of
  `docker logs`, or pin your own with `-e READ_WRITE_APIKEY=…`, or — for a
  throwaway local container only — set `-e AITO_DISABLE_AUTH=true` to keep the
  old behaviour.
- **`AITO_LICENSE_KEY` works.** In `1.0.1` setting it left the container running
  with nothing listening: the entrypoint blocked forever on the licence check
  and the server never started. If you tried a licence key against `1.0.1` and
  concluded the image was broken, it was.

## How this image is built

This repo doesn't hold any of the engine code, and — since `1.0.1` — it no
longer holds a second copy of the runtime either. On a `v*` tag push (or
`workflow_dispatch`), `.github/workflows/publish.yml`:

1. Checks out `docker/free/` from the matching [AitoDotAI/aito-core](https://github.com/AitoDotAI/aito-core) tag, so the image cannot disagree with the code that was released.
2. Downloads the obfuscated free-tier JAR from that release and verifies its checksum.
3. Builds a thin Alpine + JRE 17 image around it.
4. Runs `scripts/smoke-test.sh`, which asserts that authentication is enforced, that the generated keys work and persist across a restart, that the read-only key cannot write, that the SQL port is listening, that the free-tier limits are the documented ones, and that `AITO_LICENSE_KEY` is actually consumed.
5. Pushes to `ghcr.io/aitohq/aito:<version>` and `public.ecr.aws/aitoai/aito:<version>`, moving `:latest` only if this is the highest version published.

`1.0.1` was built from a copy of the runtime kept in this repo. That copy drifted
from `aito-core` — it disabled authentication and never exposed the SQL port —
and the smoke test of the day could not catch it, because it only checked that
the container answered on an endpoint that does not require a key. Both halves
of that are fixed above.

The engine lives at [AitoDotAI/aito-core](https://github.com/AitoDotAI/aito-core). Bugs and feature requests there.

## License

The Docker image is freely distributable under the terms documented at <https://aito.ai/license>. The contents of this repo (publish workflow, smoke test) are MIT-licensed.

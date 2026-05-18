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
  -v aito-state:/io/state \
  ghcr.io/aitohq/aito:latest

# Insert a row
curl -X POST http://localhost:9005/api/v1/data/companies \
  -H 'content-type: application/json' \
  -d '{"name":"acme","revenue":1000000}'

# Predict
curl -X POST http://localhost:9005/api/v1/_predict \
  -H 'content-type: application/json' \
  -d '{"from":"companies","predict":"revenue"}'
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
  ghcr.io/aitohq/aito:latest
```

The image phones home to `console.aito.ai/public/licenses/validate` on startup. The response is cached (AES-encrypted on the `/io/state` volume) for up to 7 days, so the image keeps working through network outages.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `9005` | HTTP listen port |
| `BIND_ADDRESS` | `0.0.0.0` | Listen address |
| `STATE_PATH` | `/io/state` | Where the database persists |
| `JVM_XMX` | `2g` | JVM max heap |
| `JVM_XMS` | `512m` | JVM initial heap |
| `AITO_LICENSE_KEY` | _(unset)_ | License key for production use |
| `AITO_LICENSE_API` | `https://console.aito.ai` | License validation endpoint |
| `AITO_LICENSE_CACHE_FRESH_SECONDS` | `86400` (24h) | Skip-network window |
| `AITO_LICENSE_CACHE_MAX_AGE_SECONDS` | `604800` (7d) | Hard cache TTL |

## How this image is built

This repo doesn't hold any of the engine code. On a `v*` tag push (or `workflow_dispatch`), `.github/workflows/publish.yml`:

1. Downloads the obfuscated free-tier JAR from the matching [AitoDotAI/aito-core release](https://github.com/AitoDotAI/aito-core/releases).
2. Builds a thin Alpine + JRE 17 image around it.
3. Smoke-tests the image boots and answers `/status`.
4. Pushes to `ghcr.io/aitohq/aito:<tag>` and `public.ecr.aws/aitoai/aito:<tag>` (+ `:latest`).

The engine lives at [AitoDotAI/aito-core](https://github.com/AitoDotAI/aito-core). Bugs and feature requests there.

## License

The Docker image is freely distributable under the terms documented at <https://aito.ai/license>. The contents of this repo (Dockerfile, entrypoint, publish workflow) are MIT-licensed.

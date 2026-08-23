# langflow-railway

Deployment files for running [Langflow](https://github.com/langflow-ai/langflow)
on [Railway](https://railway.com).

Langflow is a visual builder for AI agents and LLM workflows: you wire
components on a canvas, test them in a playground, and publish any flow as an
HTTP API or an MCP server.

Upstream's `langflowai/langflow` image needs no rebuild. What it needs is a
boot-time step, and this repo is that step and nothing else — a one-layer
`FROM langflowai/langflow:latest` plus an entrypoint.

## Why the image alone is not enough on Railway

**The volume arrives owned by root.** The image runs as uid 1000 and pre-creates
`/app/langflow` so a Docker *named volume* inherits that ownership. Railway
mounts its volume `root:root` instead, so the very first boot dies on

```
PermissionError: [Errno 13] Permission denied: '/app/langflow/secret_key'
```

(upstream [#10437](https://github.com/langflow-ai/langflow/issues/10437)). The
entrypoint runs as root, takes ownership of the mount once, and drops back to
uid 1000 before exec'ing Langflow, so the application itself never runs as root.

**`LANGFLOW_SECRET_KEY` has to be a Fernet key.** Langflow SHA-256s the value
only when it is shorter than 32 characters. At 32 or more it pads the string to
a base64 multiple and hands it straight to `Fernet`, which accepts exactly 32
decoded bytes — so 43 urlsafe-base64 characters work and the obvious operator
value, `openssl rand -hex 32` at 64 characters, does not. It deploys green and
then raises the first time a credential is encrypted. The entrypoint rewrites
only the values that would break, and passes through anything Langflow already
handles, so an existing deployment's encrypted credentials survive an upgrade.

**Nothing reaps orphans.** Langflow components spawn stdio MCP servers — the
image ships Node so they can be `npx`'d — and a worker killed mid-flight
reparents them onto PID 1, which here is CPython. `tini -s` sits in front as a
sub-reaper.

## Contents

| Path | Role |
|---|---|
| `Dockerfile` | `FROM langflowai/langflow:latest`, adds `tini` and the entrypoint |
| `entrypoint.sh` | volume ownership, secret-key normalisation, privilege drop |
| `railway.json` | builder and restart policy carried into the template |

## Configuration

Everything else is an ordinary environment variable on the Railway service; this
repo introduces no configuration of its own. The variables that matter on
Railway:

| Variable | Value | Why |
|---|---|---|
| `LANGFLOW_DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | SQLite on a volume cannot serve multiple workers |
| `LANGFLOW_REDIS_URL` | `${{Redis.REDIS_URL}}` | cache backend, database 0 |
| `LANGFLOW_REDIS_QUEUE_URL` | `${{Redis.REDIS_URL}}/1` | build-event queue, database 1 |
| `LANGFLOW_CACHE_TYPE` | `redis` | |
| `LANGFLOW_JOB_QUEUE_TYPE` | `redis` | Langflow **refuses to start** with more than one worker without it |
| `LANGFLOW_WORKERS` | `2` | never `-1`: that reads the host's core count, not the container's |
| `LANGFLOW_CONFIG_DIR` | `/app/langflow` | the volume mount point |
| `LANGFLOW_SECRET_KEY` | 43 urlsafe-base64 characters | see above |
| `LANGFLOW_AUTO_LOGIN` | `false` | otherwise the instance has no login at all |
| `LANGFLOW_SUPERUSER` / `_PASSWORD` | operator's own | required once `AUTO_LOGIN` is off |
| `LANGFLOW_CORS_ORIGINS` | the public origin | the default is `*` *with* credentials allowed |

`LANGFLOW_RATE_LIMIT_TRUST_PROXY` is deliberately left off. Langflow reads the
**rightmost** `X-Forwarded-For` entry when it is on, and Railway's edge rotates
that entry per request, so turning it on would give every request its own
rate-limit bucket and quietly remove the login throttle.

## License

Langflow is MIT-licensed by the Langflow authors. This repository only carries
deployment glue.

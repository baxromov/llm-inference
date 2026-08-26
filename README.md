# llm-inference (llm-gateway)

LiteLLM proxy — the shared OpenAI-compatible API gateway in front of the org's LLM backends.
Deployed on the dev server (`172.31.174.11`, port `8585`, domain `llm-gw.ai-dev.ipotekabank.uz`
via `proxy-light`); a preprod deploy on `172.31.214.10` (`llm-gw.ai-stage.ipotekabank.uz`) follows
the same `dev`/`staging` branch pattern as every other repo in this org.

## What this repo does NOT include

Ollama (the actual model runtime) is **not** deployed by this repo — it runs natively as a
systemd service on the GPU server (`gpusrv02`, `172.31.230.3`), managed separately. This repo's
LiteLLM proxy just talks to it as a backend (`models.yaml`'s `api_base`). An earlier version of
this repo assumed Ollama would be co-located here (`ollama/`, `SETUP_GPU_SERVER.md`,
`manage.sh ollama-gpu`, etc.) — that plan changed and those pieces were removed 2026-08-26 to
avoid the confusion of dead, misleading tooling. `grafana/`, `infinity/`, `postgres/initdb/`,
`prometheus/` were also removed the same day — none of them were ever wired into
`docker-compose.yml`.

## Services

| Component | Role | Port |
|---|---|---|
| **LiteLLM** | OpenAI-compatible API gateway + UI | `8585` (host) → `8080` (container) |
| **Postgres** | LiteLLM's own DB — UI login, user management, `store_model_in_db` | internal |

## Deploy

```bash
./deploy.sh              # full deploy (idempotent — safe to re-run)
./deploy.sh render       # re-render litellm/config.yaml from models.yaml only
./deploy.sh --dry-run    # validate everything without starting containers
```

CI (`.gitlab-ci.yml`) does the same thing over SSH — automatic on push to `dev`, manual on
`staging` (preprod, runner-only — see `DevOps/CLAUDE.md`'s Preprod/staging rollout section for
why direct SSH there doesn't work).

## Daily operations — manage.sh

```bash
./manage.sh doctor          # health check: containers, disk, API
./manage.sh fix             # restart unhealthy containers, refresh configs
./manage.sh status          # compact overview of all containers
./manage.sh logs litellm    # tail logs for any service
./manage.sh restart litellm # restart one or more services
./manage.sh add-model       # interactive wizard to add a new model
./manage.sh apply-models    # re-render configs + restart affected services
./manage.sh update-images   # pull latest pinned Docker images
./manage.sh shell litellm   # open a shell inside a container
```

## Adding a new model

All models are configured in **`models.yaml`** — the single source of truth. See the file's own
header comment for the `provider: ollama` vs `provider: openai` (vLLM etc.) schema and the
`num_retries`/timeout guidance (retry-storm history: `DevOps/CLAUDE.md`'s GPU Inference Server
notes, 2026-07-29).

```bash
./manage.sh add-model       # interactive
# or edit models.yaml directly, then:
./deploy.sh render
docker compose restart litellm
```

The model itself still needs pulling on the Ollama host separately (not through this repo):
```bash
ssh root@172.31.230.3 ollama pull <tag>
```

Note: as of 2026-08-25, the primary chat model (`gemma4:31b`) is managed as a LiteLLM `db_model`
(added via the `/model/update` API), not listed in `models.yaml` — see the file's own comment for
why duplicating it there would break the render.

## File structure

```
llm-inference/
├── deploy.sh                  ← one-command deploy (self-healing, idempotent)
├── manage.sh                  ← devops: doctor / fix / logs / add-model / ...
├── models.yaml                ← ALL models defined here (single source of truth)
├── docker-compose.yml         ← 2 services: postgres, litellm
├── .env.example                ← copy to .env (auto-done by deploy.sh)
│
├── scripts/
│   └── render-configs.py      ← generates litellm/config.yaml from models.yaml
│
├── litellm/
│   ├── config.yaml            ← AUTO-GENERATED (do not edit directly)
│   └── config.template.yaml   ← LiteLLM proxy settings (edit this)
│
├── FIX_DISK.md                 ← disk-space runbook
└── OLLAMA_TTFT_OPTIMIZATION.md ← litellm-side tuning notes for the Ollama backend
```

## Using the API

```
Authorization: Bearer <LITELLM_MASTER_KEY from .env>
```

```bash
curl https://llm-gw.ai-dev.ipotekabank.uz/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma4:31b", "messages": [{"role": "user", "content": "Salom"}]}'
```

### Python (OpenAI SDK — zero code changes)

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://llm-gw.ai-dev.ipotekabank.uz/v1",
    api_key="<LITELLM_MASTER_KEY>"
)

response = client.chat.completions.create(
    model="gemma4:31b",
    messages=[{"role": "user", "content": "Salom"}]
)
print(response.choices[0].message.content)
```

## Dashboard

| Dashboard | URL | Login |
|---|---|---|
| **LiteLLM UI** — API key management, usage | `https://llm-gw.ai-dev.ipotekabank.uz/ui` | `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` |

## Troubleshooting

```bash
./manage.sh doctor   # comprehensive health check
./manage.sh fix      # restart unhealthy services automatically
```

| Symptom | Likely cause | Fix |
|---|---|---|
| `litellm` → `502`/timeout errors | Ollama backend (gpusrv02) slow/overloaded, not this container | See `DevOps/CLAUDE.md`'s GPU Inference Server notes |
| LiteLLM UI shows no models | Config not loaded | `docker compose restart litellm && docker compose logs litellm` |
| Disk full | Logs / old images | `docker system prune -f` then check `df -h` |
| Retry storm (backend timeout amplifies into 3x load) | `num_retries` not pinned per-model, or DB-stored `router_settings.model_group_retry_policy` overriding it | See `DevOps/CLAUDE.md`'s retry-storm postmortem — the config-file `num_retries` alone is not sufficient with `store_model_in_db: true` |

```bash
./manage.sh logs litellm
docker compose logs -f          # all services
```

## Updating image versions

Image versions are pinned in `docker-compose.yml`.

```bash
./manage.sh update-images
docker compose up -d
```

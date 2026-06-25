# LLM Inference Stack

Self-hosted LLM platform for a bank's private GPU server.
Single API endpoint, fully offline after initial setup, one-command deploy.

---

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                    models.yaml  ← edit here                   │
│          (single source of truth for all models)              │
└────────────┬──────────────────┬──────────────────┬────────────┘
             │ render           │ render           │ render
             ▼                  ▼                  ▼
   litellm/config.yaml   ollama/init-models.sh  infinity/entrypoint.sh
             │                  │                  │
             ▼                  ▼                  ▼
        ┌─────────┐        ┌────────┐        ┌──────────┐
        │ LiteLLM │◄──────►│ Ollama │        │ Infinity │
        │  :4000  │        │  LLM   │        │ Embed+Re │
        └────┬────┘        │ GPU0+1 │        │  rank    │
             │             └────────┘        │  GPU 1   │
             │                               └──────────┘
             ▼
    ┌────────────────┐    ┌─────────────┐    ┌─────────┐
    │   Langfuse     │    │  Prometheus │    │ Grafana │
    │  (trace every  │    │  (metrics)  │    │  :3001  │
    │   request)     │    └─────────────┘    └─────────┘
    │   :3000 (SSH)  │
    └────────────────┘
    Postgres · ClickHouse · Redis · MinIO  (all internal)
```

## Services

| Component | Role | Port |
|-----------|------|------|
| **LiteLLM** | Unified OpenAI-compatible API gateway + UI | `4000` |
| **Ollama** | Runs LLM on GPU | internal |
| **Infinity** | Embedding + Reranker models on GPU | internal |
| **Langfuse** | Full request tracing (who asked, latency, tokens) | `3000` (SSH only) |
| **Grafana** | GPU utilization, VRAM, temperature, LLM metrics | `3001` |
| **Prometheus** | Metrics collector | internal |
| **Postgres** | Database for Langfuse + LiteLLM | internal |
| **ClickHouse** | Analytics for Langfuse | internal |
| **Redis** | Langfuse event queue | internal |
| **MinIO** | Langfuse blob storage | internal |

## GPU allocation

```
GPU 0 + GPU 1  →  Ollama      qwen3.6:27b — 17 GB VRAM (split across both)
GPU 1          →  Infinity    bge-m3 + bge-reranker — ~3.3 GB VRAM
```

2x A100 80 GB = 160 GB total VRAM. `OLLAMA_SCHED_SPREAD=1` lets Ollama spread layers across both cards.

---

## Getting started

### Prerequisites (one-time, on the GPU server)

```bash
# Docker 24+
docker --version

# NVIDIA Container Toolkit
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

If the last command shows your GPUs, you're ready.

### Download embedding / reranker models (requires internet, ~2 GB)

```bash
pip install huggingface-hub

huggingface-cli download BAAI/bge-m3 \
    --local-dir ./infinity/models/BAAI/bge-m3

huggingface-cli download BAAI/bge-reranker-v2-m3 \
    --local-dir ./infinity/models/BAAI/bge-reranker-v2-m3
```

Or let deploy.sh do it for you automatically:

```bash
HF_AUTO_DOWNLOAD=1 ./deploy.sh
```

### Deploy — single command

```bash
./deploy.sh
```

That's it. On first run it will:
1. Check prereqs (Docker, NVIDIA, Python)
2. Create `.env` with auto-generated secrets → **review org/admin settings then re-run**
3. Re-render all configs from `models.yaml`
4. Download HF models if missing (set `HF_AUTO_DOWNLOAD=1`)
5. Write Prometheus auth token
6. Start all 12 services and wait for healthy status

The first startup pulls `qwen3.6:27b` (~17 GB). Watch progress:

```bash
docker compose logs -f ollama-init
```

#### Deploy options

```bash
./deploy.sh                # full deploy
./deploy.sh render         # re-render configs only (no Docker changes)
./deploy.sh --no-gpu       # skip GPU checks (dev/CI)
./deploy.sh --dry-run      # validate everything without starting containers
./deploy.sh --no-models    # skip HuggingFace model download step
HF_AUTO_DOWNLOAD=1 ./deploy.sh   # auto-download missing HF models
```

---

## Daily operations — manage.sh

```bash
./manage.sh doctor          # health check: GPU, containers, disk, API
./manage.sh fix             # restart unhealthy containers, refresh configs
./manage.sh status          # compact overview of all containers + GPU
./manage.sh logs litellm    # tail logs for any service
./manage.sh restart litellm # restart one or more services
./manage.sh add-model       # interactive wizard to add a new model
./manage.sh apply-models    # re-render configs + restart affected services
./manage.sh update-images   # pull latest pinned Docker images
./manage.sh shell ollama    # open a shell inside a container
```

---

## Adding a new model

All models are configured in **`models.yaml`** — the single source of truth.
Changing this file and re-rendering updates LiteLLM, Ollama, and Infinity automatically.

### Interactive (recommended)

```bash
./manage.sh add-model
```

### Manual — chat model (Ollama)

1. Add to `models.yaml` under `chat:`:

```yaml
chat:
  - name: llama3.3-70b
    ollama_model: llama3.3:70b
    description: "Llama 3.3 70B"
    timeout: 600
    stream_timeout: 600
    aliases: []
```

2. Apply:

```bash
./deploy.sh render
docker exec -it ollama ollama pull llama3.3:70b
docker compose restart litellm
```

### Manual — embedding or reranker model (Infinity)

1. Download the model files:

```bash
huggingface-cli download intfloat/e5-large-v2 \
    --local-dir infinity/models/intfloat/e5-large-v2
```

2. Add to `models.yaml` under `embedding:` or `reranker:`:

```yaml
embedding:
  - name: intfloat/e5-large-v2
    hf_repo: intfloat/e5-large-v2
    local_path: /models/intfloat/e5-large-v2
    aliases: []
```

3. Apply:

```bash
./deploy.sh render
docker compose restart infinity litellm
```

---

## File structure

```
llm-inference/
├── deploy.sh                  ← one-command deploy
├── manage.sh                  ← devops: doctor / fix / logs / add-model / ...
├── models.yaml                ← ALL models defined here (single source of truth)
├── docker-compose.yml         ← 12 services
├── .env.example               ← copy to .env (auto-done by deploy.sh)
│
├── scripts/
│   └── render-configs.py      ← generates the 3 files below from models.yaml
│
├── litellm/
│   ├── config.yaml            ← AUTO-GENERATED (do not edit directly)
│   └── config.template.yaml   ← LiteLLM proxy settings (edit this)
│
├── ollama/
│   └── init-models.sh         ← AUTO-GENERATED
│
├── infinity/
│   ├── entrypoint.sh          ← AUTO-GENERATED
│   └── models/                ← HuggingFace model files (git-ignored)
│
├── postgres/
│   └── initdb/01-init.sql     ← creates langfuse + litellm databases
│
├── prometheus/
│   ├── prometheus.yml         ← scrape config
│   └── litellm_token          ← written by deploy.sh (git-ignored)
│
└── grafana/
    └── provisioning/
        ├── datasources/prometheus.yaml   ← auto-configured Prometheus datasource
        └── dashboards/dashboard.yaml     ← dashboard file provider
```

---

## Using the API

All requests go to `http://<server>:4000/v1` with:
```
Authorization: Bearer <LITELLM_MASTER_KEY from .env>
```

### Chat

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3.6-27b", "messages": [{"role": "user", "content": "Salom"}]}'
```

### Embedding

```bash
curl http://localhost:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "BAAI/bge-m3", "input": "Matn shu yerda"}'
```

### Reranking

```bash
curl http://localhost:4000/v1/rerank \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "BAAI/bge-reranker-v2-m3",
    "query": "kapital talablari",
    "documents": ["Bazel III...", "Likvidlik koeffitsienti..."]
  }'
```

### OCR / Vision

```bash
IMAGE_B64=$(base64 -w0 document.jpg)
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"qwen3.6-27b\",
    \"messages\": [{\"role\": \"user\", \"content\": [
      {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/jpeg;base64,${IMAGE_B64}\"}},
      {\"type\": \"text\", \"text\": \"Bu rasmdagi matnni chiqar\"}
    ]}]
  }"
```

### Python (OpenAI SDK — zero code changes)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://<server>:4000/v1",
    api_key="<LITELLM_MASTER_KEY>"
)

response = client.chat.completions.create(
    model="gpt-4",          # alias → routes to qwen3.6:27b automatically
    messages=[{"role": "user", "content": "Salom"}]
)
print(response.choices[0].message.content)
```

---

## Dashboards

| Dashboard | URL | Login |
|-----------|-----|-------|
| **LiteLLM UI** — API key management, usage per key | `http://<server>:4000/ui` | `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` |
| **Grafana** — GPU metrics + LLM metrics | `http://<server>:3001` | `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` |
| **Langfuse** — full request trace viewer | SSH tunnel (see below) | `LANGFUSE_ADMIN_EMAIL` / `LANGFUSE_ADMIN_PASSWORD` |

**Grafana GPU dashboard** — import once after first deploy:
> Grafana → Dashboards → Import → ID `12239` → Load
> (Prometheus datasource is auto-provisioned)

**Langfuse via SSH tunnel:**
```bash
# Run on your local machine (not the server)
ssh -L 3000:localhost:3000 <gpu-server>
# Then open http://localhost:3000
```

---

## Troubleshooting

### Comprehensive health check

```bash
./manage.sh doctor
```

### Restart unhealthy services automatically

```bash
./manage.sh fix
```

### Common issues

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `ollama` won't start | GPU not visible to Docker | `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker` |
| `infinity` exits immediately | Model files missing | `huggingface-cli download BAAI/bge-m3 --local-dir infinity/models/BAAI/bge-m3` |
| `litellm` → `502` errors | Ollama/Infinity still starting | Wait ~2 min, then `./manage.sh doctor` |
| LiteLLM UI shows no models | Config not loaded | `docker compose restart litellm && docker compose logs litellm` |
| Langfuse not tracing | Keys mismatch | Check `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` in `.env` match Langfuse project |
| Disk full | Large model weights + logs | `docker system prune -f` then check `df -h` |
| GPU out of memory | Too many models loaded | `OLLAMA_MAX_LOADED_MODELS=1` in `.env` then `docker compose restart ollama` |

### View logs

```bash
./manage.sh logs litellm
./manage.sh logs ollama
./manage.sh logs langfuse-web
docker compose logs -f             # all services
```

### Common commands

```bash
# Stop everything (keeps data)
docker compose down

# Stop and wipe all data (fresh start)
docker compose down -v

# Live GPU stats
watch -n2 "docker exec ollama nvidia-smi"

# Confirm GPU assigned correctly
docker exec ollama nvidia-smi     # shows GPU 0 + GPU 1
docker exec infinity nvidia-smi   # shows GPU 1 only
```

---

## Updating image versions

Image versions are pinned in `docker-compose.yml`. To update:

```bash
./manage.sh update-images
docker compose up -d
```

Check release notes before updating Langfuse or LiteLLM — they occasionally have breaking config changes.

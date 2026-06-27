# LLM Inference Stack

Self-hosted LLM platform on a private GPU server.
Single API endpoint, fully offline after initial setup, one-command deploy.

---

## Architecture

```
┌─────────────────────────────────────────┐
│         models.yaml  ← edit here        │
│   (single source of truth for models)   │
└──────────────┬──────────────────────────┘
               │ render           │ render
               ▼                  ▼
    litellm/config.yaml   ollama/init-models.sh
               │                  │
               ▼                  ▼
          ┌─────────┐        ┌────────┐
          │ LiteLLM │◄──────►│ Ollama │
          │  :8080  │        │  LLM   │
          └─────────┘        │ GPU0+1 │
                             └────────┘
```

## Services

| Component | Role | Port |
|-----------|------|------|
| **LiteLLM** | OpenAI-compatible API gateway + UI | `8080` |
| **Ollama** | Runs LLM on GPU | internal |

## GPU allocation

```
GPU 0 + GPU 1  →  Ollama   qwen3.6:27b — 17 GB VRAM (split across both)
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

### Deploy — single command

```bash
./deploy.sh
```

On first run it will:
1. Check prereqs (Docker, NVIDIA, Python)
2. Create `.env` with auto-generated secrets
3. Re-render configs from `models.yaml`
4. Start all services and wait for healthy status

The first startup pulls `qwen3.6:27b` (~17 GB). Watch progress:

```bash
docker compose logs -f ollama-init
```

#### Deploy options

```bash
./deploy.sh              # full deploy
./deploy.sh render       # re-render configs only (no Docker changes)
./deploy.sh --no-gpu     # skip GPU checks (dev/CI)
./deploy.sh --dry-run    # validate everything without starting containers
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
Changing this file and re-rendering updates LiteLLM and Ollama automatically.

### Interactive (recommended)

```bash
./manage.sh add-model
```

### Manual

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

---

## File structure

```
llm-inference/
├── deploy.sh                  ← one-command deploy
├── manage.sh                  ← devops: doctor / fix / logs / add-model / ...
├── models.yaml                ← ALL models defined here (single source of truth)
├── docker-compose.yml         ← 3 services: ollama, ollama-init, litellm
├── .env.example               ← copy to .env (auto-done by deploy.sh)
│
├── scripts/
│   └── render-configs.py      ← generates the 2 files below from models.yaml
│
├── litellm/
│   ├── config.yaml            ← AUTO-GENERATED (do not edit directly)
│   └── config.template.yaml   ← LiteLLM proxy settings (edit this)
│
└── ollama/
    └── init-models.sh         ← AUTO-GENERATED
```

---

## Using the API

All requests go to `http://<server>:8080/v1` with:
```
Authorization: Bearer <LITELLM_MASTER_KEY from .env>
```

### Chat

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3.6-27b", "messages": [{"role": "user", "content": "Salom"}]}'
```

### OCR / Vision

```bash
IMAGE_B64=$(base64 -w0 document.jpg)
curl http://localhost:8080/v1/chat/completions \
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
    base_url="http://<server>:8080/v1",
    api_key="<LITELLM_MASTER_KEY>"
)

response = client.chat.completions.create(
    model="gpt-4",          # alias → routes to qwen3.6:27b automatically
    messages=[{"role": "user", "content": "Salom"}]
)
print(response.choices[0].message.content)
```

---

## Dashboard

| Dashboard | URL | Login |
|-----------|-----|-------|
| **LiteLLM UI** — API key management, usage | `http://<server>:8080/ui` | `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` |

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
| `litellm` → `502` errors | Ollama still starting | Wait ~2 min, then `./manage.sh doctor` |
| LiteLLM UI shows no models | Config not loaded | `docker compose restart litellm && docker compose logs litellm` |
| Disk full | Large model weights + logs | `docker system prune -f` then check `df -h` |
| GPU out of memory | Too many models loaded | Set `OLLAMA_MAX_LOADED_MODELS=1` then `docker compose restart ollama` |

### View logs

```bash
./manage.sh logs litellm
./manage.sh logs ollama
docker compose logs -f         # all services
```

### Common commands

```bash
# Stop everything (keeps data)
docker compose down

# Stop and wipe all data (fresh start)
docker compose down -v

# Live GPU stats
watch -n2 "docker exec ollama nvidia-smi"
```

---

## Updating image versions

Image versions are pinned in `docker-compose.yml`. To update:

```bash
./manage.sh update-images
docker compose up -d
```

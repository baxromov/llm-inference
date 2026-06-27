#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# LLM Inference Stack — Setup Script
# Run this once before "docker compose up -d"
# ─────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!!]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

echo ""
echo "======================================================"
echo "  LLM Inference Stack — Setup"
echo "======================================================"
echo ""

# ── Step 1: Check prerequisites ───────────────────────────────────────────
echo "▶ Checking prerequisites..."

command -v docker   >/dev/null 2>&1 || error "Docker not found. Install Docker 24+."
command -v nvidia-smi >/dev/null 2>&1 || error "nvidia-smi not found. Install NVIDIA drivers + nvidia-container-toolkit."

GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
[ "$GPU_COUNT" -ge 2 ] || error "Expected 2 GPUs, found ${GPU_COUNT}. Check nvidia-smi."
info "Found ${GPU_COUNT} GPU(s):"
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader | sed 's/^/       /'

docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia || \
  warn "nvidia runtime not detected in Docker. Make sure nvidia-container-toolkit is configured."

# ── Step 2: Create .env from template ─────────────────────────────────────
echo ""
echo "▶ Configuring environment..."

if [ ! -f .env ]; then
  cp .env.example .env
  warn ".env created from .env.example"
  warn "IMPORTANT: Open .env and replace all CHANGE_ME values, then re-run setup.sh"
  echo ""
  echo "  Quick secret generation:"
  echo "    openssl rand -hex 32   # run 4x for the 4 secrets in .env"
  echo ""
  exit 0
fi

# Check for unfilled placeholders
if grep -q "CHANGE_ME" .env; then
  warn ".env still has CHANGE_ME placeholders. Fill them in first."
  grep "CHANGE_ME" .env | sed 's/^/  → /'
  echo ""
  echo "  Generate secrets with:  openssl rand -hex 32"
  echo ""
  exit 1
fi

info ".env is configured"

# ── Step 3: Write Prometheus token file from .env ─────────────────────────
echo ""
echo "▶ Configuring Prometheus token..."

LITELLM_MASTER_KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d'=' -f2-)
if [ -z "$LITELLM_MASTER_KEY" ]; then
  error "LITELLM_MASTER_KEY not found in .env"
fi
echo -n "$LITELLM_MASTER_KEY" > prometheus/litellm_token
info "prometheus/litellm_token written"

# ── Step 4: Check HuggingFace models ──────────────────────────────────────
echo ""
echo "▶ Checking embedding/reranker models..."

BGE_M3_PATH="infinity/models/BAAI/bge-m3"
BGE_RERANKER_PATH="infinity/models/BAAI/bge-reranker-v2-m3"

if [ ! -d "$BGE_M3_PATH" ] || [ -z "$(ls -A $BGE_M3_PATH 2>/dev/null)" ]; then
  warn "bge-m3 model not found at ./$BGE_M3_PATH"
  echo ""
  echo "  Download it with (requires internet + huggingface-hub):"
  echo "    pip install huggingface-hub"
  echo "    huggingface-cli download BAAI/bge-m3 --local-dir ./$BGE_M3_PATH"
  echo ""
  echo "  Then re-run: ./setup.sh"
  exit 1
fi
info "bge-m3 model found"

if [ ! -d "$BGE_RERANKER_PATH" ] || [ -z "$(ls -A $BGE_RERANKER_PATH 2>/dev/null)" ]; then
  warn "bge-reranker-v2-m3 model not found at ./$BGE_RERANKER_PATH"
  echo ""
  echo "  Download it with:"
  echo "    huggingface-cli download BAAI/bge-reranker-v2-m3 --local-dir ./$BGE_RERANKER_PATH"
  echo ""
  echo "  Then re-run: ./setup.sh"
  exit 1
fi
info "bge-reranker-v2-m3 model found"

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo "  Setup complete. Start the stack:"
echo ""
echo "    docker compose up -d"
echo ""
echo "  After startup, pull the LLM (~17 GB, runs once):"
echo "    docker compose logs -f ollama-init"
echo ""
echo "  Access:"
echo "    LiteLLM API  →  http://<server>:4000/v1"
echo "    LiteLLM UI   →  http://<server>:4000/ui"
echo "    Grafana      →  http://<server>:3001"
echo "    Langfuse     →  ssh -L 3000:localhost:3000 <server>"
echo "                    then http://localhost:3000"
echo "======================================================"
echo ""

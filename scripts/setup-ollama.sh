#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/setup-ollama.sh — GPU-only Ollama setup, check, and verify
#
# Usage:
#   ./scripts/setup-ollama.sh              full install + configure + verify
#   ./scripts/setup-ollama.sh check        check existing install & GPU usage
#   ./scripts/setup-ollama.sh models       show model list + GPU allocation
#   ./scripts/setup-ollama.sh gpu          live GPU utilization snapshot
#
# What it does:
#   1. Verifies NVIDIA GPU + CUDA are present  (fatal if not)
#   2. Installs Ollama if missing              (official installer)
#   3. Writes GPU-optimised systemd override
#   4. Starts / restarts Ollama service
#   5. Waits for API to be ready
#   6. Shows loaded models + PROCESSOR column  (must say "100% GPU", not CPU)
#   7. Prints nvidia-smi process table         (confirms Ollama holds VRAM)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[!!]${NC}   $1"; }
fatal() { echo -e "${RED}[FATAL]${NC} $1" >&2; exit 1; }
info()  { echo -e "${CYAN}[--]${NC}   $1"; }
fix()   { echo -e "${YELLOW}[FIX]${NC}  $1"; }
step()  { echo ""; echo -e "${BOLD}${CYAN}▶ $1${NC}"; }

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

MODELS_DIR="/data/ollama/models"
OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
CMD="${1:-install}"

# ─────────────────────────────────────────────────────────────────────────────
# 1. GPU PRESENCE CHECK
# ─────────────────────────────────────────────────────────────────────────────
check_gpu() {
  step "GPU"

  command -v nvidia-smi >/dev/null 2>&1 \
    || fatal "nvidia-smi not found. Install the NVIDIA driver first, then re-run."

  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
  [[ "$GPU_COUNT" -lt 1 ]] && fatal "nvidia-smi found but no GPUs detected. Check: nvidia-smi"

  ok "Found ${GPU_COUNT} GPU(s):"
  nvidia-smi \
    --query-gpu=index,name,memory.total,memory.free,driver_version \
    --format=csv,noheader 2>/dev/null \
    | while IFS=',' read -r idx name total free drv; do
        echo "       GPU${idx} │${name} │ VRAM total:${total} free:${free} │ driver${drv}"
      done

  # Confirm libcuda is visible (Ollama needs it to load CUDA runners)
  LIBCUDA=$(ldconfig -p 2>/dev/null | grep libcuda.so | head -1 || true)
  if [[ -z "$LIBCUDA" ]]; then
    # Try common paths
    LIBCUDA=$(find /usr/lib /usr/local/lib /usr/lib/x86_64-linux-gnu \
      -name "libcuda.so*" 2>/dev/null | head -1 || true)
  fi
  if [[ -n "$LIBCUDA" ]]; then
    ok "libcuda found: ${LIBCUDA}"
  else
    warn "libcuda.so not found in ldconfig cache — Ollama may fall back to CPU."
    warn "Fix: sudo ldconfig  or install CUDA runtime libs."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. INSTALL OLLAMA
# ─────────────────────────────────────────────────────────────────────────────
install_ollama() {
  step "Ollama installation"

  if command -v ollama >/dev/null 2>&1; then
    VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
    ok "Ollama ${VER} already installed at $(command -v ollama)"
    return 0
  fi

  fix "Ollama not found — installing via official installer..."
  curl -fsSL https://ollama.com/install.sh | $SUDO sh
  command -v ollama >/dev/null 2>&1 \
    || fatal "Ollama install failed — binary not found after installation."
  VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
  ok "Ollama ${VER} installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. WRITE GPU-OPTIMISED SYSTEMD OVERRIDE
# ─────────────────────────────────────────────────────────────────────────────
configure_service() {
  step "Systemd service — GPU-only configuration"

  # Pick model storage location
  DATA_FREE=$(df --output=avail /data 2>/dev/null | tail -1 | awk '{print int($1/1024/1024)}' || echo 0)
  if [[ "$DATA_FREE" -lt 50 ]]; then
    MODELS_DIR="/root/.ollama/models"
    warn "/data has only ${DATA_FREE} GB free — using ${MODELS_DIR}"
  else
    ok "/data has ${DATA_FREE} GB free — models dir: ${MODELS_DIR}"
  fi

  $SUDO mkdir -p "${OVERRIDE_DIR}" "${MODELS_DIR}"

  fix "Writing ${OVERRIDE_DIR}/override.conf ..."
  $SUDO tee "${OVERRIDE_DIR}/override.conf" > /dev/null << SVCEOF
[Service]
# ── Network ────────────────────────────────────────────────────────────────
Environment="OLLAMA_HOST=0.0.0.0:11434"

# ── Model storage (large NVMe disk) ────────────────────────────────────────
Environment="OLLAMA_MODELS=${MODELS_DIR}"

# ── GPU — force CUDA, expose all GPUs ──────────────────────────────────────
# CUDA_VISIBLE_DEVICES=all  tells the CUDA runtime to see every GPU.
# Without this, Ollama may silently ignore GPUs added after first install.
Environment="CUDA_VISIBLE_DEVICES=all"

# Flash-Attention: significant speedup on A100 (enabled by default in newer
# Ollama, but setting it explicitly prevents regression after upgrades).
Environment="OLLAMA_FLASH_ATTENTION=1"

# ── Performance ─────────────────────────────────────────────────────────────
# Keep models resident for 24 h so they don't reload between requests.
Environment="OLLAMA_KEEP_ALIVE=24h"
# Serve up to 4 concurrent requests per loaded model.
Environment="OLLAMA_NUM_PARALLEL=4"
# Allow up to 3 models loaded simultaneously across GPUs.
Environment="OLLAMA_MAX_LOADED_MODELS=3"
# Spread models across both A100s instead of stacking on one.
Environment="OLLAMA_SCHED_SPREAD=1"
SVCEOF

  ok "override.conf written"

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable ollama 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. START / RESTART SERVICE
# ─────────────────────────────────────────────────────────────────────────────
restart_service() {
  step "Starting Ollama service"

  if $SUDO systemctl is-active --quiet ollama 2>/dev/null; then
    fix "Service running — restarting to apply new config..."
    $SUDO systemctl restart ollama
  else
    fix "Starting ollama.service..."
    $SUDO systemctl start ollama
  fi

  info "Waiting for Ollama API (http://localhost:11434)..."
  local i=0
  until curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; do
    sleep 3; i=$((i+3))
    [[ $i -gt 90 ]] && fatal "Ollama did not come up after 90 s.\n  Check: sudo systemctl status ollama\n  Logs:  sudo journalctl -u ollama -n 50"
  done
  ok "Ollama API is ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. MODEL LIST + GPU ALLOCATION CHECK
# ─────────────────────────────────────────────────────────────────────────────
show_models() {
  step "Models"

  MODEL_LIST=$(ollama list 2>/dev/null || echo "")
  if echo "$MODEL_LIST" | grep -q "NAME"; then
    echo ""
    echo "$MODEL_LIST"
    echo ""
    MODEL_COUNT=$(echo "$MODEL_LIST" | tail -n +2 | grep -c . || echo 0)
    ok "${MODEL_COUNT} model(s) found in Ollama"
  else
    warn "No models pulled yet."
    info "Pull a model with:  ollama pull qwen3.6:27b"
    info "Or run:             ./deploy.sh   (pulls models defined in models.yaml)"
    return
  fi

  # Check which models are currently loaded and verify GPU usage
  RUNNING=$(ollama ps 2>/dev/null || echo "")
  if echo "$RUNNING" | grep -q "NAME"; then
    step "Loaded models — GPU / CPU allocation"
    echo ""
    echo "$RUNNING"
    echo ""

    CPU_MODELS=$(echo "$RUNNING" | tail -n +2 | grep -v "100% GPU" | grep -v "^$" || true)
    if [[ -n "$CPU_MODELS" ]]; then
      warn "The following models are NOT running 100% on GPU:"
      echo "$CPU_MODELS" | sed 's/^/       /'
      warn "This means VRAM may be full or GPU layers are limited."
      warn "Check VRAM usage below and consider unloading other models."
    else
      # Only show success if at least one model is loaded
      LOADED_COUNT=$(echo "$RUNNING" | tail -n +2 | grep -c . || echo 0)
      if [[ "$LOADED_COUNT" -gt 0 ]]; then
        ok "All loaded models are running 100% on GPU"
      else
        info "No models currently loaded (will load on first request)."
      fi
    fi
  else
    info "No models currently loaded in memory."
    info "Models load on first request — check 'ollama ps' after sending a request."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. LIVE GPU UTILIZATION SNAPSHOT
# ─────────────────────────────────────────────────────────────────────────────
show_gpu() {
  step "GPU utilization"

  echo ""
  echo -e "${BOLD}── Per-GPU summary ──────────────────────────────────────────${NC}"
  nvidia-smi \
    --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw \
    --format=csv,noheader 2>/dev/null \
    | while IFS=',' read -r idx name mem_u mem_t util temp pwr; do
        printf "  GPU%s │ %-30s │ VRAM %s / %s │ Util %s │ %s°C │ %s\n" \
          "$idx" "$name" "$mem_u" "$mem_t" "$util" "$temp" "$pwr"
      done

  echo ""
  echo -e "${BOLD}── Processes using GPU ──────────────────────────────────────${NC}"
  GPU_PROCS=$(nvidia-smi \
    --query-compute-apps=pid,name,used_gpu_memory \
    --format=csv,noheader 2>/dev/null || echo "")

  if [[ -z "$GPU_PROCS" || "$GPU_PROCS" == *"No running compute"* ]]; then
    info "No GPU compute processes right now (models not yet loaded into VRAM)."
    info "Processes appear here after a model is loaded via a request."
  else
    printf "  %-8s %-20s %s\n" "PID" "Process" "GPU Memory"
    echo "$GPU_PROCS" | while IFS=',' read -r pid name mem; do
      printf "  %-8s %-20s %s\n" "$pid" "$(echo "$name" | tr -d ' ')" "$(echo "$mem" | tr -d ' ')"
    done

    OLLAMA_GPU=$(echo "$GPU_PROCS" | grep -i ollama || true)
    if [[ -n "$OLLAMA_GPU" ]]; then
      ok "Ollama is consuming GPU VRAM — confirmed GPU usage"
    else
      info "Ollama process not in GPU list (models may not be loaded yet)."
    fi
  fi

  # Check systemd override is active
  echo ""
  echo -e "${BOLD}── Active Ollama environment (CUDA vars) ────────────────────${NC}"
  if $SUDO systemctl show ollama -p Environment 2>/dev/null | grep -q CUDA_VISIBLE_DEVICES; then
    $SUDO systemctl show ollama -p Environment 2>/dev/null \
      | tr ';' '\n' | grep -E "CUDA|OLLAMA_FLASH|OLLAMA_HOST|OLLAMA_MODELS" \
      | sed 's/^Environment=//; s/^/  /'
    ok "CUDA_VISIBLE_DEVICES=all is active in the service"
  else
    warn "Could not verify systemd environment — check: sudo systemctl show ollama -p Environment"
  fi
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ENTRYPOINT
# ─────────────────────────────────────────────────────────────────────────────
case "$CMD" in

  install)
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Ollama GPU Setup — Full Install + Configure       ║"
    echo "╚══════════════════════════════════════════════════════╝"
    check_gpu
    install_ollama
    configure_service
    restart_service
    show_models
    show_gpu
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  Ollama is running on GPU                           ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  API          → http://localhost:11434              ║"
    echo "║  Models dir   → ${MODELS_DIR}        "
    echo "║  Logs         → sudo journalctl -u ollama -f       ║"
    echo "║  GPU watch    → watch -n2 nvidia-smi               ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    ;;

  check)
    echo ""
    echo -e "${BOLD}── Ollama GPU check ──────────────────────────────────────${NC}"
    check_gpu
    step "Ollama service status"
    if command -v ollama >/dev/null 2>&1; then
      VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
      ok "Ollama ${VER} installed"
    else
      warn "Ollama not installed — run: ./scripts/setup-ollama.sh install"
    fi
    if $SUDO systemctl is-active --quiet ollama 2>/dev/null; then
      ok "ollama.service is active"
    else
      warn "ollama.service is NOT running"
      echo "       Start: sudo systemctl start ollama"
    fi
    if [[ -f "${OVERRIDE_DIR}/override.conf" ]]; then
      ok "systemd override.conf exists"
      grep -E "CUDA|OLLAMA_FLASH" "${OVERRIDE_DIR}/override.conf" | sed 's/^/       /'
    else
      warn "No GPU override.conf — run: ./scripts/setup-ollama.sh install"
    fi
    show_models
    show_gpu
    ;;

  models)
    show_models
    ;;

  gpu)
    show_gpu
    ;;

  *)
    echo "Usage: $0 [install|check|models|gpu]"
    echo "  install   full install + configure + verify  (default)"
    echo "  check     check existing install & GPU usage"
    echo "  models    show model list + GPU allocation"
    echo "  gpu       live GPU utilization snapshot"
    exit 1
    ;;
esac

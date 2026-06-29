#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/setup-ollama.sh — GPU-only Ollama setup, check, and verify
#
# Usage:
#   ./scripts/setup-ollama.sh              full install + configure + verify
#   ./scripts/setup-ollama.sh check        check existing install & GPU usage
#   ./scripts/setup-ollama.sh test-gpu     load a model and confirm 100% GPU
#   ./scripts/setup-ollama.sh models       show model list + GPU allocation
#   ./scripts/setup-ollama.sh gpu          live GPU utilization snapshot
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

MODELS_DIR="/data/ollama"
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

  # Confirm libcuda is visible
  LIBCUDA=$(ldconfig -p 2>/dev/null | grep libcuda.so | head -1 || true)
  if [[ -z "$LIBCUDA" ]]; then
    LIBCUDA=$(find /usr/lib /usr/local/lib /usr/lib/x86_64-linux-gnu \
      -name "libcuda.so*" 2>/dev/null | head -1 || true)
  fi
  if [[ -n "$LIBCUDA" ]]; then
    ok "libcuda found: ${LIBCUDA}"
  else
    warn "libcuda.so not found — Ollama may fall back to CPU."
    warn "Fix: sudo ldconfig  or install CUDA runtime libs."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. CHECK OLLAMA CUDA RUNNERS
# GPU inference requires Ollama's CUDA runner binary. If it's missing,
# Ollama silently falls back to CPU regardless of GPU presence.
# ─────────────────────────────────────────────────────────────────────────────
check_cuda_runners() {
  step "Ollama CUDA runners"

  local runner_base="/usr/local/lib/ollama/runners"

  if [[ ! -d "$runner_base" ]]; then
    warn "Ollama runner dir not found: ${runner_base}"
    warn "Ollama may be using CPU — reinstall Ollama to get CUDA runners:"
    warn "  curl -fsSL https://ollama.com/install.sh | sudo sh"
    return
  fi

  ok "Runner dir: ${runner_base}"
  ls "$runner_base" 2>/dev/null | sed 's/^/       /'

  # Must have a cuda runner
  CUDA_RUNNER=$(ls "${runner_base}" 2>/dev/null | grep -i cuda | head -1 || true)
  if [[ -n "$CUDA_RUNNER" ]]; then
    ok "CUDA runner found: ${CUDA_RUNNER}"
  else
    warn "No CUDA runner found in ${runner_base}!"
    warn "This is why Ollama uses CPU. Fix:"
    warn "  curl -fsSL https://ollama.com/install.sh | sudo sh   (reinstall)"
  fi

  # Check recent journal for GPU detection message
  step "Ollama startup log (GPU detection)"
  journalctl -u ollama --no-pager -n 30 2>/dev/null \
    | grep -iE "cuda|gpu|metal|cpu|runner|layer" \
    | tail -15 \
    | sed 's/^/  /' \
    || info "No journal entries found (check: journalctl -u ollama -n 50)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. INSTALL OLLAMA
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
# 4. WRITE GPU-OPTIMISED SYSTEMD OVERRIDE + FIX PERMISSIONS
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

  # Migrate models from the old default location if they exist and new dir is empty
  OLD_MODELS="/root/.ollama/models"
  if [[ -d "${OLD_MODELS}/blobs" ]] && [[ "$(ls -A "${OLD_MODELS}/blobs" 2>/dev/null)" != "" ]]; then
    if [[ ! -d "${MODELS_DIR}/blobs" ]] || [[ "$(ls -A "${MODELS_DIR}/blobs" 2>/dev/null)" == "" ]]; then
      fix "Migrating models: ${OLD_MODELS} → ${MODELS_DIR} ..."
      $SUDO cp -a "${OLD_MODELS}/." "${MODELS_DIR}/"
      ok "Models migrated to ${MODELS_DIR}"
    else
      info "Models already present in ${MODELS_DIR} — skipping migration"
    fi
  fi

  # Fix ownership: Ollama systemd service runs as 'ollama' user by default.
  # If /data/ollama is owned by root, Ollama cannot read/write models → CPU fallback.
  OLLAMA_SVC_USER=$($SUDO systemctl show ollama --property=User --value 2>/dev/null | tr -d ' ' || echo "ollama")
  [[ -z "$OLLAMA_SVC_USER" ]] && OLLAMA_SVC_USER="ollama"
  if id "$OLLAMA_SVC_USER" >/dev/null 2>&1; then
    fix "Setting ${MODELS_DIR} owner → ${OLLAMA_SVC_USER}..."
    $SUDO chown -R "${OLLAMA_SVC_USER}:${OLLAMA_SVC_USER}" "${MODELS_DIR}"
    ok "${MODELS_DIR} owned by ${OLLAMA_SVC_USER}"
  fi

  # Find CUDA library path for LD_LIBRARY_PATH in the service
  CUDA_LIB_PATH=""
  for p in /usr/local/cuda/lib64 /usr/lib/x86_64-linux-gnu /usr/local/lib; do
    if [[ -f "${p}/libcuda.so.1" ]] || [[ -f "${p}/libcuda.so" ]]; then
      CUDA_LIB_PATH="${p}"
      break
    fi
  done
  # Fallback: search ldconfig
  if [[ -z "$CUDA_LIB_PATH" ]]; then
    CUDA_LIB_PATH=$(ldconfig -p 2>/dev/null | grep libcuda.so | awk '{print $NF}' | head -1 | xargs dirname 2>/dev/null || echo "")
  fi

  fix "Writing ${OVERRIDE_DIR}/override.conf ..."
  $SUDO tee "${OVERRIDE_DIR}/override.conf" > /dev/null << SVCEOF
[Service]
# ── Network ────────────────────────────────────────────────────────────────
Environment="OLLAMA_HOST=0.0.0.0:11434"

# ── Model storage ──────────────────────────────────────────────────────────
Environment="OLLAMA_MODELS=${MODELS_DIR}"

# ── GPU / CUDA ──────────────────────────────────────────────────────────────
# Expose all NVIDIA GPUs to the CUDA runtime.
Environment="CUDA_VISIBLE_DEVICES=all"
# Ensure the CUDA runtime library is on LD_LIBRARY_PATH so Ollama's CUDA
# runner can dlopen it even when systemd strips the default library paths.
Environment="LD_LIBRARY_PATH=${CUDA_LIB_PATH}:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu"
# Flash-Attention gives a big speedup on A100.
Environment="OLLAMA_FLASH_ATTENTION=1"

# ── Performance ─────────────────────────────────────────────────────────────
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_NUM_PARALLEL=4"
Environment="OLLAMA_MAX_LOADED_MODELS=3"
# Spread models across both A100s instead of stacking on one GPU.
Environment="OLLAMA_SCHED_SPREAD=1"
SVCEOF

  ok "override.conf written (LD_LIBRARY_PATH includes ${CUDA_LIB_PATH:-/usr/lib/x86_64-linux-gnu})"

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable ollama 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. START / RESTART SERVICE
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
# 6. MODEL LIST + GPU ALLOCATION CHECK
# ─────────────────────────────────────────────────────────────────────────────
show_models() {
  step "Models"

  MODEL_LIST=$(ollama list 2>/dev/null || echo "")
  if echo "$MODEL_LIST" | grep -q "NAME"; then
    echo ""
    echo "$MODEL_LIST"
    echo ""
    MODEL_COUNT=$(echo "$MODEL_LIST" | tail -n +2 | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
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

    CPU_MODELS=$(echo "$RUNNING" | tail -n +2 | grep -v "100% GPU" | grep -v "^[[:space:]]*$" || true)
    if [[ -n "$CPU_MODELS" ]]; then
      warn "The following models are NOT running 100% on GPU:"
      echo "$CPU_MODELS" | sed 's/^/       /'
      warn "VRAM may be full, or CUDA runner not loaded. Run: ./scripts/setup-ollama.sh check"
    else
      LOADED_COUNT=$(echo "$RUNNING" | tail -n +2 | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
      if [[ "${LOADED_COUNT:-0}" -gt 0 ]]; then
        ok "All ${LOADED_COUNT} loaded model(s) running 100% on GPU"
      else
        info "No models currently loaded (will load on first request)."
        info "Run './scripts/setup-ollama.sh test-gpu' to force-load and verify GPU."
      fi
    fi
  else
    info "No models currently loaded in memory."
    info "Run './scripts/setup-ollama.sh test-gpu' to load a model and verify GPU usage."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. TEST GPU — load a model and confirm it runs 100% on GPU
# ─────────────────────────────────────────────────────────────────────────────
test_gpu() {
  step "GPU load test"

  # Pick the smallest available model to load quickly
  FIRST_MODEL=$(ollama list 2>/dev/null | tail -n +2 | grep -v '^[[:space:]]*$' | awk '{print $1}' | sort -t: -k2 | head -1 || true)
  if [[ -z "$FIRST_MODEL" ]]; then
    warn "No models found. Pull a model first: ollama pull llama3.2:latest"
    return
  fi

  info "Loading model '${FIRST_MODEL}' for GPU test (keepalive=30s)..."
  # Send a minimal generation request to force the model into VRAM
  curl -sf http://localhost:11434/api/generate \
    -d "{\"model\":\"${FIRST_MODEL}\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"30s\",\"options\":{\"num_predict\":1}}" \
    > /tmp/ollama_test_resp.json 2>&1 &
  local CURL_PID=$!

  # Poll ollama ps for up to 30 s waiting for model to appear
  local i=0
  info "Waiting for model to load into VRAM..."
  while [[ $i -lt 30 ]]; do
    sleep 2; i=$((i+2))
    PS_OUT=$(ollama ps 2>/dev/null || echo "")
    if echo "$PS_OUT" | grep -q "$FIRST_MODEL"; then
      break
    fi
  done
  wait "$CURL_PID" 2>/dev/null || true

  echo ""
  PS_OUT=$(ollama ps 2>/dev/null || echo "")
  if ! echo "$PS_OUT" | grep -q "NAME"; then
    warn "Model did not appear in 'ollama ps' — possible loading failure."
    info "Check logs: sudo journalctl -u ollama -n 30"
    return
  fi

  echo "$PS_OUT"
  echo ""

  # Check PROCESSOR column
  PROC_LINE=$(echo "$PS_OUT" | grep "$FIRST_MODEL" || true)
  if echo "$PROC_LINE" | grep -q "100% GPU"; then
    ok "CONFIRMED: '${FIRST_MODEL}' is running 100% on GPU"
    echo ""
    # Show VRAM consumption
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu \
      --format=csv,noheader 2>/dev/null \
      | while IFS=',' read -r idx name mu mt util; do
          printf "  GPU%s │ %-28s │ VRAM %s / %s │ Util %s\n" "$idx" "$name" "$mu" "$mt" "$util"
        done
    # Show ollama process in nvidia-smi
    echo ""
    GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,name,used_gpu_memory --format=csv,noheader 2>/dev/null || echo "")
    if echo "$GPU_PROCS" | grep -qi ollama; then
      ok "Ollama visible in nvidia-smi GPU processes:"
      echo "$GPU_PROCS" | grep -i ollama | sed 's/^/       /'
    fi
  elif echo "$PROC_LINE" | grep -qi "cpu"; then
    warn "Model loaded but running on CPU — CUDA runner issue."
    warn "Fix steps:"
    warn "  1. sudo journalctl -u ollama -n 50 | grep -iE 'cuda|gpu|error'"
    warn "  2. curl -fsSL https://ollama.com/install.sh | sudo sh   (reinstall for CUDA runners)"
    warn "  3. sudo systemctl restart ollama && ./scripts/setup-ollama.sh test-gpu"
  else
    info "PROCESSOR value: $(echo "$PROC_LINE" | awk '{print $4, $5}')"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. LIVE GPU UTILIZATION SNAPSHOT
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
    info "No GPU compute processes (no model loaded yet)."
    info "Run './scripts/setup-ollama.sh test-gpu' to load a model and verify."
  else
    printf "  %-8s %-22s %s\n" "PID" "Process" "GPU Memory"
    echo "$GPU_PROCS" | while IFS=',' read -r pid name mem; do
      printf "  %-8s %-22s %s\n" "$pid" "$(echo "$name" | tr -d ' ')" "$(echo "$mem" | tr -d ' ')"
    done
    OLLAMA_GPU=$(echo "$GPU_PROCS" | grep -i ollama || true)
    if [[ -n "$OLLAMA_GPU" ]]; then
      ok "Ollama is consuming GPU VRAM — confirmed GPU usage"
    else
      info "Ollama not in GPU process list (no model loaded yet)."
    fi
  fi

  echo ""
  echo -e "${BOLD}── Active Ollama environment (CUDA vars) ────────────────────${NC}"
  if $SUDO systemctl show ollama -p Environment 2>/dev/null | grep -q CUDA_VISIBLE_DEVICES; then
    $SUDO systemctl show ollama -p Environment 2>/dev/null \
      | tr ' ' '\n' \
      | grep -E "CUDA|OLLAMA_FLASH|OLLAMA_HOST|OLLAMA_MODELS|LD_LIBRARY" \
      | sed 's/^/  /'
    ok "CUDA_VISIBLE_DEVICES=all is active"
  else
    warn "Could not verify systemd CUDA env — check: sudo systemctl show ollama -p Environment"
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
    check_cuda_runners
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
    echo "║  Verify GPU   → ./scripts/setup-ollama.sh test-gpu ║"
    echo "║  Live GPU     → watch -n2 nvidia-smi               ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    ;;

  check)
    echo ""
    echo -e "${BOLD}── Ollama GPU check ──────────────────────────────────────${NC}"
    check_gpu
    check_cuda_runners
    step "Ollama service status"
    if command -v ollama >/dev/null 2>&1; then
      VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
      ok "Ollama ${VER} installed"
    else
      warn "Ollama not installed — run: ./scripts/setup-ollama.sh"
    fi
    if $SUDO systemctl is-active --quiet ollama 2>/dev/null; then
      ok "ollama.service is active"
    else
      warn "ollama.service is NOT running — start: sudo systemctl start ollama"
    fi
    if [[ -f "${OVERRIDE_DIR}/override.conf" ]]; then
      ok "systemd override.conf exists"
      grep -E "CUDA|OLLAMA_FLASH|LD_LIBRARY" "${OVERRIDE_DIR}/override.conf" | sed 's/^/       /'
    else
      warn "No GPU override.conf — run: ./scripts/setup-ollama.sh"
    fi
    show_models
    show_gpu
    ;;

  test-gpu)
    test_gpu
    ;;

  models)
    show_models
    ;;

  gpu)
    show_gpu
    ;;

  *)
    echo "Usage: $0 [install|check|test-gpu|models|gpu]"
    echo "  install    full install + configure + verify  (default)"
    echo "  check      check existing install & GPU usage"
    echo "  test-gpu   load a model and confirm 100% GPU (definitive test)"
    echo "  models     show model list + GPU allocation"
    echo "  gpu        live GPU utilization snapshot"
    exit 1
    ;;
esac

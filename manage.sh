#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# manage.sh — DevOps management tool for the LLM Inference Stack
#
# Usage:
#   ./manage.sh doctor          check all services, GPU, disk, API health
#   ./manage.sh fix             restart unhealthy services, re-render configs
#   ./manage.sh status          compact summary of all container states
#   ./manage.sh logs <service>  tail logs for a service (ctrl+c to stop)
#   ./manage.sh restart <svc>   restart one or more services
#   ./manage.sh add-model       interactive wizard to add a new model
#   ./manage.sh apply-models    restart services after git pull (configs pre-rendered)
#   ./manage.sh update-images   pull latest pinned image tags
#   ./manage.sh shell <svc>     open a shell in a running container
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GREEN}  ✓${NC}  $1"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $1"; }
err()   { echo -e "${RED}  ✗${NC}  $1"; ERRORS=$((ERRORS+1)); }
info()  { echo -e "${CYAN}  ·${NC}  $1"; }
title() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──────────────────────────────────────────────${NC}"; }
hr()    { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }

ERRORS=0

CMD="${1:-help}"
shift || true

# ─────────────────────────────────────────────────────────────────────────────
doctor() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║   LLM Stack — Doctor                                ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

  # ── Docker daemon ──
  title "Docker"
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon running"
  else
    err "Docker daemon not reachable"
    echo "  Fix: sudo systemctl start docker"
    return
  fi

  # ── GPU ──
  title "GPU"
  if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
    ok "nvidia-smi found — ${GPU_COUNT} GPU(s)"
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,temperature.gpu,utilization.gpu \
      --format=csv,noheader 2>/dev/null | while IFS=, read -r idx name mem_used mem_total temp util; do
      echo "       GPU${idx} │ ${name} │ VRAM: ${mem_used}/${mem_total} │ Temp: ${temp}°C │ Util: ${util}"
    done
    if docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
      ok "nvidia runtime registered in Docker"
    else
      warn "nvidia runtime NOT found in Docker — GPU containers won't work"
      echo "     Fix: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
    fi
  else
    warn "nvidia-smi not found — GPU checks skipped"
  fi

  # ── Disk space ──
  title "Disk space"
  DF=$(df -h . | tail -1)
  AVAIL=$(echo "$DF" | awk '{print $4}')
  USE_PCT=$(echo "$DF" | awk '{print $5}' | tr -d '%')
  if [[ "$USE_PCT" -gt 90 ]]; then
    err "Disk ${USE_PCT}% full (${AVAIL} free) — dangerously low"
  elif [[ "$USE_PCT" -gt 80 ]]; then
    warn "Disk ${USE_PCT}% full (${AVAIL} free)"
  else
    ok "Disk ${USE_PCT}% used (${AVAIL} free)"
  fi

  # ── .env ──
  title "Environment"
  if [[ ! -f .env ]]; then
    err ".env file missing — run: ./deploy.sh"
  elif grep -q "CHANGE_ME" .env; then
    err ".env has unfilled CHANGE_ME placeholders"
    grep "CHANGE_ME" .env | sed 's/^/     → /'
  else
    ok ".env configured"
  fi

  # ── Generated files sync ──
  title "Config sync (models.yaml vs generated files)"
  if [[ -f models.yaml ]]; then
    RENDERED=$(python3 - << 'PYEOF'
import yaml, sys
from pathlib import Path
with open('models.yaml') as f:
    m = yaml.safe_load(f)
with open('litellm/config.yaml') as f:
    lc = f.read()
chat = [c['name'] for c in m.get('chat', [])]
ok = all(name in lc for name in chat)
print('ok' if ok else 'stale')
PYEOF
)
    if [[ "$RENDERED" == "ok" ]]; then
      ok "litellm/config.yaml matches models.yaml"
    else
      warn "litellm/config.yaml may be stale — run: ./deploy.sh render"
    fi
  fi

  # ── Port availability ──
  title "Port availability"
  if lsof -ti ":8080" >/dev/null 2>&1; then
    PID=$(lsof -ti ":8080" | head -1)
    PROC=$(ps -p "$PID" -o comm= 2>/dev/null || echo "?")
    if [[ "$PROC" == "docker"* ]] || [[ "$PROC" == "com.docker"* ]]; then
      ok "Port 4000 in use by Docker (expected)"
    else
      warn "Port 4000 in use by PID ${PID} (${PROC}) — may conflict with stack"
    fi
  else
    info "Port 4000 free (stack not yet started or down)"
  fi

  # ── Container health ──
  title "Container health"
  if ! docker compose ps --quiet 2>/dev/null | grep -q .; then
    warn "No containers running — start with: ./deploy.sh"
  else
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Health}}" 2>/dev/null | \
      while IFS=$'\t' read -r name status health; do
        [[ "$name" == "NAME" ]] && continue
        if [[ "$health" == "healthy" ]] || [[ "$health" == "" && "$status" == *"Up"* ]]; then
          ok "${name}: ${status}"
        elif echo "$status" | grep -q "Exit\|Error"; then
          err "${name}: ${status}"
        else
          warn "${name}: ${status} (${health})"
        fi
      done
  fi

  # ── API health ──
  title "API health"
  if curl -sf --max-time 5 "http://localhost:8080/health" >/dev/null 2>&1; then
    ok "LiteLLM API responding on :8080"
    if [[ -f .env ]]; then
      KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d'=' -f2-)
      MODELS=$(curl -sf --max-time 5 -H "Authorization: Bearer ${KEY}" \
        "http://localhost:8080/v1/models" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(m['id'] for m in d.get('data',[][:5])))" 2>/dev/null || echo "?")
      info "Available models: ${MODELS}"
    fi
  else
    warn "LiteLLM API not responding on :4000 (container may still be starting)"
  fi

  # ── Summary ──
  echo ""
  hr
  if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All checks passed.${NC}"
  else
    echo -e "${RED}${BOLD}  ${ERRORS} error(s) found. Run: ./manage.sh fix${NC}"
  fi
  hr
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
fix() {
  echo ""
  echo -e "${BOLD}${CYAN}── Fix — restarting unhealthy services ──────────────────${NC}"

  UNHEALTHY=$(docker compose ps --format json 2>/dev/null \
    | python3 -c "
import sys, json
lines = sys.stdin.read().strip()
try:
    services = json.loads(lines)
except:
    services = [json.loads(l) for l in lines.splitlines() if l.strip()]
names = [s.get('Name','?') for s in services
         if s.get('Health','') in ('unhealthy','starting') and 'init' not in s.get('Name','')]
print('\n'.join(names))
" 2>/dev/null || true)

  if [[ -z "$UNHEALTHY" ]]; then
    ok "No unhealthy containers found"
  else
    echo "$UNHEALTHY" | while read -r svc; do
      [[ -z "$svc" ]] && continue
      info "Restarting ${svc}..."
      docker compose restart "${svc}" 2>/dev/null || warn "Could not restart ${svc}"
      ok "Restarted ${svc}"
    done
  fi

  echo ""
  ok "Fix complete. Run './manage.sh doctor' to verify."
}

# ─────────────────────────────────────────────────────────────────────────────
status() {
  echo ""
  docker compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}\t{{.Health}}" 2>/dev/null
  echo ""
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo -e "${CYAN}GPU status:${NC}"
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu \
      --format=csv,noheader 2>/dev/null | awk -F', ' \
      '{printf "  GPU%s │ %-30s │ VRAM %s/%s │ Util %s │ %s°C\n", $1,$2,$3,$4,$5,$6}'
  fi
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
logs() {
  SVC="${1:-}"
  if [[ -z "$SVC" ]]; then
    echo "Usage: ./manage.sh logs <service>"
    echo "Services: ollama, ollama-init, litellm"
    exit 1
  fi
  exec docker compose logs -f --tail=100 "$SVC"
}

# ─────────────────────────────────────────────────────────────────────────────
restart_svc() {
  [[ $# -eq 0 ]] && { echo "Usage: ./manage.sh restart <service> [service2 ...]"; exit 1; }
  for svc in "$@"; do
    info "Restarting ${svc}..."
    docker compose restart "$svc"
    ok "${svc} restarted"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
apply_models() {
  echo ""
  echo -e "${BOLD}${CYAN}── Apply models — configs already rendered & pulled via git ─${NC}"
  echo ""
  info "Which services need restarting?"
  echo "  1) litellm only   (changed timeout or removed model)"
  echo "  2) litellm + pull new Ollama model   (added a new model)"
  echo ""
  read -rp "  Choice [1/2]: " CHOICE

  case "$CHOICE" in
    1)
      docker compose restart litellm
      ;;
    2)
      info "Pulling new Ollama model(s) via init-models.sh ..."
      bash ollama/init-models.sh
      docker compose restart litellm
      ;;
    *) warn "Invalid choice — restart manually: docker compose restart litellm" ;;
  esac
  ok "Done. Check ./manage.sh doctor for health."
}

# ─────────────────────────────────────────────────────────────────────────────
add_model() {
  echo ""
  echo -e "${BOLD}${CYAN}── Add a new chat model ─────────────────────────────────${NC}"
  echo ""
  read -rp "  Ollama model tag (e.g. llama3.3:70b): " OLLAMA_TAG
  read -rp "  Model name for API (e.g. llama3.3-70b): " MODEL_NAME
  read -rp "  Description: " DESC
  read -rp "  OpenAI aliases (comma-separated, or blank): " ALIASES_RAW

  ALIASES_YAML=""
  if [[ -n "$ALIASES_RAW" ]]; then
    ALIASES_YAML=$(echo "$ALIASES_RAW" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | \
      awk '{print "      - " $0}' | paste -sd '\n')
  fi

  cat >> models.yaml << YAML

  - name: ${MODEL_NAME}
    ollama_model: ${OLLAMA_TAG}
    description: "${DESC}"
    timeout: 300
    stream_timeout: 300
    aliases:
${ALIASES_YAML}
YAML
  ok "Added ${MODEL_NAME} to models.yaml"
  info "To pull the model: docker exec -it ollama ollama pull ${OLLAMA_TAG}"

  echo ""
  read -rp "  Apply now? (re-render + restart litellm) [y/N]: " APPLY
  if [[ "$APPLY" =~ ^[Yy]$ ]]; then
    apply_models
  else
    info "Run './manage.sh apply-models' when ready."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
ollama_gpu() {
  bash scripts/setup-ollama.sh "${1:-check}"
}

update_images() {
  echo ""
  info "Pulling latest versions of pinned images..."
  docker compose pull
  ok "Images updated. Restart services with: docker compose up -d"
}

# ─────────────────────────────────────────────────────────────────────────────
shell_svc() {
  SVC="${1:-}"
  [[ -z "$SVC" ]] && { echo "Usage: ./manage.sh shell <service>"; exit 1; }
  info "Opening shell in ${SVC}..."
  docker compose exec "$SVC" /bin/bash 2>/dev/null || \
    docker compose exec "$SVC" /bin/sh
}

# ─────────────────────────────────────────────────────────────────────────────
help() {
  echo ""
  echo -e "${BOLD}manage.sh — LLM Stack DevOps Tool${NC}"
  echo ""
  echo "  Commands:"
  echo "    doctor           check all services, GPU, disk, API health"
  echo "    fix              restart unhealthy services, refresh configs"
  echo "    status           compact container + GPU overview"
  echo "    logs <svc>       tail logs for a service"
  echo "    restart <svc>    restart one or more containers"
  echo "    add-model        interactive wizard to add a chat model"
  echo "    apply-models     re-render configs from models.yaml + restart services"
  echo "    update-images    pull latest pinned Docker images"
  echo "    shell <svc>      open an interactive shell in a container"
  echo "    ollama-gpu       check/install Ollama GPU-only config"
  echo ""
  echo "  Services: ollama  ollama-init  litellm"
  echo ""
  echo "  Examples:"
  echo "    ./manage.sh doctor"
  echo "    ./manage.sh fix"
  echo "    ./manage.sh logs litellm"
  echo "    ./manage.sh restart litellm"
  echo "    ./manage.sh add-model"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
case "$CMD" in
  doctor)        doctor ;;
  fix)           fix ;;
  status)        status ;;
  logs)          logs "$@" ;;
  restart)       restart_svc "$@" ;;
  add-model)     add_model ;;
  apply-models)  apply_models ;;
  update-images) update_images ;;
  shell)         shell_svc "$@" ;;
  ollama-gpu)    ollama_gpu "${1:-check}" ;;
  help|--help|-h) help ;;
  *)
    warn "Unknown command: ${CMD}"
    help
    exit 1
    ;;
esac

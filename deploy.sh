#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Self-healing one-command deploy for the LLM Inference Stack
#
# Usage:
#   ./deploy.sh              full deploy (auto-install → fix → up)
#   ./deploy.sh render       regenerate configs from models.yaml only
#   ./deploy.sh --no-gpu     skip GPU checks (dev/CI or CPU-only)
#   ./deploy.sh --dry-run    validate everything without starting containers
#   ./deploy.sh --no-fix     fail fast instead of auto-fixing
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[!!]${NC}   $1"; }
fatal() { echo -e "${RED}[FATAL]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[--]${NC}   $1"; }
fixing(){ echo -e "${YELLOW}[FIX]${NC}  $1"; }
step()  { echo ""; echo -e "${BOLD}${CYAN}▶ $1${NC}"; }

NO_GPU=0; DRY_RUN=0; AUTO_FIX=1; LIBCUDA_JUST_INSTALLED=0

# sudo helper — empty if already root
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

for arg in "$@"; do
  case "$arg" in
    render)
      step "Rendering configs from models.yaml"
      python3 scripts/render-configs.py
      exit 0 ;;
    --no-gpu)  NO_GPU=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-fix)  AUTO_FIX=0 ;;
    -h|--help)
      sed -n '/^# Usage/,/^# ─/p' "$0" | grep -v '^#─' | sed 's/^# \?//'
      exit 0 ;;
    *) warn "Unknown argument: $arg" ;;
  esac
done

# --dry-run must not mutate anything: installs, relocations, daemon.json writes
# all go through AUTO_FIX, so disabling it is enough.
[[ $DRY_RUN -eq 1 ]] && AUTO_FIX=0

# ── Helpers ───────────────────────────────────────────────────────────────────

# retry <max_attempts> <command...>
retry() {
  local max=$1; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    [[ $n -ge $max ]] && return 1
    warn "Attempt $n/$max failed — retrying in 5s..."
    sleep 5
  done
}

# Detect package manager (apt / dnf / unknown)
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf  >/dev/null 2>&1; then echo "dnf"
  else echo "unknown"
  fi
}
PKG_MGR=$(detect_pkg_mgr)

# ── Auto-installers ───────────────────────────────────────────────────────────

install_docker() {
  fixing "Docker not found — installing via get.docker.com..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq ca-certificates curl gnupg lsb-release
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
      $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    $SUDO systemctl enable --now docker
    command -v docker >/dev/null 2>&1 || fatal "Docker install succeeded but 'docker' binary not found."
    if [[ $EUID -ne 0 ]]; then
      $SUDO usermod -aG docker "$USER"
      warn "Added $USER to 'docker' group."
      warn "Group membership is not active yet in this session — re-entering script via sg docker..."
      # Re-exec the entire script with docker group active so 'docker info' works immediately
      exec sg docker -c "\"$0\" $(printf '%q ' "$@")"
    fi
    ok "Docker installed"
  elif [[ "$PKG_MGR" == "dnf" ]]; then
    $SUDO dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    $SUDO systemctl enable --now docker
    command -v docker >/dev/null 2>&1 || fatal "Docker install succeeded but 'docker' binary not found."
    ok "Docker installed (dnf)"
  else
    fatal "Cannot auto-install Docker on this OS. Install manually:\n  https://docs.docker.com/engine/install/"
  fi
}

install_nvidia_toolkit() {
  fixing "nvidia-container-toolkit not found — installing..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
      $SUDO gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq nvidia-container-toolkit
    command -v nvidia-ctk >/dev/null 2>&1 || fatal "nvidia-container-toolkit install failed — 'nvidia-ctk' not found."
    ok "nvidia-container-toolkit installed"
  elif [[ "$PKG_MGR" == "dnf" ]]; then
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
      $SUDO tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
    $SUDO dnf install -y nvidia-container-toolkit
    command -v nvidia-ctk >/dev/null 2>&1 || fatal "nvidia-container-toolkit install failed."
    ok "nvidia-container-toolkit installed (dnf)"
  else
    fatal "Cannot auto-install nvidia-container-toolkit.\n  See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
  fi
}

configure_nvidia_runtime() {
  fixing "Configuring nvidia runtime in Docker..."
  $SUDO nvidia-ctk runtime configure --runtime=docker
  fixing "Restarting Docker to apply nvidia runtime..."
  $SUDO systemctl restart docker
  local attempts=0
  until docker info >/dev/null 2>&1; do
    attempts=$((attempts+1))
    [[ $attempts -gt 15 ]] && fatal "Docker did not come back up after restart."
    sleep 2
  done
  ok "nvidia runtime configured and Docker restarted"
}

# Install Ollama as a native binary on the host for direct GPU access.
# Running on the host avoids all container GPU injection complexity (libcuda, CDI, etc.)
install_ollama_host() {
  if command -v ollama >/dev/null 2>&1; then
    ok "Ollama $(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo 'found') already installed on host"
    return 0
  fi
  fixing "Installing Ollama on host (native binary — direct GPU access, no container hassle)..."
  curl -fsSL https://ollama.com/install.sh | $SUDO sh
  command -v ollama >/dev/null 2>&1 || fatal "Ollama install failed — binary not found after install"
  ok "Ollama installed on host"
}

# Configure Ollama systemd service: listen on all interfaces so LiteLLM Docker can reach it,
# and store models on the large /data NVMe disk (2.9 TB).
start_ollama_service() {
  local override_dir="/etc/systemd/system/ollama.service.d"
  local models_dir="/data/ollama/models"
  # Fall back to home dir if /data doesn't have enough space
  local data_free_gb
  data_free_gb=$(df --output=avail /data 2>/dev/null | tail -1 | awk '{print int($1/1024/1024)}' || echo 0)
  [[ "$data_free_gb" -lt 100 ]] && models_dir="/root/.ollama/models"

  fixing "Configuring Ollama service (0.0.0.0:11434, models → ${models_dir})..."
  $SUDO mkdir -p "$override_dir" "$models_dir"
  $SUDO tee "${override_dir}/override.conf" > /dev/null << SVCEOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_MODELS=${models_dir}"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_NUM_PARALLEL=4"
Environment="OLLAMA_MAX_LOADED_MODELS=3"
Environment="OLLAMA_SCHED_SPREAD=1"
SVCEOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable ollama 2>/dev/null || true
  # Restart so new env vars take effect
  $SUDO systemctl restart ollama

  local i=0
  info "Waiting for Ollama to be ready..."
  until ollama list >/dev/null 2>&1; do
    sleep 2; i=$((i+2))
    [[ $i -gt 60 ]] && { warn "Ollama slow to start — check: systemctl status ollama"; break; }
  done
  ok "Ollama running on 0.0.0.0:11434  (models: ${models_dir})"
}

# Return the mount point with the most free space (skip /, /boot, tmpfs, devtmpfs)
find_best_large_mount() {
  df --output=target,avail -x tmpfs -x devtmpfs -x squashfs 2>/dev/null \
    | awk 'NR>1 && $1 != "/" && $1 !~ /^\/boot/ {print $2, $1}' \
    | sort -rn \
    | head -1 \
    | awk '{print $2}'
}

# Merge {"data-root": path} into /etc/docker/daemon.json without wiping other keys
set_docker_dataroot() {
  local new_root="$1"
  local daemon_file="/etc/docker/daemon.json"
  $SUDO python3 - "$daemon_file" "$new_root" << 'PYEOF'
import json, sys, os
daemon_file, new_root = sys.argv[1], sys.argv[2]
config = {}
if os.path.exists(daemon_file):
    try:
        with open(daemon_file) as f:
            txt = f.read().strip()
        if txt:
            config = json.loads(txt)
    except Exception:
        pass  # corrupt daemon.json — start fresh
config['data-root'] = new_root
tmp = daemon_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(config, f, indent=2)
os.replace(tmp, daemon_file)
print(f"  daemon.json: data-root → {new_root}")
PYEOF
}

configure_docker_dataroot() {
  local current_root
  current_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")

  local free_kb free_gb
  free_kb=$(df --output=avail "$current_root" 2>/dev/null | tail -1 | tr -d ' ')
  free_gb=$(( ${free_kb:-0} / 1024 / 1024 ))

  # If current root already has plenty of space, skip
  if [[ $free_gb -ge 100 ]]; then
    return 0
  fi

  warn "Docker data-root '${current_root}' has only ${free_gb} GB free — looking for a larger partition..."

  local best_mount
  best_mount=$(find_best_large_mount)

  if [[ -z "$best_mount" ]]; then
    warn "No large alternative partition found. Continuing on ${current_root} (${free_gb} GB)."
    return 0
  fi

  local best_kb best_gb
  best_kb=$(df --output=avail "$best_mount" 2>/dev/null | tail -1 | tr -d ' ')
  best_gb=$(( ${best_kb:-0} / 1024 / 1024 ))

  if [[ $best_gb -le $free_gb ]]; then
    warn "No better partition found (best: ${best_mount} ${best_gb} GB). Staying on current root."
    return 0
  fi

  local new_root="${best_mount}/docker"
  fixing "Moving Docker data-root: ${current_root} → ${new_root} (${best_gb} GB free)"

  # Migrate existing data if any (images / volumes)
  local has_images has_volumes
  has_images=$(docker image ls -q 2>/dev/null | wc -l | tr -d ' ')
  has_volumes=$(ls "${current_root}/volumes/" 2>/dev/null | wc -l | tr -d ' ')

  if [[ $has_images -gt 0 || $has_volumes -gt 0 ]]; then
    info "Existing data found (${has_images} images, ${has_volumes} volumes) — migrating..."
    $SUDO systemctl stop docker
    $SUDO mkdir -p "$new_root"
    $SUDO rsync -a --info=progress2 "${current_root}/" "${new_root}/" 2>/dev/null || \
      $SUDO cp -a "${current_root}/." "${new_root}/"
    ok "Data migrated to ${new_root}"
  else
    $SUDO mkdir -p "$new_root"
  fi

  # Write new data-root (merge, not overwrite)
  set_docker_dataroot "$new_root"

  # Restart Docker to apply
  fixing "Restarting Docker with new data-root..."
  $SUDO systemctl restart docker
  local attempts=0
  until docker info >/dev/null 2>&1; do
    attempts=$((attempts+1))
    [[ $attempts -gt 20 ]] && fatal "Docker did not restart after data-root change.\n  Check: sudo systemctl status docker"
    sleep 3
  done

  local verified_root
  verified_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
  if [[ "$verified_root" == "$new_root" ]]; then
    ok "Docker data-root → ${new_root} (${best_gb} GB free)"
  else
    warn "Docker reports data-root as '${verified_root}' (expected '${new_root}'). Check /etc/docker/daemon.json."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    LLM Inference Stack — Self-Healing Deploy        ║"
echo "╚══════════════════════════════════════════════════════╝"
if [[ $DRY_RUN -eq 1 ]]; then
  info "Mode: DRY RUN — check only, no installs or mutations"
elif [[ $AUTO_FIX -eq 1 ]]; then
  info "Mode: Auto-fix ON"
else
  info "Mode: Auto-fix OFF (--no-fix)"
fi

# ── Step 1: Docker ────────────────────────────────────────────────────────────
step "1/9  Docker"

if ! command -v docker >/dev/null 2>&1; then
  if [[ $AUTO_FIX -eq 1 ]]; then
    install_docker
  else
    fatal "Docker not found. Install Docker 24+ or drop --no-fix."
  fi
fi

# Make sure daemon is running
if ! docker info >/dev/null 2>&1; then
  if [[ $AUTO_FIX -eq 1 ]]; then
    fixing "Docker daemon not running — starting it..."
    $SUDO systemctl start docker
    sleep 4
    docker info >/dev/null 2>&1 || fatal "Could not start Docker daemon.\n  Check: sudo systemctl status docker"
    ok "Docker daemon started"
  else
    fatal "Docker daemon not running.\n  Fix: sudo systemctl start docker"
  fi
fi

ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1) — daemon running"

# ── Step 1b: Docker storage location ─────────────────────────────────────────
# If Docker data-root is on a small partition (e.g. 46 GB OS disk) but a large
# partition exists (e.g. /data 2.9 TB NVMe), auto-relocate before anything else.
# This prevents running out of space during image/model pulls.
if [[ $AUTO_FIX -eq 1 ]]; then
  configure_docker_dataroot
fi

# ── Step 2: Python + PyYAML ───────────────────────────────────────────────────
step "2/9  Python dependencies"

if ! command -v python3 >/dev/null 2>&1; then
  if [[ $AUTO_FIX -eq 1 && "$PKG_MGR" == "apt" ]]; then
    fixing "python3 not found — installing..."
    $SUDO apt-get install -y -qq python3 python3-pip
    ok "python3 installed"
  else
    fatal "python3 not found."
  fi
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  if [[ $AUTO_FIX -eq 1 ]]; then
    fixing "PyYAML not found — installing..."
    pip3 install pyyaml -q 2>/dev/null || \
      $SUDO pip3 install pyyaml -q 2>/dev/null || \
      { [[ "$PKG_MGR" == "apt" ]] && $SUDO apt-get install -y -qq python3-yaml; } || true
    python3 -c "import yaml" 2>/dev/null || fatal "Could not install PyYAML."
    ok "PyYAML installed"
  else
    fatal "PyYAML not found.\n  Fix: pip3 install pyyaml"
  fi
fi

ok "Python $(python3 --version | grep -oP '\d+\.\d+\.\d+') + PyYAML ready"

# ── Step 3: GPU ───────────────────────────────────────────────────────────────
step "3/9  GPU & nvidia runtime"

if [[ $NO_GPU -eq 1 ]]; then
  warn "GPU checks skipped (--no-gpu)"
else
  # nvidia-smi must be installed by the user (driver install)
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    fatal "nvidia-smi not found — NVIDIA driver not installed.\n\
  Debian/Ubuntu: https://wiki.debian.org/NvidiaGraphicsDrivers\n\
  After installing, reboot and re-run this script.\n\
  To skip GPU: ./deploy.sh --no-gpu"
  fi

  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$GPU_COUNT" -lt 1 ]]; then
    fatal "nvidia-smi found but no GPUs detected.\n  Check: nvidia-smi\n  Use --no-gpu to skip."
  fi

  ok "Found ${GPU_COUNT} GPU(s):"
  nvidia-smi --query-gpu=index,name,memory.total,driver_version \
    --format=csv,noheader 2>/dev/null | sed 's/^/       /'
  ok "GPU ready — Ollama runs natively on host with direct GPU access"
fi

# ── Step 4: Disk space ────────────────────────────────────────────────────────
step "4/9  Disk space"

DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
FREE_KB=$(df --output=avail "$DOCKER_ROOT" 2>/dev/null | tail -1 | tr -d ' ')
FREE_GB=$(( ${FREE_KB:-0} / 1024 / 1024 ))
if [[ $FREE_GB -lt 10 ]]; then
  fatal "Only ${FREE_GB} GB free on ${DOCKER_ROOT} — critically low.\n\
  Models need 20-50 GB. Free up space or add a larger partition.\n\
  Tip: if you have an unmounted large disk, mount it and re-run."
elif [[ $FREE_GB -lt 30 ]]; then
  warn "Only ${FREE_GB} GB free on ${DOCKER_ROOT} (recommended 50+ GB for models)."
  warn "Continuing — monitor disk usage carefully during model pull."
else
  ok "Disk: ${FREE_GB} GB free on ${DOCKER_ROOT}"
fi

# ── Step 5: Environment file ──────────────────────────────────────────────────
step "5/9  Environment (.env)"

if [[ ! -f .env.example ]]; then
  fatal ".env.example not found. Are you in the right directory?\n  Expected: $(pwd)"
fi

if [[ ! -f .env ]]; then
  fixing "No .env found — creating from .env.example with auto-generated secrets..."
  cp .env.example .env
fi

# Fill any remaining CHANGE_ME placeholders automatically
if grep -q "CHANGE_ME" .env 2>/dev/null; then
  fixing "Filling CHANGE_ME placeholders with auto-generated secrets..."
  python3 - << 'PYEOF'
import subprocess

with open('.env', 'r') as f:
    content = f.read()

def gen(length=32):
    return subprocess.check_output(['openssl', 'rand', '-hex', str(length)]).decode().strip()

lines = []
for line in content.split('\n'):
    if '=' not in line or line.startswith('#'):
        lines.append(line)
        continue
    key, _, val = line.partition('=')
    if 'CHANGE_ME_run_openssl_rand_hex_32' in val or 'CHANGE_ME' in val:
        if val.strip().startswith('sk-'):
            val = 'sk-' + gen(32)
        else:
            val = gen(32)
    lines.append(f"{key}={val}")

with open('.env', 'w') as f:
    f.write('\n'.join(lines))
print("  Secrets auto-generated.")
PYEOF
fi

# Final check
if grep -q "CHANGE_ME" .env 2>/dev/null; then
  warn "Some CHANGE_ME placeholders could not be filled automatically:"
  grep "CHANGE_ME" .env | sed 's/^/  → /'
  [[ $AUTO_FIX -eq 0 ]] && fatal "Fix them manually then re-run."
  warn "Continuing anyway — API may not work correctly."
else
  ok ".env configured"
fi

# ── Step 6: Render configs from models.yaml ───────────────────────────────────
step "6/9  Rendering configs from models.yaml"

[[ ! -f models.yaml ]] && fatal "models.yaml not found."
[[ ! -f scripts/render-configs.py ]] && fatal "scripts/render-configs.py not found."

python3 scripts/render-configs.py || fatal "Config render failed. Check models.yaml syntax."
ok "Configs rendered (litellm/config.yaml + ollama/init-models.sh)"

# ── Step 7: Validate docker-compose ──────────────────────────────────────────
step "7/9  Validating docker-compose.yml"

docker compose config --quiet 2>&1 || fatal "docker-compose.yml is invalid. Check the file."
ok "docker-compose.yml is valid"

if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  ok "Dry-run complete — all checks passed. Remove --dry-run to start containers."
  exit 0
fi

# ── Step 8: Host Ollama + model pull + LiteLLM Docker ────────────────────────
step "8/9  Ollama (host) + LiteLLM (Docker)"

# Install and configure Ollama as a host systemd service for direct GPU access
install_ollama_host
start_ollama_service

# Pull models in background — qwen3.6:27b is 17 GB, don't block the deploy
if [[ -f ollama/init-models.sh ]]; then
  info "Pulling models in background (log: /tmp/ollama-model-pull.log)"
  nohup bash ollama/init-models.sh > /tmp/ollama-model-pull.log 2>&1 &
  ok "Model pull started — check with: ollama list"
fi

# Stop any leftover ollama Docker containers (we now run ollama on the host)
docker compose stop ollama ollama-init 2>/dev/null || true
docker compose rm -f ollama ollama-init 2>/dev/null || true

# Pull and start LiteLLM
info "Pulling LiteLLM image..."
retry 3 docker compose pull --quiet 2>/dev/null || \
  warn "Image pull had issues — continuing with cached image"
docker compose up -d --remove-orphans
ok "LiteLLM container started"

step "9/9  Health check & auto-fix"
# ── Wait for health (with auto-fix on failure) ────────────────────────────────

get_unhealthy() {
  docker compose ps --format json 2>/dev/null \
    | python3 -c "
import sys, json
lines = sys.stdin.read().strip()
if not lines:
    sys.exit(0)
try:
    services = json.loads(lines)
except Exception:
    services = [json.loads(l) for l in lines.splitlines() if l.strip()]
names = [
    s.get('Service', s.get('Name','?'))
    for s in services
    if s.get('Health','') not in ('healthy','')
    and 'init' not in s.get('Name','').lower()
]
print('\n'.join(names))
" 2>/dev/null || true
}

wait_for_healthy() {
  local label="$1" timeout="$2" interval=10 elapsed=0
  echo ""
  info "$label (timeout: ${timeout}s)"
  while [[ $elapsed -lt $timeout ]]; do
    local unhealthy
    unhealthy=$(get_unhealthy)
    if [[ -z "$unhealthy" ]]; then
      ok "All services healthy"
      return 0
    fi
    info "  [${elapsed}s] waiting on: $(echo "$unhealthy" | tr '\n' ' ')"
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  return 1
}

if ! wait_for_healthy "Waiting for services to become healthy" 300; then
  if [[ $AUTO_FIX -eq 1 ]]; then
    warn "Services not healthy after 5 min — auto-fixing..."

    unhealthy_svcs=$(get_unhealthy)
    if [[ -n "$unhealthy_svcs" ]]; then
      while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        echo ""
        warn "  ── Fixing: ${svc} ──"
        info "  Last 30 log lines:"
        docker compose logs --tail=30 "$svc" 2>/dev/null | sed 's/^/    │ /' || true
        fixing "  Restarting ${svc}..."
        docker compose restart "$svc" 2>/dev/null || true
      done <<< "$unhealthy_svcs"
    fi

    # Second chance: wait up to 3 more minutes
    if ! wait_for_healthy "Waiting again after fix" 180; then
      warn "Still not fully healthy after fix attempt."
      warn "Run: ./manage.sh doctor   for full diagnostics"
      warn "Run: ./manage.sh logs <service>   to inspect logs"
    fi
  else
    warn "Services not healthy after 5 min.\n  Run: ./manage.sh doctor"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║             Stack is up!                            ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  LiteLLM API  →  http://<server>:8080/v1           ║"
echo "║  LiteLLM UI   →  http://<server>:8080/ui           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Watch model pull:  tail -f /tmp/ollama-model-pull.log"
echo "  List models:       ollama list"
echo "  Health check:      ./manage.sh doctor"
echo "  Add a model:       ./manage.sh add-model"
echo ""

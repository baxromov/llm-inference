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

# Add the official NVIDIA CUDA apt repo (developer.download.nvidia.com).
# This is separate from the nvidia-container-toolkit repo and provides
# libcuda1-<version> and cuda-drivers packages.
add_cuda_apt_repo() {
  local arch; arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
  local os_id; os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-ubuntu}")
  local codename; codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-jammy}")

  # Map distro+codename → NVIDIA CUDA repo identifier.
  # Debian Trixie (13/testing) and Sid have no dedicated repo — use debian12.
  local repo_id
  case "${os_id}:${codename}" in
    ubuntu:noble)            repo_id="ubuntu2404" ;;
    ubuntu:jammy)            repo_id="ubuntu2204" ;;
    ubuntu:focal)            repo_id="ubuntu2004" ;;
    debian:bookworm)         repo_id="debian12"   ;;
    debian:trixie|debian:sid|debian:*) repo_id="debian12" ;;
    *)                       repo_id="ubuntu2204" ;;  # safe fallback
  esac

  if dpkg -l cuda-keyring 2>/dev/null | grep -q "^ii"; then
    return 0  # already added
  fi

  fixing "Adding NVIDIA CUDA apt repository (${repo_id}/${arch})..."
  local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_id}/${arch}/cuda-keyring_1.1-1_all.deb"
  if wget -q -O /tmp/cuda-keyring.deb "$keyring_url" 2>/dev/null \
     && $SUDO dpkg -i /tmp/cuda-keyring.deb 2>/dev/null; then
    rm -f /tmp/cuda-keyring.deb
    ok "CUDA apt repo added (${repo_id})"
  else
    rm -f /tmp/cuda-keyring.deb
    warn "Could not add CUDA apt repo (URL: ${keyring_url})"
    return 1
  fi
}

# Refresh the GPG key for the nvidia-container-toolkit repo if it is expired/missing.
# Symptom: "Missing key C95B321B61E88C1809C4F759DDCAE044F796ECB0" in apt-get update output.
fix_nvidia_container_toolkit_key() {
  local key_file="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  if [[ ! -f "$key_file" ]]; then
    return 0  # repo not configured here — skip
  fi
  local update_out
  update_out=$($SUDO apt-get update 2>&1 || true)
  if echo "$update_out" | grep -q "nvidia.github.io.*Missing key\|nvidia.github.io.*NO_PUBKEY"; then
    fixing "Refreshing expired NVIDIA container-toolkit repo GPG key..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
      $SUDO gpg --dearmor -o "$key_file" --yes 2>/dev/null
    ok "NVIDIA container-toolkit repo key refreshed"
  fi
}

# Ensure libcuda.so.1 (CUDA driver bridge) exists on the host.
# Without it, nvidia-container-toolkit can't inject CUDA compute into containers
# even when runtime: nvidia is set — nvidia-smi shows "CUDA Version: N/A" and
# Ollama reports "no compatible GPUs were discovered".
check_and_fix_cuda_libraries() {
  # 1. Already in ldconfig cache — ideal
  if ldconfig -p 2>/dev/null | grep -q "libcuda.so.1"; then
    ok "CUDA driver library (libcuda.so.1) found on host"
    return 0
  fi

  # 2. Exists on disk but not in ldconfig — just refresh the cache
  local libcuda_path
  libcuda_path=$(find /usr /opt /run -name "libcuda.so.1" 2>/dev/null | head -1)
  if [[ -n "$libcuda_path" ]]; then
    local libcuda_dir; libcuda_dir=$(dirname "$libcuda_path")
    warn "libcuda.so.1 found at ${libcuda_path} but missing from ldconfig cache"
    if [[ $AUTO_FIX -eq 1 ]]; then
      fixing "Adding ${libcuda_dir} to /etc/ld.so.conf.d/nvidia-cuda.conf..."
      echo "$libcuda_dir" | $SUDO tee /etc/ld.so.conf.d/nvidia-cuda.conf >/dev/null
      $SUDO ldconfig
      ok "libcuda.so.1 registered in ldconfig"
      LIBCUDA_JUST_INSTALLED=1
    fi
    return 0
  fi

  # 3. Completely missing — try to install the driver userspace package
  warn "libcuda.so.1 NOT found on host — CUDA compute won't work in containers"
  warn "This is why Ollama logs 'no compatible GPUs were discovered'"

  if [[ $AUTO_FIX -eq 0 ]]; then
    fatal "libcuda.so.1 missing.\n  Fix: sudo apt-get install -y cuda-drivers\n  Then re-run ./deploy.sh"
  fi

  local driver_major
  driver_major=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
    | head -1 | cut -d. -f1)

  fixing "Installing CUDA driver userspace libraries (driver: ${driver_major})..."

  if [[ "$PKG_MGR" == "apt" ]]; then
    # Fix any expired GPG keys before running apt-get update
    fix_nvidia_container_toolkit_key
    $SUDO apt-get update -qq 2>/dev/null || true

    # Pass 1: try from already-configured repos (Debian non-free often has libcuda1)
    if $SUDO apt-get install -y -qq "libcuda1" 2>/dev/null \
       || $SUDO apt-get install -y -qq "libcuda1-${driver_major}" 2>/dev/null; then
      $SUDO ldconfig
      if ldconfig -p 2>/dev/null | grep -q "libcuda.so.1"; then
        ok "libcuda.so.1 installed from existing repos"
        return 0
      fi
    fi

    # Pass 2: add NVIDIA CUDA apt repo and retry
    add_cuda_apt_repo
    $SUDO apt-get update -qq 2>/dev/null || true

    $SUDO apt-get install -y -qq "libcuda1-${driver_major}" 2>/dev/null \
    || $SUDO apt-get install -y -qq "libcuda1" 2>/dev/null \
    || $SUDO apt-get install -y -qq "cuda-drivers-${driver_major}" 2>/dev/null \
    || $SUDO apt-get install -y -qq cuda-drivers 2>/dev/null \
    || {
      warn "Auto-install failed. Manual steps to fix on this server:"
      warn "  arch=\$(dpkg --print-architecture)"
      warn "  wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/\${arch}/cuda-keyring_1.1-1_all.deb"
      warn "  sudo dpkg -i cuda-keyring_1.1-1_all.deb"
      warn "  sudo apt-get update && sudo apt-get install -y libcuda1-${driver_major}"
      warn "  Then re-run ./deploy.sh"
      return 1
    }
    $SUDO ldconfig
    if ldconfig -p 2>/dev/null | grep -q "libcuda.so.1"; then
      ok "libcuda.so.1 installed and registered"
      LIBCUDA_JUST_INSTALLED=1
    else
      warn "Package installed but libcuda.so.1 still not in ldconfig — CUDA may still fail"
    fi
  else
    warn "Non-apt system: install CUDA driver libraries manually, then re-run."
    return 1
  fi
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

  # nvidia-container-toolkit
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    if [[ $AUTO_FIX -eq 1 ]]; then
      install_nvidia_toolkit
    else
      fatal "nvidia-container-toolkit not found.\n  See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
    fi
  else
    ok "nvidia-container-toolkit $(nvidia-ctk --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo 'found')"
  fi

  # nvidia runtime in Docker
  if ! docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
    if [[ $AUTO_FIX -eq 1 ]]; then
      configure_nvidia_runtime
    else
      fatal "nvidia runtime not in Docker.\n  Fix: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
    fi
  else
    ok "nvidia runtime registered in Docker"
  fi

  # Final confirmation: nvidia must appear in docker info runtimes
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    ok "nvidia runtime confirmed in Docker"
  else
    if [[ $AUTO_FIX -eq 1 ]]; then
      warn "nvidia runtime still missing after configure — retrying..."
      configure_nvidia_runtime
    else
      warn "nvidia runtime not confirmed. Continuing — monitor ollama container startup."
    fi
  fi

  # CUDA compute libraries — must exist on host so the toolkit can inject them
  # into containers. Without this, nvidia-smi works but CUDA does not.
  check_and_fix_cuda_libraries
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

# ── Step 8: Deploy ────────────────────────────────────────────────────────────
step "8/9  Starting services"

# Pull images first (retry up to 3 times)
info "Pulling Docker images..."
retry 3 docker compose pull --quiet 2>/dev/null || \
  warn "Image pull had issues — continuing with locally cached images"

# If libcuda was just installed this run, force-recreate GPU containers so the
# nvidia-container-toolkit injects CUDA libraries into a fresh container.
# (docker compose up -d won't recreate a running container unless config changed.)
if [[ $LIBCUDA_JUST_INSTALLED -eq 1 ]]; then
  fixing "libcuda installed this run — force-recreating ollama to pick up CUDA injection..."
  docker compose up -d --force-recreate ollama 2>/dev/null || true
  info "Waiting 15s for ollama to restart before starting dependents..."
  sleep 15
fi

# --wait makes compose block until all health checks pass before returning,
# which ensures dependent services (ollama-init, litellm) start in the right order.
docker compose up -d --remove-orphans --wait --wait-timeout 300 \
  || docker compose up -d --remove-orphans  # fallback for older compose versions
ok "Containers started"

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
echo "  Watch model pull:  docker compose logs -f ollama-init"
echo "  Health check:      ./manage.sh doctor"
echo "  Add a model:       ./manage.sh add-model"
echo ""

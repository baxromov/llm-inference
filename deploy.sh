#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — One-command deploy for the LLM Inference Stack
#
# Usage:
#   ./deploy.sh              full deploy (prereqs → env → render → models → up)
#   ./deploy.sh render       regenerate configs from models.yaml only
#   ./deploy.sh --no-gpu     skip GPU checks (dev/CI environment)
#   ./deploy.sh --dry-run    validate everything without starting containers
#   ./deploy.sh --no-models  skip HuggingFace model download step
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $1"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[--]${NC}  $1"; }
step() { echo ""; echo -e "${CYAN}▶ $1${NC}"; }

NO_GPU=0; DRY_RUN=0; NO_MODELS=0
for arg in "$@"; do
  case "$arg" in
    render)      step "Rendering configs from models.yaml"; python3 scripts/render-configs.py; exit 0 ;;
    --no-gpu)    NO_GPU=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --no-models) NO_MODELS=1 ;;
    -h|--help)
      sed -n '/^# Usage/,/^# ─/p' "$0" | grep -v '^#─' | sed 's/^# \?//'
      exit 0 ;;
    *) warn "Unknown argument: $arg" ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║        LLM Inference Stack — Deploy                 ║"
echo "╚══════════════════════════════════════════════════════╝"

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
step "Checking prerequisites"

command -v docker >/dev/null 2>&1 || err "Docker not found. Install Docker 24+."
ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"

command -v python3 >/dev/null 2>&1 || err "python3 not found."
ok "Python $(python3 --version | grep -oP '\d+\.\d+\.\d+')"

if ! python3 -c "import yaml" 2>/dev/null; then
  info "Installing PyYAML..."
  pip3 install pyyaml -q || err "Could not install PyYAML. Run: pip3 install pyyaml"
fi
ok "PyYAML available"

if [[ $NO_GPU -eq 0 ]]; then
  command -v nvidia-smi >/dev/null 2>&1 || err "nvidia-smi not found. Use --no-gpu to skip GPU checks."
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
  [[ "$GPU_COUNT" -ge 2 ]] || err "Expected 2 GPUs, found ${GPU_COUNT}. Use --no-gpu to skip."
  ok "Found ${GPU_COUNT} GPU(s):"
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/       /'
  docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia || \
    warn "nvidia runtime not detected in Docker. Ensure nvidia-container-toolkit is configured."
else
  warn "GPU checks skipped (--no-gpu)"
fi

# ── Step 2: Environment file ──────────────────────────────────────────────────
step "Configuring environment"

if [[ ! -f .env ]]; then
  info "No .env found — creating from .env.example and auto-generating secrets..."
  cp .env.example .env

  python3 - << 'PYEOF'
import subprocess, re

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
    if 'CHANGE_ME_run_openssl_rand_hex_32' in val:
        val = gen(32)
    elif val == 'lf-pk-CHANGE_ME':
        val = 'lf-pk-' + gen(24)
    elif val == 'lf-sk-CHANGE_ME':
        val = 'lf-sk-' + gen(24)
    elif val.startswith('sk-CHANGE_ME'):
        val = 'sk-' + gen(32)
    elif 'CHANGE_ME' in val:
        val = gen(16)
    lines.append(f"{key}={val}")

with open('.env', 'w') as f:
    f.write('\n'.join(lines))

print("  Secrets auto-generated. Review .env for org/admin settings before first deploy.")
PYEOF

  ok ".env created with auto-generated secrets"
  echo ""
  warn "Review .env now — update LANGFUSE_ADMIN_EMAIL, LANGFUSE_ADMIN_NAME, and org names if needed."
  warn "Then re-run: ./deploy.sh"
  echo ""
  exit 0
fi

if grep -q "CHANGE_ME" .env; then
  warn ".env still has unfilled CHANGE_ME placeholders:"
  grep "CHANGE_ME" .env | sed 's/^/  → /'
  err "Fill them in (use: openssl rand -hex 32) then re-run."
fi
ok ".env configured"

# ── Step 3: Render configs from models.yaml ───────────────────────────────────
step "Rendering configs from models.yaml"
python3 scripts/render-configs.py

# ── Step 4: Prometheus token ──────────────────────────────────────────────────
step "Writing Prometheus auth token"
LITELLM_MASTER_KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d'=' -f2-)
[[ -n "$LITELLM_MASTER_KEY" ]] || err "LITELLM_MASTER_KEY not found in .env"
echo -n "$LITELLM_MASTER_KEY" > prometheus/litellm_token
ok "prometheus/litellm_token written"

# ── Step 5: HuggingFace model files ──────────────────────────────────────────
step "Checking embedding / reranker model files"

if [[ $NO_MODELS -eq 1 ]]; then
  warn "Model download skipped (--no-models)"
else
  python3 - << 'PYEOF'
import sys, yaml, os, subprocess
from pathlib import Path

with open('models.yaml') as f:
    models = yaml.safe_load(f)

all_models = list(models.get('embedding', [])) + list(models.get('reranker', []))
missing = []

for m in all_models:
    local = Path('infinity/models') / m['hf_repo']
    if not local.exists() or not any(local.iterdir()):
        missing.append(m)

if not missing:
    print("  [OK]  All model files present")
    sys.exit(0)

print(f"  [!!]  {len(missing)} model(s) not found locally:")
for m in missing:
    print(f"         • {m['hf_repo']}")

if os.environ.get('HF_AUTO_DOWNLOAD', '0') == '1':
    # Resolve hf CLI: prefer system install, fall back to a local venv
    hf_cli = 'hf'
    try:
        subprocess.check_call([hf_cli, '--version'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        venv_dir = Path('.hf-venv')
        venv_cli = venv_dir / 'bin' / 'hf'
        if not venv_cli.exists():
            print("  hf CLI not found — creating local venv (.hf-venv) ...")
            try:
                subprocess.check_call([sys.executable, '-m', 'venv', str(venv_dir)])
            except subprocess.CalledProcessError:
                # python3-venv not installed (Debian/Ubuntu) — install it
                pkg = f"python3.{sys.version_info.minor}-venv"
                print(f"  python3-venv missing — running: apt install -y {pkg}")
                subprocess.check_call(['apt', 'install', '-y', pkg])
                subprocess.check_call([sys.executable, '-m', 'venv', str(venv_dir)])
            subprocess.check_call([str(venv_dir / 'bin' / 'pip'), 'install',
                                    'huggingface_hub', '-q'])
        hf_cli = str(venv_cli)

    for m in missing:
        dest = Path('infinity/models') / m['hf_repo']
        dest.mkdir(parents=True, exist_ok=True)
        print(f"  Downloading {m['hf_repo']} → {dest} ...")
        subprocess.check_call([
            hf_cli, 'download', m['hf_repo'],
            '--local-dir', str(dest)
        ])
    print("  [OK]  All models downloaded")
else:
    print("")
    print("  To download automatically, re-run:")
    print("    HF_AUTO_DOWNLOAD=1 ./deploy.sh")
    print("")
    print("  Or download manually:")
    for m in missing:
        dest = Path('infinity/models') / m['hf_repo']
        print(f"    hf download {m['hf_repo']} --local-dir {dest}")
    sys.exit(1)
PYEOF
fi

# ── Step 6: Validate docker-compose ──────────────────────────────────────────
step "Validating docker-compose.yml"
docker compose config --quiet && ok "docker-compose.yml is valid"

if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  ok "Dry-run complete — all checks passed. Remove --dry-run to start containers."
  exit 0
fi

# ── Step 7: Deploy ────────────────────────────────────────────────────────────
step "Starting all services"
docker compose up -d --remove-orphans
ok "All services started"

# ── Step 8: Wait and report ───────────────────────────────────────────────────
step "Waiting for core services to become healthy (up to 3 min)..."
timeout=180; elapsed=0; interval=10
while [[ $elapsed -lt $timeout ]]; do
  UNHEALTHY=$(docker compose ps --format json 2>/dev/null \
    | python3 -c "
import sys, json
lines = sys.stdin.read().strip()
# handle both array and newline-delimited JSON
try:
    services = json.loads(lines)
except json.JSONDecodeError:
    services = [json.loads(l) for l in lines.splitlines() if l.strip()]
unhealthy = [s.get('Name','?') for s in services
             if s.get('Health','') not in ('healthy','') and 'init' not in s.get('Name','')]
print('\n'.join(unhealthy))
" 2>/dev/null || true)

  if [[ -z "$UNHEALTHY" ]]; then
    ok "All services healthy"
    break
  fi
  info "Waiting... (${elapsed}s) still starting: $(echo "$UNHEALTHY" | tr '\n' ' ')"
  sleep $interval
  elapsed=$((elapsed + interval))
done

if [[ $elapsed -ge $timeout ]]; then
  warn "Timed out waiting. Check status with: ./manage.sh doctor"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║             Stack is up!                            ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  LiteLLM API  →  http://<server>:4000/v1           ║"
echo "║  LiteLLM UI   →  http://<server>:4000/ui           ║"
echo "║  Grafana      →  http://<server>:3001              ║"
echo "║  Langfuse     →  ssh -L 3000:localhost:3000 <srv>  ║"
echo "║                  then http://localhost:3000          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Watch Ollama model pull:  docker compose logs -f ollama-init"
echo "  Health check:             ./manage.sh doctor"
echo "  Add a model:              ./manage.sh add-model"
echo ""

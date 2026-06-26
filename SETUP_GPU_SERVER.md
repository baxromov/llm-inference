# GPU Server Setup Guide — `gpusrv02` (2× A100 SXM4 80GB)

**Server:** `gpusrv02` · IP: `172.31.230.3`  
**OS:** Debian GNU/Linux **Trixie (13)** — Proxmox VE **9.2.3** (`pveversion`)  
**Kernel:** `7.0.6-2-pve` (custom Proxmox kernel)  
**Hardware:** 2× NVIDIA A100 SXM4 80GB via NVSwitch (NVLink)  
**Goal:** Fresh server → full LLM inference stack running

> **Important:** This is PVE 9 / Debian Trixie — do NOT add Debian Bullseye (11) or Bookworm (12) repos.
> Mixing versions causes libglvnd dependency conflicts. Use Trixie repos + NVIDIA's own CUDA repo.

---

## Table of Contents

1. [Connect to the Server](#1-connect-to-the-server)
2. [Install NVIDIA Drivers](#2-install-nvidia-drivers)
3. [Install CUDA Toolkit](#3-install-cuda-toolkit)
4. [Install Docker](#4-install-docker)
5. [Install nvidia-container-toolkit](#5-install-nvidia-container-toolkit)
6. [Verify GPU + Docker](#6-verify-gpu--docker)
7. [Clone the Repository](#7-clone-the-repository)
8. [Configure Environment](#8-configure-environment)
9. [Download Embedding / Reranker Models](#9-download-embedding--reranker-models)
10. [Deploy the Stack](#10-deploy-the-stack)
11. [Verify Everything is Working](#11-verify-everything-is-working)
12. [Firewall / Network](#12-firewall--network)
13. [Troubleshooting](#13-troubleshooting)
14. [Going Fully Offline (On-Premise)](#14-going-fully-offline-on-premise-no-internet)

---

## 1. Connect to the Server

```bash
ssh root@172.31.230.3
```

Confirm you are on the right machine:

```bash
hostname        # gpusrv02
uname -r        # 7.0.6-2-pve  (Proxmox VE kernel)
lspci | grep -i nvidia
# expected:
#   0b:00.0 3D controller: NVIDIA Corporation GA100 [A100 SXM4 80GB]
#   48:00.0 3D controller: NVIDIA Corporation GA100 [A100 SXM4 80GB]
```

---

## 2. Install NVIDIA Drivers

> **Do you need CUDA on the host?** No. Docker containers (Ollama, Infinity) carry their own
> CUDA runtime inside the image. The host only needs:
> 1. The **NVIDIA kernel driver** (so the OS can talk to the GPU hardware)
> 2. **nvidia-container-toolkit** (so Docker can pass GPUs into containers)
> That's it. No CUDA toolkit, no nvcc needed on the host.

> **PVE 9 / Debian Trixie specific issues encountered:**
> - `nvidia-driver` from Debian repos → `libglvnd0` version conflict (fixed by using Trixie repos)
> - NVIDIA CUDA apt repo → SHA1 signature rejected by Trixie's sqv since 2026-02-01
>
> **Solution:** Use NVIDIA's `.run` installer — bypasses apt and the SHA1/sqv issue entirely.
> This is also NVIDIA's recommended approach for servers with custom kernels (like PVE).

### 2a. Fix sources.list — use Trixie repos only

```bash
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

# Proxmox repo stays untouched in /etc/apt/sources.list.d/
apt update
```

### 2b. Install PVE kernel headers and build tools

```bash
# 'pve-headers-*' is an alias — apt resolves it to 'proxmox-headers-*' automatically
apt install -y pve-headers-$(uname -r) build-essential dkms
```

### 2c. Disable Nouveau (before installing NVIDIA driver)

```bash
echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist-nouveau.conf
update-initramfs -u
```

### 2d. Download and run the NVIDIA driver installer

> Use the **Data Center / Tesla** driver for A100 (not GeForce).
> Check the latest version at: https://www.nvidia.com/en-us/drivers/unix/

```bash
cd /tmp

# Tesla/Data Center driver 570.x — current recommended for A100
wget https://us.download.nvidia.com/tesla/570.133.07/NVIDIA-Linux-x86_64-570.133.07.run
chmod +x NVIDIA-Linux-x86_64-570.133.07.run

# Install: headless (no X11), silent, register with DKMS so it survives kernel updates
./NVIDIA-Linux-x86_64-570.133.07.run \
  --no-x-check \
  --no-opengl-files \
  --silent \
  --dkms
```

> `--dkms` registers the module with DKMS so it automatically recompiles after kernel updates.
> `--no-opengl-files` skips X11/OpenGL (not needed on a headless GPU server).
> Takes ~5 minutes to compile the kernel module.

### 2e. Reboot

```bash
reboot
```

### 2f. Verify

```bash
nvidia-smi
```

Expected output:
```
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 570.133.07  Driver Version: 570.133.07  CUDA Version: 12.x      |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC|
|   0  A100 SXM4 80GB Off      | 00000000:0B:00.0 Off |                  Off |
|   1  A100 SXM4 80GB Off      | 00000000:48:00.0 Off |                  Off |
+-----------------------------------------------------------------------------+
```

Check DKMS module is registered (important for surviving kernel updates):
```bash
dkms status
# expected: nvidia/570.133.07, 7.0.6-2-pve, x86_64: installed
```

---

## 3. CUDA Toolkit (Optional — not needed for Docker inference)

The CUDA toolkit (`nvcc`, etc.) is **not required** for running the LLM inference stack.
Docker containers carry their own CUDA runtime. Skip this section unless you need host-level
CUDA tools for debugging.

If you do want it for development/debugging:

```bash
# Download CUDA toolkit .run installer (avoid apt due to SHA1/sqv issue on Trixie)
cd /tmp
wget https://developer.download.nvidia.com/compute/cuda/12.6.0/local_installers/cuda_12.6.0_560.28.03_linux.run
chmod +x cuda_12.6.0_560.28.03_linux.run

# Install toolkit only — driver is already installed
./cuda_12.6.0_560.28.03_linux.run --silent --toolkit --no-drm

echo 'export PATH=/usr/local/cuda/bin:$PATH' >> /root/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /root/.bashrc
source /root/.bashrc

nvcc --version
```

---

## 4. Install Docker

```bash
# Install dependencies
apt install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repo
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable and start Docker
systemctl enable docker
systemctl start docker
```

Verify:

```bash
docker --version              # Docker version 24+
docker compose version        # Docker Compose version 2+
```

---

## 5. Install nvidia-container-toolkit

This allows Docker containers to access the NVIDIA GPUs.

> The nvidia-container-toolkit apt repo may also fail signature verification on Trixie (same SHA1 issue).
> Use `[trusted=yes]` to bypass — acceptable on a controlled on-prem server.

```bash
# Add NVIDIA container toolkit repo with trusted=yes (bypasses SHA1/sqv issue on Trixie)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [trusted=yes] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update
apt install -y nvidia-container-toolkit

# Configure Docker to use nvidia runtime
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
```

---

## 6. Verify GPU + Docker

Run a quick GPU test inside a container:

```bash
docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi
```

Expected: same `nvidia-smi` output as on host, showing both A100s.

Test NVLink (both GPUs see each other at high bandwidth):

```bash
docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 \
  nvidia-smi topo -m
```

Expected: `NV*` entries between GPU0 and GPU1 (NVLink — not PCIe).

---

## 7. Clone the Repository

```bash
# Install git if not present
apt install -y git python3 python3-pip

# Clone
cd /opt
git clone git@github.com:baxromov/llm-inference.git
cd llm-inference
```

> If you don't have SSH key set up on this server, use HTTPS:
> ```bash
> git clone https://github.com/baxromov/llm-inference.git
> ```

---

## 8. Configure Environment

```bash
cd /opt/llm-inference
```

Run `deploy.sh` once — it will auto-generate `.env` from `.env.example` and exit:

```bash
./deploy.sh
```

After that, open `.env` and update these values (everything else is auto-generated):

```bash
nano .env
```

| Variable | What to set |
|---|---|
| `LANGFUSE_ADMIN_EMAIL` | Your admin email |
| `LANGFUSE_ADMIN_NAME` | Your name |
| `LANGFUSE_INIT_ORG_NAME` | Your organization name |
| `LANGFUSE_INIT_PROJECT_NAME` | Your project name |
| `LITELLM_UI_USERNAME` | LiteLLM UI login username |
| `LITELLM_UI_PASSWORD` | LiteLLM UI login password |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password |

All crypto secrets (`LANGFUSE_SALT`, `LANGFUSE_ENCRYPTION_KEY`, etc.) are auto-generated — leave them as-is.

---

## 9. Download Embedding / Reranker Models

These models run in the **Infinity** container. They must be downloaded to the host first (Infinity runs offline, no internet access inside container).

```bash
pip3 install huggingface-hub

cd /opt/llm-inference

# Download embedding model (~570 MB)
huggingface-cli download BAAI/bge-m3 \
  --local-dir infinity/models/BAAI/bge-m3

# Download reranker model (~570 MB)
huggingface-cli download BAAI/bge-reranker-v2-m3 \
  --local-dir infinity/models/BAAI/bge-reranker-v2-m3
```

> If HuggingFace is blocked, use `HF_ENDPOINT=https://hf-mirror.com` prefix.
>
> Or use the auto-download flag:
> ```bash
> HF_AUTO_DOWNLOAD=1 ./deploy.sh
> ```

Verify files are present:

```bash
ls infinity/models/BAAI/bge-m3/           # should show model files
ls infinity/models/BAAI/bge-reranker-v2-m3/
```

---

## 10. Deploy the Stack

```bash
cd /opt/llm-inference
./deploy.sh
```

This single command:
1. Checks Docker + NVIDIA GPU availability
2. Validates `.env` (no CHANGE_ME placeholders)
3. Renders `litellm/config.yaml`, `ollama/init-models.sh`, `infinity/entrypoint.sh` from `models.yaml`
4. Starts all 12 services via `docker compose up -d`
5. Waits up to 3 minutes for all services to become healthy
6. Prints access URLs

Expected final output:

```
╔══════════════════════════════════════════════════════╗
║             Stack is up!                            ║
╠══════════════════════════════════════════════════════╣
║  LiteLLM API  →  http://172.31.230.3:4000/v1       ║
║  LiteLLM UI   →  http://172.31.230.3:4000/ui       ║
║  Grafana      →  http://172.31.230.3:3001           ║
║  Langfuse     →  ssh -L 3000:localhost:3000 gpusrv02║
║                  then http://localhost:3000           ║
╚══════════════════════════════════════════════════════╝
```

### Watch Ollama pull the chat model (first run only):

```bash
docker compose logs -f ollama-init
```

Ollama downloads **Qwen 3.6 27B (~17 GB)** on first start. This takes 5–15 minutes depending on network speed.

---

## 11. Verify Everything is Working

### Full health check:

```bash
./manage.sh doctor
```

### Check all containers are healthy:

```bash
docker compose ps
```

All services should show `healthy` (except `ollama-init` and `minio-init` which exit after setup).

### Test the LLM API:

```bash
# Replace sk-... with your LITELLM_MASTER_KEY from .env
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $(grep LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-27b",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "max_tokens": 50
  }'
```

### Test the embedding API:

```bash
curl http://localhost:4000/v1/embeddings \
  -H "Authorization: Bearer $(grep LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  -H "Content-Type: application/json" \
  -d '{"model": "text-embedding-3-large", "input": "Hello world"}'
```

### Check GPU utilization (should show load during inference):

```bash
watch -n1 nvidia-smi
```

### Open dashboards:

| Service | URL |
|---|---|
| LiteLLM API | `http://172.31.230.3:4000/v1` |
| LiteLLM UI | `http://172.31.230.3:4000/ui` |
| Grafana (GPU + LLM metrics) | `http://172.31.230.3:3001` |
| Langfuse (trace viewer) | SSH tunnel → `http://localhost:3000` |

**Langfuse SSH tunnel:**

```bash
# From your local machine:
ssh -L 3000:localhost:3000 root@172.31.230.3
# Then open http://localhost:3000 in browser
```

---

## 12. Firewall / Network

Open required ports on `gpusrv02`:

```bash
# Allow LiteLLM API (all clients need this)
iptables -A INPUT -p tcp --dport 4000 -j ACCEPT

# Allow Grafana
iptables -A INPUT -p tcp --dport 3001 -j ACCEPT

# Langfuse is localhost-only (SSH tunnel) — no firewall rule needed

# Save rules
apt install -y iptables-persistent
netfilter-persistent save
```

> If your network already uses Proxmox-managed firewall (PVE Firewall), add these rules in the Proxmox web UI under Datacenter → Firewall instead.

---

## 13. Troubleshooting

### `nvidia-driver` install fails with `libglvnd0` conflict

This happens when Debian Bullseye (11) repos are mixed into a Trixie (13) system.
Fix: switch to Trixie repos and use NVIDIA's own CUDA repo:

```bash
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
apt update

wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt update
apt install -y cuda-drivers
```

### NVIDIA apt repo rejected: `SHA1 is not considered secure` (Trixie sqv policy)

Debian Trixie's Sequoia PGP (`sqv`) rejects SHA1-signed repos since 2026-02-01.
Both NVIDIA's CUDA repo and container toolkit repo are affected. **Solution: use `.run` installer.**

```bash
# For NVIDIA driver — use .run installer (Section 2d above)
cd /tmp
wget https://us.download.nvidia.com/tesla/570.133.07/NVIDIA-Linux-x86_64-570.133.07.run
chmod +x NVIDIA-Linux-x86_64-570.133.07.run
./NVIDIA-Linux-x86_64-570.133.07.run --no-x-check --no-opengl-files --silent --dkms

# For nvidia-container-toolkit — add repo with [trusted=yes] to skip verification
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [trusted=yes] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt update
apt install -y nvidia-container-toolkit
```

### `nvidia-smi: command not found` after reboot

```bash
# Check if DKMS module compiled successfully
dkms status

# Check if module is loaded
lsmod | grep nvidia

# If not loaded — re-run the .run installer
cd /tmp
./NVIDIA-Linux-x86_64-570.133.07.run --no-x-check --no-opengl-files --silent --dkms
reboot
```

### `nvidia runtime not detected in Docker`

```bash
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
# Verify
docker info | grep -i runtime
```

### Container can't see GPUs

```bash
# Test directly
docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi

# If it fails, check containerd
systemctl restart containerd docker
```

### Ollama init is stuck / failing

```bash
# Check logs
docker compose logs ollama-init

# Check if Ollama itself is healthy
docker compose logs ollama | tail -20

# Restart just the init
docker compose restart ollama-init
```

### Infinity model not found

```bash
# Check model files exist
ls -lh infinity/models/BAAI/bge-m3/

# If empty, re-download
huggingface-cli download BAAI/bge-m3 --local-dir infinity/models/BAAI/bge-m3
docker compose restart infinity
```

### LiteLLM can't connect to Ollama

```bash
# Both are on the same internal Docker network — check Ollama is healthy
docker compose ps ollama

# Check LiteLLM logs
docker compose logs litellm | tail -30
```

### Out of disk space for model files

```bash
df -h /
# Docker images + Ollama models + HF models take ~80–100 GB total
# Make sure /opt or wherever you cloned has enough space
```

### Full reset (nuclear option)

```bash
docker compose down -v      # stops all containers AND deletes volumes (data loss!)
docker system prune -af     # removes all images and build cache
./deploy.sh                 # fresh deploy
```

---

## 14. Going Fully Offline (On-Premise, No Internet)

After everything is installed and working with internet, the server can be cut off completely.
All services run from local Docker images and local model files — nothing phones home.

### Before cutting the internet — pre-pull everything:

#### 14a. Pull all Docker images

```bash
cd /opt/llm-inference

# Pull every image referenced in docker-compose.yml
docker compose pull

# Verify all images are cached locally
docker images
```

#### 14b. Pull the Ollama chat model

```bash
# Start Ollama and pull the model manually
docker compose up -d ollama
docker compose logs -f ollama-init   # wait for it to finish pulling

# Or pull manually:
docker exec ollama ollama pull qwen3.6:27b
```

#### 14c. Download HuggingFace embedding + reranker models

```bash
pip3 install huggingface-hub

HF_AUTO_DOWNLOAD=1 ./deploy.sh

# Or manually:
huggingface-cli download BAAI/bge-m3 --local-dir infinity/models/BAAI/bge-m3
huggingface-cli download BAAI/bge-reranker-v2-m3 --local-dir infinity/models/BAAI/bge-reranker-v2-m3
```

#### 14d. Save Docker images to disk (optional, for disaster recovery)

```bash
mkdir -p /opt/docker-images

docker save ollama/ollama:0.6.5           | gzip > /opt/docker-images/ollama.tar.gz
docker save michaelf34/infinity:0.0.72    | gzip > /opt/docker-images/infinity.tar.gz
docker save ghcr.io/berriai/litellm:main-v1.57.0-stable | gzip > /opt/docker-images/litellm.tar.gz
docker save langfuse/langfuse:3.35.0      | gzip > /opt/docker-images/langfuse-web.tar.gz
docker save langfuse/langfuse-worker:3.35.0 | gzip > /opt/docker-images/langfuse-worker.tar.gz
docker save postgres:16-alpine            | gzip > /opt/docker-images/postgres.tar.gz
docker save clickhouse/clickhouse-server:24.8-alpine | gzip > /opt/docker-images/clickhouse.tar.gz
docker save redis:7.2-alpine              | gzip > /opt/docker-images/redis.tar.gz
docker save minio/minio:RELEASE.2024-11-07T00-52-20Z | gzip > /opt/docker-images/minio.tar.gz
docker save prom/prometheus:v2.53.0       | gzip > /opt/docker-images/prometheus.tar.gz
docker save grafana/grafana:11.0.0        | gzip > /opt/docker-images/grafana.tar.gz
docker save nvcr.io/nvidia/k8s/dcgm-exporter:3.3.6-3.4.2-ubuntu22.04 | gzip > /opt/docker-images/dcgm.tar.gz

echo "All images saved to /opt/docker-images/"
ls -lh /opt/docker-images/
```

To restore from saved images (after full reset or on a new server):
```bash
for f in /opt/docker-images/*.tar.gz; do
  echo "Loading $f..."
  docker load < "$f"
done
```

#### 14e. Disable outbound internet (verify stack still works)

```bash
# Test: block outbound, ensure everything still runs
iptables -A OUTPUT -m state --state NEW -j DROP

# Run health check
./manage.sh doctor

# Test API
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $(grep LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3.6-27b", "messages": [{"role": "user", "content": "hello"}], "max_tokens": 20}'

# If everything works, the DROP rule is fine to keep permanently
# To remove the test rule:
iptables -D OUTPUT -m state --state NEW -j DROP
```

### What works offline:

| Component | Offline-safe? | Notes |
|---|---|---|
| Ollama (LLM) | Yes | Model cached in Docker volume |
| Infinity (embeddings) | Yes | Models in `infinity/models/` on disk |
| LiteLLM API | Yes | No external calls |
| Langfuse | Yes | Fully self-hosted |
| Grafana / Prometheus | Yes | No telemetry (disabled in config) |
| DCGM Exporter | Yes | Host GPU only |
| Docker images | Yes | Pre-pulled and cached |

### What requires internet only once (during setup):

- NVIDIA driver install (`apt install cuda-drivers`)
- Docker install
- `docker compose pull` (image downloads)
- `huggingface-cli download` (model downloads)
- `pip3 install huggingface-hub` (one-time tool)

Once installed, **zero internet needed** for normal operation.

---

## GPU Allocation Summary

| Service | GPUs | VRAM Used |
|---|---|---|
| Ollama (Qwen 3.6 27B) | GPU 0 + GPU 1 | ~17 GB split across both |
| Infinity (embeddings + reranker) | GPU 1 | ~3.5 GB |
| DCGM Exporter (monitoring) | Both (read-only) | 0 |
| **Total available** | **2× A100 80GB = 160 GB** | **~20 GB used** |

> With 140+ GB free VRAM you can add much larger models (70B, 72B, even 405B quantized).  
> To add a model, edit `models.yaml` and run `./manage.sh apply-models`.

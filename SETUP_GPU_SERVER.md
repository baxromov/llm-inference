# GPU Server Setup Guide — `gpusrv02` (2× A100 SXM4 80GB)

**Server:** `gpusrv02` · IP: `172.31.230.3`  
**OS:** Debian GNU/Linux (Proxmox VE 7 kernel)  
**Hardware:** 2× NVIDIA A100 SXM4 80GB via NVSwitch (NVLink)  
**Goal:** Fresh server → full LLM inference stack running

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

> **Note:** This is a Proxmox VE host. You must use `pve-headers` (not generic linux-headers) and add the `non-free` and `non-free-firmware` apt repos.

### 2a. Add non-free repos

```bash
# Edit /etc/apt/sources.list
cat > /etc/apt/sources.list << 'EOF'
deb http://ftp.debian.org/debian bullseye main contrib non-free non-free-firmware
deb http://ftp.debian.org/debian bullseye-updates main contrib non-free non-free-firmware
deb http://security.debian.org bullseye-security main contrib non-free non-free-firmware
EOF

# Also keep Proxmox repos (don't overwrite /etc/apt/sources.list.d/)
apt update
```

### 2b. Install kernel headers for PVE kernel

```bash
apt install -y pve-headers-$(uname -r)
```

### 2c. Install NVIDIA driver

```bash
apt install -y nvidia-driver firmware-misc-nonfree
```

> This takes 3–5 minutes — it compiles the kernel module.

### 2d. Disable Nouveau (open-source GPU driver that conflicts with NVIDIA)

```bash
echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist-nouveau.conf
update-initramfs -u
```

### 2e. Reboot

```bash
reboot
```

### 2f. Verify drivers loaded

```bash
nvidia-smi
```

Expected output:
```
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 525.xx   Driver Version: 525.xx   CUDA Version: 12.x            |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC|
|   0  A100 SXM4 80GB Off      | 00000000:0B:00.0 Off |                  Off |
|   1  A100 SXM4 80GB Off      | 00000000:48:00.0 Off |                  Off |
+-----------------------------------------------------------------------------+
```

---

## 3. Install CUDA Toolkit

Docker containers carry their own CUDA libraries, so you only need the host driver (already installed above). However, install the CUDA toolkit for any host-level tools or direct testing:

```bash
# Add NVIDIA CUDA repo for Debian 11
wget https://developer.download.nvidia.com/compute/cuda/repos/debian11/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt update

# Install CUDA 12.x (just toolkit, driver already installed)
apt install -y cuda-toolkit-12-3
```

Add to PATH:

```bash
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> /root/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /root/.bashrc
source /root/.bashrc
```

Verify:

```bash
nvcc --version   # CUDA compiler version
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

```bash
# Add NVIDIA container toolkit repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
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

### `nvidia-smi: command not found` after reboot

```bash
# Check if module is loaded
lsmod | grep nvidia

# If not loaded, reinstall
apt install --reinstall nvidia-driver
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

## GPU Allocation Summary

| Service | GPUs | VRAM Used |
|---|---|---|
| Ollama (Qwen 3.6 27B) | GPU 0 + GPU 1 | ~17 GB split across both |
| Infinity (embeddings + reranker) | GPU 1 | ~3.5 GB |
| DCGM Exporter (monitoring) | Both (read-only) | 0 |
| **Total available** | **2× A100 80GB = 160 GB** | **~20 GB used** |

> With 140+ GB free VRAM you can add much larger models (70B, 72B, even 405B quantized).  
> To add a model, edit `models.yaml` and run `./manage.sh apply-models`.

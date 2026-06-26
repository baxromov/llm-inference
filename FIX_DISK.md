# Fix: Move Docker to NVMe (no space left on device)

**Muammo:** `/dev/sda2` root disk 46GB, 93% to'la. Docker uchun joy yo'q.  
**Yechim:** Bo'sh `nvme0n1` (2.9TB) diskni ishlatish.

---

## Buyruqlar (ketma-ket bajaring)

```bash
# 1. NVMe-ni format qilish va mount qilish
mkfs.ext4 /dev/nvme0n1
mkdir -p /data
mount /dev/nvme0n1 /data
echo "/dev/nvme0n1 /data ext4 defaults 0 2" >> /etc/fstab

# 2. Docker va containerd-ni to'xtatish
systemctl stop docker containerd

# 3. Mavjud data-ni ko'chirish
mv /var/lib/containerd /data/containerd
mv /var/lib/docker /data/docker

# 4. Docker-ga yangi yo'lni ko'rsatish
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "data-root": "/data/docker"
}
EOF

# 5. Containerd-ga yangi yo'lni ko'rsatish
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's|/var/lib/containerd|/data/containerd|g' /etc/containerd/config.toml

# 6. Qayta ishga tushirish
systemctl start containerd docker

# 7. Tekshirish
docker info | grep "Docker Root Dir"
df -h /data

# 8. Eski to'liq docker cache-ni tozalash
docker system prune -af

# 9. Deploy
cd /opt/llm-inference
git pull
HF_AUTO_DOWNLOAD=1 ./deploy.sh
```

---

## Natija

| Disk | Hajm | Maqsad |
|---|---|---|
| `/dev/sda2` | 46 GB | OS, kod, config |
| `/dev/nvme0n1` → `/data` | 2.9 TB | Docker images, volumes, models |

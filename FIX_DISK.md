# Fix: Move Docker to NVMe (no space left on device)

**Muammo:** `/dev/sda2` root disk 46GB, 93% to'la. Docker uchun joy yo'q.  
**Yechim:** Bo'sh `nvme0n1` (2.9TB) diskni ishlatish — symlink orqali.

> **Eslatma:** Oldingi versiyada `containerd config.toml` o'zgartirish bor edi —
> bu xavfli va keraksiz. Symlink yondashuvi soddaroq va ishonchli.

---

## Nima bo'lyapti?

```
/var/lib/containerd  = 11 GB  ← Docker image-lar bu yerda (system containerd)
/var/lib/docker      = 240 KB ← deyarli bo'sh
```

Docker 29+ system containerd-ni image store sifatida ishlatadi.
Faqat `daemon.json data-root` o'zgartirish yetarli emas — image-lar hali ham
`/var/lib/containerd`-ga yoziladi. Symlink esa barcha yo'llarni avtomatik ko'chiradi.

---

## Buyruqlar (ketma-ket bajaring)

```bash
# 1. NVMe-ni format qilish va mount qilish
mkfs.ext4 /dev/nvme0n1
mkdir -p /data
mount /dev/nvme0n1 /data

# UUID bilan fstab (device nomi reboot-da o'zgarishi mumkin)
UUID=$(blkid -s UUID -o value /dev/nvme0n1)
echo "UUID=$UUID /data ext4 defaults 0 2" >> /etc/fstab

# 2. Docker va containerd-ni to'xtatish
systemctl stop docker containerd

# 3. Data-ni NVMe-ga ko'chirish
mv /var/lib/containerd /data/containerd
mv /var/lib/docker /data/docker

# 4. Symlink qo'yish (config o'zgartirish shart emas)
ln -s /data/containerd /var/lib/containerd
ln -s /data/docker /var/lib/docker

# 5. Qayta ishga tushirish
systemctl start containerd docker

# 6. Tekshirish
docker info | grep "Docker Root Dir"
ls -la /var/lib/containerd   # → /data/containerd ko'rinishi kerak
ls -la /var/lib/docker       # → /data/docker ko'rinishi kerak
df -h /data                  # 2.9TB bo'sh

# 7. Test: kichik image tortib ko'rish
docker pull hello-world && docker run --rm hello-world
# "Hello from Docker!" chiqishi kerak

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
| `/dev/sda2` → `/` | 46 GB | OS, kod, config, HF models |
| `/dev/nvme0n1` → `/data` | 2.9 TB | Docker images, volumes, Ollama models |

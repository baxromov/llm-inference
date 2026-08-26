# Fix: "Store Prompts in Spend Logs" o'zi o'chib qolyapti

**Muammo:** LiteLLM UI'da (Settings → General Settings) "Store Prompts in Spend Logs" ni yoqsangiz ham, keyingi `docker compose restart litellm`dan so'ng yana o'chib qolar edi.

**Sabab:** `store_model_in_db: true` bo'lgani uchun LiteLLM har start'da `litellm/config.yaml`dagi `general_settings` blokini o'qib, Postgres'dagi `LiteLLM_Config` jadvaliga **to'liq qayta yozadi** (UI orqali DB'ga qo'lda yozilgan qiymatni ham bosib o'tadi). Serverdagi `litellm/config.template.yaml` git bilan sinxronlanmay qolgan (mahalliy tahrirlangan, commit qilinmagan) va shu tahrirda `store_prompts_in_spend_logs: true` qatori tushib qolgan edi. Natijada:

```
UI'da yoqasiz → DB'ga yoziladi → restart → config.yaml (bu qatorsiz) DB'ni qayta bosib o'tadi → yana o'chiq
```

Ya'ni bu odatiy "UI bug'i" emas — **fayl → DB bir tomonlama sinxronizatsiya** xususiyati, va muammo fayl darajasida edi.

---

## Doimiy yechim

`litellm/config.template.yaml`dagi `general_settings`ga qo'shildi (config.yaml auto-generated bo'lgani uchun **shu faylni** tahrirlash kerak, config.yaml'ni emas):

```yaml
general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  store_model_in_db: true
  disable_error_logs: false
  store_prompts_in_spend_logs: true   # ← shu qator
  user_url_allowed_hosts:
    - "172.31.174.11"
    - "172.31.174.11:8123"
```

Qo'llash:

```bash
./deploy.sh render              # config.template.yaml + models.yaml → config.yaml
docker compose restart litellm
```

Tekshirish (DB'dagi haqiqiy qiymat, UI keshiga emas):

```bash
docker exec litellm-postgres psql -U litellm -d litellm -t \
  -c "SELECT param_value::json->>'store_prompts_in_spend_logs' FROM \"LiteLLM_Config\" WHERE param_name='general_settings';"
# → true
```

2026-07-27'da ikki marta ketma-ket restart qilib tasdiqlandi — `true` qiymati endi barqaror qolyapti.

---

## Eslatma — kelajakda qayta chiqmasligi uchun

- **`litellm/config.yaml`ni hech qachon qo'lda tahrirlamang** — u `config.template.yaml` + `models.yaml`dan avtomatik generatsiya qilinadi (`scripts/render-configs.py`), qo'lda qilingan tahrir keyingi `render`da yo'qoladi.
- Serverdagi (`/home/bakhromovshb/llm-inference`) working tree hozircha git bilan to'liq sinxron emas — `docker-compose.yml`, `models.yaml`, `litellm/config.template.yaml` va boshqalarda commit qilinmagan mahalliy o'zgarishlar bor. Xohlasangiz shularni ko'rib chiqib, kerakli qismlarini `git add` + commit qilib qo'yish tavsiya etiladi — aks holda bu xil "sozlama sababsiz o'chib qoladi" holatlari yana chiqishi mumkin.

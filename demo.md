# Kịch bản demo trên lớp (~25 phút)

Mọi lệnh chạy trong **Git Bash** tại `D:\LTDL-N13`. Thời gian trong ngoặc đo khi chạy thử ngày 30/9/2026.

## A. Chuẩn bị

**Hôm trước** (dựng lại từ đầu; `make clean` XÓA toàn bộ dữ liệu demo):

```bash
make clean && make up && make setup && make ingest && make train && make predict
```

Tập lại toàn bộ kịch bản một lần, nhất là mục 6c (Object Lock) — mục duy nhất chưa chạy thử.

**15 phút trước giờ demo:**

1. Bật Docker Desktop → `make up` → `docker compose ps`: 6 container Up/healthy.
2. Mở sẵn tab: MinIO A http://localhost:9001 · MinIO B http://localhost:9101 · MLflow http://localhost:5000
   (mật khẩu: `grep ROOT .env`).
3. Mở terminal Git Bash và chạy dòng dưới. **Bắt buộc có `MSYS_NO_PATHCONV=1`**: thiếu nó, Git Bash đổi
   `/d/...` thành `D:/...` và các lệnh `docker run` ở mục 5, 6b chạy sai mà **không báo lỗi**.

```bash
cd /d/LTDL-N13; export MSYS_NO_PATHCONV=1; set -a; source .env; set +a; unset TZ
alias mc='./bin/mc.exe --no-color'; IMG=python:3.12.12-alpine3.22   # image đã có sẵn, không cần mạng
```

## B. Kịch bản

### 1. Kiến trúc (3 phút)

- Mở `docs/architecture.md` bằng Preview của VS Code (sơ đồ mermaid).
- Ý chính: 2 site · MinIO 4 drive EC:2 · Site Replication hai chiều · Postgres backup 5 phút/lần.
- `docker compose ps`

### 2. Luồng ML (4 phút)

```bash
.venv/Scripts/python.exe app/ingest.py --last 3 --delay 1   # đẩy 3 lô mới
mc ls siteB/raw-data/weather/hanoi/2025/                     # đã sang site B
make train                                                   # rồi mở MLflow UI: run, metric, model
make predict
```

### 3. Replication (2 phút)

```bash
make status        # bucket/user/policy/ILM in sync; số object hai site bằng nhau
```

Đặt Console A và B cạnh nhau.

### 4. Versioning — cứu dữ liệu xóa nhầm (2 phút)

```bash
f=siteA/raw-data/weather/hanoi/2025/2025-12.csv
mc rm $f; mc ls siteB/raw-data/weather/hanoi/2025/    # lệnh xóa lan sang B: mất 2025-12.csv
mc ls --versions $f                                   # v1 PUT vẫn còn, v2 chỉ là delete marker
mc undo $f; mc ls siteB/raw-data/weather/hanoi/2025/  # khôi phục, B cũng có lại
```

Replication bất đồng bộ: nếu B chưa đổi, đợi 2–3 giây rồi `mc ls` lại.

Ý chính: **replication không thay được backup** — xóa nhầm cũng được nhân bản; versioning mới cứu được.

### 5. Erasure coding — mất 2/4 drive vẫn đọc được (2 phút)

```bash
O=raw-data/weather/hanoi/2025/2025-11.csv
ls_drives() { for d in 1 2 3 4; do echo "data$d: $(docker run --rm -v ltdl-dr_minio-a-data$d:/d:ro $IMG ls /d/$O 2>/dev/null)"; done; }
mc admin info siteA | grep EC                     # 4 drives online, EC:2
ls_drives                                         # cả 4 drive có xl.meta
for d in 1 2; do docker run --rm -v ltdl-dr_minio-a-data$d:/d $IMG rm -rf /d/$O; done
ls_drives                                         # data1, data2 trống
mc cat siteA/$O | head -3                         # vẫn đọc được
mc admin heal -r siteA/raw-data                   # Green 100%
ls_drives                                         # cả 4 drive có lại
```

Nếu thầy hỏi:
- Chỉ có `xl.meta` vì file nhỏ được MinIO lưu inline trong metadata.
- EC 2+2: mất 2 drive vẫn **đọc** được, cần ≥ 3 drive mới **ghi** được.
- MinIO còn tự heal khi đọc thấy thiếu; `heal -r` là quét chủ động cả bucket.

### 6. Bảo mật (4 phút)

**a. Least privilege**

```bash
mc alias set mlflowUser http://localhost:9000 "$MLFLOW_APP_ACCESS_KEY" "$MLFLOW_APP_SECRET_KEY"
mc alias set rawUser    http://localhost:9000 "$RAW_READER_ACCESS_KEY" "$RAW_READER_SECRET_KEY"
echo test > t.txt
mc cp t.txt mlflowUser/mlflow-artifacts/test/t.txt        # OK
mc --quiet cp t.txt mlflowUser/raw-data/t.txt             # Insufficient permissions
mc ls mlflowUser/db-backup                                # Access Denied
mc ls rawUser/raw-data/weather/hanoi/2025/                # OK (đọc)
mc --quiet cp t.txt rawUser/raw-data/t.txt                # Insufficient permissions
mc admin info mlflowUser                                  # Access Denied (không có quyền admin)
mc rm mlflowUser/mlflow-artifacts/test/t.txt; rm t.txt
```

`--quiet` để thanh tiến trình của `mc cp` không che mất dòng báo lỗi.

**b. Mã hóa SSE-S3**

```bash
mc encrypt info siteA/raw-data                                        # sse-s3 is enabled
mc stat siteA/raw-data/weather/hanoi/2025/2025-12.csv | grep -i encrypt   # SSE-S3
docker run --rm -v ltdl-dr_minio-a-data1:/d:ro $IMG sh -c 'grep -rl temp_mean /d/raw-data | wc -l'   # 0
mc cat siteA/raw-data/weather/hanoi/2025/2025-12.csv | head -2        # qua API có quyền: đọc được
```

Ý chính: trên đĩa là ciphertext (0 file chứa chữ `temp_mean`), chỉ đọc được qua API có quyền.

**c. Object Lock (WORM)** — *chưa chạy thử, phải tập trước*

```bash
mc retention info --default siteA/db-backup          # COMPLIANCE 1DAYS
b=$(mc ls siteA/db-backup | tail -1 | awk '{print $NF}')
mc stat siteA/db-backup/$b | grep -i lock            # Retain-Until-Date
v=$(mc ls --versions siteA/db-backup/$b | awk '{print $6}')
mc rm --version-id "$v" siteA/db-backup/$b           # PHẢI bị từ chối — kể cả root
```

Chỉ thử xóa **một** bản backup (xóa đúng version, không chỉ tạo delete marker) — đủ chứng minh, và nếu có gì sai
cũng chỉ mất một bản.

**d. Audit log**

```bash
docker compose logs --tail 5 audit-log
docker compose exec -T audit-log grep -c '"statusCode":403' /logs/audit-site-a.jsonl   # các lần bị từ chối ở trên
```

### 7. Backup (1 phút)

```bash
make backup && mc ls siteB/db-backup | tail -3    # bản mới đã sang B
mc ilm rule ls siteA/db-backup                    # tự xóa sau 7 ngày
```

### 8. Failover — mất site A (5 phút, cao trào)

**Chuẩn bị để thấy RPO:** chạy `make train` ngay **sau** một mốc cron (phút :x1–:x3), không chạy
`make backup`, rồi tắt site A trước mốc 5 phút tiếp theo. Model mới sẽ **không** có ở site B → mất dữ liệu đúng bằng
khoảng từ lần backup cuối (RPO ≤ 5 phút).

```bash
docker compose stop minio-a mlflow-a postgres-a   # giả lập site A sập        (~5s)
make dr-up                                        # postgres-b + mlflow-b      (~19s)
make dr-restore                                   # nạp dump mới nhất từ B     (~7s)
MLFLOW_TRACKING_URI=http://localhost:5100 MLFLOW_S3_ENDPOINT_URL=http://localhost:9100 \
  .venv/Scripts/python.exe app/predict.py         # vẫn dự báo được            (~6s)
```

- Tổng ≈ **45 giây** (RTO mục tiêu 30 phút). Mở http://localhost:5100 để thấy run/model.
- `make backup` lúc này báo `could not translate host name "postgres-a"` — **đúng**: site A đang sập.

**Khôi phục site A** (dùng `up --wait`, không dùng `start`: `start` trả về khi MLflow chưa sẵn sàng):

```bash
docker compose up -d --wait postgres-a minio-a mlflow-a    # ~12s
make status                                                # hàng đợi replication về 0
docker compose --profile dr stop mlflow-b postgres-b
```

File ghi vào MinIO B trong lúc A sập tự sang A (~40s sau khi A lên).

## C. Mẹo & câu hỏi thường gặp

- **Mất mạng:** `ingest` tự dùng dữ liệu giả lập; mọi image đã có sẵn trên máy.
- **Ít thời gian:** giữ mục 1, 2, 6c, 8.
- **Câu hỏi dễ gặp:**
  - RPO/RTO từng loại dữ liệu → bảng mục 3 `docs/architecture.md`.
  - Vì sao chỉ dùng được 50 % dung lượng → EC 2+2.
  - Vì sao TLS tắt mặc định, hạn chế KMS tĩnh → `docs/security.md`.
  - **Hạn chế failover:** file MinIO đồng bộ hai chiều, nhưng metadata MLflow ghi vào `postgres-b` lúc failover
    **không** tự về `postgres-a`; muốn quay về đầy đủ phải dump `postgres-b` rồi nạp ngược (ngoài phạm vi demo).

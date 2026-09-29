# Lưu trữ, sao lưu & khôi phục thảm họa đa site cho hệ thống dự báo thời tiết (MinIO + Docker)

Bài tập lớn môn Lưu trữ dữ liệu. Hệ thống có hai site MinIO (4 drive, erasure coding EC:2) nhân bản với nhau
bằng **Site Replication**. MLflow dùng PostgreSQL làm backend và MinIO làm artifact store. Metadata được backup
5 phút một lần vào bucket **Object Lock (COMPLIANCE)**. Ứng dụng Python dự báo nhiệt độ Hà Nội ngày kế tiếp.

- Kiến trúc, dung lượng EC, RPO/RTO: [`docs/architecture.md`](docs/architecture.md)
- Các lớp bảo mật và lệnh kiểm chứng: [`docs/security.md`](docs/security.md)

## 1. Yêu cầu môi trường

| Thành phần | Phiên bản đã kiểm thử | Ghi chú |
|---|---|---|
| Windows 10/11 + **Docker Desktop** (WSL2) | Docker 29.7, Compose v5.3 | RAM cấp cho Docker ≥ 4 GB (đo thực tế: stack mặc định ≈ 1.7 GB, bật thêm profile `dr` ≈ 2.3 GB) |
| **Git Bash** | đi kèm Git for Windows | chạy `make` và mọi script `.sh` từ Git Bash |
| **GNU Make** | 4.x | `winget install ezwinports.make` |
| **Python** | 3.12 | `winget install Python.Python.3.12` |
| **mc** (MinIO Client) trên host | RELEASE.2025-04-16T18-13-26Z | xem bên dưới |

Cài `mc`: trang dl.min.io đã ngừng phát bản community (HTTP 410), nên tải từ GitHub Releases rồi đặt vào `./bin/`
(script tự tìm `mc` trong PATH trước, sau đó tới `./bin/mc.exe`):

```bash
T=RELEASE.2025-04-16T18-13-26Z
curl -fL -o bin/mc.exe https://github.com/minio/mc/releases/download/$T/mc.windows-amd64.$T.exe
curl -fsL https://github.com/minio/mc/releases/download/$T/mc.windows-amd64.$T.exe.sha256sum; sha256sum bin/mc.exe
```

Image dùng (đều ghim phiên bản):

| Service | Image |
|---|---|
| minio-a, minio-b | `quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z` |
| mc (tool) | `quay.io/minio/mc:RELEASE.2025-04-16T18-13-26Z` |
| postgres-a/b | `postgres:16.15-alpine` |
| mlflow-a/b | `ghcr.io/mlflow/mlflow:v3.16.1` + psycopg2, boto3 (`docker/mlflow/Dockerfile`) |
| backup-cron | `postgres:16.15-alpine` + `mc` + busybox crond (`docker/backup-cron/Dockerfile`) |
| audit-log | `python:3.12.12-alpine3.22` |

> **Về phiên bản MinIO:** từ 2025 MinIO ngừng phát image/binary community mới. Bản `RELEASE.2025-04-22T22-12-26Z` là
> bản cuối còn **console quản trị đầy đủ**, gồm trang Site Replication, Users, Policies, Lifecycle và Encryption.
> Các bản sau chỉ còn Object Browser. Tất cả tính năng dùng trong demo (Site Replication, Object Lock, ILM, SSE-S3 với
> KMS tĩnh, audit webhook) đều có trong bản này. Nếu phải dùng bản mới hơn, mọi thao tác vẫn làm được qua `mc`, chỉ mất
> các màn hình quản trị trên console.

## 2. Chạy từ đầu

```bash
make env       # sinh .env với mật khẩu/khóa ngẫu nhiên (không ghi đè nếu đã có)
make up        # build + chạy: minio-a, postgres-a, mlflow-a, backup-cron, minio-b, audit-log (chờ healthy)
make setup     # alias, site replication, bucket, versioning, object lock, SSE-S3, ILM, user/policy
make ingest    # tải dữ liệu Open-Meteo (Hà Nội 2016–2025), đẩy 120 lô tháng vào raw-data
make train     # train RandomForest, log vào MLflow, đăng ký model weather-next-day-temp
make predict   # nạp version mới nhất, dự báo nhiệt độ ngày mai
make backup    # backup DB ngay (ngoài lịch cron 5 phút)
make status    # trạng thái replication + số object mỗi bucket ở 2 site
```

Lệnh khác: `make down` (dừng, giữ dữ liệu), `make clean` (dừng và **xóa mọi volume**; đây là cách duy nhất để xóa
backup đang bị COMPLIANCE lock), `make dr-up` (bật `postgres-b` + `mlflow-b`), `make certs` (sinh chứng chỉ TLS),
`make logs`. Mọi script đều chạy lại được nhiều lần.

`ingest.py --delay 2` đẩy từng lô cách nhau 2 giây để mô phỏng dữ liệu đổ về liên tục. `--last 3` chỉ đẩy 3 tháng cuối.
Chạy lại ingest sẽ tạo version mới cho object.

| Địa chỉ | Tài khoản |
|---|---|
| Console site A: http://localhost:9001 | `MINIO_A_ROOT_USER` / `MINIO_A_ROOT_PASSWORD` trong `.env` |
| Console site B: http://localhost:9101 | `MINIO_B_ROOT_USER` / `MINIO_B_ROOT_PASSWORD` |
| MLflow A: http://localhost:5000 · MLflow B (profile dr): http://localhost:5100 | — |

### Chuyển ứng dụng sang site B

Ba script đọc endpoint từ biến môi trường (biến môi trường được ưu tiên hơn `.env`):

```bash
make dr-up
MLFLOW_TRACKING_URI=http://localhost:5100 MLFLOW_S3_ENDPOINT_URL=http://localhost:9100 make predict
```

`mlflow-b` khởi động với `postgres-b` trống. Metadata (run, registry) phải restore từ backup đã replicate sang site B,
ví dụ:

```bash
set -a; source .env; set +a; unset TZ
f=$(bin/mc.exe ls siteB/db-backup | awk '{print $NF}' | tail -1)
bin/mc.exe cat siteB/db-backup/$f | gunzip | docker compose exec -T postgres-b psql -q -U mlflow -d mlflow
```

## 3. Ảnh nên chụp cho báo cáo

1. `docker compose ps`: các container healthy, đúng tên và port.
2. Console site A (http://localhost:9001) → **Buckets**: 4 bucket, cột Versioning/Encryption/Object Locking.
3. Console site B (http://localhost:9101) → **Buckets**: cùng 4 bucket và cùng số object dù không ghi trực tiếp vào B.
4. Console → **Site Replication**: 2 site `a` / `b` với endpoint `minio-a:9000`, `minio-b:9000`.
5. Terminal: `mc admin replicate status siteA` (Buckets/Policies/Users/ILM in sync, số object đã replicate).
6. Console → bucket `db-backup` → một file `.sql.gz` → tab Retention: **COMPLIANCE**, Retain until …
7. Terminal: `mc rm -r --versions --force siteA/db-backup/` bị từ chối.
8. Console → Buckets → `raw-data` → **Lifecycle** (noncurrent 14 ngày) và `logs` (expire 30 ngày).
9. Console → **Identity > Users / Policies**: 4 user ứng dụng và policy tương ứng. Terminal: user `mlflow-app` ghi vào
   `raw-data` bị Access Denied (docs/security.md mục 2).
10. `mc admin info siteA`: 4 drive, EC:2.
11. MLflow UI (http://localhost:5000): experiment `weather-forecast`, run với param/metric (mae, rmse, r2),
    tab Artifacts, và Models → `weather-next-day-temp`.
12. Kết quả `make predict`, `make backup`, `docker compose logs backup-cron` (cron 5 phút).
13. `docker compose logs audit-log`: audit log có dòng 403.
14. `mc stat siteA/raw-data/...`: `Encryption: SSE-S3`.

## 4. Cấu trúc thư mục

```
docker-compose.yml         # 2 site + backup-cron + audit-log + mc (tools); profile dr cho postgres-b, mlflow-b
docker-compose.tls.yml     # override bật TLS (không dùng mặc định)
.env.example               # mẫu cấu hình -> make env sinh .env
Makefile
scripts/  setup.sh backup_db.sh gen_env.sh gen_certs.sh status.sh lib.sh
policies/ *.json           # IAM policy least privilege
docker/   mlflow/ backup-cron/ audit-log/
app/      ingest.py train.py predict.py common.py requirements.txt
docs/     architecture.md security.md
```

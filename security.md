# Bảo mật: các lớp và lệnh kiểm chứng

Mọi lệnh chạy từ thư mục gốc dự án trong Git Bash, sau `make up && make setup`.
Nạp biến để dùng trong lệnh: `set -a; source .env; set +a; unset TZ`.
`mc` là `mc` trong PATH hoặc `./bin/mc.exe`.

## Tổng quan

| # | Lớp | Cách làm | Trạng thái |
|---|---|---|---|
| 1 | Quản lý bí mật | Mọi mật khẩu/khóa nằm trong `.env` (sinh ngẫu nhiên bằng `make env`, đã `.gitignore`). Compose chỉ tham chiếu `${VAR}` | Bật |
| 2 | Least privilege (IAM) | Không app nào dùng root. Có 4 user: `mlflow-app`, `raw-reader`, `ingest-writer`, `db-backup-writer` (policy trong `policies/`) | Bật |
| 3 | Mã hóa lưu trữ (SSE-S3) | KMS tĩnh `MINIO_KMS_SECRET_KEY` + `mc encrypt set sse-s3` cho cả 4 bucket | Bật |
| 4 | Bất biến (WORM) | `db-backup`: Object Lock **COMPLIANCE**, retention mặc định 1 ngày | Bật |
| 5 | Versioning | Cả 4 bucket (bắt buộc với Site Replication) | Bật |
| 6 | Audit log | `MINIO_AUDIT_WEBHOOK_*` → container `audit-log` → `/logs/audit-site-{a,b}.jsonl` | Bật |
| 7 | Phân vùng mạng | Mỗi site có network riêng; chỉ 2 MinIO chung network `replication`; Postgres không publish port ra host | Bật |
| 8 | Mã hóa đường truyền (TLS) | `scripts/gen_certs.sh` + `docker-compose.tls.yml` | **Tắt mặc định** (theo yêu cầu, để `mc` dùng được `http://localhost`) |

## 1. Bí mật trong `.env`

```bash
grep -nE 'PASSWORD|SECRET' docker-compose.yml   # chỉ thấy ${...}, không có giá trị thật
git check-ignore .env                            # .env bị ignore (nếu dùng git)
```

## 2. Least privilege

| User | Policy | Được phép | Bị cấm |
|---|---|---|---|
| `mlflow-app` | `mlflow-artifacts-rw` | List/Get/Put/Delete trong `mlflow-artifacts` | mọi bucket khác |
| `raw-reader` | `raw-data-readonly` | List/Get `raw-data` | ghi/xóa |
| `ingest-writer` | `raw-data-ingest` | List/Put `raw-data` | xóa, đọc bucket khác |
| `db-backup-writer` | `db-backup-writer` | List/Get/Put `db-backup` | xóa (kết hợp Object Lock) |

Site Replication tự đồng bộ user và policy sang site B, nên khi failover app dùng lại đúng credential.

Kiểm chứng:

```bash
mc alias set mlflowUser http://localhost:9000 "$MLFLOW_APP_ACCESS_KEY" "$MLFLOW_APP_SECRET_KEY"
mc alias set rawUser    http://localhost:9000 "$RAW_READER_ACCESS_KEY" "$RAW_READER_SECRET_KEY"
echo test > t.txt          # dùng đường dẫn tương đối: mc.exe không hiểu /tmp của Git Bash

mc cp t.txt mlflowUser/mlflow-artifacts/test/t.txt   # OK
mc cp t.txt mlflowUser/raw-data/t.txt                # PHẢI lỗi: Access Denied
mc ls mlflowUser/db-backup                                # PHẢI lỗi: Access Denied
mc ls rawUser/raw-data/weather/hanoi/2025/                # OK (đọc)
mc cp t.txt rawUser/raw-data/t.txt                   # PHẢI lỗi: Access Denied
mc admin info mlflowUser                                  # PHẢI lỗi: không có quyền admin
mc admin user info siteA mlflow-app                       # xem policy gắn với user
mc rm mlflowUser/mlflow-artifacts/test/t.txt
```

## 3. Mã hóa phía server SSE-S3

MinIO bản community không đi kèm KES. Ở đây dùng **KMS tĩnh một khóa** (`MINIO_KMS_SECRET_KEY=minio-kms:<32 byte base64>`),
cách MinIO hỗ trợ cho môi trường thử nghiệm. Hai site dùng **cùng một khóa**, để object SSE-S3 nhân bản sang B vẫn giải mã được.

- Hạn chế: khóa tĩnh nằm trong biến môi trường, không có xoay khóa hay HSM. Lộ `.env` là lộ khóa.
- Production: dùng **KES** (hoặc MinIO AIStor KMS) kết nối Vault / AWS KMS / HSM, thay `MINIO_KMS_SECRET_KEY` bằng
  `MINIO_KMS_KES_ENDPOINT`, `MINIO_KMS_KES_KEY_NAME`, v.v.

Kiểm chứng:

```bash
mc encrypt info siteA/raw-data                 # Auto encryption 'sse-s3' is enabled
mc encrypt info siteB/raw-data                 # đã replicate sang B
mc admin kms key status siteA                  # Key: minio-kms, Encryption/Decryption OK
mc stat siteA/raw-data/weather/hanoi/2025/2025-12.csv | grep -i encrypt   # Encrypted: SSE-S3
# Dữ liệu trên đĩa là ciphertext: 0 file chứa header CSV "temp_mean" (image MinIO không có grep nên dùng alpine)
docker run --rm -v ltdl-dr_minio-a-data1:/d:ro python:3.12.12-alpine3.22 sh -c 'grep -rl temp_mean /d/raw-data | wc -l'
mc cat siteA/raw-data/weather/hanoi/2025/2025-12.csv | head -2   # đọc qua API (có quyền) vẫn ra plaintext
```

## 4. Object Lock (WORM) cho `db-backup`

```bash
mc retention info --default siteA/db-backup    # COMPLIANCE, 1 DAYS
mc retention info --default siteB/db-backup    # giống hệt (replicate)
mc rm -r --versions --force siteA/db-backup/   # PHẢI bị từ chối (kể cả root) cho tới khi hết retention
mc stat siteA/db-backup/<file>.sql.gz           # Retention: COMPLIANCE, Retain until ...
```

COMPLIANCE không cho ai rút ngắn retention hay xóa version, kể cả root. Vì vậy `make clean` phải xóa hẳn volume Docker.

## 5. Audit log

```bash
docker compose logs -f audit-log               # mỗi request S3 một dòng: site, accessKey, API, bucket/object, HTTP status
docker compose exec audit-log tail -n 3 /logs/audit-site-a.jsonl
# Lần thử ghi bị từ chối ở mục 2 hiện ra với statusCode 403 và accessKey=mlflow-app:
docker compose exec audit-log grep -c '"statusCode":403' /logs/audit-site-a.jsonl
```

Production: gửi webhook vào SIEM (Elasticsearch/Loki/Splunk) thay vì file cục bộ.

## 6. Phân vùng mạng

```bash
docker network inspect ltdl-dr_replication --format '{{range .Containers}}{{.Name}} {{end}}'  # chỉ minio-a, minio-b
docker compose ps postgres-a            # không có port publish ra host
```

## 7. TLS (không bật mặc định)

Lý do tắt mặc định: đề bài yêu cầu `mc` dùng `http://localhost`, và chứng chỉ self-signed làm demo phức tạp thêm.

Bật TLS:

```bash
bash scripts/gen_certs.sh          # certs/ca.crt, certs/minio-{a,b}/{public.crt,private.key,CAs/ca.crt}
                                   # SAN: minio-x, localhost, 127.0.0.1 ; ký bởi CA nội bộ
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

Sau khi bật:
1. Đổi alias sang https và tin CA:
   `mkdir -p ~/mc/certs/CAs && cp certs/ca.crt ~/mc/certs/CAs/` (Linux/macOS: `~/.mc/certs/CAs/`).
   `make setup` tự nhận ra TLS đã bật và tạo alias `https://localhost:9000` / `:9100`.
2. Site Replication: endpoint ngang hàng phải là `https://minio-a:9000` / `https://minio-b:9000`. Mỗi site đã tin CA
   qua thư mục `CAs/`. Với cụm đã cấu hình bằng HTTP, cập nhật bằng
   `mc admin replicate update siteA --deployment-id <id> --endpoint https://minio-b:9000`
   (lấy id từ `mc admin replicate info siteA`).
3. App Python: `MLFLOW_S3_ENDPOINT_URL=https://localhost:9000` và `AWS_CA_BUNDLE=$(pwd)/certs/ca.crt`.
4. Kiểm chứng: `curl --cacert certs/ca.crt https://localhost:9000/minio/health/live` trả về 200;
   `curl http://localhost:9000/...` thất bại.

Production: dùng chứng chỉ từ CA thật (hoặc cert-manager). Không dùng `--insecure`.

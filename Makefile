# Chạy từ Git Bash (Windows) hoặc shell Linux/macOS.
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
export MSYS_NO_PATHCONV := 1

COMPOSE := docker compose
ALL_PROFILES := --profile dr --profile tools
PYTHON ?= python
VENV := .venv
ifeq ($(OS),Windows_NT)
  VPY := $(VENV)/Scripts/python.exe
else
  VPY := $(VENV)/bin/python
endif

.PHONY: help env up setup ingest train predict backup down clean dr-up dr-restore status logs certs

help:
	@echo "make env      - sinh .env (bí mật ngẫu nhiên) nếu chưa có"
	@echo "make up       - build + chạy site A, minio-b, backup-cron, audit-log (chờ healthy)"
	@echo "make setup    - alias, bucket, versioning, object lock, SSE, ILM, IAM, site replication"
	@echo "make ingest   - đẩy dữ liệu thời tiết theo lô vào raw-data"
	@echo "make train    - huấn luyện model, log vào MLflow"
	@echo "make predict  - nạp model mới nhất và dự báo nhiệt độ ngày mai"
	@echo "make backup   - backup DB MLflow ngay (ngoài lịch 5 phút)"
	@echo "make status   - trạng thái replication + danh sách backup 2 site"
	@echo "make dr-up    - bật postgres-b + mlflow-b (profile dr) khi failover"
	@echo "make dr-restore - nạp dump mới nhất từ siteB/db-backup vào postgres-b (GHI ĐÈ)"
	@echo "make certs    - sinh chứng chỉ self-signed (TLS không bật mặc định)"
	@echo "make down     - dừng tất cả (giữ dữ liệu)"
	@echo "make clean    - dừng và XÓA toàn bộ volume dữ liệu"

env: .env
.env:
	bash scripts/gen_env.sh

up: .env
	$(COMPOSE) up -d --build --wait
	$(COMPOSE) ps

setup:
	bash scripts/setup.sh

$(VPY): app/requirements.txt
	$(PYTHON) -m venv $(VENV)
	$(VPY) -m pip install -q --upgrade pip
	$(VPY) -m pip install -q -r app/requirements.txt
	touch $(VPY)

ingest: $(VPY)
	$(VPY) app/ingest.py

train: $(VPY)
	$(VPY) app/train.py

predict: $(VPY)
	$(VPY) app/predict.py

backup:
	$(COMPOSE) exec -T backup-cron bash /scripts/backup_db.sh

status:
	bash scripts/status.sh

dr-up:
	$(COMPOSE) --profile dr up -d --build --wait postgres-b mlflow-b

dr-restore:
	bash scripts/restore_db.sh

logs:
	$(COMPOSE) logs -f --tail=50

certs:
	bash scripts/gen_certs.sh

down:
	$(COMPOSE) $(ALL_PROFILES) down

clean:
	$(COMPOSE) $(ALL_PROFILES) down -v --remove-orphans

# BerryDB

Trình quản lý cơ sở dữ liệu **native cho macOS** — nhẹ, khởi động nhanh, không Electron.
Thay thế Navicat cho luồng công việc hằng ngày, kèm AI agent (gói trả phí).

> Toàn bộ kiến trúc & quyết định thiết kế: [`docs/architecture/01-tong-quan.md`](docs/architecture/01-tong-quan.md)

## Trạng thái

Đang ở **M1 — Driver mạng** (lộ trình M0–M7 tại [`docs/architecture/08`](docs/architecture/08-ke-hoach-trien-khai.md)).

- ✅ M0: mở file SQLite → duyệt bảng/view → grid streaming (NSTableView).
- 🔨 M1: driver **PostgreSQL + MySQL/MariaDB** pass conformance suite với server thật
  (kể cả MySQL 8.4 `caching_sha2_password`); hồ sơ kết nối lưu qua GRDB,
  mật khẩu trong Keychain; hủy query qua `pg_cancel_backend` / `KILL QUERY`.
  Còn lại: SSH tunnel, TLS verify modes, spike 1M dòng.

## Chạy dev

```sh
make run      # build (debug) + đóng gói dist/BerryDB.app + kill instance cũ + mở lại
              # (scripts/run.sh — không phải `swift run`, app cần chạy như .app bundle
              # thật để có Info.plist/icon/entitlements đúng)
make watch    # dev loop: tự build lại + relaunch app khi code đổi,
              # notification macOS khi build fail
make test     # chạy toàn bộ test
make app      # đóng gói dist/BerryDB.app (build release, ký ad-hoc — đủ chạy local,
              # CHƯA ký Developer ID/notarize, xem mục Release bên dưới)
```

`make run`/`make watch` tự nạp `.env` nếu có (copy từ `.env.example`) — dùng để trỏ
app sang backend khác localhost, ví dụ `BERRYDB_BACKEND_URL=https://berrydb-api.notex.work`.
`.env` chỉ dành cho dev cục bộ, tách biệt hoàn toàn với secret release (`deploy/.env`,
xem mục Release) — hai file không bao giờ được trộn vào nhau.

Test driver với server thật (conformance suite, docs/architecture/05 §7) — danh sách
đầy đủ biến môi trường cho từng driver nằm ở comment đầu `Tests/docker/compose.yml`:

```sh
docker compose -f Tests/docker/compose.yml up -d --wait
BERRYDB_TEST_SQLSERVER=127.0.0.1:14339:sa:BerryDB_Test_2026!:master \
BERRYDB_TEST_QDRANT=127.0.0.1:63339 \
BERRYDB_TEST_ELASTICSEARCH=127.0.0.1:19200 \
swift test
```

> Postgres/MySQL (`postgres16`/`mysql84`) đang bị comment tắt trong `compose.yml` —
> bỏ comment 2 service đó nếu cần test lại (biến `BERRYDB_TEST_POSTGRES`/
> `BERRYDB_TEST_MYSQL` đã có sẵn ở comment đầu file).

Yêu cầu: macOS 14+, Xcode 16+ (Swift 6).

Tạo file demo để thử nhanh:

```sh
sqlite3 /tmp/demo.sqlite "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('xin chào'),(NULL);"
make run   # rồi ⌘O mở /tmp/demo.sqlite
```

## Release

```sh
make release 0.2.0           # build (release) → ký Developer ID → notarize → staple
                              # → đóng gói .dmg → ký Sparkle
make upload                  # đẩy R2 + dựng lại appcast.xml + purge CDN
```

Cần `deploy/.env` (secret ký/notarize/R2 — gitignored, tách biệt hoàn toàn khỏi `.env`
dev ở trên). Chi tiết đầy đủ: [`deploy/README.md`](deploy/README.md).

## Cấu trúc

```
App/                    # app target — nơi duy nhất đăng ký driver
Packages/
  BerryDriverKit/       # hợp đồng driver (docs/architecture/05)
  BerryDriverSQLite/    # driver SQLite (libsqlite3)
  BerryCore/            # QueryService, Session, SchemaCatalog, ResultBuffer
  BerryUI/              # SwiftUI shell + DataGrid (AppKit NSTableView)
docs/architecture/      # 10 tài liệu kiến trúc, đánh số 01–10
```

Quy tắc phụ thuộc một chiều (docs/architecture/04 §1): UI không import driver;
driver không biết core; mọi SQL đi qua `QueryService` (một đường duy nhất).

## Quy trình

- Mỗi PR gắn ID chức năng (`KN-*`, `ED-*`, … định nghĩa tại [`docs/architecture/02`](docs/architecture/02-chuc-nang.md)).
- Đổi kiến trúc/hợp đồng → sửa tài liệu 01–10 trong cùng PR.

# BerryDB — Release & distribution

Ký, notarize, và phát hành qua Sparkle (docs/architecture/08 §6, 10 §3). Toàn bộ
secret nằm ở `.env` (gitignored) — xem `.env.example`. **Không bao giờ commit giá
trị thật.**

## Một lần: khóa cập nhật Sparkle (EdDSA)

```sh
# Từ một checkout Sparkle (hoặc bản release Sparkle), tạo cặp khóa:
./bin/generate_keys            # lưu private key vào Keychain, in ra public key
```

- Public key → điền `SU_PUBLIC_ED_KEY` trong `.env` (được nhúng vào Info.plist).
- Private key ở Keychain, dùng bởi `sign_update` khi release. Trỏ `SPARKLE_BIN`
  tới `sign_update` nếu không nằm trong PATH/.build.

## Một lần: bật in-app updater (framework Sparkle)

Mặc định app build **không nhúng** Sparkle: menu *Check for Updates…* là no-op
(`NoopUpdater`). Lý do — Sparkle là binary framework, sẽ phá vỡ mục tiêu zero
runtime-dep + size guard (`scripts/check-size.sh`, 08 §6) của bản build thường và
của test/`swift run`. Code updater (`App/Sources/AppUpdater.swift`) khóa theo
`#if canImport(Sparkle)`, nên chỉ cần link framework là bản thật tự bật.

Để bật cho release:

1. Bỏ comment **hai** dòng trong `Package.swift`: `.package(url: …/Sparkle.git…)`
   và `.product(name: "Sparkle", package: "Sparkle")` trong target `BerryApp`.
   `canImport(Sparkle)` khi đó thành true → `SparkleUpdater` được biên dịch và
   `makeUpdater()` kích hoạt nó khi chạy từ `.app` bundle đã ký.
2. Nhúng + ký lại framework vào bundle **sau** `swift build -c release`, **trước**
   `codesign` app ngoài cùng (bước thủ công — chưa tự động trong `make_app.sh` vì
   không verify được headless):

   ```sh
   FW="$(swift build -c release --show-bin-path)/Sparkle.framework"
   mkdir -p dist/BerryDB.app/Contents/Frameworks
   ditto "$FW" dist/BerryDB.app/Contents/Frameworks/Sparkle.framework
   # Ký từ trong ra ngoài: XPCServices + Autoupdate rồi tới framework.
   codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
     dist/BerryDB.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc
   codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
     dist/BerryDB.app/Contents/Frameworks/Sparkle.framework
   ```

   `release.sh` chạy `codesign --deep` cho app ngoài cùng sẽ ký lại toàn bộ, nên
   `@rpath/Sparkle.framework` vượt library validation với Developer ID của ta.
3. Vì đã nhúng dep ngoài hệ thống, thêm `Sparkle.framework` vào allowlist của
   `scripts/check-size.sh` cho bản release (bản thường vẫn phải zero-dep).

## Mỗi lần phát hành

```sh
python3 -m pip install -r deploy/requirements.txt   # boto3 (một lần)

make release 0.2.0             # build → sign → notarize → staple → zip → ký Sparkle
python3 deploy/upload-release.py   # upload R2 + dựng lại appcast + purge CDN
```

- `deploy/release.sh` tạo `dist/BerryDB-<version>.dmg` (installer kéo-thả vào
  Applications, đã notarize + staple) + `deploy/last-release.json`. App bên trong
  được staple riêng để mở offline sau khi kéo ra. Sparkle 2 cập nhật thẳng từ .dmg.
- `upload-release.py` gộp vào `deploy/releases.json` (lịch sử), dựng `appcast.xml`,
  upload cả zip lẫn appcast lên R2, rồi purge cache Cloudflare. Upload thêm một
  bản alias cố định `BerryDB-latest.<đuôi file>` (song song, không thay thế bản
  versioned) — để link tải "luôn là bản mới nhất" trên website mà không phải sửa
  URL mỗi lần phát hành. Appcast/Sparkle vẫn chỉ đọc các entry versioned; alias
  không tham gia vào appcast vì chữ ký EdDSA của Sparkle gắn với đúng file
  versioned, không phải với key cố định này.

## Checklist bảo mật trước khi phát hành thật

- [ ] **Thay khóa công khai license** `LicenseManager.devPublicKeyBase64`
      (`Packages/BerryLicense/Sources/LicenseManager.swift`) bằng public key của
      backend **production**. Khóa này **biên dịch thẳng vào binary** (verify
      offline N4) — KHÔNG được đọc từ env lúc chạy (kẻ tấn công có thể thay khóa
      tin cậy). Backend in public key lúc khởi động.
- [ ] Backend production chạy **HTTPS** (`BERRYDB_BACKEND_URL=https://…`) — client
      từ chối gửi bearer token qua `http://` non-loopback (fail về local, 07 §2).
- [ ] TLS DB: nhắc người dùng dùng **Verify certificate** cho production
      (prefer/require chỉ mã hóa, không xác thực máy chủ — 07 §4).

## Env cần thiết (`.env`)

| Nhóm | Key |
|---|---|
| Apple (ký + notarize) | `APPLE_ID`, `APP_SPEC_PASSWORD`, `SIGNING_IDENTITY`*, `APPLE_TEAM_ID`* |
| Sparkle | `SU_PUBLIC_ED_KEY`, `SU_FEED_URL`*, `SPARKLE_BIN`* |
| Cloudflare R2 | `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` |
| CDN purge | `CF_ZONE_ID`, `CF_API_TOKEN` (khuyên dùng) |
| Tải xuống | `DOWNLOAD_BASE_URL`* (mặc định domain R2 custom) |

\* có mặc định trong script — chỉ đặt khi đổi.

## App icon

Thả **`deploy/icon-1024.png`** (1024×1024) — `make_app.sh` tự render `AppIcon.icns`
(mọi kích thước qua `sips`+`iconutil`, `.icns` là artifact — gitignore) và nhúng vào
bundle. Không có → app dùng icon hệ thống mặc định (bản dev).

Hiện đang dùng **icon placeholder** (nền gradient xanh macOS + glyph database), sinh
bởi `scripts/make_placeholder_icon.swift` (`swift scripts/make_placeholder_icon.swift deploy/icon-1024.png`).
**Nên thay bằng art thật** — chỉ cần ghi đè `deploy/icon-1024.png`.

## Ghi chú

- App **không sandbox** (dev tool cần host DB tùy ý + file SQLite tùy chọn) — chỉ
  hardened runtime. Entitlements: `deploy/BerryDB.entitlements`.
- `codesign --deep` ký lại mọi framework nhúng (kể cả Sparkle) bằng Developer ID
  của ta → library validation vượt qua mà không cần nới lỏng.
- `appcast.xml` và `releases.json` được sinh tự động — không sửa tay.

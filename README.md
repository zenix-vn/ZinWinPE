<p align="center"><img src="assets/branding/logo-128.png" alt="ZinWinPE" width="128"></p>

# ZinWinPE

USB cứu hộ WinPE tự build cho **cửa hàng sửa chữa máy tính**: WinPE 11 x64 có Explorer, mạng, driver đầy đủ, ~50 công cụ portable, cài Windows nhanh theo preset (song ngữ Anh/Việt), tự nạp driver theo model và tự cài phần mềm cho khách.

- Thiết kế đầy đủ: [docs/ZinWinPE-Design.md](docs/ZinWinPE-Design.md)
- Kế hoạch & tiến độ: [TODO.md](TODO.md)
- Hướng dẫn build: [docs/build.md](docs/build.md) · Sử dụng: [docs/user-guide.md](docs/user-guide.md)

## Thành phần

| Thư mục | Nội dung |
|---|---|
| `src/common` | `ZinCommon.psm1` — log, INI/JSON, dò ZINDATA, i18n, thông tin máy |
| `src/loader` | PE Loader: driver T2, công cụ portable, shortcut, mạng (thiết kế 6.4) |
| `src/zinsetup` | ZinSetup: cài Windows, Cài nhanh (preset), unattend, phiếu kết quả (8.3–8.5) |
| `src/zindriver` | ZinDriver: nhận diện model, khớp driver theo hãng / HWID (9.4) |
| `src/zinpost` | ZinPost: cài phần mềm & driver lần đầu vào Windows (8.7.2) |
| `src/fixboot`, `src/tools` | FixBoot, SysInfo, QuickTest, Capture-ShopImage |
| `src/installer` | ZinWinPE Installer: tạo / cập nhật USB, ISO, cài vào ổ cứng (12) |
| `src/lang` | `en-US.json`, `vi-VN.json` |
| `builder` | Build tổng, inject driver T1 + script vào boot.wim, tạo BCD, image chuẩn cửa hàng |
| `boot` | GRUB2 + shim + khoá MOK (build trong WSL) |
| `packages` | Định nghĩa & script đóng gói công cụ portable |
| `apps` | Manifest phần mềm cho khách + script tải bộ cài |
| `drivers` | ZinDriverSync + danh sách model |
| `config` | `zinpe.ini`, preset, mẫu unattend, app mặc định |
| `tests` | Unit test Pester |

## Bắt đầu nhanh (máy build Windows 11 x64)

```powershell
# 1. Công cụ, phần mềm, driver
.\packages\build.ps1
.\apps\Get-Apps.ps1
.\drivers\ZinDriverSync.ps1 -Package Standard

# 2. GRUB2 (WSL):  ./boot/new-mok.sh  (1 lần)  &&  ./boot/build-grub.sh

# 3. PE: build boot.wim bằng PhoenixPE (builder/phoenixpe/README.md), rồi:
.\builder\Build-ZinWinPE.ps1 -BootWim D:\PhoenixPE\Target\sources\boot.wim -Zip -Iso

# 4. Tạo USB
.\src\installer\ZinInstaller.ps1
```

Kiểm thử đơn vị (Windows PowerShell 5.1 / PowerShell 7, kể cả macOS/Linux):

```powershell
Invoke-Pester ./tests
```

## Quy ước

- Script `.ps1/.psm1` chỉ dùng ký tự ASCII (Windows PowerShell 5.1 trong WinPE đọc file không BOM theo ANSI); mọi chuỗi tiếng Việt nằm trong `src/lang/*.json`.
- Log luôn bằng tiếng Anh.
- Không commit ISO, WIM, bộ cài, driver, khoá ký (`.gitignore`).

## Bản quyền

Mục đích sử dụng là **thương mại** (cửa hàng) — xem [LICENSES.md](LICENSES.md) và thiết kế mục 16. Không tích hợp công cụ kích hoạt lậu, không phân phối công khai bản build WinPE.

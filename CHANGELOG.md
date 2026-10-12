# Changelog

Phiên bản dạng `YYYY.MM` (thiết kế mục 13). Mỗi bản phát hành ghi lại ở đây.

## [Unreleased] — 2026.10

### Thêm
- Khung repo: cấu trúc `builder/ src/ packages/ apps/ drivers/ boot/ config/ tests/`, `.gitignore`, `.gitattributes`.
- `src/common/ZinCommon.psm1`: log, INI/JSON, dò ZINDATA theo `zinpe.tag`, i18n EN/VI, thông tin máy, kiểm tra chuẩn Win11, SNTP.
- PE Loader (`src/loader`): chế độ Bình thường / Full RAM / Safe, nạp driver T2, giải nén công cụ `.7z/.wim`, shortcut theo nhóm, mạng, đồng bộ giờ, hình nền in phiên bản.
- ZinDriver (`src/zindriver`): đọc `.inf`, khớp HWID, `index.json` theo hãng (Dell SKU / HP baseboard / Lenovo MTM), fallback SDIO lọc theo HWID (`sdio-index.tsv`).
- ZinSetup (`src/zinsetup`): GUI WPF song ngữ, Cài nhanh theo preset, chế độ Nâng cao, chia ổ GPT/MBR, apply bằng wimlib/dism, driver, unattend, ZinPost, phiếu kết quả; CLI `-Preset -Disk -Yes`.
- ZinPost (`src/zinpost`): cài phần mềm lần đầu khởi động (SYSTEM + user), SDIO, winget, cờ chống chạy lặp.
- FixBoot, SysInfo, QuickTest, Capture-ShopImage (`src/fixboot`, `src/tools`).
- ZinWinPE Installer (`src/installer`): tạo / cập nhật USB 2 phân vùng, tạo ISO, thêm vào boot ổ cứng.
- Build: `builder/Build-ZinWinPE.ps1`, `inject-t1.ps1`, `New-ZinBcd.ps1`, `builder/image/Merge-ShopImages.ps1`.
- GRUB2 + shim + MOK: `boot/new-mok.sh`, `boot/build-grub.sh`, `boot/grub/*`.
- Gói công cụ: 53 định nghĩa `packages/defs/*.ini`, `packages/build.ps1`, `LICENSES.md` tự sinh.
- `apps/Get-Apps.ps1`, cấu hình Office ODT, `drivers/ZinDriverSync.ps1` + `models.json`.
- Preset mẫu, mẫu unattend, `zinpe.ini`, `DefaultAppAssociations.xml`.
- Unit test Pester (`tests/`).

### Chưa kiểm thử trên phần cứng
Toàn bộ phần chạy trên Windows/WinPE mới chỉ kiểm tra cú pháp + unit test; xem `TODO.md` cho các mục kiểm thử P1–P5.

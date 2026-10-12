# ZinWinPE — TODO

> Kế hoạch triển khai theo [docs/ZinWinPE-Design.md](docs/ZinWinPE-Design.md) (mục 15 – Lộ trình).
> Quy ước: `[ ]` chưa làm · `[~]` đã có code/tài liệu, **chờ chạy/kiểm thử trên Windows** · `[x]` xong · ⚠️ ưu tiên/rủi ro cao
> Cập nhật 2026-10-12: đã viết toàn bộ mã nguồn & cấu hình trong repo (32 unit test Pester pass, PSScriptAnalyzer sạch). Việc còn lại cần máy build Windows + máy thật.

---

## 🔖 Quyết định

Đã chốt 2026-10-12 (chi tiết: mục 1.4 tài liệu thiết kế):

- [x] D1 — 1 bản PE: **ZinWinPE 11 x64**
- [x] D2 — Gói driver mặc định **Standard**, USB **64 GB**
- [x] D3 — **Có** hỗ trợ Legacy BIOS
- [x] D4 — Dùng cho **cửa hàng**: nhiều máy, máy cũ, cần **cài nhanh**
- [x] D5 — **GRUB2 + shim** Secure Boot ngay từ P1
- [x] D6 — ZinSetup **song ngữ Anh + Việt**
- [x] D7 — Builder chính: **PhoenixPE**

Còn mở:

- [ ] Danh sách phần mềm thương mại đã có / sẽ mua license (bản Technician)
- [ ] Bản Windows cho máy cũ không lên Win11: Win10 22H2 / LTSC 2021 / Win11 + bypass
- [x] Danh sách phần mềm cơ bản văn phòng (mục 8.7.4, manifest trong `apps/`)
- [ ] Phần mềm chuyên ngành hay cài (kế toán, HTKK, chữ ký số/token...)?

---

## P0 — Chuẩn bị môi trường

### Repo
- [x] `git init`, thêm remote `origin` → https://github.com/zenix-vn/ZinWinPE.git
- [x] Tài liệu thiết kế `docs/ZinWinPE-Design.md`
- [x] Tạo `.gitignore` (ISO, `out/`, `iso-src/`, driver, gói công cụ, `*.wim`, `*.esd`)
- [x] Tạo cấu trúc thư mục: `builder/ src/{loader,zinsetup,zindriver,fixboot,installer}/ packages/ drivers/ boot/` — thêm `config/`, `tests/`, `src/common`, `src/lang`, `src/tools`
- [x] `README.md`, `CHANGELOG.md`, `LICENSES.md`
- [ ] Commit đầu tiên & push `main`

### Máy build
- [ ] ⚠️ Chuẩn bị máy/VM **Windows 11 x64** (không dùng Windows ARM trên Apple Silicon)
- [ ] Ổ NTFS ≥ 200 GB trống
- [ ] Cài Windows ADK + WinPE add-on (bản mới nhất)
- [ ] Cài PEBakery + PhoenixPE (Win10XPE chỉ dự phòng)
- [ ] Cài WSL (Ubuntu) để build & ký GRUB2: `grub-efi`, `grub-pc-bin`, `sbsigntool`, `mokutil`
- [ ] Cài 7-Zip, wimlib, Git, PowerShell 7 (tuỳ chọn)
- [ ] Tải ISO gốc Microsoft: Windows 11 24H2/25H2 x64 (en-US) — nguồn build PE + cài đặt
- [ ] Tải ISO Windows 10 22H2 x64 / LTSC (chỉ để cài cho máy cũ, không build PE)
- [~] Ghi hash SHA-256 các ISO nguồn vào `docs/sources.md` — mẫu `docs/sources.md`

### VM kiểm thử
- [ ] Hyper-V Gen 2 (UEFI + Secure Boot), Gen 1 (Legacy)
- [ ] VMware: UEFI SB on/off, BIOS, NVMe controller
- [ ] (Tuỳ chọn) QEMU/OVMF để test DB/DBX CA 2023

---

## P1 — PE lõi (ZinWinPE 11 x64)

### Build PE
- [ ] Build PhoenixPE với nguồn Win11 → boot được trên VM
- [~] Lưu cấu hình PhoenixPE (project/script đã chọn) vào `builder/` để build lại được — checklist `builder/phoenixpe/README.md`
- [ ] Bật thành phần: Explorer shell, Start menu, Network + WiFi, Audio, PowerShell, WMI, .NET 4.8, MSI, BitLocker, RDP client, VHD/ISO mount
- [~] Locale vi-VN, múi giờ SE Asia, font Việt, bộ gõ UniKey/EVKey — Loader đặt múi giờ; UniKey là gói Utilities
- [x] Logo + tài nguyên dẫn xuất trong `assets/branding/` (ico, png nhiều size, wallpaper, nền GRUB) — mục 6.6
- [~] Theme / wallpaper ZinWinPE trong PhoenixPE, hiển thị phiên bản **động** trên desktop — Loader vẽ phiên bản lên wallpaper (`Set-ZinWallpaper`)
- [ ] Icon đơn giản hoá cho size 16–24 px
- [ ] (Tuỳ chọn) Logo gốc độ phân giải cao ≥ 2048 px hoặc SVG cho màn hình 2K/4K
- [x] `autorun.inf` cho ZINDATA (icon + nhãn ổ) — `config/autorun.inf`
- [~] Tối ưu: dọn file thừa, nén LZX, **boot.wim < 1.5 GB** — `inject-t1.ps1` export /Compress:max + cảnh báo > 1.5 GB
- [ ] Đo RAM tối thiểu để boot (mục tiêu: chạy được trên 4 GB — máy cũ ở cửa hàng)
- [ ] Xác nhận PE 11 boot Legacy BIOS ổn trên máy 2015–2017

### Driver T1 (tích hợp boot.wim)
- [ ] ⚠️ Intel RST / VMD (`iaStorVD`) — test trên máy Gen 11+
- [ ] AMD RAID (RAIDXpert2), AMD chipset I2C/GPIO
- [ ] Intel Serial IO, I2C HID touchpad
- [ ] USB 3.x / USB4 / Thunderbolt
- [ ] LAN: Intel, Realtek, Killer
- [ ] WiFi: Intel, Realtek, MediaTek, Qualcomm
- [~] Nguồn: Dell / HP / Lenovo WinPE Driver Pack → gộp, loại trùng — ZinDriverSync tự tải Dell WinPE 11 pack → `drivers/store/T1`
- [x] Script `builder/inject-t1.ps1` (mount → add-driver → commit)

### Boot
- [~] Tạo BCD UEFI + Legacy (ramdisk, theo Phụ lục B) — `builder/New-ZinBcd.ps1`
- [~] ⚠️ Lấy boot files ký **Windows UEFI CA 2023** + bộ CA 2011; kiểm chứng tình trạng mới nhất từ Microsoft — Build-ZinWinPE lấy `EFI_EX` từ ADK → `EFI\zin\ca2023`; cần kiểm chứng
- [~] Menu BCD: ZinWinPE 11 / Menu phụ GRUB2 / Boot ổ cứng — "Boot ổ cứng" nằm trong menu GRUB2 (bootmgr không có loại mục này)
### GRUB2 + shim (D5)
- [~] Lấy shim mới (≥ 15.8, SBAT hợp lệ) đã ký Microsoft từ Debian/Ubuntu/Fedora — cả bản ký UEFI CA 2011 và CA 2023 nếu có — `boot/build-grub.sh` (apt-get download shim-signed)
- [~] Tạo khoá MOK ZinWinPE (`ZinWinPE.key/.crt/.cer`) — **cất khoá riêng an toàn, không commit** — `boot/new-mok.sh`, `boot/mok/` bị gitignore
- [~] Build `grubx64.efi` (UEFI) + `core.img` (Legacy) với module cần thiết (ntfs, exfat, iso9660, loopback, chain, ntldr...) — `boot/build-grub.sh` (module nhúng sẵn, SBAT)
- [~] Ký GRUB2 + các EFI phụ bằng `sbsign`
- [x] Theme GRUB2 dùng `grub-bg-1024x768.png` + logo — `boot/grub/themes/zinwinpe`
- [~] Chain: bootmgr (BCD) → mục "Menu phụ" → shim → GRUB2; Legacy: bootmgr → grub2 core.img — UEFI: bootapp → shim (chỉ khi SB tắt); SB bật: "Boot from file"; Legacy: g2ldr.mbr (cần grldr.mbr)
- [x] Tài liệu hướng dẫn enroll MOK cho KTV (`docs/mok-enroll.md`, song ngữ)
- [ ] Test: SB bật (enroll MOK), SB tắt, Legacy; máy cũ chỉ có CA 2011, máy mới có CA 2023

### USB thủ công
- [~] Tạo USB 2 phân vùng **thủ công** (diskpart) theo mục 4: ZINBOOT FAT32 ẩn + ZINDATA exFAT — các bước trong `docs/manual-usb.md`
- [x] Viết `docs/manual-usb.md` ghi lại các bước

### Kiểm thử P1
- [ ] VM: UEFI SB on, UEFI SB off, Legacy
- [ ] 3 máy thật (1 Intel đời cũ, 1 Intel VMD, 1 AMD): thấy ổ, có mạng, touchpad chạy
- [ ] GRUB2 menu phụ chạy được khi bật Secure Boot (sau enroll MOK)

---

## P2 — Công cụ & PE Loader

### PE Loader
- [x] Chọn nền tảng: PECMD / PowerShell / AutoIt (biên dịch) — ưu tiên khởi động nhanh — PowerShell 5.1 (`src/loader/ZinLoader.ps1` + `ZinLoader.cmd`)
- [x] Dò phân vùng ZINDATA qua `ZinPE\zinpe.tag`
- [x] Đọc manifest `.ini` → giải nén `.7z` vào `X:\Programs` hoặc mount `.wim`
- [x] Tạo shortcut Start Menu theo nhóm + Desktop
- [x] Nạp driver T2 cho thiết bị thiếu driver (drvload / pnputil) + rescan ổ
- [x] Khởi động PENetwork, đồng bộ giờ — SNTP tự viết
- [x] Chế độ: Bình thường / Full RAM / Safe (Minimal) — phím F / S lúc khởi động hoặc `zinpe.ini`
- [x] Ghi log `ZINDATA\ZinPE\Logs\loader.log`

### Hệ thống gói công cụ
- [x] Định nghĩa format `.ini` (Name, Group, Archive, Exe, Desktop, LoadToRam, Arch, Version, Url, Sha256, License) — `packages/README.md`
- [x] Script `packages/build.ps1`: tải → kiểm hash → nén `.7z` → `out/ZINDATA/ZinPE/Programs`
- [x] Tự sinh `LICENSES.md` từ manifest (có cột **Dùng thương mại: Có/Không**) — `packages/New-LicensesMd.ps1`
- [~] ⚠️ Rà soát license từng công cụ cho mục đích **cửa hàng** — loại/thay các freeware chỉ cho cá nhân — cột `Commercial=` ban đầu; cần đọc lại điều khoản từng công cụ

### Đóng gói công cụ (mục 7)
- [~] **Phân vùng**: DiskGenius, MiniTool PW, AOMEI PA, BOOTICE, Victoria — defs có sẵn
- [~] **Backup/Restore**: Hasleo Backup Suite, AOMEI Backupper, Dism++, wimlib, Ghost (nếu có license) — defs có sẵn
- [~] **Cứu dữ liệu**: DMDE, TestDisk/PhotoRec, Recuva — defs có sẵn
- [~] **Test phần cứng**: HWiNFO64, CPU-Z, GPU-Z, CrystalDiskInfo/Mark, HD Tune, OCCT, Prime95, FurMark, BatteryInfoView, Keyboard Test, Dead Pixel Test — defs có sẵn
- [~] **Hệ thống/mật khẩu**: NTPWEdit, Autoruns, Process Explorer, ProduKey/ShowKeyPlus, EasyUEFI, BitLocker GUI — defs có sẵn
- [~] **Mạng/remote**: Chrome/Firefox Portable, UltraViewer, AnyDesk/TeamViewer QS, WinSCP, FileZilla, PuTTY, Angry IP Scanner — defs có sẵn
- [~] **Diệt virus**: KVRT, Emsisoft Emergency Kit, AdwCleaner — defs có sẵn
- [~] **Tiện ích**: 7-Zip, Total Commander/Q-Dir, Everything, Notepad++, SumatraPDF, ImDisk/OSFMount, FastCopy/TeraCopy, IrfanView — defs có sẵn
- [ ] Công cụ thương mại có license: AIDA64, Macrium, Acronis, R-Studio... (theo quyết định)
- [x] Công cụ test nhanh cho cửa hàng: 1 nút chạy chuỗi test (SMART ổ, pin, bàn phím, màn hình, loa/mic, webcam) → xuất phiếu — `src/tools/QuickTest.ps1`

### Script tự viết
- [x] **FixBoot**: tự dò phân vùng Windows + EFI/System Reserved → `bcdboot` / `bootrec`, UEFI & Legacy — `src/fixboot/FixBoot.ps1`
- [x] Test webcam / mic / loa — trong QuickTest
- [x] Công cụ xem nhanh thông tin máy (model, serial, CPU, RAM, ổ, pin, key OEM) — `src/tools/SysInfo.ps1`

### Kiểm thử P2
- [ ] Tất cả công cụ mở được trong PE, shortcut đúng nhóm
- [ ] Full RAM: rút USB không lỗi
- [ ] Thời gian boot đến desktop (mục tiêu < 90 giây trên USB 3.0)

---

## P3 — Cài Windows (ZinSetup)

- [x] Tích hợp WinNTSetup (bản thủ công) — nút trong ZinSetup + `packages/defs/WinNTSetup.ini`
- [x] **Song ngữ (D6)**: khung i18n, `Lang/en-US.json`, `Lang/vi-VN.json`, nút chuyển EN/VI, cấu hình mặc định trong `zinpe.ini` — `src/lang/*.json`, nút EN/VI
- [ ] ZinSetup wizard:
  - [x] Liệt kê ISO/WIM/ESD trong `ZINDATA\ISO\Windows` → mount ISO
  - [x] Chọn edition (`dism /Get-WimInfo`)
  - [x] Phát hiện UEFI/Legacy (`PEFirmwareType`)
  - [x] Chọn ổ: xoá & chia tự động (GPT: EFI/MSR/Windows/Recovery · MBR: System Reserved/Windows) hoặc cài vào phân vùng có sẵn
  - [x] Apply (wimlib / dism) có thanh tiến trình
  - [x] Gọi ZinDriver (pha 1, mục 9.6)
  - [x] `bcdboot /f UEFI|BIOS|ALL`
  - [x] Báo cáo kết quả, log
- [ ] Unattend (tuỳ chọn bật/tắt):
  - [x] Bypass TPM/SecureBoot/RAM Win11 (kèm cảnh báo) — apply trực tiếp không bị kiểm tra; ghi LabConfig + MoSetup offline
  - [x] Bỏ online account (BypassNRO), tạo user local
  - [x] Locale/múi giờ VN
  - [x] Tắt device encryption tự động
  - [x] Gắn `SetupComplete.cmd` → ZinPost
- [x] Mẫu unattend trong `ZINDATA\ZinPE\Unattend\` — `config/Unattend/zin-unattend.xml`

### Cài nhanh cho cửa hàng (D4, mục 8.5)
- [x] Định dạng preset JSON (`ZinPE\Presets\*.json`): image, edition, chia ổ, unattend, gói ZinPost
- [x] Preset mẫu: `Win11-Pro-Shop`, `Win10-Pro-OldPC` (hoặc LTSC) — + `Win11-Pro-Bypass`
- [x] Kiểm tra máy đạt chuẩn Win11 (CPU, TPM 2.0, Secure Boot, RAM) → gợi ý preset
- [x] Chế độ 1 màn hình: chọn ổ + preset → Cài — tab Cài nhanh; CLI `ZinSetup.ps1 -Preset -Disk -Yes`
- [x] Script chuẩn bị image: tích hợp cumulative update, .NET 3.5, gộp edition vào 1 `install.esd` — `builder/image/Merge-ShopImages.ps1`

### Image chuẩn cửa hàng (mục 8.7.1)
- [ ] Dựng VM mẫu Win11 Pro (và Win10/LTSC) → Audit Mode
- [ ] Cài update, .NET 3.5, VC++ runtimes, DirectX, phần mềm chung
- [x] `unattend-sysprep.xml` + `sysprep /generalize /oobe` — `builder/image/unattend-sysprep.xml`
- [x] Capture bằng wimlib từ ZinWinPE → gộp vào `install.esd` — `src/tools/Capture-ShopImage.ps1`
- [~] Script hoá quy trình (`builder/image/`) để làm lại hằng tháng — capture + merge xong; phần VM mẫu làm tay theo `docs/build.md`
- [ ] Test: image chuẩn + ZinDriver trên máy Intel, AMD, đời cũ

### Phần mềm theo khách — ZinPost (mục 8.7.2)
- [x] Định dạng `app.ini` (Target, Type, Installer, Args, RunAs, DetectPath, Default, Winget, License, Verify) + 20 manifest mẫu trong `apps/`
- [ ] ⚠️ Kiểm thử các manifest `Verify=1`: SumatraPDF, UniKey, font Việt, UltraViewer, Zalo, AnyDesk, TeamViewer, Foxit, Adobe Reader, Cốc Cốc, Office, LibreOffice, Zoom
- [~] Bộ font Việt (VNI, TCVN3): chọn nguồn, script chép + đăng ký registry offline — code cài offline + đăng ký registry xong; còn chọn nguồn font
- [~] Cấu hình mặc định UniKey (Unicode + Telex, chạy cùng Windows) — ZinSetup nhập `apps/UniKey/defaults.reg` vào Default user nếu có; cần tạo file
- [~] `DefaultAppAssociations.xml` (PDF → SumatraPDF, web → Chrome, video → VLC) — `config/DefaultAppAssociations.xml`, cần kiểm ProgId
- [x] Office: `config-*.xml` cho ODT (365 / LTSC, tiếng Việt), quyết định nguồn offline hay online — 365 online + LTSC 2024
- [x] Script tải bộ cài mới nhất (`winget download` / `Source=`) + kiểm hash → `ZINDATA\ZinPE\Apps` — `apps/Get-Apps.ps1`
- [ ] Kiểm thử tham số silent từng bộ cài (thêm `/norestart`)
- [x] ZinSetup: màn hình chọn phần mềm (checkbox, song ngữ, preset chọn sẵn)
- [x] Chép bộ cài + `ZinPost.ps1` vào `W:\ZinPost`, đăng ký **cả** `SetupComplete.cmd` **và** `FirstLogonCommands`, cờ `done.flag` chống chạy lặp
- [x] Xử lý `RunAs`: `pe-offline` làm ngay trong PE · `system` qua SetupComplete · `user` qua FirstLogonCommands
- [x] winget upgrade khi có mạng (tuỳ chọn)
- [ ] Test trường hợp máy OEM có key trong BIOS (SetupComplete không chạy → FirstLogonCommands phải chạy)
- [~] Apply bằng `wimlib-imagex` đa luồng; đo thời gian cài trên USB 3.0 — đã dùng wimlib; còn đo thời gian
- [x] Phiếu kết quả `ZINDATA\Reports\<serial>_<ngày>.txt`
- [x] Cách C: mount ISO → chạy `setup.exe` gốc

### Kiểm thử P3
- [ ] Win11 UEFI/GPT (SB on) end-to-end
- [ ] Win10 Legacy/MBR end-to-end
- [ ] Cài vào phân vùng có sẵn, giữ dữ liệu phân vùng khác
- [ ] Máy không đạt chuẩn Win11 + bypass
- [ ] Cài nhanh bằng preset: đo thời gian từ bấm Cài → desktop (mục tiêu < 15 phút trên SSD)
- [ ] Giao diện EN/VI đầy đủ, không sót chuỗi

---

## P4 — Driver (ZinDriver / ZinDriverSync / ZinPost)

### ZinDriverSync (chạy trên máy build)
- [x] Đọc catalog: Dell `DriverPackCatalog.cab`, HP `HPClientDriverPackCatalog.cab`, Lenovo `catalogv2.xml`
- [x] Danh sách model chọn trước (`drivers/models.json`): Latitude, Precision, OptiPlex, EliteBook, ProBook, ThinkPad, ThinkCentre, Surface...
- [x] Tải, kiểm hash, **giải nén `.exe` → `.inf`**
- [x] Chuẩn hoá thư mục `OS\<Vendor>\<Model|PlatformID|MTM4>\<OS>\`
- [x] Sinh `index.json`
- [~] Tải/cập nhật SDIO + driverpacks — SDIO đặt thủ công vào `drivers/store/SDIO`
- [x] Tạo gói **Standard (mặc định)**, Lite, Full — `-Package Lite|Standard|Full`
- [~] ⚠️ Tỉa SDIO cho vừa USB 64 GB (mục tiêu ~25–30 GB), kiểm tra tổng dung lượng theo bảng ngân sách mục 9.5 — `models.json` sdio.exclude/lite + báo dung lượng

### ZinDriver (chạy trong PE)
- [x] Nhận diện: Manufacturer, Model, SKU, BaseBoard (HP), MTM4 (Lenovo), danh sách HWID
- [x] Khớp `index.json` → `dism /Image:W:\ /Add-Driver /Recurse`
- [x] Fallback: lọc SDIO theo HWID, chỉ inject driver khớp — `sdio-index.tsv`
- [x] Driver T2 cho chính PE (drvload)
- [x] Log `driver.log`

### ZinPost — phần driver (lần đầu vào Windows)
- [ ] Cài silent app hãng, driver đồ hoạ đầy đủ
- [ ] DCH apps qua `Add-ProvisionedAppxPackage` (nếu có)
- [x] SDIO quét thiết bị còn thiếu (chạy **trước** khi cài phần mềm)
- [x] Ghi log, tự dọn bộ cài tạm

### Kiểm thử P4
- [ ] Dell / HP / Lenovo có pack → Device Manager không còn thiết bị lỗi
- [ ] Asus / Acer / MSI / máy lắp ráp → fallback SDIO hoạt động
- [ ] Không có BSOD / xung đột sau inject

---

## P5 — ZinWinPE Installer

- [x] Chọn công nghệ GUI (WinForms / WPF / PowerShell + WPF) — PowerShell + WPF
- [x] Chỉ liệt kê ổ USB/removable, xác nhận 2 lần trước khi xoá
- [x] Tuỳ chọn: MBR/GPT (mặc định MBR), exFAT/NTFS, kích thước ZINBOOT, bộ boot files (Auto/2011/2023), gói driver (mặc định Standard) — gói driver chọn lúc build (ZinDriverSync)
- [x] Giao diện song ngữ EN/VI (dùng chung khung i18n với ZinSetup)
- [x] Cảnh báo khi USB < 64 GB hoặc không đủ chỗ cho gói đã chọn
- [x] Tạo mới: diskpart → copy → `bootsect /nt60` → active → ẩn P1 → `zinpe.tag`
- [x] **Cập nhật** giữ nguyên ISO & dữ liệu người dùng
- [x] Cài vào ổ cứng (thêm mục boot vào BCD của máy)
- [x] Tạo ISO (cho VM / Ventoy)
- [x] Xác minh hash sau khi chép
- [x] Hướng dẫn sử dụng `docs/user-guide.md`

---

## P6 — Mở rộng → bản 1.0

- [ ] MemTest86 / Memtest86+ (đã ký MOK)
- [ ] ISO Linux: SystemRescue, GParted Live, Clonezilla (khi dùng USB ≥ 128 GB)
- [~] Chế độ tương thích Ventoy — ISO gộp ZINBOOT + ZinPE (`-Action Iso`)
- [ ] Gói driver Full
- [ ] Thống kê từ phiếu kết quả (số máy, model hay gặp, driver hay thiếu) → bổ sung kho driver
- [ ] Chạy toàn bộ checklist mục 14.3 trên ma trận máy mục 14.2
- [ ] Phát hành **v1.0** (tag Git, CHANGELOG, release notes)

---

## P7 — Tương lai

- [ ] WinPE ARM64 (Snapdragon X, Surface ARM)
- [ ] Boot qua mạng PXE / iPXE
- [ ] Cập nhật công cụ / driver online từ trong PE
- [~] Tự động build (CI trên Windows runner) cho phần không cần ISO bản quyền — unit test Pester chạy được trên mọi OS

---

## 📌 Theo dõi định kỳ

- [ ] Hằng tháng: cập nhật phiên bản công cụ (`packages/*.ini`)
- [ ] Hằng tháng: làm lại image chuẩn cửa hàng (update + phần mềm mới) cho Cài nhanh
- [ ] Hằng tháng: cập nhật bộ cài trong `Apps\`
- [ ] Hằng quý: chạy ZinDriverSync, cập nhật WinPE driver pack
- [ ] Theo dõi SBAT / bản shim mới; ký lại GRUB2 khi cập nhật
- [ ] Theo dõi thông báo Microsoft về Secure Boot CA 2023 / DBX
- [ ] Khi có bản Windows/ADK mới: build lại PE, chạy lại kiểm thử

# ZinWinPE — Tài liệu thiết kế USB cứu hộ WinPE

> Phiên bản tài liệu: 0.2 (đã chốt quyết định — mục 1.4) · Ngày: 2026-10-12
> Mục tiêu: xây dựng một bộ USB boot cứu hộ đa năng (tương tự AnhDV Boot / DLC Boot / Hiren's BootCD PE), tự build, tự kiểm soát nội dung và dễ cập nhật.

---

## Mục lục

1. [Tổng quan & mục tiêu](#1-tổng-quan--mục-tiêu)
2. [Phạm vi phần cứng hỗ trợ](#2-phạm-vi-phần-cứng-hỗ-trợ)
3. [Kiến trúc tổng thể](#3-kiến-trúc-tổng-thể)
4. [Bố cục USB & phân vùng](#4-bố-cục-usb--phân-vùng)
5. [Cơ chế boot (UEFI / Legacy / Secure Boot)](#5-cơ-chế-boot-uefi--legacy--secure-boot)
6. [Thiết kế WinPE](#6-thiết-kế-winpe)
7. [Danh mục công cụ](#7-danh-mục-công-cụ)
8. [Cài Windows](#8-cài-windows)
9. [Chiến lược driver](#9-chiến-lược-driver)
10. [Cấu trúc thư mục trên USB](#10-cấu-trúc-thư-mục-trên-usb)
11. [Quy trình build](#11-quy-trình-build)
12. [Công cụ tạo USB (ZinWinPE Installer)](#12-công-cụ-tạo-usb-zinwinpe-installer)
13. [Cập nhật & quản lý phiên bản](#13-cập-nhật--quản-lý-phiên-bản)
14. [Kiểm thử](#14-kiểm-thử)
15. [Lộ trình triển khai](#15-lộ-trình-triển-khai)
16. [Bản quyền & pháp lý](#16-bản-quyền--pháp-lý)
17. [Rủi ro & lưu ý kỹ thuật](#17-rủi-ro--lưu-ý-kỹ-thuật)
18. [Phụ lục](#18-phụ-lục)

---

## 1. Tổng quan & mục tiêu

### 1.1 Mục tiêu chính

| # | Mục tiêu | Mô tả |
|---|----------|-------|
| G1 | **WinPE cứu hộ** | Môi trường Windows PE x64 có giao diện Explorer, mạng, âm thanh, đầy đủ công cụ test phần cứng, phân vùng, copy/backup/restore, cứu dữ liệu, sửa boot, reset mật khẩu. |
| G2 | **Cài Windows dễ dàng** | Cài Windows 10/11 (và tuỳ chọn 7/8.1) từ ISO/WIM/ESD đặt trên USB, chọn edition, tự nạp driver, tuỳ chọn bỏ qua yêu cầu TPM/Secure Boot/online account của Win11. |
| G3 | **Driver đầy đủ** | Nhận ổ cứng, mạng, touchpad trên mọi máy từ 2015 trở lại đây ngay trong WinPE; có kho driver theo hãng/model để nạp vào Windows sau khi cài. |
| G4 | **Dễ bảo trì** | Công cụ để ngoài boot.wim (portable, nạp khi khởi động) → cập nhật công cụ không cần build lại PE. |
| G5 | **Tương thích boot** | UEFI 64-bit (có/không Secure Boot) và Legacy BIOS/CSM. |

### 1.2 Ngoài phạm vi (giai đoạn đầu)

- Máy ARM64 (Snapdragon X, Surface Pro X...) — để dành phiên bản sau.
- WinPE 32-bit (x86) — máy từ 2015 gần như đều x64; chỉ cân nhắc nếu có nhu cầu thật.
- Máy Mac Intel/Apple Silicon.

### 1.3 Đối tượng sử dụng

Kỹ thuật viên sửa chữa máy tính, IT nội bộ doanh nghiệp, người dùng nâng cao.

### 1.4 Quyết định đã chốt (2026-10-12)

| # | Hạng mục | Quyết định | Ảnh hưởng |
|---|----------|-----------|-----------|
| D1 | Số bản PE | **1 bản: ZinWinPE 11 x64** (nguồn Windows 11) | Bỏ ZinWinPE 10; vẫn cài được Win10 từ PE 11 |
| D2 | Gói driver mặc định | **Standard**, USB mục tiêu **64 GB** | Ngân sách dung lượng chặt — xem mục 9.5 |
| D3 | Legacy BIOS | **Có hỗ trợ** | MBR mặc định, BCD + GRUB2 cho cả BIOS |
| D4 | Mục đích sử dụng | **Cửa hàng sửa chữa** — dùng cho nhiều máy, nhiều máy cũ, cần **cài đặt nhanh** | Ưu tiên chế độ Cài nhanh (mục 8.5); license phải cho phép dùng thương mại (mục 16) |
| D5 | GRUB2 + Secure Boot | **GRUB2 + shim ngay từ đầu** (giai đoạn P1) | Xem mục 5.2 — cần MOK, rủi ro chứng chỉ |
| D6 | Ngôn ngữ ZinSetup | **Song ngữ Anh + Việt** (chọn khi chạy, mặc định theo cấu hình) | File ngôn ngữ tách riêng (mục 8.6) |
| D7 | Builder chính | **PhoenixPE** (PEBakery) | Win10XPE chỉ là phương án dự phòng |
| — | Phần mềm thương mại có license | *Chưa chốt* | Giai đoạn đầu chỉ dùng freeware cho phép dùng thương mại |

---

## 2. Phạm vi phần cứng hỗ trợ

| Nhóm | Phạm vi |
|------|---------|
| CPU Intel | Gen 6 (Skylake, 2015) → Core Ultra (Meteor Lake / Lunar Lake / Arrow Lake) và mới hơn |
| CPU AMD | Ryzen 1000 → Ryzen 9000 / Ryzen AI |
| Lưu trữ | SATA AHCI, NVMe, **Intel RST / VMD** (bắt buộc driver với Gen 11+ nhiều laptop), AMD RAID/RAIDXpert2, eMMC, USB-C/Thunderbolt |
| Mạng | Intel / Realtek / Killer / Broadcom / Marvell LAN; WiFi Intel / Realtek / MediaTek / Qualcomm-Atheros / Broadcom |
| Input | I2C HID touchpad (Intel Serial IO, AMD I2C), touchscreen |
| USB | USB 3.x xHCI, USB4/Thunderbolt 3/4 |
| Hãng | Dell, HP, Lenovo, Asus, Acer, MSI, Gigabyte, Microsoft Surface, Toshiba/Dynabook, Samsung, LG, Fujitsu, máy lắp ráp (desktop) |
| RAM tối thiểu | 4 GB (khuyến nghị 8 GB cho chế độ load toàn bộ vào RAM) |

---

## 3. Kiến trúc tổng thể

```
┌──────────────────────────────────────────────────────────────────┐
│                          USB ZinWinPE                            │
│                                                                  │
│  ┌───────────── P1: ZINBOOT (FAT32, ẩn) ─────────────┐           │
│  │ EFI\Boot\bootx64.efi  → Windows Boot Manager       │           │
│  │ EFI\Boot\grubx64.efi  → GRUB2 (menu phụ, ISO, mem) │           │
│  │ bootmgr + BCD (Legacy) · grub4dos/grub2 (Legacy)   │           │
│  │ ZinPE\boot.wim (WinPE x64 lõi, ~1–1.5 GB)          │           │
│  └────────────────────────────────────────────────────┘           │
│                                                                  │
│  ┌───────────── P2: ZINDATA (exFAT/NTFS, hiện) ──────┐           │
│  │ ZinPE\Programs\   công cụ portable (.7z/.wim)      │           │
│  │ ZinPE\Drivers\    kho driver WinPE + theo hãng      │           │
│  │ ZinPE\Scripts\    script tự động (cài Win, driver) │           │
│  │ ISO\              ISO Windows, Linux, tiện ích     │           │
│  │ (không gian trống cho dữ liệu người dùng)          │           │
│  └────────────────────────────────────────────────────┘           │
└──────────────────────────────────────────────────────────────────┘

Luồng khởi động:
 Firmware → bootx64.efi / bootmgr → BCD menu
   ├─ ZinWinPE 11 x64 (mặc định)      → boot.wim → PE Loader
   ├─ Menu phụ (GRUB2)                 → MemTest86, Linux rescue, boot ISO
   └─ Boot vào ổ cứng
 PE Loader (startup):
   1. Tìm phân vùng ZINDATA (theo file đánh dấu ZinPE\zinpe.tag)
   2. Nạp driver bổ sung (storage/net/input) theo phần cứng phát hiện
   3. Mount/giải nén công cụ portable → tạo shortcut Desktop/Start Menu
   4. Khởi động mạng (PENetwork), đồng bộ giờ, áp theme
```

### 3.1 Nguyên tắc thiết kế

1. **boot.wim nhỏ gọn**: chỉ chứa thành phần hệ thống + driver boot-critical + vài công cụ thiết yếu (để vẫn dùng được khi không tìm thấy phân vùng dữ liệu).
2. **Công cụ để ngoài**: phần lớn công cụ nằm ở P2, đóng gói từng gói `.7z` hoặc `.wim`, nạp lúc khởi động → thêm/bớt/cập nhật bằng cách chép file.
3. **Không phụ thuộc ký tự ổ đĩa**: mọi script dò ổ theo file đánh dấu / nhãn phân vùng.
4. **Một nguồn sự thật cho driver**: index JSON ánh xạ Manufacturer/Model/SKU → thư mục driver.

---

## 4. Bố cục USB & phân vùng

### 4.1 Phương án chọn: 2 phân vùng (giống AnhDV Boot)

| Phân vùng | FS | Kích thước | Thuộc tính | Nội dung |
|-----------|----|-----------|------------|----------|
| P1 `ZINBOOT` | FAT32 | 2–4 GB | Ẩn (không gán ký tự), active (Legacy) | EFI, bootmgr, BCD, GRUB, các file `.wim` của PE |
| P2 `ZINDATA` | exFAT (mặc định) hoặc NTFS | Phần còn lại | Hiện, dùng như USB thường | Công cụ, driver, ISO, dữ liệu người dùng |

- **Vì sao FAT32 cho P1**: mọi firmware UEFI đều đọc được FAT32 → boot ổn định nhất, không cần driver NTFS/exFAT trong UEFI.
- **Giới hạn 4 GB/file của FAT32**: boot.wim phải < 4 GB (thiết kế đã giữ ~1–1.5 GB).
- **P2 exFAT vs NTFS**: exFAT đọc/ghi được trên Windows + macOS; NTFS hỗ trợ quyền/file nén/ổn định hơn khi copy file lớn. Cho phép chọn khi tạo USB.
- Windows 10 1703+ đọc được nhiều phân vùng trên USB removable → P2 hiện ra bình thường.
- Đặt P2 **trước** hoặc **sau** P1: đặt P1 ở cuối ổ (như AnhDV) giúp Windows cũ chỉ thấy P2; đặt P1 đầu ổ đơn giản hơn. → Chọn **P1 đầu ổ, ẩn bằng cách bỏ ký tự ổ + GPT attribute / MBR type 0x1C (hidden FAT32 LBA)**. Cần kiểm thử với các firmware kén.

### 4.2 Bảng phân vùng: MBR hay GPT?

- **Mặc định MBR** (hybrid boot): boot được cả Legacy lẫn UEFI trên hầu hết máy.
- **Tuỳ chọn GPT**: chỉ UEFI, dùng cho ổ > 2 TB (SSD gắn ngoài) hoặc khi máy yêu cầu.

### 4.3 Phương án thay thế: Ventoy

Có thể hỗ trợ thêm chế độ "Ventoy compatible": chép `ZinWinPE.iso` + thư mục `ZinPE` vào USB Ventoy. Ưu điểm: dễ thêm ISO; nhược: Secure Boot phải enroll key MOK, một số máy kén. → **Giai đoạn 3**, không phải phương án chính.

---

## 5. Cơ chế boot (UEFI / Legacy / Secure Boot)

### 5.1 Menu khởi động chính — Windows Boot Manager (BCD)

- UEFI: `\EFI\Boot\bootx64.efi` = `bootmgfw.efi` (ký bởi Microsoft) → Secure Boot OK.
- Legacy: `bootmgr` + `\Boot\BCD`.
- Các mục: ZinWinPE 11 x64, Menu phụ (GRUB2), Boot ổ cứng nội bộ.
- Boot WIM dạng **ramdisk** (`boot.sdi` + `.wim`): toàn bộ PE chạy trên RAM → rút USB ra vẫn dùng được PE (nhưng mất truy cập công cụ ở P2 nếu chưa nạp vào RAM).

### 5.2 Menu phụ — GRUB2

- MemTest86 (UEFI), Memtest86+ (Legacy/UEFI), Linux rescue (SystemRescue, GParted Live, Clonezilla), boot ISO trực tiếp, chuyển tiếp sang Ventoy-like ISO boot.
- **Secure Boot — làm ngay từ P1 (D5)**. Phương án:
  1. Dùng **shim đã được Microsoft ký** (Microsoft UEFI CA) lấy từ một bản phân phối Linux (Debian/Ubuntu/Fedora) — ZinWinPE không tự xin ký được.
  2. Tạo **khoá MOK riêng của ZinWinPE**; ký `grubx64.efi` và các file EFI phụ (memtest, kernel Linux nếu cần) bằng khoá này.
  3. Lần đầu boot menu phụ trên một máy có Secure Boot: **MokManager** hiện ra → enroll khoá ZinWinPE (`ENROLL_THIS_KEY_IN_MOKMANAGER.cer`, giống cách Ventoy làm). Mỗi máy chỉ cần 1 lần.
  4. Menu chính (WinPE qua bootmgr) **không cần MOK** — chỉ menu phụ GRUB2 cần.
  5. *(Ghi chú triển khai)* Windows Boot Manager khi bật Secure Boot chỉ chạy ứng dụng ký Windows → mục BCD "Menu phụ" (bootapp → `\EFI\zin\shimx64.efi`) dự kiến chỉ chạy khi **tắt** SB; khi bật SB vào GRUB2 qua "Boot from file" của firmware (`docs/mok-enroll.md`). Cần kiểm chứng trên máy thật.
- Rủi ro cần kiểm thử:
  - **SBAT**: các shim/GRUB cũ đã bị thu hồi qua SBAT → phải dùng shim bản mới (≥ 15.8) và GRUB có SBAT hợp lệ.
  - **Microsoft UEFI CA 2011 hết hạn (2026)**: shim mới ký bằng CA 2023 có thể không chạy trên máy cũ chưa có CA 2023 trong DB → cần giữ cả shim ký CA 2011 (nếu chưa bị thu hồi) và CA 2023, chọn theo máy giống bootmgr (mục 5.3).
  - Với cửa hàng: thao tác enroll MOK trên từng máy khách tốn thời gian → khi chỉ cần WinPE thì luôn vào menu chính; menu phụ dùng khi thật cần (MemTest, Linux).

### 5.3 Vấn đề chứng chỉ Secure Boot 2023 (quan trọng)

- Các chứng chỉ Secure Boot **Microsoft 2011** (Windows Production PCA 2011, Microsoft UEFI CA 2011) hết hạn trong năm 2026, Microsoft đã chuyển sang **Windows UEFI CA 2023**; các máy đã nhận bản cập nhật DBX (giảm thiểu BlackLotus – CVE-2023-24932) có thể **từ chối bootmgr ký bằng PCA 2011**.
- Hệ quả: USB dùng bootmgr cũ có thể không boot được trên máy đã cập nhật khi bật Secure Boot.
- Giải pháp:
  1. Lấy `bootmgfw.efi` / boot files **ký bằng Windows UEFI CA 2023** (từ ADK/ISO Windows 11 bản mới, thư mục `EFI_EX` / `bootmgfw_EX.efi`, hoặc công cụ `Make2023BootableMedia.ps1` của Microsoft).
  2. Duy trì **2 bộ boot files** (2011 cho máy cũ chưa có CA 2023 trong DB, 2023 cho máy mới) — installer cho phép chọn hoặc có mục BCD dự phòng.
  3. Ghi rõ trong hướng dẫn: nếu không boot được với Secure Boot → thử bộ boot files còn lại / tắt Secure Boot.
- ⚠️ Cần kiểm chứng lại tình trạng mới nhất từ Microsoft tại thời điểm build (xem Phụ lục C).

---

## 6. Thiết kế WinPE

### 6.1 Một bản PE: ZinWinPE 11 x64 (D1)

| Bản | Nguồn | Dùng cho |
|-----|-------|----------|
| **ZinWinPE 11 x64** | Windows 11 24H2/25H2 (install.wim/WinRE) | Tất cả máy x64 từ 2015: UEFI + Legacy BIOS |

- WinPE 11 vẫn boot được Legacy BIOS và vẫn cài được Windows 10 / LTSC → không cần bản PE 10 riêng.
- Máy cũ RAM thấp (4 GB): giữ boot.wim nhỏ, chế độ Bình thường (không Full RAM).
- Nếu gặp phần mềm/driver kén PE 11 trên máy cũ → ghi nhận lại; chỉ cân nhắc build thêm PE 10 khi thật cần.

### 6.2 Công cụ build

Ưu tiên dùng builder cộng đồng đã trưởng thành thay vì tự build từ ADK thuần (ADK WinPE thiếu Explorer, thiếu nhiều thành phần):

| Builder | Ghi chú | Lựa chọn |
|---------|---------|----------|
| **PhoenixPE** (PEBakery) | Hiện đại, hỗ trợ Win10/11, script rõ ràng, dễ tuỳ biến | ✅ **Đã chọn (D7)** |
| **Win10XPE** (ChrisR) | Rất nhiều plugin, cộng đồng TheOven lớn, hỗ trợ cả Win11 | Dự phòng (khi PhoenixPE thiếu thành phần) |
| Windows ADK + DISM thủ công | Kiểm soát hoàn toàn nhưng phải tự bổ sung shell, thành phần | ❌ Chỉ dùng cho bản "PE Setup" tối giản |

### 6.3 Thành phần hệ thống trong PE

- Shell: Explorer (hoặc WinXShell nhẹ hơn), Start menu (StartAllBack/Open-Shell), taskbar, thumbnail.
- Mạng: TCP/IP, WiFi (WLAN service), SMB client/server, RDP client, **PENetwork** quản lý mạng.
- Âm thanh, hiển thị (đổi độ phân giải, DPI scaling), font Việt (Segoe UI, Arial, Times New Roman) + bộ gõ **UniKey/EVKey**.
- PowerShell 5.1, WMI, .NET Framework 4.8 (cần cho nhiều công cụ), MSI, VC++ runtimes.
- BitLocker (manage-bde, unlock bằng recovery key), Storage Spaces, VHD/VHDX mount, ISO mount (ImDisk).
- Ngôn ngữ: giao diện tiếng Anh + hỗ trợ hiển thị tiếng Việt; locale vi-VN, múi giờ SE Asia Standard Time.

### 6.4 PE Loader (khởi động)

Một chương trình/ script chạy khi PE khởi động (PECMD, hoặc PowerShell/AutoIt được biên dịch):

```text
1. Đặt độ phân giải, theme, múi giờ
2. Dò phân vùng dữ liệu: tìm \ZinPE\zinpe.tag trên mọi volume → gán biến %ZINDATA%
3. Nạp driver bổ sung:
     - Đọc PnP ID chưa có driver (pnputil /enum-devices /problem)
     - drvload/pnputil /add-driver từ %ZINDATA%\ZinPE\Drivers\PE\...
     - Rescan ổ đĩa (để thấy ổ VMD/RAID vừa nạp driver)
4. Nạp công cụ:
     - Duyệt %ZINDATA%\ZinPE\Programs\*.7z|*.wim
     - Mỗi gói kèm manifest (tên, nhóm, exe, icon, cần .NET?, chạy từ RAM hay từ USB)
     - Giải nén vào X:\Programs (RAM) hoặc mount wim read-only
     - Tạo shortcut Start Menu theo nhóm + Desktop cho công cụ ghim
5. Khởi động PENetwork (DHCP), đồng bộ giờ (nếu có mạng)
6. Mở Explorer
```

Manifest mẫu cho mỗi công cụ (`Programs\DiskGenius.ini`):

```ini
[Program]
Name=DiskGenius
Group=Partition
Archive=DiskGenius_6.0.7z
Exe=DiskGenius\DiskGenius.exe
Desktop=1
LoadToRam=1
Arch=x64
```

### 6.5 Chế độ khởi động

- **Bình thường**: PE trong RAM, công cụ nạp từ USB.
- **Full RAM** (tuỳ chọn khi RAM ≥ 8 GB): nạp tất cả công cụ vào RAM → rút USB ra dùng cho việc khác (copy dữ liệu, cài Win từ USB khác).
- **Safe/Minimal**: không nạp driver bổ sung, không nạp công cụ — để xử lý máy bị treo khi nạp driver.

### 6.6 Nhận diện: logo & giao diện

Logo chính: chữ **Z vàng kim trong vòng tròn**, nền trong suốt — file gốc `logo-trans.png` (571×522, RGBA). Tài nguyên dẫn xuất nằm trong `assets/branding/`:

| File | Kích thước | Dùng cho |
|------|-----------|----------|
| `logo-square.png` | vuông, nền trong suốt | Bản gốc đã căn vuông để sinh các size khác |
| `zinwinpe.ico` | 16–256 px (nhiều size) | Icon ZinSetup, ZinWinPE Installer, PE Loader, shortcut, icon ổ USB |
| `logo-16/32/48/64/128/256.png` | | Icon trong giao diện, Start menu, báo cáo |
| `wallpaper-1920x1080.png` | 1920×1080 | Hình nền desktop WinPE |
| `grub-bg-1024x768.png` | 1024×768 | Nền theme GRUB2 (menu phụ) |

Nơi hiển thị logo:

| Vị trí | Cách làm |
|--------|---------|
| Hình nền WinPE | PhoenixPE: thay wallpaper khi build; **phiên bản in động** (PE Loader vẽ đè hoặc build sinh lại ảnh theo `version.txt`) |
| Màn hình chờ PE Loader | Splash nhỏ có logo + tiến trình nạp driver/công cụ |
| ZinSetup / Installer | Icon cửa sổ & file `.exe`, logo trên header |
| Menu GRUB2 | Theme `boot/grub/themes/zinwinpe/` với nền + logo |
| Icon ổ USB (ZINDATA) | `autorun.inf` ở gốc ZINDATA: `[autorun]` `icon=ZinPE\zinwinpe.ico` `label=ZinWinPE` (Windows vẫn hiện icon/nhãn dù autorun đã bị tắt) |
| Phiếu kết quả (mục 8.5) | Logo ở đầu phiếu (khi xuất HTML/PDF) |
| README / GitHub | Logo đầu README |

Giới hạn:

- **Menu BCD (Windows Boot Manager) không đổi được logo** — chỉ là menu chữ; màn hình boot WinPE hiện logo Windows/logo hãng (BGRT). Logo chỉ xuất hiện từ khi PE vào desktop, và ở menu GRUB2.
- Logo có chi tiết mảnh (3 vạch nhỏ, viền kim loại) → ở 16–24 px hơi nhoè; nên có thêm **bản icon đơn giản hoá** (Z phẳng, 1 màu) cho size nhỏ.
- File gốc chỉ 571 px → đủ cho 1080p; muốn hình nền 2K/4K sắc nét cần **bản gốc ≥ 2048 px hoặc vector (SVG)**.
- Màu chủ đạo cho giao diện: vàng kim `#DEB85C` trên nền tối `#0E1016`.

---

## 7. Danh mục công cụ

> Cột **License**: F = Freeware, F* = miễn phí cho cá nhân/có giới hạn, C = thương mại (cần mua license, chỉ đưa vào nếu có license hợp lệ). Xem mục 16.

### 7.1 Phân vùng & ổ đĩa

| Công cụ | License | Ghi chú |
|---------|---------|---------|
| DiskGenius | F* | Phân vùng, chuyển MBR↔GPT, clone, cứu phân vùng |
| MiniTool Partition Wizard | F* | |
| AOMEI Partition Assistant | F* | |
| Diskpart / Disk Management (diskmgmt.msc) | Có sẵn | |
| BOOTICE | F | Sửa MBR/PBR, BCD, UEFI boot entries |
| HDD Low Level Format / Disk wipe (DiskGenius, `diskpart clean all`) | F | |
| Victoria | F | Test bề mặt, remap |

### 7.2 Backup / Restore / Clone

| Công cụ | License | Ghi chú |
|---------|---------|---------|
| Hasleo Backup Suite | F | Backup/restore/clone, hỗ trợ tốt UEFI |
| AOMEI Backupper | F* | |
| Macrium Reflect | C | |
| Acronis Cyber Protect Home | C | |
| Norton Ghost 11.5 / Ghost64 12 + OneKey Ghost | — | File .gho phổ biến ở VN; kiểm tra bản quyền |
| Dism++ | F | Backup/restore WIM, dọn hệ thống, sửa boot |
| wimlib-imagex | F | Capture/apply WIM/ESD nhanh |
| Clonezilla (menu GRUB2) | F | Clone sector-level |

### 7.3 Cứu dữ liệu

| Công cụ | License |
|---------|---------|
| DMDE | F* |
| TestDisk / PhotoRec | F |
| Recuva Portable | F* |
| R-Studio | C |
| Active@ / EaseUS (tuỳ license) | C |

### 7.4 Test phần cứng

| Công cụ | Mục đích | License |
|---------|----------|---------|
| HWiNFO64 | Thông tin + cảm biến | F |
| CPU-Z, GPU-Z | CPU/RAM/GPU | F |
| AIDA64 | Thông tin, stress test | C |
| CrystalDiskInfo / CrystalDiskMark | SMART, tốc độ ổ | F |
| HD Tune / HD Sentinel | Test ổ | F*/C |
| OCCT / Prime95 / FurMark | Stress CPU/GPU/PSU | F* |
| BatteryInfoView / BatteryMon | Độ chai pin | F |
| Keyboard Test Utility, Mouse test | Bàn phím, chuột | F |
| Dead Pixel Tester / Screen test | Màn hình | F |
| Webcam/mic/loa test (script đơn giản) | Ngoại vi | Tự viết |
| MemTest86 / Memtest86+ (menu GRUB2) | RAM | F |
| ThrottleStop (chỉ xem) | Nhiệt/xung | F |

### 7.5 Hệ thống, boot, mật khẩu

| Công cụ | Mục đích |
|---------|----------|
| Script **Fix Boot UEFI/Legacy** (bcdboot, bootrec, bcdedit) | Sửa boot một chạm, tự dò phân vùng Windows & EFI |
| EasyUEFI / BOOTICE | Quản lý boot entry UEFI |
| NTPWEdit / Lazesoft Recover My Password / Windows Login Unlocker | Reset/xoá mật khẩu tài khoản local |
| Registry Editor PE (sửa registry offline), Autoruns, Process Explorer | Dọn malware, sửa hệ thống |
| Windows Recovery helpers (sfc /offbootdir, DISM /Image) | Sửa file hệ thống offline |
| ProduKey / ShowKeyPlus | Lấy key Windows/Office (OEM key trong BIOS) |
| BitLocker unlock tool (manage-bde GUI) | Mở khoá ổ BitLocker bằng recovery key |

### 7.6 Mạng & điều khiển từ xa

PENetwork, Chrome/Firefox Portable, UltraViewer / TeamViewer QS / AnyDesk (tuỳ license), WinSCP, FileZilla, chia sẻ SMB, Angry IP Scanner, PuTTY.

### 7.7 Diệt virus (offline)

Kaspersky Virus Removal Tool (KVRT), Emsisoft Emergency Kit, ESET Online Scanner, HitmanPro (C), Malwarebytes AdwCleaner.

### 7.8 Tiện ích chung

7-Zip, Total Commander / Q-Dir / Explorer++, Everything, Notepad++, SumatraPDF, ImDisk / OSFMount, Snipping tool, IrfanView, FastCopy / TeraCopy (copy dữ liệu lớn, verify), UniKey/EVKey.

---

## 8. Cài Windows

### 8.1 Nguồn cài đặt

Đặt ISO/WIM/ESD trong `ZINDATA:\ISO\Windows\` (hoặc `ZINDATA:\WIM\`):

- Windows 11 (24H2/25H2) x64, Windows 10 22H2 x64, Windows LTSC (tuỳ chọn), Windows 7/8.1 (tuỳ chọn, cho máy đặc thù).
- Có thể dùng file `install.wim` đã tuỳ biến (tích hợp update, driver, phần mềm).

### 8.2 Ba cách cài

| Cách | Mô tả | Khi nào dùng |
|------|-------|--------------|
| **A. ZinSetup (khuyến nghị)** | Wizard tự viết bọc **WinNTSetup** + script: chọn ISO → chọn edition → chọn ổ → tự chia phân vùng GPT/MBR theo chế độ boot → apply → nạp driver theo model → bcdboot → unattend | Đa số trường hợp |
| **B. WinNTSetup thủ công** | Dùng trực tiếp WinNTSetup | KTV muốn kiểm soát chi tiết |
| **C. Setup gốc của Microsoft** | Mount ISO → chạy `setup.exe` (hoặc `sources\setup.exe` cho clean install) | Nâng cấp tại chỗ / cần trình cài gốc |

### 8.3 Luồng ZinSetup

```text
[1] Chọn nguồn: liệt kê ISO/WIM/ESD trong ZINDATA\ISO → mount ISO (PowerShell Mount-DiskImage / ImDisk)
[2] Chọn edition: đọc dism /Get-WimInfo
[3] Chọn ổ đích + chế độ:
      - Phát hiện chế độ boot hiện tại (UEFI/Legacy) qua registry PEFirmwareType
      - Tuỳ chọn: "Xoá sạch ổ & chia tự động" hoặc "Cài vào phân vùng có sẵn"
      - UEFI → GPT: EFI 260MB FAT32, MSR 16MB, Windows, Recovery 1GB
      - Legacy → MBR: System Reserved 500MB NTFS active, Windows
[4] Apply image: wimlib-imagex apply / dism /Apply-Image
[5] Driver: chạy ZinDriver (mục 9.4) → dism /Image:W:\ /Add-Driver /Driver:<dir> /Recurse
[6] Boot: bcdboot W:\Windows /s S: /f UEFI|BIOS|ALL
[7] Unattend (tuỳ chọn, tick chọn):
      - Bỏ qua TPM/SecureBoot/RAM check Win11 (LabConfig/ BypassNRO) — cảnh báo người dùng
      - Tạo tài khoản local, bỏ OOBE online account
      - Ngôn ngữ/múi giờ VN, tắt BitLocker tự động mã hoá (device encryption)
      - Copy SDIO + script cài driver bổ sung vào C:\ZinPost để chạy lần đầu đăng nhập
[8] Phần mềm (mục 8.7): chép bộ cài đã chọn + manifest vào W:\ZinPost, đăng ký chạy tự động
[9] Báo cáo & khởi động lại
```

### 8.4 Hậu cài đặt (tuỳ chọn)

- Chạy Snappy Driver Installer Origin (offline) cho thiết bị còn thiếu.
- Cài gói phần mềm cơ bản — chi tiết ở mục 8.7.
- Kích hoạt: **không** tích hợp công cụ kích hoạt lậu. Máy OEM có key trong BIOS (MSDM) sẽ tự kích hoạt.

### 8.5 Chế độ Cài nhanh cho cửa hàng (D4)

Mục tiêu: KTV chỉ cần **chọn ổ + chọn bản Windows + bấm Cài**, mọi thứ còn lại tự động.

| Thành phần | Mô tả |
|-----------|-------|
| **Preset** | File cấu hình đặt sẵn (vd `Win11-Pro-Shop.json`, `Win10-Pro-OldPC.json`): image, edition, kiểu chia ổ, unattend, gói phần mềm ZinPost |
| **Tự chọn theo máy** | Gợi ý preset: máy không đạt chuẩn Win11 (CPU cũ, không TPM 2.0) → gợi ý Win10/LTSC hoặc Win11 + bypass (có cảnh báo) |
| **Image chuẩn bị sẵn** | WIM/ESD đã tích hợp bản cập nhật mới nhất (DISM `/Add-Package`), .NET 3.5, chỉ giữ các edition hay dùng → apply nhanh, giảm thời gian Windows Update |
| **Apply nhanh** | `wimlib-imagex apply` (đa luồng) thay `dism`; khuyến nghị ổ USB 3.x tốc độ đọc ≥ 150 MB/s |
| **Không hỏi gì trong OOBE** | Unattend đầy đủ: ngôn ngữ, múi giờ VN, user local, bỏ online account, tắt device encryption tự động |
| **Hậu cài tự động** | ZinPost: driver còn thiếu (SDIO) + gói phần mềm cơ bản của cửa hàng |
| **Phiếu kết quả** | Cuối quy trình in/lưu báo cáo: model, serial, CPU/RAM/ổ, Windows đã cài, driver thiếu, thời gian → lưu `ZINDATA\Reports\<serial>_<ngày>.txt` để quản lý máy khách |

> Ghi chú hỗ trợ: Windows 10 22H2 đã hết hỗ trợ chính thức (10/2025, ESU người dùng cá nhân đến 10/2026). Với máy cũ không lên được Win11, cân nhắc Windows 10 IoT Enterprise LTSC 2021 (hỗ trợ đến 2032) nếu có license hợp lệ.

### 8.6 Giao diện song ngữ (D6)

- ZinSetup (và về sau Installer, PE Loader) dùng **file ngôn ngữ tách riêng**: `ZinPE\Lang\en-US.json`, `ZinPE\Lang\vi-VN.json`.
- Mọi chuỗi hiển thị lấy qua khoá (vd `setup.select_disk`), không viết cứng trong code.
- Chọn ngôn ngữ bằng nút EN/VI trên giao diện; mặc định đọc từ `ZinPE\Config\zinpe.ini` (`Language=vi-VN`).
- Log luôn ghi tiếng Anh (dễ tra cứu lỗi).

### 8.7 Cài phần mềm tự động

**Giới hạn:** bộ cài `.exe`/`.msi` luôn cài vào hệ điều hành **đang chạy** — trong PE đó là `X:` (PE), không phải Windows vừa apply ở `W:`. Vì vậy **không chạy bộ cài trực tiếp trong PE**; thay vào đó dùng các cách sau:

| Cách | Làm trong PE? | Tốc độ | Dùng cho |
|------|--------------|--------|----------|
| **A. Image chuẩn cài sẵn phần mềm** (sysprep + capture) | ✅ Chỉ apply image | ⚡ Nhanh nhất | Phần mềm mọi khách đều cần |
| **B. ZinPost**: PE chép bộ cài vào `W:\ZinPost`, Windows tự cài silent lần boot đầu | ⚠️ PE chuẩn bị | +5–15 phút | Phần mềm chọn theo từng khách |
| C. Appx/MSIX, provisioning package (`dism /Add-ProvisionedAppxPackage`, `/Add-ProvisioningPackage`) | ✅ | Nhanh | App dạng Store/MSIX (ít gặp) |
| D. Portable: chép vào `W:\Program Files\...` + tạo shortcut | ✅ | Nhanh | Tiện ích nhỏ, không cần dịch vụ |
| E. winget | ❌ Lần boot đầu, cần mạng | Phụ thuộc mạng | Cập nhật bản mới nhất (dự phòng) |

**Phương án chọn: A + B (+ E khi có mạng).**

#### 8.7.1 Image chuẩn của cửa hàng (cách A)

```text
Máy ảo mẫu (Hyper-V/VMware, KHÔNG dùng máy thật — tránh dính driver riêng)
  1. Cài Windows từ ISO gốc → vào Audit Mode (Ctrl+Shift+F3 tại OOBE)
  2. Cài: bản cập nhật mới nhất, .NET 3.5, VC++ runtimes (2008–2022), DirectX runtime
  3. Cài phần mềm chung: 7-Zip, UniKey/EVKey, Chrome, SumatraPDF/Foxit, Zalo, UltraViewer...
  4. Tinh chỉnh mặc định (default user profile, tắt quảng cáo Start menu...)
  5. sysprep /generalize /oobe /shutdown /unattend:<unattend-sysprep.xml>
  6. Boot ZinWinPE → capture: wimlib-imagex capture C:\ install.wim "Win11 Pro Shop 2026.10"
  7. Gộp các image (Win11 Shop, Win10/LTSC Shop) vào 1 install.esd (mục 9.5)
```

- Lặp lại **hằng tháng** (script hoá trong `builder\image\`), đặt tên edition kèm phiên bản `YYYY.MM`.
- Chỉ đưa vào image phần mềm **miễn phí / có license cho mọi máy khách**; Office và phần mềm thương mại để cách B, dùng license của khách.
- Vẫn giữ **ISO gốc** (image sạch) cho khách yêu cầu Windows nguyên bản.

#### 8.7.2 ZinPost — phần mềm theo từng khách (cách B)

Kho bộ cài: `ZINDATA\ZinPE\Apps\<App>\` gồm bộ cài + manifest:

```ini
; Apps\UltraViewer\app.ini
[App]
Name=UltraViewer
Category=Remote
Target=zinpost        ; image = đưa vào image chuẩn · zinpost = chọn theo khách
Type=exe              ; exe | msi | portable | font | feature | odt
Installer=UltraViewer_setup.exe
Args=/VERYSILENT /NORESTART
RunAs=system          ; system (SetupComplete) | user (FirstLogonCommands) | pe-offline (làm ngay trong PE)
DetectPath=%ProgramFiles(x86)%\UltraViewer\UltraViewer_Desktop.exe
Default=1             ; tick sẵn trong ZinSetup
Winget=DucFabulous.UltraViewer
License=Freeware (kiểm tra điều khoản)
Verify=1              ; 1 = tham số silent / đường dẫn chưa kiểm thử thực tế
Note=KHÔNG đưa vào image: ID máy có thể bị trùng
```

Manifest mẫu của toàn bộ danh sách ở mục 8.7.4 nằm trong repo: `apps/<App>/app.ini`. Bộ cài (`.exe/.msi`) **không** commit vào Git — script build tải về (ưu tiên `winget download --id <Winget>` hoặc `Source=`).

Luồng:

```text
Trong PE (ZinSetup):
  Danh sách phần mềm (checkbox, song ngữ), preset chọn sẵn mặc định
  → chép bộ cài đã chọn + app.ini + ZinPost.ps1 vào W:\ZinPost\
  → đăng ký chạy tự động (cả hai, có cờ chống chạy lặp):
       W:\Windows\Setup\Scripts\SetupComplete.cmd
       unattend FirstLogonCommands (dự phòng)

Lần boot đầu (ZinPost.ps1, quyền SYSTEM/Admin):
  1. Driver còn thiếu → SDIO (mục 9.6)
  2. Cài lần lượt từng app: chạy Installer + Args, chờ xong, kiểm tra DetectPath
  3. Có mạng → winget upgrade cho các app có khai báo Winget (tuỳ chọn)
  4. Ghi C:\ZinPost\post.log + cập nhật phiếu kết quả (mục 8.5)
  5. Gỡ đăng ký tự chạy, xoá bộ cài tạm
```

#### 8.7.3 Lưu ý

- `SetupComplete.cmd` **có thể không chạy khi Windows cài bằng product key OEM** (trừ Enterprise) — vì vậy luôn đăng ký thêm `FirstLogonCommands` hoặc scheduled task; ZinPost dùng file cờ `C:\ZinPost\done.flag` để không chạy hai lần.
- Bộ cài phải có **tham số silent** đã kiểm thử (`/S`, `/quiet`, `/qn`, `/VERYSILENT`...); bộ cài nào không hỗ trợ silent thì loại hoặc dùng bản MSI/portable.
- Một số bộ cài tự khởi động lại máy → luôn thêm `/norestart` (hoặc tương đương), ZinPost tự restart một lần ở cuối nếu cần.
- Phần mềm trong image (cách A) cập nhật cũ dần → winget/updater của phần mềm sẽ cập nhật sau.
- **Phần mềm điều khiển từ xa** (UltraViewer, AnyDesk, TeamViewer) **không** đưa vào image: ID sinh theo máy, các máy cài từ cùng image có thể bị trùng ID.
- **Phần mềm cài theo user** (Zalo, Teams cá nhân...) cài vào `%LocalAppData%` → phải chạy ở `FirstLogonCommands` với quyền user, không chạy từ `SetupComplete.cmd` (SYSTEM).

### 8.7.4 Danh sách phần mềm cơ bản văn phòng

**Nhóm A — Image chuẩn (mọi máy đều có):**

| Phần mềm | Mục đích | Cách cài | Ghi chú |
|----------|---------|----------|---------|
| VC++ Redistributable 2015–2022 (x64+x86) | Runtime | `/install /quiet /norestart` | Nhiều phần mềm cần |
| .NET Framework 3.5 | Runtime | `dism /Enable-Feature NetFx3` (offline được trong PE) | Phần mềm kế toán, phần mềm cũ |
| Google Chrome (Enterprise MSI) | Trình duyệt | `msiexec /qn` | Bản MSI cài cho mọi user, tự cập nhật |
| 7-Zip | Nén/giải nén | `/S` | Thay WinRAR (WinRAR trả phí) |
| SumatraPDF | Đọc PDF mặc định | `-install -s -all-users` | Nhẹ, nhanh; GPL |
| UniKey | Gõ tiếng Việt | Portable — chép offline trong PE + shortcut Startup | Mặc định Unicode + Telex |
| Bộ font Việt (VNI, TCVN3 .Vn*) | Mở văn bản cũ | Chép vào `Windows\Fonts` + đăng ký registry offline | Cơ quan, trường học hay dùng |
| VLC | Xem video/nghe nhạc | `/L=1033 /S` | |
| Microsoft Edge, WebView2, Windows Media Player | — | Có sẵn trong Windows | |

Đặt ứng dụng mặc định (PDF → SumatraPDF, trình duyệt → Chrome, video → VLC) bằng `DefaultAppAssociations.xml`: `dism /Image:W:\ /Import-DefaultAppAssociations:<file>` (làm được offline).

**Nhóm B — ZinPost, chọn theo khách:**

| Phần mềm | Tick sẵn | Chạy với | Ghi chú |
|----------|:-------:|----------|---------|
| UltraViewer | ✅ | SYSTEM | Không vào image (trùng ID) |
| Zalo PC | ✅ | **User** | Cài theo user; tham số silent cần kiểm thử |
| AnyDesk | | SYSTEM | Không vào image |
| TeamViewer | | SYSTEM | Miễn phí cho cá nhân |
| Foxit PDF Reader | | SYSTEM | Khách cần ký / ghi chú PDF |
| Adobe Acrobat Reader | | SYSTEM | `/sAll /rs /msi EULA_ACCEPT=YES` |
| Cốc Cốc | | SYSTEM | Tham số cần kiểm thử |
| Firefox | | SYSTEM | `/S` |
| Microsoft 365 / Office LTSC (ODT) | | SYSTEM | **License của khách**; nguồn offline ~3–4 GB |
| LibreOffice + tiếng Việt | | SYSTEM | Thay Office miễn phí |
| Zoom (MSI) | | SYSTEM | |
| Notepad++ | | SYSTEM | |

- Preset `Win11-Pro-Shop` / `Win10-Pro-OldPC` dùng chung danh sách tick sẵn ở trên; KTV bỏ/thêm theo yêu cầu khách.
- **Office**: nguồn offline ~3–4 GB làm chật USB 64 GB (mục 9.5) → mặc định tải online khi máy có mạng; chỉ để nguồn offline nếu còn chỗ. Không tích hợp công cụ kích hoạt lậu.
- Các mục `Verify=1` trong manifest phải kiểm thử tham số silent & `DetectPath` trên máy thật trước khi đưa vào dùng.

---

## 9. Chiến lược driver

### 9.1 Hai tầng driver

| Tầng | Mục đích | Vị trí | Kích thước ước tính |
|------|----------|--------|---------------------|
| **T1 – Driver PE tích hợp** | Boot-critical: storage (NVMe, Intel RST/VMD, AMD RAID), USB3/USB4, LAN, WiFi phổ biến, I2C/HID touchpad | Inject sẵn vào `boot.wim` | 200–500 MB |
| **T2 – Driver PE mở rộng** | Thiết bị hiếm hơn, nạp khi cần lúc chạy | `ZinPE\Drivers\PE\` | 1–3 GB |
| **T3 – Driver cho Windows đã cài** | Bộ driver đầy đủ theo hãng/model + driver chung | `ZinPE\Drivers\OS\` | 20–100+ GB (tuỳ chọn số model) |

### 9.2 Nguồn driver

**Cho WinPE (T1/T2):**

| Nguồn | Ghi chú |
|-------|---------|
| Dell WinPE Driver Pack (WinPE 10/11) | Gói chính thức, cập nhật thường xuyên, dùng tốt cho cả máy không phải Dell |
| HP WinPE Driver Pack | Chính thức |
| Lenovo WinPE Driver Pack | Chính thức |
| Intel RST/VMD (`iaStorVD`), Intel Serial IO, Intel LAN/WiFi | Lấy từ Intel / Dell pack |
| AMD RAID (RAIDXpert2), AMD chipset (GPIO/I2C) | Từ AMD |
| Realtek LAN/WiFi, MediaTek WiFi, Qualcomm WiFi | Từ catalog OEM |

**Cho Windows (T3):**

| Hãng | Nguồn chính thức |
|------|------------------|
| Dell | Dell Command \| Deploy Driver Packs (theo model, file .cab) |
| HP | HP Client Driver Packs (HP Image Assistant / driver pack matrix, file .exe softpaq) |
| Lenovo | Lenovo SCCM Driver Packs (theo Machine Type) |
| Microsoft Surface | Surface MSI driver/firmware |
| Asus, Acer, MSI, Gigabyte... | Không có driver pack tập trung → dùng nguồn chung |
| **Chung** | **Snappy Driver Installer Origin (SDIO)** driverpacks (~30–40 GB), Windows Update Catalog |

### 9.3 Cấu trúc kho driver

```text
ZinPE\Drivers\
├── PE\                         # T2 – nạp lúc chạy PE
│   ├── Storage\{Intel_VMD, AMD_RAID, ...}
│   ├── Net\{LAN, WiFi}\<Vendor>\
│   ├── Input\{Intel_SerialIO, AMD_I2C, Touchpad}\
│   └── USB\
├── OS\                         # T3 – nạp vào Windows sau khi apply
│   ├── Dell\<Model>\Win11\ ...
│   ├── HP\<PlatformID>\Win11\ ...
│   ├── Lenovo\<MTM4>\Win11\ ...
│   ├── Surface\<Model>\
│   └── Generic\SDIO\           # Snappy Driver Installer Origin + driverpacks + sdio-index.tsv (HWID → pack/inf)
└── index.json                  # ánh xạ model → thư mục driver
```

Mẫu `index.json`:

```json
{
  "version": "2026.10",
  "rules": [
    { "manufacturer": "Dell Inc.", "match": "model", "value": "Latitude 7490",
      "os": ["win10", "win11"], "path": "OS\\Dell\\Latitude_7490" },
    { "manufacturer": "HP", "match": "baseboard", "value": "83B3",
      "path": "OS\\HP\\83B3" },
    { "manufacturer": "LENOVO", "match": "mtm4", "value": "20L5",
      "path": "OS\\Lenovo\\20L5" }
  ],
  "fallback": "OS\\Generic\\SDIO"
}
```

### 9.4 ZinDriver — tự động nhận diện & nạp driver

```text
Nhận diện (WMI):
  Manufacturer  = Win32_ComputerSystem.Manufacturer
  Model         = Win32_ComputerSystem.Model
  SKU           = Win32_ComputerSystem.SystemSKUNumber   (Dell: SystemSKU)
  BaseBoard     = Win32_BaseBoard.Product                 (HP: Platform ID 4 ký tự)
  Lenovo MTM    = 4 ký tự đầu của Model                   (vd 20L5)
  HWIDs         = danh sách PnP ID thiết bị

Trong PE:
  - Thiết bị lỗi/thiếu driver → tìm .inf khớp HWID trong Drivers\PE → drvload

Khi cài Windows:
  1. Khớp index.json → có pack hãng → dism /Add-Driver /Recurse
  2. Không khớp → chọn lọc từ SDIO theo HWID (chỉ inject driver khớp, tránh phình DriverStore)
  3. Ghi log C:\ZinPost\driver.log
```

### 9.5 Chiến lược dung lượng

USB 64 GB không đủ chứa driver pack cho mọi model của mọi hãng từ 2015. Đề xuất **3 gói driver** — **mặc định: Standard (D2)**:

| Gói | Nội dung | Dung lượng | USB đề xuất |
|-----|----------|-----------|-------------|
| **Lite** | T1 + T2 + SDIO (chỉ các pack quan trọng: chipset, LAN, WLAN, storage, touchpad, card reader) | ~8–12 GB | 32 GB |
| **Standard** | Lite + SDIO đầy đủ | ~40 GB | 64–128 GB |
| **Full** | Standard + driver pack OEM Dell/HP/Lenovo/Surface cho các model doanh nghiệp phổ biến (Latitude, Precision, OptiPlex, EliteBook, ProBook, ThinkPad, ThinkCentre...) | 150–400 GB | SSD gắn ngoài 256–512 GB |

**Ngân sách dung lượng USB 64 GB (gói Standard)** — dung lượng thực ~57–58 GiB:

| Hạng mục | Dung lượng ước tính |
|----------|--------------------|
| ZINBOOT (boot files, boot.wim, GRUB2, memtest) | 3 GB |
| Công cụ portable (`Programs\`) | 3–5 GB |
| Driver T2 (PE mở rộng) | 1–2 GB |
| Driver Standard (SDIO đầy đủ) | ~40 GB |
| **Còn lại cho ISO/WIM Windows + dữ liệu** | **~8–10 GB** |

⚠️ 8–10 GB chỉ đủ khoảng **1 bộ cài Windows** đầy đủ. Cách xử lý (theo thứ tự ưu tiên):

1. **Gộp image**: 1 file `install.esd` chứa các edition cần dùng (Win11 Pro/Home + Win10 Pro / LTSC) — ESD nén tốt hơn ISO, các edition dùng chung dữ liệu → ~5–7 GB cho cả Win10 + Win11.
2. **Tỉa SDIO**: loại các pack hiếm gặp ở máy từ 2015 (driver XP/Vista-only, máy in, thiết bị rất cũ) → mục tiêu ~25–30 GB.
3. Khuyến nghị cửa hàng dùng **USB 128 GB** hoặc SSD gắn ngoài nếu cần thêm ISO Linux/nhiều bản Windows.

Công cụ **ZinDriverSync** (chạy trên máy build) tải driver pack theo danh sách model chọn trước từ catalog chính thức (Dell `DriverPackCatalog.cab`, HP `HPClientDriverPackCatalog.cab`, Lenovo `catalogv2.xml`), giải nén, chuẩn hoá thư mục và sinh `index.json`.

### 9.6 Giới hạn nạp driver offline

Trong WinPE, driver được nạp **offline** vào bản Windows vừa apply (`dism /Image:W:\ /Add-Driver`) — Windows chưa chạy, lần boot đầu sẽ tự nhận driver (có mạng, touchpad, chipset ngay từ OOBE). Cơ chế này **chỉ áp dụng cho driver dạng `.inf`**:

| Loại | Nạp từ PE? | Cách xử lý |
|------|-----------|-----------|
| Driver `.inf/.sys/.cat` (chipset, LAN, WiFi, storage, audio, touchpad...) | ✅ Có | `dism /Add-Driver /Recurse` |
| Driver đóng gói `.exe` (Dell, HP SoftPaq, Lenovo, Intel...) | ✅ Sau khi giải nén | Giải nén lấy `.inf` **lúc build kho driver** (ZinDriverSync: 7-Zip, `/e`, `-extract`, `/s /e=<dir>`) |
| Driver DCH (đời mới) | ✅ Phần `.inf` | App đi kèm (Realtek Audio Console, Intel Graphics Command Center...) → `dism /Image:W:\ /Add-ProvisionedAppxPackage` hoặc để Windows Update/Store cài |
| Phần mềm tiện ích hãng (Dell Optimizer, HP Hotkey Support, Lenovo Vantage...) | ❌ Không | Cài silent lần đầu đăng nhập (`SetupComplete.cmd` / `FirstLogonCommands`) |
| Driver đồ hoạ NVIDIA/AMD bản đầy đủ (kèm control panel) | ⚠️ Chỉ phần `.inf` | Bản đầy đủ cài lần đầu đăng nhập |
| Cập nhật BIOS / firmware | ❌ Không nên | Làm sau trong Windows bằng công cụ của hãng |

**Luồng hai pha:**

```text
Pha 1 – Trong PE (ZinSetup):
  Apply Windows → ZinDriver nhận diện model (WMI)
    → khớp pack hãng: dism /Add-Driver
    → không khớp: lọc driver SDIO theo HWID → dism /Add-Driver
  → chép bộ cài .exe cần chạy sau vào W:\ZinPost\
  → ghi lệnh gọi ZinPost vào W:\Windows\Setup\Scripts\SetupComplete.cmd (hoặc unattend FirstLogonCommands)
  → bcdboot → khởi động lại

Pha 2 – Lần đầu vào Windows (ZinPost, tự động):
  Cài silent: app hãng, driver đồ hoạ đầy đủ, VC++ runtimes, phần mềm cơ bản
  → SDIO quét lần cuối các thiết bị còn thiếu driver
  → ghi log C:\ZinPost\post.log → tự xoá bộ cài tạm
```

**Lưu ý:**

- **Chỉ inject driver khớp với máy** — inject cả kho SDIO vào Windows làm phình DriverStore, có thể gây xung đột/BSOD; ZinDriver phải lọc theo HWID.
- **Driver cho PE ≠ driver cho Windows**: `drvload` / `pnputil` trong PE chỉ giúp PE đang chạy nhận thiết bị và mất khi tắt máy; `dism /Image:W:\ /Add-Driver` mới nạp vào Windows đã cài.
- **Đúng kiến trúc & phiên bản**: driver x64 cho Windows x64; ưu tiên driver đánh dấu Win11 cho Win11, Win10 cho Win10 (đa số driver Win10 vẫn dùng được cho Win11).
- Driver không ký số sẽ bị từ chối khi nạp offline với `dism` trừ khi dùng `/ForceUnsigned` — **không** dùng tuỳ chọn này cho Windows x64 có Secure Boot (driver sẽ không load).

---

## 10. Cấu trúc thư mục trên USB

```text
ZINBOOT (P1, FAT32, ẩn)
├── EFI\
│   ├── Boot\bootx64.efi            # bootmgfw.efi (bản CA 2023 hoặc 2011)
│   ├── Microsoft\Boot\BCD, bootmgfw.efi
│   └── zin\                        # shimx64.efi, grubx64.efi (ký MOK), mmx64.efi,
│                                   # ca2011\ + ca2023\ (2 bộ bootx64.efi), bootfiles.txt
├── Boot\BCD, boot.sdi, fonts\      # Legacy
├── bootmgr
├── grub\                           # cấu hình & theme GRUB2 (zinboot.id, grub.cfg, custom.cfg)
├── g2ldr, g2ldr.mbr                # GRUB2 cho Legacy (bootmgr → bootsector → g2ldr)
├── tools\memtest\                 # Memtest86+ (EFI ký MOK)
└── ZinPE\
    ├── boot11.wim                  # ZinWinPE 11 x64
    └── version.txt

ZINDATA (P2, exFAT/NTFS)
├── autorun.inf                     # icon + nhãn ổ USB (mục 6.6)
├── ZinPE\
│   ├── zinpe.tag                   # file đánh dấu để PE dò phân vùng
│   ├── Programs\                   # *.7z / *.wim + *.ini manifest
│   │   ├── Partition\  Backup\  Recovery\  HWTest\
│   │   ├── System\  Network\  Antivirus\  Utilities\
│   ├── Drivers\                    # xem mục 9.3
│   ├── Scripts\                    # ZinSetup, ZinDriver, FixBoot, ...
│   ├── Unattend\                   # mẫu autounattend.xml
│   ├── Presets\                    # preset Cài nhanh (mục 8.5)
│   ├── Apps\                       # bộ cài phần mềm cho khách + app.ini (mục 8.7)
│   ├── Lang\                       # en-US.json, vi-VN.json (mục 8.6)
│   ├── Config\                     # cấu hình loader, theme, wallpaper
│   └── Logs\
├── Reports\                        # phiếu kết quả từng máy (mục 8.5)
├── ISO\
│   ├── Windows\                    # install.esd gộp / ISO Win11, Win10, LTSC...
│   ├── Linux\                      # SystemRescue, GParted, Clonezilla
│   └── Tools\                      # MemTest86, ...
└── Backup\                         # nơi mặc định lưu ảnh backup (tuỳ)
```

---

## 11. Quy trình build

### 11.1 Môi trường build

> Máy hiện tại là macOS → **bắt buộc** dùng máy/VM Windows để build (DISM, ADK, PEBakery chỉ chạy trên Windows).

| Thành phần | Yêu cầu |
|-----------|---------|
| Hệ điều hành build | Windows 11 x64 (máy thật hoặc VM: Parallels / VMware Fusion / UTM trên Mac Intel; trên Apple Silicon chỉ có Windows ARM → **không phù hợp** để build PE x64, nên dùng máy Windows x64 riêng hoặc VM cloud) |
| Ổ đĩa | ≥ 200 GB trống (NTFS), SSD |
| Phần mềm | Windows ADK + WinPE add-on (bản mới nhất), PEBakery + PhoenixPE, wimlib, 7-Zip, Git; WSL/Linux để build & ký GRUB2 (`grub-mkimage`, `sbsign`) |
| Nguồn | ISO Windows 11 24H2/25H2 x64 và Windows 10 22H2 x64 (bản gốc Microsoft, en-US) |

### 11.2 Cấu trúc repo dự án (trên máy build)

```text
ZinWinPE\
├── docs\                     # tài liệu (file này)
├── assets\branding\          # logo, icon, wallpaper, theme (mục 6.6)
├── builder\                  # cấu hình PhoenixPE, plugin tuỳ biến
├── src\
│   ├── loader\               # PE Loader
│   ├── zinsetup\             # wizard cài Windows
│   ├── zindriver\            # nhận diện & nạp driver
│   ├── fixboot\              # script sửa boot
│   └── installer\            # công cụ tạo USB
├── packages\                 # công thức đóng gói công cụ portable (*.ini + script tải)
├── apps\                     # manifest phần mềm cho khách: <App>\app.ini (mục 8.7)
├── drivers\                  # script ZinDriverSync + danh sách model
├── boot\                     # BCD template, grub.cfg, theme
├── iso-src\                  # (gitignore) ISO nguồn
└── out\                      # (gitignore) kết quả build
```

### 11.3 Các bước build

```text
B1. Chuẩn bị nguồn: mount ISO Windows → lấy install.wim (index Pro) cho builder
B2. Build PE lõi bằng PhoenixPE:
      - Bật: Explorer shell, Network+WiFi, Audio, PowerShell, .NET 4.8, WMI, BitLocker, RDP
      - Thêm: font, bộ gõ, theme ZinWinPE, PE Loader
      - Inject driver T1 (dism /Add-Driver /Recurse)
B3. Tối ưu: dọn file thừa, nén boot.wim (LZX) → kiểm tra kích thước < 1.5 GB
B4. Đóng gói công cụ: script packages\build.ps1 tải bản mới nhất (theo URL/version trong .ini),
    xác minh hash, nén .7z → out\ZINDATA\ZinPE\Programs
B5. Driver: ZinDriverSync tải/cập nhật T2/T3 theo gói Lite/Standard/Full
B5b. Image chuẩn cửa hàng (hằng tháng, mục 8.7.1): VM mẫu → cài phần mềm → sysprep → capture → gộp install.esd
B5c. Kho Apps: script tải bộ cài mới nhất theo app.ini, kiểm hash → out\ZINDATA\ZinPE\Apps
B6. Boot files: tạo BCD (2 bộ boot files 2011/2023), build GRUB2 + ký bằng khoá MOK, chép shim, grub.cfg
B7. Xuất:
      - out\ZinWinPE-<ver>-USB.zip  (cho Installer)
      - out\ZinWinPE-<ver>.iso      (test VM / Ventoy)
B8. Kiểm thử tự động trên VM (mục 14)
```

---

## 12. Công cụ tạo USB (ZinWinPE Installer)

Ứng dụng Windows (GUI đơn giản, WinForms/WPF hoặc PowerShell + WPF) — tương tự "Tạo USB boot" của AnhDV:

| Chức năng | Mô tả |
|-----------|-------|
| Chọn USB | Chỉ liệt kê ổ removable/USB, cảnh báo xoá dữ liệu, xác nhận 2 lần |
| Kiểu phân vùng | **MBR (UEFI+Legacy, mặc định)** / GPT (UEFI) |
| FS cho ZINDATA | exFAT / NTFS |
| Kích thước ZINBOOT | 2 / 3 / 4 GB |
| Bộ boot files | Tự động / CA 2011 / CA 2023 |
| Gói driver | Lite / **Standard (mặc định)** / Full (hoặc bỏ qua) |
| **Cập nhật** | Chỉ ghi đè P1 + `ZinPE\` trên P2, **giữ nguyên** ISO/dữ liệu người dùng |
| Cài vào ổ cứng (tuỳ chọn) | Thêm mục "ZinWinPE" vào boot menu của máy (copy wim vào ổ cứng + bcdedit) |
| Tạo ISO | Cho VM / Ventoy |

Các bước kỹ thuật khi tạo mới:

```text
diskpart: clean → convert mbr|gpt → create P1 (FAT32, ZINBOOT) → create P2 (exFAT/NTFS, ZINDATA)
P1: copy boot files, wim → bootsect /nt60 (Legacy) → đặt active (MBR) → ẩn P1 (remove letter, set id)
P2: copy ZinPE\, ISO\ → tạo zinpe.tag
Xác minh: so hash file quan trọng
```

---

## 13. Cập nhật & quản lý phiên bản

- Phiên bản dạng `YYYY.MM` (vd `2026.10`), ghi trong `version.txt` và hiện trên màn hình nền PE.
- **Cập nhật công cụ**: chép đè file `.7z` + `.ini` trong `Programs\` — không cần build lại PE.
- **Cập nhật driver**: chạy ZinDriverSync → chép `Drivers\` mới.
- **Cập nhật PE**: chỉ khi có bản Windows/ADK mới, sửa lỗi lớn, hoặc thay đổi boot files (CA 2023).
- Lưu `CHANGELOG.md` cho mỗi bản phát hành.
- Quản lý mã nguồn bằng Git (không commit ISO, công cụ có bản quyền, driver).

---

## 14. Kiểm thử

### 14.1 Máy ảo

| Nền tảng | Chế độ |
|---------|--------|
| Hyper-V Gen 2 | UEFI + Secure Boot (template Microsoft Windows) |
| Hyper-V Gen 1 | Legacy BIOS |
| VMware Workstation | UEFI (SB bật/tắt), BIOS, NVMe controller |
| QEMU/OVMF | UEFI, test DB/DBX chứng chỉ 2023 |

### 14.2 Máy thật (ma trận tối thiểu)

| Thế hệ | Ví dụ | Kiểm tra trọng tâm |
|--------|-------|-------------------|
| Intel Gen 6–8 (2015–2018) | Dell Latitude E7470/7480, HP EliteBook 840 G3–G5, ThinkPad T460/T470/T480 | Legacy + UEFI, NVMe/SATA |
| Intel Gen 10–12 | Latitude 5410/5420, ThinkPad T14 Gen 1–3, HP ProBook 450 G8 | **Intel VMD**, WiFi 6, touchpad I2C |
| Intel Gen 13–14 / Core Ultra | Laptop 2023–2026 | VMD, WiFi 6E/7, CA 2023 Secure Boot |
| AMD Ryzen 3000–8000 / AI | ThinkPad T14 AMD, HP 845, Asus/Lenovo consumer | AMD I2C touchpad, MediaTek/Realtek WiFi |
| Desktop lắp ráp | Main Asus/Gigabyte/MSI B-series | Realtek/Intel LAN, RAID |
| Surface | Surface Pro 5–9, Laptop 3–5 | Bàn phím Type Cover, touch |

### 14.3 Checklist chức năng

- [ ] Boot UEFI (SB bật), UEFI (SB tắt), Legacy
- [ ] Thấy ổ NVMe/SATA/VMD/RAID
- [ ] Có mạng LAN & WiFi, kết nối được Internet
- [ ] Touchpad, bàn phím, màn hình cảm ứng hoạt động
- [ ] Đọc ổ BitLocker (với recovery key)
- [ ] Tất cả công cụ mở được, shortcut đúng nhóm
- [ ] Cài Win11 UEFI/GPT + Win10 Legacy/MBR thành công, driver tự nạp
- [ ] Fix boot thành công trên máy cố ý làm hỏng BCD
- [ ] Backup → restore một phân vùng Windows thành công
- [ ] Chế độ Full RAM: rút USB không lỗi
- [ ] Tiếng Việt hiển thị đúng, gõ được tiếng Việt

---

## 15. Lộ trình triển khai

| Giai đoạn | Nội dung | Kết quả |
|-----------|----------|---------|
| **P0 – Chuẩn bị** | Dựng máy/VM build Windows, tải ADK, PhoenixPE, ISO nguồn; tạo repo | Môi trường build chạy được |
| **P1 – PE lõi + boot** | Build ZinWinPE 11 x64 có Explorer, mạng, driver T1; boot UEFI+Legacy qua BCD; **GRUB2 + shim + MOK**; USB 2 phân vùng thủ công | PE boot được trên VM + 3 máy thật, GRUB2 chạy khi bật SB |
| **P2 – Công cụ** | PE Loader + định dạng gói `.7z/.ini`; đóng gói ~40 công cụ ở mục 7 | Menu công cụ đầy đủ |
| **P3 – Cài Windows** | ZinSetup song ngữ + **Cài nhanh (preset)** + unattend + image chuẩn bị sẵn | Cài Win10/11 end-to-end không cần thao tác OOBE |
| **P4 – Driver** | ZinDriver + ZinDriverSync + index.json + gói Standard (tỉa cho vừa 64 GB) | Driver tự động theo model |
| **P5 – Installer** | ZinWinPE Installer (tạo/cập nhật USB, tạo ISO) | Người khác tự tạo USB được |
| **P6 – Mở rộng** | ISO Linux trong menu GRUB2, Ventoy mode, gói driver Full, phiếu kết quả nâng cao | Bản 1.0 |
| **P7 – Tương lai** | ARM64 PE, boot qua mạng (PXE/iPXE), cổng cập nhật online | — |

---

## 16. Bản quyền & pháp lý

- **Bối cảnh (D4)**: dùng tại **cửa hàng sửa chữa** = sử dụng **thương mại**. Mọi công cụ phải có license cho phép dùng thương mại / dịch vụ kỹ thuật cho khách hàng.
- **Windows PE**: theo điều khoản Microsoft, WinPE được dùng cho triển khai/khôi phục, **không** dùng như hệ điều hành đa dụng — phù hợp mục đích cửa hàng. Không phân phối công khai bản build.
- **Bản quyền Windows cài cho khách**: máy OEM dùng key trong BIOS; máy khác cần key hợp lệ của khách/cửa hàng.
- **Phần mềm thương mại** (Acronis, Macrium, AIDA64, R-Studio, Paragon, HitmanPro...): chỉ tích hợp khi có license hợp lệ cho mục đích sử dụng; **không** đóng gói bản crack/keygen.
- ⚠️ **Freeware "chỉ cho cá nhân"** (một số bản Free của AOMEI, MiniTool, DiskGenius, HWiNFO, DMDE, Recuva...): **không** được dùng trong dịch vụ của cửa hàng nếu điều khoản cấm → phải mua bản Technician/Commercial hoặc thay bằng công cụ mã nguồn mở / freeware cho phép thương mại (TestDisk/PhotoRec, wimlib, CrystalDiskInfo, 7-Zip, Hasleo Free...). Rà soát từng công cụ ở P2 và ghi vào `LICENSES.md` cột "Dùng thương mại: Có/Không".
- **Công cụ kích hoạt Windows/Office lậu**: không tích hợp.
- **Driver OEM**: được phép tải và dùng cho thiết bị tương ứng; không phân phối lại công khai nếu điều khoản cấm.
- Ghi file `LICENSES.md` liệt kê từng công cụ, phiên bản, nguồn tải, loại license.

---

## 17. Rủi ro & lưu ý kỹ thuật

| Rủi ro | Ảnh hưởng | Giảm thiểu |
|--------|-----------|-----------|
| Chứng chỉ Secure Boot 2011 hết hạn / bị thu hồi (mục 5.3) | Không boot được khi bật SB | Hai bộ boot files, ưu tiên CA 2023, hướng dẫn tắt SB |
| Intel VMD không có driver | PE/Setup không thấy ổ | Inject `iaStorVD` vào T1; hướng dẫn tắt VMD trong BIOS |
| boot.wim quá lớn | Boot chậm, máy RAM 4 GB lỗi | Giữ < 1.5 GB, công cụ để ngoài |
| Firmware kén USB nhiều phân vùng / FAT32 ẩn | Không boot | Kiểm thử ma trận; tuỳ chọn không ẩn P1 |
| Inject quá nhiều driver vào Windows | BSOD, chậm, xung đột | Chỉ inject driver khớp HWID / pack đúng model |
| Phần mềm diệt virus báo nhầm công cụ (password reset...) | Khó chịu/ bị xoá | Ghi chú; tách gói "Security tools" riêng |
| Antivirus/EDR trong doanh nghiệp chặn | — | Không áp dụng (PE chạy ngoài hệ điều hành) |
| Build trên Mac Apple Silicon | Không build được PE x64 | Dùng máy Windows x64 riêng / VM x64 |
| Dung lượng driver Full quá lớn | USB đắt, chậm | Chia gói Lite/Standard/Full |
| Bỏ qua yêu cầu Win11 | Máy không hỗ trợ có thể không nhận bản cập nhật tính năng | Cảnh báo rõ, để người dùng chọn |

---

## 18. Phụ lục

### A. Lệnh tham khảo

```bat
:: Mount / sửa boot.wim
dism /Mount-Image /ImageFile:boot.wim /Index:1 /MountDir:C:\mnt
dism /Image:C:\mnt /Add-Driver /Driver:D:\Drivers\T1 /Recurse
dism /Unmount-Image /MountDir:C:\mnt /Commit
dism /Export-Image /SourceImageFile:boot.wim /SourceIndex:1 /DestinationImageFile:boot_new.wim /Compress:max

:: Nạp driver lúc chạy PE
drvload X:\path\driver.inf
pnputil /add-driver D:\ZinPE\Drivers\PE\*.inf /subdirs /install

:: Phát hiện UEFI/Legacy trong PE (1 = BIOS, 2 = UEFI)
reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType

:: Áp image & tạo boot
dism /Apply-Image /ImageFile:install.wim /Index:6 /ApplyDir:W:\
bcdboot W:\Windows /s S: /f ALL

:: Nạp driver vào Windows offline
dism /Image:W:\ /Add-Driver /Driver:D:\ZinPE\Drivers\OS\Dell\Latitude_7490 /Recurse
```

### B. Mẫu BCD cho WIM ramdisk

```bat
bcdedit /store BCD /create {ramdiskoptions} /d "Ramdisk"
bcdedit /store BCD /set {ramdiskoptions} ramdisksdidevice boot
bcdedit /store BCD /set {ramdiskoptions} ramdisksdipath \Boot\boot.sdi
bcdedit /store BCD /create /d "ZinWinPE 11 x64" /application osloader
:: -> {GUID}
bcdedit /store BCD /set {GUID} device ramdisk=[boot]\ZinPE\boot11.wim,{ramdiskoptions}
bcdedit /store BCD /set {GUID} osdevice ramdisk=[boot]\ZinPE\boot11.wim,{ramdiskoptions}
bcdedit /store BCD /set {GUID} path \Windows\System32\boot\winload.efi
bcdedit /store BCD /set {GUID} systemroot \Windows
bcdedit /store BCD /set {GUID} winpe yes
bcdedit /store BCD /set {GUID} detecthal yes
bcdedit /store BCD /displayorder {GUID} /addlast
```

> Với Legacy dùng `winload.exe` thay cho `winload.efi` (BCD riêng ở `\Boot\BCD`).

### C. Nguồn tham khảo cần kiểm tra khi build

- Microsoft Learn: Windows ADK & WinPE; "Windows Secure Boot certificate expiration and CA updates"; KB5025885 (BlackLotus / CVE-2023-24932) và hướng dẫn tạo media khởi động ký CA 2023.
- PhoenixPE (GitHub), Win10XPE / TheOven.org forum.
- Dell Command | Deploy Driver Packs; HP Client Driver Pack Catalog; Lenovo Driver Packs (catalog SCCM); Microsoft Surface drivers.
- Snappy Driver Installer Origin.
- WinNTSetup (msfn.org).

### D. Câu hỏi mở

Đã chốt D1–D7 (xem mục 1.4). Còn mở:

1. Danh sách phần mềm thương mại đã có / sẽ mua license (bản Technician cho cửa hàng)?
2. Bản Windows cho máy cũ không lên được Win11: Win10 22H2, LTSC 2021, hay Win11 + bypass?
3. ~~Danh sách phần mềm cơ bản~~ → đã chốt ở mục 8.7.4; bổ sung phần mềm chuyên ngành (kế toán, thuế HTKK, chữ ký số...) nếu cửa hàng hay cài.

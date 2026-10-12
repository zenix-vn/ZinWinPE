# Hướng dẫn build ZinWinPE

> Thiết kế mục 11. Máy build: **Windows 11 x64** (không dùng Windows ARM trên Apple Silicon), ổ NTFS ≥ 200 GB, chạy PowerShell **as Administrator**.

## 0. Chuẩn bị (một lần)

| Phần mềm | Ghi chú |
|---|---|
| Windows ADK + WinPE add-on (bản mới nhất) | Cần `Deployment Tools` (oscdimg, bcdboot) và `Windows Preinstallation Environment` |
| PEBakery + PhoenixPE | Builder chính (D7) — xem [builder/phoenixpe/README.md](../builder/phoenixpe/README.md) |
| 7-Zip (bản x64, cài vào `C:\Program Files\7-Zip`) | Dùng cho mọi script đóng gói |
| Git, PowerShell 7 (tuỳ chọn) | |
| WSL Ubuntu | `sudo apt install grub-efi-amd64-bin grub-pc-bin grub-common sbsigntool openssl python3` |

Tải ISO gốc Microsoft (Windows 11 24H2/25H2 x64 en-US, Windows 10 22H2 / LTSC) vào `iso-src\` và ghi SHA-256 vào [sources.md](sources.md).

## 1. Công cụ portable → `out\ZINDATA\ZinPE\Programs`

```powershell
.\packages\build.ps1                  # tất cả
.\packages\build.ps1 -CommercialOnly  # chỉ công cụ được phép dùng thương mại (khuyến nghị cho cửa hàng)
.\packages\New-LicensesMd.ps1         # cập nhật LICENSES.md
```

Công cụ không có `Url=` (bản quyền / link thay đổi): chép file tải thủ công vào `packages\cache\<Id>\` rồi chạy lại. Sau lần tải đầu, điền `Version=` và `Sha256=` (log in ra hash) vào `packages\defs\<Id>.ini`.

## 2. Phần mềm cho khách → `out\ZINDATA\ZinPE\Apps`

```powershell
.\apps\Get-Apps.ps1
```

Dùng `Source=` hoặc `winget download`. Bộ font Việt, UniKey, Office: chép thủ công vào `apps\<App>\` (bị `.gitignore`).

## 3. Driver → `out\ZINDATA\ZinPE\Drivers` + `drivers\store\T1`

```powershell
.\drivers\ZinDriverSync.ps1 -Package Standard   # mặc định D2
.\drivers\ZinDriverSync.ps1 -Package Full       # + driver pack Dell/HP/Lenovo theo models.json
```

Chuẩn bị trước: `drivers\store\SDIO\` (SDIO + driverpacks), `drivers\store\PE\` (Intel VMD/RST, AMD RAID, Serial IO... cho T2), `drivers\store\T1\manual\` (driver bổ sung T1). Xem [drivers/README.md](../drivers/README.md).

## 4. GRUB2 + shim (WSL)

```bash
cd /mnt/d/ZinWinPE/boot
./new-mok.sh            # một lần — CẤT KỸ boot/mok/ZinWinPE.key
GRUB4DOS_MBR=/path/grldr.mbr MEMTEST_DIR=/path/memtest ./build-grub.sh
```

## 5. PE + đóng gói

1. Build `boot.wim` bằng PhoenixPE với nguồn Win11 (cấu hình ở `builder\phoenixpe\README.md`).
2. Chạy:

```powershell
.\builder\Build-ZinWinPE.ps1 -BootWim D:\PhoenixPE\Target\sources\boot.wim -Zip -Iso
```

Kết quả: `out\ZinWinPE-<ver>\{ZINBOOT,ZINDATA}`, `SHA256SUMS.txt`, `out\ZinWinPE-<ver>-USB.zip`, `out\ZinWinPE-<ver>.iso`. Kiểm tra log: `boot11.wim` phải < 1.5 GB.

## 6. Image chuẩn cửa hàng (hằng tháng, thiết kế 8.7.1)

1. VM mẫu → cài Windows → **Ctrl+Shift+F3** vào Audit Mode → cài update, .NET 3.5, VC++, phần mềm nhóm A.
2. `sysprep /generalize /oobe /shutdown /unattend:C:\Windows\Panther\unattend-sysprep.xml` (file mẫu: `builder\image\unattend-sysprep.xml`).
3. Boot ZinWinPE → `Scripts\tools\Capture-ShopImage.ps1 -Source C: -Name "Win11 Pro Shop 2026.10"`.
4. Gộp vào `install.esd`:

```powershell
.\builder\image\Merge-ShopImages.ps1 -Sources @(
  @{ File = 'E:\WIM\Win11-Pro-Shop-2026.10.wim'; Index = 1; Name = 'Windows 11 Pro Shop 2026.10' },
  @{ File = 'D:\iso-src\Win10\sources\install.wim'; Edition = 'Windows 10 Pro' }
) -Out .\out\ZinWinPE-2026.10\ZINDATA\ISO\Windows\install.esd
```

Preset dùng mẫu tên edition (`*Windows 11 Pro*`) nên tên image phải chứa chuỗi đó.

## 7. Tạo USB

`.\src\installer\ZinInstaller.ps1` (GUI) hoặc thủ công theo [manual-usb.md](manual-usb.md).

## Kiểm thử

- Unit test: `Invoke-Pester .\tests`
- VM + máy thật: checklist thiết kế mục 14 và `TODO.md`.

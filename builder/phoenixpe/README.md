# Cấu hình PhoenixPE cho ZinWinPE 11 x64

> PEBakery là công cụ GUI, không lưu được cấu hình dạng script đơn giản → ghi lại các lựa chọn ở đây để build lại giống nhau.
> Sau khi build, xuất file `Target\sources\boot.wim` cho `builder\Build-ZinWinPE.ps1 -BootWim ...`.
> Sau mỗi lần chỉnh, chép `PhoenixPE\Projects\PhoenixPE\script.project` + các `.script` đã sửa vào thư mục này để theo dõi bằng Git.

## Nguồn

- Source: thư mục giải nén ISO Windows 11 24H2/25H2 x64 **en-US** (bản gốc Microsoft, hash trong `docs/sources.md`).
- Edition: Pro (index theo `dism /Get-WimInfo`).
- Kiến trúc: x64. Ngôn ngữ giao diện: en-US. Fallback locale: vi-VN.

## Thành phần cần bật (TODO P1, thiết kế 6.3)

| Nhóm | Lựa chọn |
|---|---|
| Shell | Explorer + Start menu (StartAllBack/Open-Shell tuỳ bản PhoenixPE), thumbnail |
| Network | Network core, WLAN (WiFi), SMB client, RDP client, PENetwork (nếu có trong PhoenixPE; nếu không, Loader dùng `wpeutil InitializeNetwork`) |
| Audio | Audio core |
| Components | PowerShell, WMI, .NET Framework 4.8, MSI, BitLocker (manage-bde), Storage Spaces, VHD/VHDX, Windows Imaging (DISM), WoW64 (chạy công cụ x86) |
| Drivers | ImDisk (mount ISO) |
| Fonts | Segoe UI, Arial, Times New Roman, Tahoma (hiển thị tiếng Việt) |
| Locale | Time zone `SE Asia Standard Time`, input en-US; bộ gõ UniKey nạp từ Programs (Utilities\UniKey) |
| Theme | Wallpaper `assets\branding\wallpaper-1920x1080.png` (Loader vẽ đè phiên bản lúc khởi động) |

## Hook khởi động

PE Loader phải chạy **trước** shell:

- PhoenixPE → *Shell* / *Autorun* (tên mục có thể khác theo phiên bản): thêm lệnh chạy trước shell, chờ kết thúc:
  `X:\ZinPE\Scripts\loader\ZinLoader.cmd`
- `inject-t1.ps1` chép sẵn `X:\ZinPE\Scripts` (bản dự phòng trong boot.wim); `ZinLoader.cmd` ưu tiên bản trên ZINDATA nên cập nhật script **không** cần build lại PE.

## Tối ưu dung lượng (mục tiêu boot.wim < 1.5 GB)

- Không nhúng công cụ vào boot.wim (để ở `ZINDATA\ZinPE\Programs`).
- Chỉ giữ font cần thiết, bỏ ngôn ngữ phụ, bỏ thành phần không dùng (Speech, Media Player...).
- `inject-t1.ps1` export lại với `/Compress:max` và cảnh báo nếu > 1.5 GB.

## Dự phòng

Nếu PhoenixPE thiếu thành phần → Win10XPE (TheOven) với cùng nguồn Win11, cùng hook `ZinLoader.cmd`.

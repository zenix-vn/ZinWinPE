# Gói công cụ portable (thiết kế 6.4, 7, 11.3 B4)

Mỗi công cụ = 1 file `defs/<Id>.ini`:

```ini
[Program]
Name=CPU-Z                 ; tên hiển thị / shortcut
Group=HWTest               ; Partition | Backup | Recovery | HWTest | System | Network | Antivirus | Utilities
Archive=CPU-Z.7z           ; gói trên USB (luôn = <Id>.7z)
Exe=cpuz_x64.exe           ; đường dẫn trong gói (sau khi bỏ thư mục gốc đơn)
Args=                      ; tham số cho shortcut (tuỳ chọn)
Shortcut1=Tên|exe khác|args ; shortcut bổ sung (tuỳ chọn)
Desktop=0                  ; 1 = thêm shortcut Desktop
LoadToRam=1                ; 1 = giải nén vào X:\Programs ; 0 + .wim = mount từ USB
Arch=x64                   ; x86 chỉ nạp khi PE có WoW64
Version=                   ; điền sau khi tải
Url=                       ; trống = tải thủ công vào packages\cache\<Id>\
Sha256=                    ; điền để khoá phiên bản
Extract=zip                ; zip | 7z | copy | manual
Commercial=Yes             ; Yes | No | Check — dùng thương mại (thiết kế 16)
License=...
```

- `build.ps1` bỏ các khoá `Url/Sha256/Extract` khi chép `.ini` lên USB.
- `-CommercialOnly` chỉ đóng gói công cụ `Commercial=Yes`.
- Công cụ dạng thư mục chạy thẳng từ USB (không nén): đặt `Folder=<thư mục>` thay cho `Archive=` trong `.ini` trên USB.
- Sau khi sửa defs: `.\New-LicensesMd.ps1` để cập nhật `LICENSES.md`.

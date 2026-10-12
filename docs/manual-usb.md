# Tạo USB ZinWinPE thủ công (diskpart)

> Dùng ở giai đoạn P1 khi chưa có Installer, hoặc để xử lý sự cố. Bố cục theo thiết kế mục 4. Mọi lệnh chạy trong **cmd as Administrator** trên Windows 10/11.
> ⚠️ `clean` xoá toàn bộ ổ — kiểm tra kỹ số ổ.

## 1. Chia phân vùng (MBR — UEFI + Legacy, mặc định)

```bat
diskpart
list disk
select disk <N>            :: ổ USB, kiểm tra dung lượng!
clean
convert mbr
create partition primary size=3072
format quick fs=fat32 label="ZINBOOT"
assign letter=B
active
create partition primary
format quick fs=exfat label="ZINDATA"
assign letter=D
exit
```

GPT (chỉ UEFI): thay `convert mbr` bằng `convert gpt` và bỏ `active`.

## 2. Chép dữ liệu

```bat
robocopy out\ZinWinPE-2026.10\ZINBOOT B:\ /E
robocopy out\ZinWinPE-2026.10\ZINDATA D:\ /E
bootsect /nt60 B: /mbr /force
```

Chọn bộ boot files CA 2011 thay vì mặc định (máy cũ chưa có CA 2023):

```bat
copy /y B:\EFI\zin\ca2011\bootx64.efi B:\EFI\Boot\bootx64.efi
copy /y B:\EFI\zin\ca2011\bootx64.efi B:\EFI\Microsoft\Boot\bootmgfw.efi
```

## 3. Ẩn ZINBOOT

```bat
diskpart
select disk <N>
select partition 1
remove letter=B
set id=1c override                       :: MBR: FAT32 LBA ẩn
:: GPT thay bằng: gpt attributes=0x8000000000000000
exit
```

Nếu một số máy không boot khi P1 ẩn → bỏ bước 3 (để `set id=0c`) và ghi lại model máy vào TODO.

## 4. Kiểm tra

- `D:\ZinPE\zinpe.tag` tồn tại (PE Loader dò ZINDATA bằng file này).
- Boot thử: VM UEFI (SB bật/tắt), VM Legacy, rồi máy thật.
- Cập nhật sau này: `ZinInstaller.ps1 -Action Update` (giữ ISO & dữ liệu).

# Hướng dẫn sử dụng ZinWinPE (cho kỹ thuật viên)

## Khởi động

1. Cắm USB → menu boot (F12/F9/F11/Esc) → chọn USB (UEFI hoặc Legacy).
2. Menu **Windows Boot Manager**: `ZinWinPE 11 x64` (mặc định) hoặc `Menu phu (GRUB2)` (MemTest, Linux, ISO — xem [mok-enroll.md](mok-enroll.md)).
3. Khi PE khởi động có 3 giây để chọn chế độ:
   - **Enter / chờ**: Bình thường — công cụ nạp từ USB.
   - **F**: Full RAM — chép công cụ + script vào RAM, rút USB ra được (cần RAM ≥ 8 GB).
   - **S**: Safe — không nạp driver bổ sung, không nạp công cụ (dùng khi máy treo lúc nạp driver).

Không thấy ổ cứng (Intel VMD / RAID): chạy **ZinDriver - Load drivers** trong Start Menu → System, hoặc tắt VMD/RAID trong BIOS.

## Cài Windows nhanh (ZinSetup → Cài nhanh)

1. Desktop → **ZinSetup - Install Windows**. Đầu cửa sổ hiện model, serial, CPU/RAM, TPM và máy **có đạt chuẩn Windows 11** không.
2. Chọn **ổ đích** và **preset** (preset gợi ý theo phần cứng). Nút **EN/VI** đổi ngôn ngữ.
3. Bấm **Cài đặt** → xác nhận xoá ổ → chờ (thanh tiến trình).
4. Xong: chọn **Có** để khởi động lại, rút USB. Windows tự qua OOBE, tự đăng nhập tài khoản `User`, ZinPost tự cài phần mềm + driver còn thiếu (cắm lại USB nếu muốn SDIO chạy).

Preset mẫu: `Win11-Pro-Shop`, `Win11-Pro-Bypass` (máy không đạt chuẩn), `Win10-Pro-OldPC`. Sửa/thêm preset: `ZINDATA\ZinPE\Presets\*.json`.

## Cài nâng cao (ZinSetup → Nâng cao)

- Chọn ISO/WIM/ESD trong `ZINDATA\ISO\Windows`, phiên bản (edition), ổ.
- **Cài vào phân vùng có sẵn**: chỉ format phân vùng được chọn, giữ dữ liệu phân vùng khác.
- Tick/bỏ: unattend (user local, bỏ tài khoản Microsoft, tắt BitLocker tự động, bỏ qua kiểm tra Win11, vùng VN), driver, .NET 3.5, SDIO, winget, danh sách phần mềm (dấu **(!)** = tham số silent chưa kiểm thử).
- **WinNTSetup (thủ công)** và **setup.exe của Microsoft** cho trường hợp đặc biệt.

## Phiếu kết quả

`ZINDATA\Reports\<serial>_<ngày>.txt` — model, serial, CPU/RAM/ổ/pin, bản Windows đã cài, driver còn thiếu, thời gian. ZinPost bổ sung `_post.txt` nếu USB còn cắm lúc vào Windows.

## Công cụ khác (Desktop / Start Menu → ZinWinPE)

| Công cụ | Dùng khi |
|---|---|
| **FixBoot** | Máy không vào Windows sau khi hỏng boot: tự dò phân vùng Windows + EFI/active, sao lưu BCD cũ vào `ZINDATA\Backup\BCD`, tạo lại boot |
| **Machine info** | Xem nhanh model, serial, RAM từng khe, ổ (SMART), pin, key OEM |
| **Quick hardware test** | Chuỗi test: ổ, pin, bàn phím, màn hình, loa trái/phải, mic, webcam → lưu phiếu |
| Partition / Backup / Recovery / HWTest / System / Network / Antivirus / Utilities | Công cụ portable theo nhóm |

## Cập nhật USB

- Công cụ: chép đè `.7z` + `.ini` vào `ZINDATA\ZinPE\Programs\<Nhóm>\`.
- Cả bộ: `ZinInstaller.ps1` → **Cập nhật USB** (giữ ISO và dữ liệu).
- Cấu hình cửa hàng: `ZINDATA\ZinPE\Config\zinpe.ini` (ngôn ngữ mặc định, chế độ khởi động, preset mặc định).

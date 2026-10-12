# Enroll MOK cho menu phụ GRUB2 / Enrolling the ZinWinPE MOK

> Chỉ cần cho **menu phụ GRUB2** (MemTest, Linux, ISO) khi **Secure Boot bật**. Menu chính ZinWinPE (Windows Boot Manager) **không** cần bước này. Mỗi máy chỉ làm **một lần**.
> Only needed for the **GRUB2 secondary menu** with **Secure Boot ON**. The main ZinWinPE entry never needs it. Once per machine.

## Tiếng Việt

1. Cắm USB, mở menu boot của máy (F12 / F9 / F11 / Esc tuỳ hãng).
2. Vào GRUB2:
   - **Secure Boot tắt**: chọn ZinWinPE → ở menu Windows Boot Manager chọn **"Menu phu (GRUB2)"**.
   - **Secure Boot bật**: Windows Boot Manager không chạy được shim. Trong menu boot của máy chọn **"Boot from file"** (nếu có) → ổ USB → `EFI\zin\shimx64.efi`. Máy không có "Boot from file": tạm tắt Secure Boot, hoặc dùng EFI shell.
3. Lần đầu, màn hình xanh **MokManager** hiện ra ("Shim UEFI key management"):
   1. Nhấn phím bất kỳ → **Enroll key from disk**.
   2. Chọn ổ ZINBOOT → `ENROLL_THIS_KEY_IN_MOKMANAGER.cer`.
   3. **Continue** → **Yes** → **Reboot**.
4. Từ lần sau GRUB2 chạy thẳng khi bật Secure Boot.

Gỡ khoá khi trả máy cho khách (tuỳ chọn): từ một Linux live chạy `mokutil --delete ENROLL_THIS_KEY_IN_MOKMANAGER.cer`, khởi động lại và xác nhận trong MokManager.

Không boot được với Secure Boot:
- Thông báo "SBAT self-check failed" / "Security Policy Violation": shim/GRUB đã bị thu hồi → cập nhật shim mới và build lại GRUB (`boot/build-grub.sh`).
- Máy mới chỉ tin CA 2023, shim ký CA 2011 → dùng bản shim ký CA 2023 (nếu có) hoặc tắt Secure Boot.
- Kernel Linux / ISO không ký → chỉ chạy được khi tắt Secure Boot.

## English

1. Plug in the USB and open the one-time boot menu (F12 / F9 / F11 / Esc).
2. Reach GRUB2:
   - **Secure Boot off**: boot ZinWinPE → choose **"Menu phu (GRUB2)"** in Windows Boot Manager.
   - **Secure Boot on**: Windows Boot Manager cannot start shim. Use the firmware's **"Boot from file"** → USB → `EFI\zin\shimx64.efi`, or temporarily disable Secure Boot.
3. On first run the blue **MokManager** screen appears: **Enroll key from disk** → ZINBOOT → `ENROLL_THIS_KEY_IN_MOKMANAGER.cer` → **Continue** → **Yes** → **Reboot**.
4. GRUB2 then starts directly with Secure Boot on.

Troubleshooting: "SBAT self-check failed" means the shim/GRUB generation was revoked — update shim and rebuild GRUB. Unsigned Linux kernels only boot with Secure Boot off.

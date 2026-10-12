#!/usr/bin/env bash
# Builds and signs GRUB2 for ZINBOOT (design 5.2, 11.3 B6). Run in WSL (Ubuntu/Debian):
#   sudo apt install grub-efi-amd64-bin grub-pc-bin grub-common sbsigntool openssl python3
#   ./new-mok.sh            # once
#   ./build-grub.sh         # -> ../out/grub/ZINBOOT  (merged into ZINBOOT by Build-ZinWinPE.ps1)
# Optional env:
#   SHIM_DEB=/path/shim-signed.deb   use a specific shim package (default: apt-get download shim-signed)
#   GRUB4DOS_MBR=/path/grldr.mbr     enables the Legacy BCD -> GRUB2 chain (g2ldr.mbr)
#   MEMTEST_DIR=/path/memtest86plus  folder with mt86plus_x64.efi / mt86plus_x64.bin (signed here)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/../out/grub/ZINBOOT}"
KEY="$HERE/mok/ZinWinPE.key"; CRT="$HERE/mok/ZinWinPE.crt"; CER="$HERE/mok/ZinWinPE.cer"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

for t in grub-mkimage sbsign openssl; do command -v $t >/dev/null || { echo "missing: $t"; exit 1; }; done
[[ -f "$KEY" && -f "$CRT" ]] || { echo "MOK key missing - run ./new-mok.sh first"; exit 1; }

COMMON="part_gpt part_msdos fat exfat ntfs iso9660 udf loopback search search_fs_file search_fs_uuid search_label \
configfile normal echo test ls cat chain linux gzio xzio lzopio regexp all_video gfxterm gfxterm_background gfxmenu \
png jpeg font sleep reboot halt true minicmd probe"
EFI_MODS="$COMMON efifwsetup efi_gop efi_uga"
BIOS_MODS="$COMMON biosdisk ntldr vbe vga linux16"

rm -rf "$OUT"; mkdir -p "$OUT/EFI/zin" "$OUT/grub/fonts" "$OUT/grub/themes"

echo "== grubx64.efi"
grub-mkimage -O x86_64-efi -o "$WORK/grubx64.efi" -p /grub -c "$HERE/grub/early.cfg" --sbat "$HERE/grub/sbat.csv" $EFI_MODS
sbsign --key "$KEY" --cert "$CRT" --output "$OUT/EFI/zin/grubx64.efi" "$WORK/grubx64.efi"

echo "== core.img / g2ldr (Legacy)"
grub-mkimage -O i386-pc -o "$WORK/core.img" -p /grub -c "$HERE/grub/early.cfg" $BIOS_MODS
cat /usr/lib/grub/i386-pc/lnxboot.img "$WORK/core.img" > "$OUT/g2ldr"
if [[ -n "${GRUB4DOS_MBR:-}" ]]; then
  # grldr.mbr (grub4dos) loads a file named GRLDR; patch the name to G2LDR (same length). Verify=1.
  python3 - "$GRUB4DOS_MBR" "$OUT/g2ldr.mbr" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
n = data.count(b'GRLDR')
if n == 0: sys.exit('GRLDR string not found in grldr.mbr')
open(sys.argv[2], 'wb').write(data.replace(b'GRLDR', b'G2LDR'))
print(f'g2ldr.mbr: patched {n} occurrence(s)')
PY
else
  echo "   GRUB4DOS_MBR not set -> Legacy BCD entry 'Menu phu' will not work until g2ldr.mbr is added"
fi

echo "== shim (Microsoft-signed) + MokManager"
if [[ -z "${SHIM_DEB:-}" ]]; then (cd "$WORK" && apt-get download shim-signed >/dev/null) ; SHIM_DEB="$(ls "$WORK"/shim-signed_*.deb | head -1)"; fi
dpkg-deb -x "$SHIM_DEB" "$WORK/shim"
SHIM="$(ls "$WORK"/shim/usr/lib/shim/shimx64.efi.signed.latest 2>/dev/null || ls "$WORK"/shim/usr/lib/shim/shimx64.efi.signed* | head -1)"
cp "$SHIM" "$OUT/EFI/zin/shimx64.efi"
MM="$(find "$WORK/shim" /usr/lib/shim -name 'mmx64.efi*' 2>/dev/null | head -1 || true)"
[[ -n "$MM" ]] && cp "$MM" "$OUT/EFI/zin/mmx64.efi" || echo "   mmx64.efi not found (install shim-signed / mokutil package)"
echo "   shim: $(basename "$SHIM_DEB")"
sbverify --list "$OUT/EFI/zin/shimx64.efi" | grep -i 'subject\|issuer' || true
objcopy -O binary --only-section=.sbat "$OUT/EFI/zin/shimx64.efi" /dev/stdout 2>/dev/null | head -5 || true

echo "== memtest (optional)"
if [[ -n "${MEMTEST_DIR:-}" ]]; then
  mkdir -p "$OUT/tools/memtest"
  [[ -f "$MEMTEST_DIR/mt86plus_x64.efi" ]] && sbsign --key "$KEY" --cert "$CRT" --output "$OUT/tools/memtest/mt86plus_x64.efi" "$MEMTEST_DIR/mt86plus_x64.efi"
  [[ -f "$MEMTEST_DIR/mt86plus_x64.bin" ]] && cp "$MEMTEST_DIR/mt86plus_x64.bin" "$OUT/tools/memtest/"
fi

echo "== config, theme, font, MOK certificate"
cp "$HERE/grub/grub.cfg" "$HERE/grub/custom.cfg" "$HERE/grub/zinboot.id" "$OUT/grub/"
cp -r "$HERE/grub/themes/zinwinpe" "$OUT/grub/themes/"
cp "$HERE/../assets/branding/grub-bg-1024x768.png" "$OUT/grub/themes/zinwinpe/background.png"
cp /usr/share/grub/unicode.pf2 "$OUT/grub/fonts/" 2>/dev/null || grub-mkfont -o "$OUT/grub/fonts/unicode.pf2" /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
cp "$CER" "$OUT/ENROLL_THIS_KEY_IN_MOKMANAGER.cer"

sbverify --cert "$CRT" "$OUT/EFI/zin/grubx64.efi"
echo "OK -> $OUT"

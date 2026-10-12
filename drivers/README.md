# Kho driver (thiết kế 9)

```text
drivers\
├── ZinDriverSync.ps1      # build kho driver
├── models.json            # model cần driver pack hãng + quy tắc tỉa SDIO
├── cache\                 # (gitignore) catalog + gói tải về
└── store\                 # (gitignore) nguồn thủ công
    ├── T1\                # → inject vào boot.wim (Dell WinPE pack tự tải + manual\)
    ├── PE\                # → ZINDATA\ZinPE\Drivers\PE (T2, nạp lúc chạy PE)
    ├── SDIO\              # SDIO_x64_*.exe + drivers\*.7z (+ indexes\)
    └── OS\<Hãng>\<Key>\<os>\  # driver pack thủ công (Surface...) + "manualRules" trong models.json
```

Kết quả `out\ZINDATA\ZinPE\Drivers`:

| File | Dùng bởi |
|---|---|
| `index.json` | ZinDriver: khớp `sku` (Dell), `baseboard` (HP), `mtm4` (Lenovo), `model`/`friendly` (thủ công) |
| `OS\...\pack-index.json` | Biết driver pack hãng phủ thiết bị nào → phần còn thiếu lấy từ SDIO |
| `OS\Generic\SDIO\sdio-index.tsv` | `HWID<TAB>pack<TAB>inf<TAB>ngày` — ZinDriver chỉ giải nén thư mục `.inf` khớp máy |
| `PE\pe-index.json` | Loader nạp driver T2 cho thiết bị thiếu driver (drvload) |

Gói: **Lite** (T2 + SDIO thiết yếu), **Standard** (mặc định, SDIO đầy đủ đã tỉa `sdio.exclude`), **Full** (+ driver pack hãng theo `models.json`). Script in tổng dung lượng và cảnh báo khi vượt `-BudgetGB` (mặc định 30 GB cho USB 64 GB).

Quy tắc thủ công trong `models.json`:

```json
"manualRules": [
  { "manufacturer": "Microsoft Corporation", "match": "model", "value": "Surface Pro 7*", "os": ["win11"], "path": "OS\\Surface\\SurfacePro7\\win11" }
]
```

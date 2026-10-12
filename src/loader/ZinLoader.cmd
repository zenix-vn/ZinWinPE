@echo off
:: ZinWinPE startup hook - called by PhoenixPE (builder\phoenixpe\README.md).
:: Prefers the scripts on ZINDATA (updatable without rebuilding boot.wim),
:: falls back to the copy embedded in boot.wim at X:\ZinPE\Scripts.
:: -NoExplorer: PhoenixPE starts its own shell after this hook returns.
setlocal
set "ZINSCRIPTS=X:\ZinPE\Scripts"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist "%%D:\ZinPE\zinpe.tag" if exist "%%D:\ZinPE\Scripts\loader\ZinLoader.ps1" (
    set "ZINSCRIPTS=%%D:\ZinPE\Scripts"
    goto :run
  )
)
:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ZINSCRIPTS%\loader\ZinLoader.ps1" -NoExplorer %*
endlocal

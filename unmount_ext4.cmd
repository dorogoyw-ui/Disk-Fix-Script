@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

:: 1. Проверка прав Администратора. Если их нет, запрашиваем повышение
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: 2. Путь для временного файла скрипта PowerShell
set "ps_unmount_file=%temp%\wsl_unmount_temp.ps1"

:: 3. Записываем чистый рабочий код PowerShell во временный файл
echo Write-Host "1. Scanning Windows network paths for mounted WSL disks..." -ForegroundColor Cyan > "%ps_unmount_file%"
echo $wslDefaultDistro = (wsl --list --running --quiet ^| Out-String).Trim() -split "`r`n" ^| Select-Object -First 1 >> "%ps_unmount_file%"
echo $wslDefaultDistro = $wslDefaultDistro -replace "[\r\n`0\s]", "" >> "%ps_unmount_file%"
echo if (-not $wslDefaultDistro) { >> "%ps_unmount_file%"
echo     $wslDefaultDistro = (wsl --list --quiet ^| Out-String).Trim() -split "`r`n" ^| Select-Object -First 1 >> "%ps_unmount_file%"
echo     $wslDefaultDistro = $wslDefaultDistro -replace "[\r\n`0\s]", "" >> "%ps_unmount_file%"
echo } >> "%ps_unmount_file%"
echo if (-not $wslDefaultDistro) { $wslDefaultDistro = "Ubuntu" } >> "%ps_unmount_file%"
echo $wslPath = "\\wsl.localhost\$wslDefaultDistro\mnt\wsl" >> "%ps_unmount_file%"
echo $unmountedCount = 0 >> "%ps_unmount_file%"
echo if (Test-Path $wslPath) { >> "%ps_unmount_file%"
echo     $mountedFolders = Get-ChildItem -Path $wslPath -Directory ^| Where-Object { $_.Name -match "PHYSICALDRIVE\d+" } >> "%ps_unmount_file%"
echo     if ($mountedFolders) { >> "%ps_unmount_file%"
echo         foreach ($folder in $mountedFolders) { >> "%ps_unmount_file%"
echo             if ($folder.Name -match "PHYSICALDRIVE(\d+)") { >> "%ps_unmount_file%"
echo                 $diskNum = $Matches[1] >> "%ps_unmount_file%"
echo                 $targetDevice = "\\.\PHYSICALDRIVE" + $diskNum >> "%ps_unmount_file%"
echo                 Write-Host "Found active mount folder: $($folder.Name)" -ForegroundColor Yellow >> "%ps_unmount_file%"
echo                 Write-Host "Safely unmounting $targetDevice..." -ForegroundColor Cyan >> "%ps_unmount_file%"
echo                 $null = wsl --unmount $targetDevice 2^>$null >> "%ps_unmount_file%"
echo                 Write-Host "SUCCESS! $targetDevice has been safely removed." -ForegroundColor Green >> "%ps_unmount_file%"
echo                 $unmountedCount++ >> "%ps_unmount_file%"
echo             } >> "%ps_unmount_file%"
echo         } >> "%ps_unmount_file%"
echo     } >> "%ps_unmount_file%"
echo } >> "%ps_unmount_file%"
echo if ($unmountedCount -eq 0) { >> "%ps_unmount_file%"
echo     Write-Host "No active mounted ext4 disks found in Windows Explorer network paths." -ForegroundColor Yellow >> "%ps_unmount_file%"
echo } >> "%ps_unmount_file%"

:: 4. Запускаем созданный скрипт PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File "%ps_unmount_file%"

:: 5. Удаляем временный файл после выполнения
if exist "%ps_unmount_file%" del /f /q "%ps_unmount_file%"

:: 6. Финал
echo.
echo ===================================================
echo Скрипт завершил работу.
pause

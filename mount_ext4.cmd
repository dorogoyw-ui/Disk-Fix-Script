@echo off
:: Переключаем кодировку консоли CMD в UTF-8 для корректного вывода русского текста
chcp 65001 >nul
setlocal EnableDelayedExpansion

:: 1. Проверка прав Администратора. Если их нет, запрашиваем повышение
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: 2. Путь для временного файла скрипта PowerShell
set "ps_file=%temp%\wsl_mount_temp.ps1"

:: 3. Записываем чистый рабочий код PowerShell во временный файл
echo Write-Host "1. Scanning all system disks for ext4 partitions..." -ForegroundColor Cyan > "%ps_file%"
echo $wslDefaultDistro = (wsl --list --quiet ^| Out-String).Trim() -split "`r`n" ^| Select-Object -First 1 >> "%ps_file%"
echo $wslDefaultDistro = $wslDefaultDistro -replace "[\r\n`0\s]", "" >> "%ps_file%"
echo if (-not $wslDefaultDistro) { $wslDefaultDistro = "Ubuntu" } >> "%ps_file%"
echo $disks = Get-CimInstance -ClassName Win32_DiskDrive >> "%ps_file%"
echo $ext4Found = $false >> "%ps_file%"
echo foreach ($disk in $disks) { >> "%ps_file%"
echo     $deviceID = $disk.DeviceID >> "%ps_file%"
echo     $diskNumber = $deviceID.Split("E")[-1] >> "%ps_file%"
echo     Write-Host "Checking disk: $($disk.Model) ($deviceID)..." -ForegroundColor Gray >> "%ps_file%"
echo     $null = wsl --unmount $deviceID 2^>$null >> "%ps_file%"
echo     Start-Sleep -Seconds 1 >> "%ps_file%"
echo     $wslOut = wsl --mount $deviceID --partition 1 --type ext4 2^>^&1 ^| Out-String >> "%ps_file%"
echo     if ($LASTEXITCODE -eq 0 -or $wslOut -match "already mounted") { >> "%ps_file%"
echo         Write-Host "SUCCESS! Real ext4 partition found on: $($disk.Model)" -ForegroundColor Green >> "%ps_file%"
echo         $ext4Found = $true >> "%ps_file%"
echo         $mountName = "PHYSICALDRIVE" + $diskNumber + "p1" >> "%ps_file%"
echo         $targetWindowsPath = "\\wsl.localhost\$wslDefaultDistro\mnt\wsl\$mountName" >> "%ps_file%"
echo         Write-Host "2. Granting full read/write permissions for File Explorer..." -ForegroundColor Cyan >> "%ps_file%"
echo         $null = wsl -u root bash -c "chmod 777 /mnt/wsl/$mountName 2>/dev/null" >> "%ps_file%"
echo         $null = wsl -u root bash -c "chown -R 1000:1000 /mnt/wsl/$mountName 2>/dev/null" >> "%ps_file%"
echo         Write-Host "Opening folder in Explorer: $targetWindowsPath" -ForegroundColor Green >> "%ps_file%"
echo         Start-Sleep -Seconds 2 >> "%ps_file%"
echo         explorer.exe $targetWindowsPath >> "%ps_file%"
echo     } else { >> "%ps_file%"
echo         Write-Host "Not an available ext4 disk. Skipping..." -ForegroundColor DarkGray >> "%ps_file%"
echo     } >> "%ps_file%"
echo } >> "%ps_file%"
echo if (-not $ext4Found) { >> "%ps_file%"
echo     Write-Host "No available ext4 partitions found on any disk." -ForegroundColor Red >> "%ps_file%"
echo } >> "%ps_file%"

:: 4. Запускаем созданный скрипт PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File "%ps_file%"

:: 5. Удаляем временный файл после выполнения
if exist "%ps_file%" del /f /q "%ps_file%"

:: 6. Пауза в самом конце
echo.
echo ===================================================
echo Скрипт завершил работу.
pause

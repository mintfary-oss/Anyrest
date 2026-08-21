<#
.SYNOPSIS
    Anyrest Windows Installer v1
    Устанавливает Anyrest-агент или полный сервер на Windows.

.DESCRIPTION
    Режимы:
      -AgentOnly    Только агент (для управляемого ПК, соединяется с сервером)
      -ServerMode   Полный сервер через Docker (сигнализация + relay + веб)

    По умолчанию — агент.

.EXAMPLE
    # Агент (подключиться к серверу 217.198.12.184):
    .\install.ps1 -ServerIP 217.198.12.184

    # Полный сервер:
    .\install.ps1 -ServerMode

    # One-liner (агент):
    powershell -ExecutionPolicy Bypass -c "irm https://cdn.jsdelivr.net/gh/mintfary-oss/Anyrest@main/install.ps1 | iex"
#>
param(
    [string]  $ServerIP   = "",
    [switch]  $ServerMode,
    [string]  $InstallDir = "C:\Anyrest",
    [int]     $FPS        = 15,
    [int]     $Quality    = 75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Цвета ─────────────────────────────────────────────────────────────────────
function Write-Ok   { param($Msg) Write-Host "  [OK]  $Msg" -ForegroundColor Green }
function Write-Fail { param($Msg) Write-Host "  [!!]  $Msg" -ForegroundColor Red;   $script:HasErrors = $true }
function Write-Info { param($Msg) Write-Host "  -->   $Msg" -ForegroundColor Cyan }
function Write-Warn { param($Msg) Write-Host "  [?]   $Msg" -ForegroundColor Yellow }
function Write-Hr   { Write-Host ("─" * 52) -ForegroundColor DarkGray }
function Write-Hr2  { Write-Host ("═" * 52) -ForegroundColor DarkGray }

$script:HasErrors = $false
$script:DiagItems = @()   # каждый элемент: [status, message]

function Add-Diag {
    param([string]$Status, [string]$Msg)
    $script:DiagItems += [PSCustomObject]@{ Status = $Status; Msg = $Msg }
}

# ── Проверка прав администратора ──────────────────────────────────────────────
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "`n  Anyrest требует прав Администратора." -ForegroundColor Red
    Write-Host "  Перезапустите скрипт в PowerShell от имени Администратора.`n" -ForegroundColor Yellow
    Pause
    Exit 1
}

Write-Hr
Write-Host "  Anyrest — Установка Windows v1" -ForegroundColor White -BackgroundColor DarkBlue
Write-Hr
Write-Host ""

# ── Информация о системе ─────────────────────────────────────────────────────
$OSInfo = Get-CimInstance Win32_OperatingSystem
$Arch   = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "x86" }
Write-Ok  "ОС: $($OSInfo.Caption) [$Arch]"
Add-Diag "OK" "ОС: $($OSInfo.Caption)"
Write-Ok  "PowerShell: $($PSVersionTable.PSVersion)"

# ── Определение публичного IP ─────────────────────────────────────────────────
function Get-PublicIP {
    $services = @(
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
        "https://icanhazip.com"
    )
    foreach ($svc in $services) {
        try {
            $ip = (Invoke-WebRequest -Uri $svc -UseBasicParsing -TimeoutSec 5).Content.Trim()
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
        } catch {}
    }
    # Fallback: локальный IP
    return (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" } | Select-Object -First 1).IPAddress
}

if (-not $ServerMode -and -not $ServerIP) {
    Write-Info "ServerIP не указан. Введите IP сервера Anyrest (или Enter для локального):"
    $ServerIP = Read-Host "  Server IP"
}

if ($ServerMode) {
    $ServerIP = Get-PublicIP
    Write-Ok "Публичный IP (сервер): $ServerIP"
    Add-Diag "OK" "Публичный IP: $ServerIP"
}

# ─────────────────────────────────────────────────────────────────────────────
# РЕЖИМ АГЕНТА
# Скачивает anyrest-agent.exe, запускает как Windows Service.
# Не требует Docker, работает на любом Windows 10/11/Server 2019+.
# ─────────────────────────────────────────────────────────────────────────────
function Install-Agent {
    Write-Hr
    Write-Host "  Установка агента (управляемый ПК)" -ForegroundColor Cyan
    Write-Hr

    # Папка установки
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $AgentExe  = Join-Path $InstallDir "anyrest-agent.exe"
    $AgentUrl  = "https://github.com/mintfary-oss/Anyrest/raw/main/bin/windows-amd64/anyrest-agent.exe"
    $AgentUrlJ = "https://cdn.jsdelivr.net/gh/mintfary-oss/Anyrest@main/bin/windows-amd64/anyrest-agent.exe"

    # Скачиваем бинарник
    Write-Info "Скачиваю anyrest-agent.exe (~11 MB)..."
    $downloaded = $false
    foreach ($url in @($AgentUrlJ, $AgentUrl)) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $AgentExe -UseBasicParsing -TimeoutSec 120
            $downloaded = $true
            break
        } catch {
            Write-Warn "Не удалось с $url — пробую резервный..."
        }
    }
    if (-not $downloaded) {
        Write-Fail "Не удалось скачать anyrest-agent.exe. Проверьте интернет-соединение."
        return
    }
    Write-Ok "anyrest-agent.exe скачан: $AgentExe"
    Add-Diag "OK" "anyrest-agent.exe скачан"

    # Проверяем что бинарник запускается
    try {
        $ver = & $AgentExe --help 2>&1 | Select-Object -First 1
        Write-Ok "Бинарник проверен: $ver"
    } catch {
        Write-Warn "Проверка бинарника пропущена (это нормально)."
    }

    # ── Настройка сигнального сервера ──────────────────────────────────────────
    $SignalURL = if ($ServerIP) { "wss://${ServerIP}/ws" } else { "ws://localhost:8080/ws" }
    Write-Ok "Signal URL: $SignalURL"
    Add-Diag "OK" "Signal URL: $SignalURL"

    # ── Создание Windows Service ───────────────────────────────────────────────
    $ServiceName = "AnyrestAgent"
    $ServiceDesc = "Anyrest Desktop Agent — remote desktop sharing"

    # Удаляем старый сервис если есть
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Info "Остановка старого сервиса..."
        Stop-Service  -Name $ServiceName -Force -ErrorAction SilentlyContinue
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }

    # Создаём сервис через sc.exe (работает без .NET WMI)
    $BinPath = "`"$AgentExe`" -signal `"$SignalURL`" -fps $FPS -quality $Quality"
    sc.exe create $ServiceName binPath= $BinPath `
        start= auto `
        DisplayName= "Anyrest Agent" | Out-Null
    sc.exe description $ServiceName $ServiceDesc | Out-Null

    # Запускаем
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Ok "Сервис AnyrestAgent запущен."
        Add-Diag "OK" "Windows Service AnyrestAgent: Running"
    } else {
        Write-Warn "Сервис не запустился автоматически. Проверьте дисплей:"
        Write-Warn "  Агент требует активной графической сессии (Remote Desktop или физический вход)."
        Write-Warn "  Запустите вручную: $AgentExe -signal '$SignalURL'"
        Add-Diag "WARN" "Сервис AnyrestAgent не запустился — нужна активная графическая сессия"
    }

    # ── Правило брандмауэра (агент не слушает порты, но для STUN/TURN) ─────────
    Write-Info "Разрешаю исходящие соединения для агента..."
    New-NetFirewallRule -DisplayName "Anyrest Agent" `
        -Direction Outbound `
        -Program $AgentExe `
        -Action Allow `
        -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Ok "Правило брандмауэра добавлено."
    Add-Diag "OK" "Firewall: исходящие разрешены"
}

# ─────────────────────────────────────────────────────────────────────────────
# РЕЖИМ СЕРВЕРА (Docker Compose)
# ─────────────────────────────────────────────────────────────────────────────
function Install-Server {
    Write-Hr
    Write-Host "  Установка сервера (Docker Compose)" -ForegroundColor Cyan
    Write-Hr

    # ── Docker ────────────────────────────────────────────────────────────────
    $dockerOk = $false
    try {
        $dockerVer = (docker --version 2>&1)
        if ($dockerVer -match "Docker") {
            Write-Ok "Docker: $dockerVer"
            Add-Diag "OK" "Docker: $dockerVer"
            $dockerOk = $true
        }
    } catch {}

    if (-not $dockerOk) {
        Write-Info "Docker не найден. Устанавливаю Docker Desktop..."

        # Скачиваем Docker Desktop installer
        $dockerInstaller = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
        $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
        try {
            Write-Info "Скачиваю Docker Desktop (~650 MB)..."
            Invoke-WebRequest -Uri $dockerUrl -OutFile $dockerInstaller -UseBasicParsing -TimeoutSec 600
            Write-Info "Устанавливаю Docker Desktop (silent)..."
            Start-Process -FilePath $dockerInstaller -ArgumentList "install --quiet --accept-license" -Wait
            Write-Ok "Docker Desktop установлен. Требуется перезагрузка."
            Add-Diag "WARN" "Docker Desktop установлен — перезагрузите ПК, затем запустите install.ps1 снова."
            Write-Host ""
            Write-Warn "ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА для завершения установки Docker."
            Write-Warn "После перезагрузки запустите: powershell -ExecutionPolicy Bypass -File '$PSCommandPath'"
        } catch {
            Write-Fail "Не удалось установить Docker Desktop: $_"
            Write-Warn "Установите вручную: https://www.docker.com/products/docker-desktop/"
        }
        return
    }

    # Ждём пока Docker daemon готов
    Write-Info "Проверяю Docker daemon..."
    $tries = 0
    while ($tries -lt 30) {
        try { docker info 2>&1 | Out-Null; break } catch {}
        Start-Sleep -Seconds 2
        $tries++
    }

    # ── Репозиторий ───────────────────────────────────────────────────────────
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    if (-not (Test-Path (Join-Path $InstallDir "docker-compose.yml"))) {
        Write-Info "Клонирую репозиторий..."
        git clone --depth 1 https://github.com/mintfary-oss/Anyrest.git $InstallDir 2>&1 | Out-Null
        Write-Ok "Репозиторий клонирован: $InstallDir"
    } else {
        Write-Info "Обновляю репозиторий..."
        git -C $InstallDir pull --quiet 2>&1 | Out-Null
        Write-Ok "Репозиторий обновлён."
    }

    # ── Сертификаты ───────────────────────────────────────────────────────────
    $certsDir = Join-Path $InstallDir "certs"
    $serverCrt = Join-Path $certsDir "server.crt"
    if (-not (Test-Path $serverCrt)) {
        Write-Info "Генерирую TLS-сертификаты..."
        $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($opensslCmd) {
            # WSL / Git Bash / Windows OpenSSL
            $cnf = Join-Path $certsDir "openssl.cnf"
            @"
[req]
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no
[req_distinguished_name]
CN = Anyrest Root CA
[v3_ca]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, keyCertSign, cRLSign
"@ | Set-Content $cnf
            Push-Location $certsDir
            openssl genrsa -out ca.key 4096 2>&1 | Out-Null
            openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -config $cnf 2>&1 | Out-Null

            $srvCnf = Join-Path $certsDir "server-ext.cnf"
            @"
subjectAltName = IP:$ServerIP
"@ | Set-Content $srvCnf
            openssl genrsa -out server.key 4096 2>&1 | Out-Null
            openssl req -new -key server.key -out server.csr `
                -subj "/CN=$ServerIP" 2>&1 | Out-Null
            openssl x509 -req -days 3650 `
                -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial `
                -extfile $srvCnf -out server.crt 2>&1 | Out-Null
            Pop-Location
            Write-Ok "Сертификаты созданы."
            Add-Diag "OK" "TLS сертификаты созданы (IP SAN: $ServerIP)"
        } else {
            Write-Warn "openssl не найден. Сертификаты сгенерируйте вручную:"
            Write-Warn "  bash certs/gen-certs.sh --ip $ServerIP  (в Git Bash или WSL)"
            Add-Diag "WARN" "openssl не найден — сертификаты нужно сгенерировать вручную"
        }
    } else {
        Write-Ok "Сертификаты уже существуют."
    }

    # ── .env ─────────────────────────────────────────────────────────────────
    $envFile = Join-Path $InstallDir ".env"
    if (-not (Test-Path $envFile)) {
        $secret = [System.Convert]::ToHexString(
            [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        @"
RELAY_SECRET=$secret
ANYREST_SIGNAL_URL=wss://${ServerIP}/ws
"@ | Set-Content $envFile -Encoding UTF8
        Write-Ok ".env создан."
    } else {
        Write-Ok ".env уже существует."
    }

    # ── Открытие портов ────────────────────────────────────────────────────────
    Write-Info "Открываю порты 80, 443, 8081 в Windows Firewall..."
    foreach ($port in @(80, 443, 8081)) {
        $ruleName = "Anyrest TCP $port"
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $port `
            -Action Allow `
            -Profile Any | Out-Null
    }
    Write-Ok "Firewall: порты 80, 443, 8081 открыты."
    Add-Diag "OK" "Windows Firewall: открыты порты 80, 443, 8081"

    # ── Установка зеркал Docker (РФ) ──────────────────────────────────────────
    $dockerConfigDir = Join-Path $env:USERPROFILE ".docker"
    $daemonJson = Join-Path $dockerConfigDir "daemon.json"
    if (-not (Test-Path $daemonJson) -or -not ((Get-Content $daemonJson -Raw) -match "registry-mirrors")) {
        if (-not (Test-Path $dockerConfigDir)) { New-Item -ItemType Directory $dockerConfigDir | Out-Null }
        @'
{
  "registry-mirrors": [
    "https://huecker.io",
    "https://dockerhub.timeweb.cloud"
  ]
}
'@ | Set-Content $daemonJson -Encoding UTF8
        Write-Ok "Зеркала Docker Hub настроены (huecker.io, timeweb.cloud)."
    }

    # ── Docker Compose ─────────────────────────────────────────────────────────
    Write-Info "Запускаю Docker Compose (только COPY, ~30 сек)..."
    Push-Location $InstallDir
    $env:TARGETARCH = "amd64"

    # Остановка если запущено
    docker compose down --remove-orphans 2>&1 | Out-Null

    # Сборка
    $buildOk = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Info "Сборка образов (попытка $attempt/3)..."
        docker compose build 2>&1
        if ($LASTEXITCODE -eq 0) { $buildOk = $true; break }
        Write-Warn "Ошибка сборки. Повтор через 15 сек..."
        Start-Sleep -Seconds 15
    }
    if (-not $buildOk) {
        Write-Fail "Сборка Docker образов не удалась после 3 попыток."
        Pop-Location
        return
    }

    docker compose up -d 2>&1
    Pop-Location

    # Ожидаем готовности
    Write-Info "Ожидаю запуска (до 60 сек)..."
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "https://${ServerIP}/health" `
                -UseBasicParsing -TimeoutSec 3 `
                -SkipCertificateCheck -ErrorAction SilentlyContinue
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
        Start-Sleep -Seconds 1
    }

    if ($ready) {
        Write-Ok "Сервер запущен и отвечает."
        Add-Diag "OK" "Сервер https://${ServerIP}/health → OK"
    } else {
        Write-Warn "Сервер не ответил за 60 сек. Проверьте: docker compose logs"
        Add-Diag "WARN" "Health check не ответил"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Диагностика — проверка связности
# ─────────────────────────────────────────────────────────────────────────────
function Test-Connectivity {
    Write-Hr
    Write-Info "Диагностика подключения..."
    Write-Hr

    # DNS
    try {
        [System.Net.Dns]::GetHostAddresses("github.com") | Out-Null
        Write-Ok "DNS: github.com разрешается."
        Add-Diag "OK" "DNS: OK"
    } catch {
        Write-Fail "DNS: не удаётся разрешить github.com. Проверьте сетевые настройки."
        Add-Diag "FAIL" "DNS: ошибка"
    }

    # Исходящий HTTPS
    try {
        Invoke-WebRequest -Uri "https://dns.google" -UseBasicParsing -TimeoutSec 5 | Out-Null
        Write-Ok "Исходящий HTTPS: OK."
        Add-Diag "OK" "Исходящий HTTPS: OK"
    } catch {
        Write-Warn "Исходящий HTTPS ограничен — WebRTC STUN/TURN может не работать."
        Add-Diag "WARN" "Исходящий HTTPS: ограничен"
    }

    if ($ServerMode -and $ServerIP) {
        # Проверка HTTPS сервера
        try {
            $r = Invoke-WebRequest -Uri "https://${ServerIP}/health" `
                -UseBasicParsing -TimeoutSec 5 -SkipCertificateCheck
            Write-Ok "HTTPS https://${ServerIP}/health: $($r.StatusCode)"
            Add-Diag "OK" "HTTPS health: OK"
        } catch {
            Write-Fail "HTTPS https://${ServerIP}/health: не отвечает"
            Add-Diag "FAIL" "HTTPS health: нет ответа"
        }

        # Проверка TCP relay
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.ConnectAsync($ServerIP, 8081).Wait(3000) | Out-Null
            if ($tcp.Connected) {
                Write-Ok "Relay TCP ${ServerIP}:8081 — открыт."
                Add-Diag "OK" "Relay TCP 8081: OK"
            }
            $tcp.Close()
        } catch {
            Write-Warn "Relay TCP ${ServerIP}:8081 — нет ответа (проверьте firewall)."
            Add-Diag "WARN" "Relay TCP 8081: нет ответа"
        }
    } elseif ($ServerIP) {
        # Агент: проверяем доступность сигнального сервера
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.ConnectAsync($ServerIP, 443).Wait(5000) | Out-Null
            if ($tcp.Connected) {
                Write-Ok "Сигнальный сервер ${ServerIP}:443 — доступен."
                Add-Diag "OK" "Сигнальный сервер 443: OK"
            }
            $tcp.Close()
        } catch {
            Write-Fail "Сигнальный сервер ${ServerIP}:443 — не доступен!"
            Write-Fail "  Убедитесь что сервер запущен и порт 443 открыт."
            Add-Diag "FAIL" "Сигнальный сервер: недоступен"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Финальный отчёт
# ─────────────────────────────────────────────────────────────────────────────
function Print-Report {
    Write-Host ""
    Write-Hr2
    Write-Host "  Anyrest — Диагностический отчёт" -ForegroundColor Magenta
    Write-Hr2

    foreach ($item in $script:DiagItems) {
        switch ($item.Status) {
            "OK"   { Write-Host "  [OK]  $($item.Msg)" -ForegroundColor Green  }
            "WARN" { Write-Host "  [!]   $($item.Msg)" -ForegroundColor Yellow }
            "FAIL" { Write-Host "  [X]   $($item.Msg)" -ForegroundColor Red    }
        }
    }

    Write-Host ""
    Write-Hr2

    if ($script:HasErrors) {
        Write-Host "  РЕЗУЛЬТАТ: ОБНАРУЖЕНЫ ОШИБКИ" -ForegroundColor Red
    } else {
        Write-Host "  РЕЗУЛЬТАТ: УСТАНОВКА ЗАВЕРШЕНА  [OK]" -ForegroundColor Green
    }

    Write-Host ""
    if ($ServerMode) {
        Write-Host "  Откройте в браузере: https://$ServerIP" -ForegroundColor Cyan
        Write-Host "  CA-сертификат:       https://$ServerIP/certs/ca.crt" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Установить CA в Chrome:" -ForegroundColor White
        Write-Host "    Скачайте ca.crt → правая кнопка → Установить сертификат"
        Write-Host "    → Локальный компьютер → Доверенные корневые центры"
    } else {
        Write-Host "  Агент установлен и запущен как Windows Service 'AnyrestAgent'." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Управление:" -ForegroundColor White
        Write-Host "    Проверить статус: Get-Service AnyrestAgent"
        Write-Host "    Перезапустить:    Restart-Service AnyrestAgent"
        Write-Host "    Логи:             Get-EventLog -LogName Application -Source AnyrestAgent"
        Write-Host ""
        if ($ServerIP) {
            Write-Host "  Откройте в браузере на другом ПК:" -ForegroundColor Cyan
            Write-Host "  https://$ServerIP" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Этот ПК появится как управляемый агент в списке подключений." -ForegroundColor White
        }
    }

    Write-Host ""
    Write-Hr2
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
if ($ServerMode) {
    Write-Info "Режим: полный сервер (Docker Compose)"
    Install-Server
} else {
    Write-Info "Режим: агент (управляемый ПК)"
    Install-Agent
}

Test-Connectivity
Print-Report

if ($script:HasErrors) { Exit 1 } else { Exit 0 }

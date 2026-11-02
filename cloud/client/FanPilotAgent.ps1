param([switch]$Staged)

# FanPilot Cloud Agent: показания датчиков -> облачная панель, команды из Telegram, подписанные автообновления.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:AgentVersion = '1.0.0'
$script:ApiBase = '__API_BASE__'
$script:UpdatePublicKeyXml = '__PUBLIC_KEY_XML__'

$script:DataDir = Join-Path $env:LOCALAPPDATA 'FanPilot'
$script:LogPath = Join-Path $script:DataDir 'agent.log'
$script:CloudPath = Join-Path $script:DataDir 'cloud.json'
$script:CredPath = Join-Path $script:DataDir 'agent.json'
$script:StagedPath = Join-Path $script:DataDir 'Updates\FanPilotAgent.ps1'
$script:TaskName = 'FanPilot Cloud Agent'
$script:DeviceKey = $null
New-Item -ItemType Directory -Path (Join-Path $script:DataDir 'Updates') -Force | Out-Null

function Write-AgentLog {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 512KB) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
        }
        Add-Content -LiteralPath $script:LogPath -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message) -Encoding UTF8
    } catch { }
}

function Test-FileSignature {
    param([byte[]]$Bytes, [string]$SignatureBase64)
    if ($script:UpdatePublicKeyXml -notlike '<RSAKeyValue>*') { return $false }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($script:UpdatePublicKeyXml)
        return [bool]$rsa.VerifyData($Bytes, 'SHA256', [Convert]::FromBase64String($SignatureBase64))
    } finally { $rsa.Dispose() }
}

function Get-VersionFromText {
    param([string]$Text)
    if ($Text -match "\`$script:AgentVersion\s*=\s*'(\d+\.\d+\.\d+)'") { return [version]$Matches[1] }
    return $null
}

# --- Если в Updates лежит проверенная подписью более новая версия агента, запускаем её ---
if (-not $Staged -and (Test-Path -LiteralPath $script:StagedPath) -and (Test-Path -LiteralPath ($script:StagedPath + '.sig'))) {
    try {
        $stagedBytes = [IO.File]::ReadAllBytes($script:StagedPath)
        $stagedVersion = Get-VersionFromText -Text ([Text.Encoding]::UTF8.GetString($stagedBytes))
        $signature = (Get-Content -LiteralPath ($script:StagedPath + '.sig') -Raw).Trim()
        if ($null -ne $stagedVersion -and $stagedVersion -gt [version]$script:AgentVersion -and (Test-FileSignature -Bytes $stagedBytes -SignatureBase64 $signature)) {
            $env:FANPILOT_ENTRY = $PSCommandPath
            Write-AgentLog ('Запускаю обновлённый агент ' + $stagedVersion)
            & $script:StagedPath -Staged
            exit 0
        }
    } catch {
        Write-AgentLog ('Обновлённый агент не запустился, использую встроенную версию: ' + $_.Exception.Message)
        Remove-Item -LiteralPath $script:StagedPath, ($script:StagedPath + '.sig') -Force -ErrorAction SilentlyContinue
    }
}
$script:EntryPath = if ($env:FANPILOT_ENTRY) { $env:FANPILOT_ENTRY } else { $PSCommandPath }

function Get-CloudEnabled {
    try { return [bool]((Get-Content -LiteralPath $script:CloudPath -Raw -Encoding UTF8 | ConvertFrom-Json).Enabled) } catch { return $false }
}

function Disable-Cloud {
    Set-Content -LiteralPath $script:CloudPath -Value '{"Enabled":false}' -Encoding UTF8
    Remove-Item -LiteralPath $script:CredPath -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-AgentLog 'Облачный доступ отключён, учётные данные удалены.'
}

if ($script:ApiBase -notmatch '^https://') { Write-AgentLog 'Адрес API не настроен (tools/release.js setup).'; exit 0 }
if (-not (Get-CloudEnabled)) { exit 0 }

# --- только один агент; новый процесс после обновления ждёт завершения старого ---
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\FanPilotCloudAgent', [ref]$createdNew)
if (-not $createdNew) {
    $acquired = $false
    try { $acquired = $script:Mutex.WaitOne(20000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { exit 0 }
}

# --- Датчики ---
$libDir = @((Join-Path $script:DataDir 'Runtime\lib'), (Join-Path (Split-Path -Parent $script:EntryPath) 'lib')) |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'LibreHardwareMonitorLib.dll') } | Select-Object -First 1
if (-not $libDir) { Write-AgentLog 'Не найдена библиотека датчиков. Запустите PC-PersonalControl.exe один раз.'; exit 1 }
foreach ($name in @('System.CodeDom.dll', 'HidSharp.dll', 'System.Management.dll', 'LibreHardwareMonitorLib.dll')) {
    [Reflection.Assembly]::LoadFrom((Join-Path $libDir $name)) | Out-Null
}

function New-Computer {
    $c = New-Object LibreHardwareMonitor.Hardware.Computer
    $c.IsCpuEnabled = $true; $c.IsGpuEnabled = $true; $c.IsMotherboardEnabled = $true
    $c.IsControllerEnabled = $true; $c.IsMemoryEnabled = $true
    $c.Open()
    return $c
}

function Get-HardwareTree {
    param([object]$Hardware)
    foreach ($item in $Hardware) {
        $item
        if ($item.SubHardware) { Get-HardwareTree -Hardware $item.SubHardware }
    }
}

function Get-Specs {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $board = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
    $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $gpus = @()
    foreach ($hw in (Get-HardwareTree -Hardware $script:Computer.Hardware)) {
        if ($hw.HardwareType.ToString() -like 'Gpu*') {
            $vram = $null
            foreach ($s in $hw.Sensors) { if ($s.Name -eq 'GPU Memory Total' -and $null -ne $s.Value) { $vram = [double]$s.Value } }
            $gpus += @{ name = [string]$hw.Name; vramMB = $vram }
        }
    }
    $disks = @(Get-CimInstance Win32_DiskDrive | ForEach-Object { @{ name = [string]$_.Model; sizeGB = [Math]::Round([double]$_.Size / 1GB) } })
    return @{
        os = [string]$os.Caption
        board = (([string]$board.Manufacturer + ' ' + [string]$board.Product).Trim())
        ramGB = [Math]::Round([double]$ram / 1GB, 1)
        cpu = @{ name = ([string]$cpu.Name).Trim(); cores = [int]$cpu.NumberOfCores; threads = [int]$cpu.NumberOfLogicalProcessors }
        gpu = $gpus
        disks = $disks
    }
}

function Get-Readings {
    $temps = New-Object System.Collections.ArrayList
    $fans = [ordered]@{}
    $load = @{ cpu = $null; gpu = $null; ram = $null }
    foreach ($hw in (Get-HardwareTree -Hardware $script:Computer.Hardware)) {
        $hw.Update()
        $type = $hw.HardwareType.ToString()
        foreach ($s in $hw.Sensors) {
            if ($null -eq $s.Value) { continue }
            $kind = $s.SensorType.ToString()
            if ($kind -eq 'Temperature') {
                $group = if ($type -eq 'Cpu') { 'cpu' } elseif ($type -like 'Gpu*') { 'gpu' } else { 'other' }
                [void]$temps.Add(@{ hw = [string]$hw.Name; name = [string]$s.Name; value = [double]$s.Value; kind = $group })
            } elseif ($kind -eq 'Fan' -or $kind -eq 'Control') {
                $key = $hw.Name + '|' + $s.Name
                if (-not $fans.Contains($key)) { $fans[$key] = @{ hw = [string]$hw.Name; name = [string]$s.Name; rpm = $null; percent = $null } }
                if ($kind -eq 'Fan') { $fans[$key].rpm = [double]$s.Value } elseif ($s.Name -match '(?i)fan') { $fans[$key].percent = [double]$s.Value }
            } elseif ($kind -eq 'Load') {
                if ($type -eq 'Cpu' -and $s.Name -eq 'CPU Total') { $load.cpu = [double]$s.Value }
                elseif ($type -like 'Gpu*' -and $s.Name -eq 'GPU Core') { $load.gpu = [double]$s.Value }
                elseif ($type -eq 'Memory' -and $s.Name -eq 'Memory') { $load.ram = [double]$s.Value }
            }
        }
    }
    $fanList = @($fans.Values | Where-Object { $null -ne $_.rpm -or $null -ne $_.percent })
    return @{ temps = $temps.ToArray(); fans = $fanList; load = $load }
}

# --- API ---
function Get-HttpStatus {
    param($ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

function Invoke-Api {
    param([string]$Method, [string]$Path, [object]$Body, [int]$Timeout = 30)
    $request = @{ Uri = $script:ApiBase + $Path; Method = $Method; TimeoutSec = $Timeout; UseBasicParsing = $true; Headers = @{} }
    if ($script:DeviceKey) { $request.Headers.Authorization = 'Bearer ' + $script:DeviceKey }
    if ($null -ne $Body) {
        $request.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 8 -Compress))
        $request.ContentType = 'application/json; charset=utf-8'
    }
    return (Invoke-WebRequest @request).Content | ConvertFrom-Json
}

function Open-PairLink {
    param([string]$Url)
    if ($Url -match '^https://t\.me/[A-Za-z0-9_]{4,64}\?start=[A-Z2-9]{8}$') {
        Write-AgentLog ('Для привязки откройте: ' + $Url)
        try { Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList $Url } catch { Write-AgentLog ('Не удалось открыть ссылку: ' + $_.Exception.Message) }
    }
}

function Initialize-Device {
    if (Test-Path -LiteralPath $script:CredPath) {
        $cred = Get-Content -LiteralPath $script:CredPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $secure = ConvertTo-SecureString ([string]$cred.KeyProtected)
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $script:DeviceKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        $pair = Invoke-Api -Method POST -Path '/api/v1/agent/pair-code' -Body @{}
        if (-not $pair.paired) { Open-PairLink -Url $pair.pairUrl }
        return
    }
    $reg = Invoke-Api -Method POST -Path '/api/v1/agent/register' -Body @{ name = [Environment]::MachineName }
    $script:DeviceKey = [string]$reg.deviceKey
    $protected = ConvertFrom-SecureString (ConvertTo-SecureString -String $script:DeviceKey -AsPlainText -Force)
    ConvertTo-Json -InputObject @{ DeviceId = [string]$reg.deviceId; KeyProtected = $protected } | Set-Content -LiteralPath $script:CredPath -Encoding UTF8
    Write-AgentLog 'Устройство зарегистрировано.'
    Open-PairLink -Url ([string]$reg.pairUrl)
}

# --- Команды (только фиксированный список) ---
if (-not ('FanPilotCloudNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class FanPilotCloudNative {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool LockWorkStation();
    [DllImport("powrprof.dll", SetLastError = true)] public static extern bool SetSuspendState(bool hibernate, bool force, bool disableWake);
}
'@
}

function Invoke-Shutdown {
    param([string[]]$Arguments)
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\shutdown.exe') -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

function Send-WakePacket {
    $mac = ''
    try { $mac = [string](Get-Content -LiteralPath (Join-Path $script:DataDir 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Power.BotWakeMac } catch { }
    if ($mac -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') { throw 'MAC для Wake-on-LAN не задан в FanPilot.' }
    $bytes = [byte[]]@($mac -split '[:-]' | ForEach-Object { [Convert]::ToByte($_, 16) })
    $packet = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 255 }
    for ($i = 0; $i -lt 16; $i++) { [Array]::Copy($bytes, 0, $packet, 6 + $i * 6, 6) }
    $udp = New-Object Net.Sockets.UdpClient
    try { $udp.EnableBroadcast = $true; [void]$udp.Send($packet, $packet.Length, (New-Object Net.IPEndPoint([Net.IPAddress]::Broadcast, 9))) } finally { $udp.Dispose() }
}

function Invoke-Command-Safe {
    param($Command)
    $action = [string]$Command.action
    switch ($action) {
        'lock' { if (-not [FanPilotCloudNative]::LockWorkStation()) { throw 'Windows не смогла заблокировать сеанс.' }; return 'Сеанс заблокирован.' }
        'sleep' { if (-not [FanPilotCloudNative]::SetSuspendState($false, $false, $false)) { throw 'Спящий режим недоступен.' }; return 'Перехожу в сон.' }
        'shutdown' { [void](Invoke-Shutdown @('/a')); if ((Invoke-Shutdown @('/s', '/t', '0')) -ne 0) { throw 'Не удалось выключить ПК.' }; return 'Выключаю ПК.' }
        'restart' { [void](Invoke-Shutdown @('/a')); if ((Invoke-Shutdown @('/r', '/t', '0')) -ne 0) { throw 'Не удалось перезагрузить ПК.' }; return 'Перезагружаю ПК.' }
        'timer' {
            $seconds = [long]$Command.arg
            if ($seconds -lt 1 -or $seconds -gt 315360000) { throw 'Недопустимая длительность.' }
            [void](Invoke-Shutdown @('/a'))
            if ((Invoke-Shutdown @('/s', '/t', $seconds.ToString())) -ne 0) { throw 'Не удалось установить таймер.' }
            return 'Таймер выключения установлен.'
        }
        'cancel' { $code = Invoke-Shutdown @('/a'); if ($code -ne 0 -and $code -ne 1116) { throw 'Не удалось отменить таймер.' }; return 'Таймер отменён.' }
        'wake' { Send-WakePacket; return 'Wake-on-LAN отправлен.' }
        'unlink' { Disable-Cloud; exit 0 }
        default { throw 'Неизвестная команда.' }
    }
}

# --- Обновление ---
function Install-AgentUpdate {
    param($Release)
    if ([string]$Release.agent.url -notmatch '^/dl/agent-\d+\.\d+\.\d+\.ps1$') { throw 'Недопустимый адрес обновления.' }
    $download = Join-Path $script:DataDir 'Updates\download.tmp'
    Invoke-WebRequest -Uri ($script:ApiBase + $Release.agent.url) -UseBasicParsing -TimeoutSec 60 -OutFile $download
    $bytes = [IO.File]::ReadAllBytes($download)
    Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
    if ($hash -ne ([string]$Release.agent.sha256).ToUpperInvariant()) { throw 'Контрольная сумма обновления не совпала.' }
    if (-not (Test-FileSignature -Bytes $bytes -SignatureBase64 ([string]$Release.agent.signature))) { throw 'Подпись обновления недействительна — установка отменена.' }
    $newVersion = Get-VersionFromText -Text ([Text.Encoding]::UTF8.GetString($bytes))
    if ($null -eq $newVersion -or $newVersion -ne [version]$Release.version -or $newVersion -le [version]$script:AgentVersion) { throw 'Версия в обновлении не соответствует заявленной.' }
    [IO.File]::WriteAllBytes($script:StagedPath + '.tmp', $bytes)
    Set-Content -LiteralPath ($script:StagedPath + '.sig') -Value ([string]$Release.agent.signature) -Encoding ASCII
    Move-Item -LiteralPath ($script:StagedPath + '.tmp') -Destination $script:StagedPath -Force
    Write-AgentLog ('Обновление ' + $newVersion + ' проверено и установлено, перезапуск.')
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script:EntryPath + '"'
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden
    try { $script:Mutex.ReleaseMutex() } catch { }
    exit 0
}

# --- Основной цикл ---
try {
    $script:Computer = New-Computer
    Initialize-Device
    $specs = Get-Specs
    $specsAt = Get-Date
    Write-AgentLog ('Агент ' + $script:AgentVersion + ' запущен.')
    $lastCloudCheck = Get-Date
    $failedUpdate = ''
    $fast = $false
    $emptyReadings = 0
    while ($true) {
        try {
            $readings = Get-Readings
            if ($readings.temps.Count -eq 0 -and $readings.fans.Count -eq 0) {
                $emptyReadings++
                if ($emptyReadings -ge 3) {
                    try { $script:Computer.Close() } catch { }
                    $script:Computer = New-Computer; $emptyReadings = 0
                    Write-AgentLog 'Датчики перезапущены (пустые показания).'
                }
            } else { $emptyReadings = 0 }
            if (((Get-Date) - $specsAt).TotalMinutes -gt 60) { $specs = Get-Specs; $specsAt = Get-Date }
            $uptime = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes
            $result = Invoke-Api -Method POST -Path '/api/v1/agent/telemetry' -Body @{
                host = [Environment]::MachineName; agent = $script:AgentVersion; uptimeMin = [Math]::Round($uptime)
                specs = $specs; temps = $readings.temps; fans = $readings.fans; load = $readings.load
            }
            $fast = [bool]$result.fast
            $release = $result.release
            if ($release -and $release.version -ne $failedUpdate -and [version]$release.version -gt [version]$script:AgentVersion) {
                try { Install-AgentUpdate -Release $release } catch {
                    $failedUpdate = [string]$release.version
                    Write-AgentLog ('Обновление не установлено: ' + $_.Exception.Message)
                }
            }
            $wait = if ($fast) { 4 } else { 25 }
            if ($result.paired) {
                $poll = Invoke-Api -Method GET -Path ('/api/v1/agent/poll?wait=' + $wait) -Timeout 40
                foreach ($command in @($poll.commands)) {
                    $ok = $true
                    try { $message = Invoke-Command-Safe -Command $command } catch { $ok = $false; $message = $_.Exception.Message }
                    Write-AgentLog ('Команда ' + $command.action + ': ' + $message)
                    try { [void](Invoke-Api -Method POST -Path '/api/v1/agent/result' -Body @{ id = $command.id; ok = $ok; message = $message }) } catch { }
                }
            } else { Start-Sleep -Seconds 20 }
        } catch {
            if ((Get-HttpStatus $_) -eq 401) { Write-AgentLog 'Сервер не знает это устройство (отвязано). Облако отключено.'; Disable-Cloud; exit 0 }
            Write-AgentLog ('Ошибка цикла: ' + $_.Exception.Message)
            Start-Sleep -Seconds 15
        }
        if (((Get-Date) - $lastCloudCheck).TotalSeconds -gt 60) {
            $lastCloudCheck = Get-Date
            if (-not (Get-CloudEnabled)) { Write-AgentLog 'Облако выключено пользователем.'; break }
        }
    }
} finally {
    try { if ($script:Computer) { $script:Computer.Close() } } catch { }
}

param(
    [switch]$RestoreDefaults,
    [int]$CloseProcessId = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not [Environment]::Is64BitProcess) {
    [System.Windows.Forms.MessageBox]::Show(
        'Запустите приложение в 64-разрядной Windows PowerShell.',
        'PC-PersonalControl',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        if ($RestoreDefaults) {
            $arguments += ' -RestoreDefaults'
        }
        if ($CloseProcessId -gt 0) {
            $arguments += ' -CloseProcessId ' + $CloseProcessId
        }
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            'Для чтения датчиков и управления вентиляторами приложению нужны права администратора. ' + $_.Exception.Message,
            'PC-PersonalControl',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    exit
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:LibraryDirectory = Join-Path $PSScriptRoot 'lib'
$script:PackageDefinitions = @(
    @{
        Id = 'LibreHardwareMonitorLib'
        Version = '0.9.2'
        Sha256 = '0E3354D8F48ABA03F6173F4D76637A6CC23084CA3BAEEE44A4ED292E66D72647'
        Asset = 'lib/net472/LibreHardwareMonitorLib.dll'
        File = 'LibreHardwareMonitorLib.dll'
    },
    @{
        Id = 'HidSharp'
        Version = '2.1.0'
        Sha256 = '0B05B2A7367F85E0D61883387810A56B8CD33D707DF8BDFDF536157BFCCF7616'
        Asset = 'lib/netstandard2.0/HidSharp.dll'
        File = 'HidSharp.dll'
    },
    @{
        Id = 'System.Management'
        Version = '7.0.0'
        Sha256 = '404758073F1FF34B7D9AF852CCE1EC48873B27455E3843B39199D13ABFE47DF4'
        Asset = 'lib/netstandard2.0/System.Management.dll'
        File = 'System.Management.dll'
    },
    @{
        Id = 'System.CodeDom'
        Version = '7.0.0'
        Sha256 = 'EC83EDDFD718FB48F465C46BFC9E39C4FB448E749775427FE5A8B779B6984221'
        Asset = 'lib/net462/System.CodeDom.dll'
        File = 'System.CodeDom.dll'
    }
)

function Install-HardwareLibrary {
    if (-not (Test-Path -LiteralPath $script:LibraryDirectory)) {
        New-Item -ItemType Directory -Path $script:LibraryDirectory -Force | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($package in $script:PackageDefinitions) {
        $destination = Join-Path $script:LibraryDirectory $package.File
        if (Test-Path -LiteralPath $destination) {
            continue
        }

        $packagePath = Join-Path $env:TEMP ($package.Id + '.' + $package.Version + '.nupkg')
        $packageUrl = 'https://api.nuget.org/v3-flatcontainer/' +
            $package.Id.ToLowerInvariant() + '/' + $package.Version + '/' +
            $package.Id.ToLowerInvariant() + '.' + $package.Version + '.nupkg'

        try {
            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
            $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
            if ($actualHash -ne $package.Sha256) {
                throw ('Не совпала контрольная сумма пакета ' + $package.Id + '.')
            }

            $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
            try {
                $entry = $archive.GetEntry($package.Asset)
                if ($null -eq $entry) {
                    throw ('В пакете отсутствует ожидаемый файл ' + $package.Asset + '.')
                }
                $inputStream = $entry.Open()
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew)
                try {
                    $inputStream.CopyTo($outputStream)
                } finally {
                    $outputStream.Dispose()
                    $inputStream.Dispose()
                }
            } finally {
                $archive.Dispose()
            }
        } finally {
            if (Test-Path -LiteralPath $packagePath) {
                Remove-Item -LiteralPath $packagePath -Force
            }
        }
    }
}

function Import-HardwareLibrary {
    Install-HardwareLibrary
    foreach ($name in @('System.CodeDom.dll', 'HidSharp.dll', 'System.Management.dll', 'LibreHardwareMonitorLib.dll')) {
        [Reflection.Assembly]::LoadFrom((Join-Path $script:LibraryDirectory $name)) | Out-Null
    }
}

try {
    Import-HardwareLibrary
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Не удалось подготовить библиотеку датчиков.`r`n$($_.Exception.Message)`r`n`r`nПроверьте подключение к интернету и доступ на запись в папку приложения.",
        'PC-PersonalControl — ошибка запуска',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$script:Computer = New-Object LibreHardwareMonitor.Hardware.Computer
$script:Computer.IsCpuEnabled = $true
$script:Computer.IsGpuEnabled = $true
$script:Computer.IsMotherboardEnabled = $true
$script:Computer.IsControllerEnabled = $true
$script:Computer.IsMemoryEnabled = $true
$script:LogDirectory = Join-Path $env:LOCALAPPDATA 'FanPilot'
$script:LogPath = Join-Path $script:LogDirectory 'fanpilot.log'
$script:SettingsPath = Join-Path $script:LogDirectory 'settings.json'
$script:BotConfigPath = Join-Path $script:LogDirectory 'telegram.json'
$script:BotWorkerPath = Join-Path $PSScriptRoot 'TelegramBotWorker.ps1'
$script:BotTaskName = 'FanPilot Telegram Bot'
if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
    New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
}
$script:Fans = New-Object System.Collections.ArrayList
$script:Temperatures = New-Object System.Collections.ArrayList
$script:FanSettings = @{}
$script:PowerSettings = @{ Plan = 'Рекомендуемый'; CpuLimit = 100; WolMac = ''; BotWakeMac = '' }
$script:CurveDirty = $false
$script:CurveOwnerId = ''
if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $savedSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($savedSettings.Fans) {
            foreach ($property in $savedSettings.Fans.PSObject.Properties) {
                $script:FanSettings[$property.Name] = $property.Value
            }
        }
        if ($savedSettings.Power) {
            if ($savedSettings.Power.Plan -in @('Рекомендуемый', 'Производительность', 'Экономичный')) {
                $script:PowerSettings.Plan = [string]$savedSettings.Power.Plan
            }
            $savedCpuLimit = 100
            if ([int]::TryParse([string]$savedSettings.Power.CpuLimit, [ref]$savedCpuLimit) -and $savedCpuLimit -ge 50 -and $savedCpuLimit -le 100) {
                $script:PowerSettings.CpuLimit = $savedCpuLimit
            }
            if ([string]$savedSettings.Power.WolMac -match '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
                $script:PowerSettings.WolMac = [string]$savedSettings.Power.WolMac
            }
            if ([string]$savedSettings.Power.BotWakeMac -match '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
                $script:PowerSettings.BotWakeMac = [string]$savedSettings.Power.BotWakeMac
            }
        }
    } catch {
        Add-Content -LiteralPath $script:LogPath -Value ((Get-Date).ToString('HH:mm:ss') + '  Не удалось загрузить настройки: ' + $_.Exception.Message) -Encoding UTF8
    }
}
$script:Busy = $false
$script:UpdatingUi = $false
$script:FormClosing = $false
$script:BotProcess = $null
$script:BotExitReported = $false
$script:LogLines = New-Object System.Collections.ArrayList

$script:Colors = @{
    Background = [Drawing.Color]::FromArgb(17, 20, 28)
    Panel = [Drawing.Color]::FromArgb(26, 31, 42)
    PanelLight = [Drawing.Color]::FromArgb(34, 41, 54)
    Text = [Drawing.Color]::FromArgb(235, 240, 248)
    Muted = [Drawing.Color]::FromArgb(151, 163, 181)
    Accent = [Drawing.Color]::FromArgb(84, 167, 255)
    Green = [Drawing.Color]::FromArgb(62, 201, 146)
    Orange = [Drawing.Color]::FromArgb(255, 177, 66)
    Red = [Drawing.Color]::FromArgb(255, 95, 100)
}

$script:PCPersonalControlVersion = '1.1.0'
$script:LatestReleaseUrl = $null

function Write-AppLog {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('HH:mm:ss')
    [void]$script:LogLines.Add("$timestamp  $Message")
    try {
        Add-Content -LiteralPath $script:LogPath -Value ("$timestamp  $Message") -Encoding UTF8
    } catch {
        if ($null -ne $script:StatusLabel -and -not $script:StatusLabel.IsDisposed) {
            $script:StatusLabel.Text = 'Не удалось записать журнал: ' + $_.Exception.Message
        }
    }
    while ($script:LogLines.Count -gt 80) {
        $script:LogLines.RemoveAt(0)
    }
    if ($null -ne $script:LogBox -and -not $script:LogBox.IsDisposed) {
        $script:LogBox.Lines = [string[]]$script:LogLines.ToArray()
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

function Get-PCPersonalControlLatestRelease {
    $apiUrl = 'https://api.github.com/repos/Shabanov00/fanpilot-web/releases/latest'
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{
            Accept = 'application/vnd.github+json'
            'User-Agent' = 'PC-PersonalControl-Updater'
            'X-GitHub-Api-Version' = '2022-11-28'
        } -TimeoutSec 15 -UseBasicParsing
    } catch {
        $response = $_.Exception.Response
        if ($null -ne $response -and [int]$response.StatusCode -eq 404) {
            return @{ State = 'no-release' }
        }
        throw ('Не удалось проверить обновления GitHub: ' + $_.Exception.Message)
    }

    if ([string]$release.tag_name -notmatch '^v?(?<version>\d+\.\d+\.\d+)$') {
        throw 'У последнего релиза некорректная версия. Используйте тег вида v1.2.3.'
    }

    $releaseUri = $null
    if (-not [Uri]::TryCreate([string]$release.html_url, [UriKind]::Absolute, [ref]$releaseUri) -or
        $releaseUri.Scheme -ne 'https' -or
        $releaseUri.Host -ne 'github.com' -or
        $releaseUri.AbsolutePath -notlike '/Shabanov00/fanpilot-web/releases/tag/*') {
        throw 'GitHub вернул некорректную ссылку на релиз.'
    }

    $latestVersion = [version]$Matches.version
    $currentVersion = [version]$script:PCPersonalControlVersion
    $state = if ($latestVersion -gt $currentVersion) { 'update' } else { 'current' }
    return @{
        State = $state
        Version = $latestVersion.ToString()
        Url = $releaseUri.AbsoluteUri
        HasPackage = @($release.assets | Where-Object {
            $_.name -in @('PC-PersonalControl-project.zip', 'FanPilot-project.zip')
        }).Count -gt 0
    }
}

function Save-AppSettings {
    try {
        $snapshot = @{
            Fans = $script:FanSettings
            Power = $script:PowerSettings
        }
        ConvertTo-Json -InputObject $snapshot -Depth 8 |
            Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch {
        Write-AppLog ('Не удалось сохранить настройки: ' + $_.Exception.Message)
    }
}

function Get-PairingCodeHash {
    param([string]$Code)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Code))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Save-TelegramConfigFile {
    param([object]$Config)
    $temporaryPath = $script:BotConfigPath + '.tmp'
    ConvertTo-Json -InputObject $Config -Depth 4 |
        Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:BotConfigPath -Force
}

function Save-TelegramConfig {
    param([string]$Token)
    if ($Token -notmatch '^\d{5,15}:[A-Za-z0-9_-]{25,}$') {
        throw 'Токен не похож на токен Telegram-бота. Вставьте новый токен из BotFather.'
    }
    if ($script:BotWakeMacBox.Text.Trim() -and
        $script:BotWakeMacBox.Text.Trim() -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
        throw 'MAC-адрес Wake-on-LAN должен иметь формат AA:BB:CC:DD:EE:FF или оставаться пустым.'
    }

    $allowedUserId = ''
    $allowedChatId = ''
    $webAppUrl = ''
    if (Test-Path -LiteralPath $script:BotConfigPath) {
        $existing = Get-Content -LiteralPath $script:BotConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$existing.AllowedUserId -match '^\d{5,15}$' -and
            [string]$existing.AllowedChatId -eq [string]$existing.AllowedUserId) {
            $allowedUserId = [string]$existing.AllowedUserId
            $allowedChatId = [string]$existing.AllowedChatId
        }
        if ([string]$existing.WebAppUrl -match '^https://') {
            $webAppUrl = [string]$existing.WebAppUrl
        }
    }

    $pairingCode = ''
    $pairingHash = ''
    $pairingExpiresUtc = ''
    if (-not $allowedUserId) {
        $randomBytes = New-Object byte[] 5
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $random.GetBytes($randomBytes)
        } finally {
            $random.Dispose()
        }
        $pairingCode = [BitConverter]::ToString($randomBytes).Replace('-', '')
        $pairingHash = Get-PairingCodeHash -Code $pairingCode
        $pairingExpiresUtc = [DateTime]::UtcNow.AddMinutes(10).ToString('o')
    }

    $secureToken = ConvertTo-SecureString -String $Token -AsPlainText -Force
    $config = @{
        Version = 1
        TokenProtected = ConvertFrom-SecureString -SecureString $secureToken
        AllowedUserId = $allowedUserId
        AllowedChatId = $allowedChatId
        PairingCodeHash = $pairingHash
        PairingExpiresUtc = $pairingExpiresUtc
        WakeMac = $script:BotWakeMacBox.Text.Trim()
        WebAppUrl = $webAppUrl
    }
    Save-TelegramConfigFile -Config $config
    $script:PowerSettings.BotWakeMac = $script:BotWakeMacBox.Text.Trim()
    Save-AppSettings
    return $pairingCode
}

function Save-TelegramWakeMac {
    $macAddress = $script:BotWakeMacBox.Text.Trim()
    if ($macAddress -and $macAddress -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
        throw 'MAC-адрес Wake-on-LAN должен иметь формат AA:BB:CC:DD:EE:FF или оставаться пустым.'
    }
    if ($null -ne (Get-BotWorkerProcess)) {
        throw 'Сначала остановите бота, затем сохраните MAC-адрес.'
    }
    if (-not (Test-Path -LiteralPath $script:BotConfigPath)) {
        throw 'Сначала сохраните токен Telegram.'
    }

    $config = Get-Content -LiteralPath $script:BotConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.Version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$config.TokenProtected)) {
        throw 'Файл настроек Telegram повреждён. Сохраните токен заново.'
    }
    $config.WakeMac = $macAddress
    Save-TelegramConfigFile -Config $config
    $script:PowerSettings.BotWakeMac = $macAddress
    Save-AppSettings
}

function Save-TelegramWebAppUrl {
    $url = $script:TelegramWebAppUrlBox.Text.Trim()
    if ($url) {
        $parsedUrl = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsedUrl) -or
            $parsedUrl.Scheme -ne 'https' -or
            -not [string]::IsNullOrEmpty($parsedUrl.UserInfo)) {
            throw 'Для Mini App нужен полный HTTPS-адрес, например https://example.com/pc-personalcontrol/.'
        }
    }
    if ($null -ne (Get-BotWorkerProcess)) {
        throw 'Сначала остановите бота, затем сохраните ссылку Mini App.'
    }
    if (-not (Test-Path -LiteralPath $script:BotConfigPath)) {
        throw 'Сначала сохраните токен Telegram.'
    }

    $config = Get-Content -LiteralPath $script:BotConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.Version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$config.TokenProtected)) {
        throw 'Файл настроек Telegram повреждён. Сохраните токен заново.'
    }
    $config | Add-Member -NotePropertyName WebAppUrl -NotePropertyValue $url -Force
    Save-TelegramConfigFile -Config $config
}

function Get-BotWorkerProcess {
    if (-not (Test-Path -LiteralPath ($script:BotConfigPath + '.pid'))) {
        return $null
    }
    $processId = 0
    $pidText = Get-Content -LiteralPath ($script:BotConfigPath + '.pid') -Raw -ErrorAction SilentlyContinue
    if (-not [int]::TryParse([string]$pidText, [ref]$processId) -or $processId -le 0) {
        return $null
    }
    $process = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $processId) -ErrorAction SilentlyContinue
    if ($null -eq $process -or
        [string]$process.CommandLine -notlike ('*' + [IO.Path]::GetFileName($script:BotWorkerPath) + '*')) {
        return $null
    }
    return Get-Process -Id $processId -ErrorAction SilentlyContinue
}

function Register-BotLogonTask {
    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'Планировщик заданий Windows недоступен; включить автозапуск бота не удалось.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        $script:BotWorkerPath + '" -ConfigPath "' + $script:BotConfigPath + '"'
    $workerDirectory = Split-Path -Parent $script:BotWorkerPath
    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments -WorkingDirectory $workerDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Запускает Telegram-пульт PC-PersonalControl при входе текущего пользователя в Windows.'
    Register-ScheduledTask -TaskName $script:BotTaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
}

function Remove-BotLogonTask {
    $task = Get-ScheduledTask -TaskName $script:BotTaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $script:BotTaskName -Confirm:$false -ErrorAction Stop
    }
}

function Start-BotWorker {
    if (-not (Test-Path -LiteralPath $script:BotWorkerPath)) {
        throw 'Не найден обработчик Telegram. Пересоберите PC-PersonalControl или восстановите TelegramBotWorker.ps1.'
    }
    if (-not (Test-Path -LiteralPath $script:BotConfigPath)) {
        throw 'Сначала сохраните новый токен Telegram в PC-PersonalControl.'
    }
    if ($null -ne (Get-BotWorkerProcess)) {
        Stop-BotWorker
    }
    $script:BotProcess = $null
    $stopPath = $script:BotConfigPath + '.stop'
    if (Test-Path -LiteralPath $stopPath) {
        Remove-Item -LiteralPath $stopPath -Force
    }
    Register-BotLogonTask
    if ($null -eq (Get-BotWorkerProcess)) {
        Start-ScheduledTask -TaskName $script:BotTaskName -ErrorAction Stop
    }
    $script:BotExitReported = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $script:BotProcess = Get-BotWorkerProcess
        if ($null -ne $script:BotProcess) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Бот не запустился. Проверьте журнал %LOCALAPPDATA%\FanPilot\telegram.log и состояние задачи в Планировщике Windows.'
}

function Stop-BotWorker {
    $process = Get-BotWorkerProcess
    if ($null -eq $process -or $process.HasExited) {
        $script:BotProcess = $null
        return
    }
    Set-Content -LiteralPath ($script:BotConfigPath + '.stop') -Value 'stop' -Encoding ASCII
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $process = Get-BotWorkerProcess
        if ($null -eq $process -or $process.HasExited) {
            $script:BotProcess = $null
            Remove-Item -LiteralPath ($script:BotConfigPath + '.stop') -Force -ErrorAction SilentlyContinue
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Бот получил запрос остановки, но ещё завершает текущий запрос Telegram. Повторите проверку через несколько секунд.'
}

function Get-HardwareTree {
    param([object]$Hardware)
    foreach ($item in $Hardware) {
        $item
        if ($item.SubHardware) {
            Get-HardwareTree -Hardware $item.SubHardware
        }
    }
}

if ($RestoreDefaults -and $CloseProcessId -gt 0) {
    try {
        $oldProcess = Get-Process -Id $CloseProcessId -ErrorAction Stop
        if (-not $oldProcess.CloseMainWindow()) {
            throw 'Не удалось штатно закрыть старый экземпляр приложения.'
        }
        if (-not $oldProcess.WaitForExit(5000)) {
            throw 'Старый экземпляр приложения не завершился за 5 секунд; управление вентиляторами не менялось.'
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'PC-PersonalControl — ошибка закрытия',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}

if ($RestoreDefaults) {
    $restoredCount = 0
    $restoreErrors = New-Object System.Collections.ArrayList
    try {
        $script:Computer.Open()
        foreach ($hardware in (Get-HardwareTree -Hardware $script:Computer.Hardware)) {
            $hardware.Update()
            foreach ($sensor in $hardware.Sensors) {
                if ($sensor.SensorType.ToString() -eq 'Control' -and $null -ne $sensor.Control) {
                    try {
                        $sensor.Control.SetDefault()
                        $restoredCount++
                    } catch {
                        [void]$restoreErrors.Add($sensor.Name + ': ' + $_.Exception.Message)
                    }
                }
            }
        }
    } catch {
        [void]$restoreErrors.Add($_.Exception.Message)
    } finally {
        try {
            $script:Computer.Close()
        } catch {
            [void]$restoreErrors.Add('Ошибка закрытия контроллера: ' + $_.Exception.Message)
        }
    }

    if ($restoreErrors.Count -gt 0) {
        $restoreMessage = 'Не удалось восстановить автоматическое управление для всех каналов: ' +
            ($restoreErrors -join '; ')
        Add-Content -LiteralPath $script:LogPath -Value ((Get-Date).ToString('HH:mm:ss') + '  ' + $restoreMessage) -Encoding UTF8
        Write-Error $restoreMessage
        exit 1
    }
    $restoreMessage = "Автоматическое управление возвращено для каналов: $restoredCount."
    Add-Content -LiteralPath $script:LogPath -Value ((Get-Date).ToString('HH:mm:ss') + '  ' + $restoreMessage) -Encoding UTF8
    Write-Output $restoreMessage
    exit 0
}

$createdNew = $false
$script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\FanPilot', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        'PC-PersonalControl уже запущен. Используйте открытое окно, чтобы не управлять одними вентиляторами из двух программ.',
        'PC-PersonalControl уже работает',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}

function Get-FanKey {
    param([object]$Fan)
    if ($Fan.PSObject.Properties['GroupKey']) {
        return [string]$Fan.GroupKey
    }
    return $Fan.Sensor.Identifier.ToString()
}

function Format-RussianCount {
    param(
        [int]$Count,
        [string]$One,
        [string]$Few,
        [string]$Many
    )
    $lastTwo = $Count % 100
    $last = $Count % 10
    if ($lastTwo -ge 11 -and $lastTwo -le 14) {
        $word = $Many
    } elseif ($last -eq 1) {
        $word = $One
    } elseif ($last -ge 2 -and $last -le 4) {
        $word = $Few
    } else {
        $word = $Many
    }
    return "$Count $word"
}

function Get-FanSetting {
    param([object]$Fan)
    $key = Get-FanKey $Fan
    if (-not $script:FanSettings.ContainsKey($key)) {
        $script:FanSettings[$key] = @{
            Profile = 'Тихо'
            TemperatureId = ''
            LastValue = -1.0
            LastMode = ''
            CustomCurve = @(
                @{ Temperature = 30; Speed = 30 },
                @{ Temperature = 40; Speed = 35 },
                @{ Temperature = 55; Speed = 45 },
                @{ Temperature = 65; Speed = 60 },
                @{ Temperature = 75; Speed = 80 },
                @{ Temperature = 82; Speed = 100 }
            )
        }
    }
    return ,$script:FanSettings[$key]
}

function Update-HardwareSnapshot {
    $temperatureList = New-Object System.Collections.ArrayList
    $rawFanList = New-Object System.Collections.ArrayList
    foreach ($hardware in (Get-HardwareTree -Hardware $script:Computer.Hardware)) {
        $hardware.Update()
        foreach ($sensor in $hardware.Sensors) {
            $value = $sensor.Value
            if ($sensor.SensorType.ToString() -eq 'Temperature' -and $null -ne $value) {
                [void]$temperatureList.Add(@{
                    Sensor = $sensor
                    Id = $sensor.Identifier.ToString()
                    HardwareName = $hardware.Name
                    Name = $sensor.Name
                    Label = $hardware.Name + ' — ' + $sensor.Name
                    Value = [double]$value
                })
            }
            if ($sensor.SensorType.ToString() -eq 'Control' -and $null -ne $sensor.Control) {
                $control = $sensor.Control
                if ($control.MaxSoftwareValue -gt $control.MinSoftwareValue) {
                    [void]$rawFanList.Add(@{
                        Sensor = $sensor
                        Hardware = $hardware
                        HardwareName = $hardware.Name
                        Name = $sensor.Name
                        Id = $sensor.Identifier.ToString()
                        Control = $control
                    })
                }
            }
        }
    }

    $script:Temperatures.Clear()
    foreach ($temperature in $temperatureList) {
        [void]$script:Temperatures.Add($temperature)
    }

    $existing = @{}
    foreach ($fan in $script:Fans) {
        $existing[(Get-FanKey $fan)] = $fan
    }

    $groupMap = @{}
    foreach ($channel in $rawFanList) {
        if ($channel.HardwareName -match '(?i)NVIDIA|GeForce|Radeon|AMD') {
            $kind = 'GPU'
            $groupKey = 'GPU:' + $channel.HardwareName
        } elseif ($channel.Name -match '(?i)\bCPU\b|Processor') {
            $kind = 'CPU'
            $groupKey = 'CPU:' + $channel.HardwareName
        } else {
            $kind = 'Case'
            $groupKey = 'CASE:' + $channel.HardwareName
        }

        if (-not $groupMap.ContainsKey($groupKey)) {
            $groupMap[$groupKey] = @{
                GroupKey = $groupKey
                Kind = $kind
                HardwareName = $channel.HardwareName
                Hardware = $channel.Hardware
                Channels = New-Object System.Collections.ArrayList
            }
        }
        [void]$groupMap[$groupKey].Channels.Add($channel)
    }

    $groupList = New-Object System.Collections.ArrayList
    foreach ($group in $groupMap.Values) {
        $channelCount = $group.Channels.Count
        switch ($group.Kind) {
            'GPU' {
                $displayName = 'Видеокарта — ' + (Format-RussianCount $channelCount 'вентилятор' 'вентилятора' 'вентиляторов')
            }
            'CPU' {
                $displayName = 'Вентилятор процессора — ' + (Format-RussianCount $channelCount 'канал' 'канала' 'каналов')
            }
            default {
                $displayName = if ($group.HardwareName -match '(?i)board|motherboard|mainboard|super.?io|gigabyte') {
                    'Вентиляторы корпуса — ' + (Format-RussianCount $channelCount 'канал' 'канала' 'каналов') + ' (разъёмы платы)'
                } else {
                    $group.HardwareName + ' — ' + (Format-RussianCount $channelCount 'канал' 'канала' 'каналов')
                }
            }
        }
        $representative = $group.Channels[0]
        $fanGroup = @{
            GroupKey = $group.GroupKey
            Kind = $group.Kind
            HardwareName = $group.HardwareName
            Hardware = $group.Hardware
            Name = $displayName
            Channels = $group.Channels.ToArray()
            Sensor = $representative.Sensor
            Control = $representative.Control
        }
        $key = [string]$fanGroup.GroupKey
        $fanSetting = Get-FanSetting ([pscustomobject]$fanGroup)
        if ($existing.ContainsKey($key)) {
            $fanSetting.LastValue = $existing[$key].Setting.LastValue
            $fanSetting.LastMode = $existing[$key].Setting.LastMode
        }
        $fanGroup.Setting = $fanSetting
        [void]$groupList.Add([pscustomobject]$fanGroup)
    }

    $script:Fans.Clear()
    foreach ($fan in ($groupList | Sort-Object { switch ($_.Kind) { 'GPU' { 0 } 'CPU' { 1 } default { 2 } } }, Name)) {
        [void]$script:Fans.Add($fan)
    }
}

function Get-FanGroupSpeed {
    param([object]$Fan)
    $values = @($Fan.Channels | Where-Object { $null -ne $_.Sensor.Value } | ForEach-Object { [double]$_.Sensor.Value })
    if ($values.Count -eq 0) {
        return '—'
    }
    return ([Math]::Round(($values | Measure-Object -Average).Average)).ToString() + '%'
}

function Find-Temperature {
    param([object]$Fan)
    if ($script:Temperatures.Count -eq 0) {
        return $null
    }

    $setting = Get-FanSetting $Fan
    if ($setting.TemperatureId) {
        $chosen = $script:Temperatures | Where-Object { $_.Id -eq $setting.TemperatureId } | Select-Object -First 1
        if ($null -ne $chosen) {
            return $chosen
        }
    }

    $sameHardware = @($script:Temperatures | Where-Object { $_.HardwareName -eq $Fan.HardwareName })
    $pool = if ($sameHardware.Count -gt 0) { $sameHardware } else { @($script:Temperatures) }
    switch ($Fan.Kind) {
        'GPU' {
            $preferred = $pool | Where-Object { $_.Name -match 'GPU|Core|Hot.?Spot|Junction|Memory' } | Sort-Object Value -Descending | Select-Object -First 1
        }
        'CPU' {
            $preferred = $script:Temperatures | Where-Object {
                $_.HardwareName -match '(?i)CPU|Intel|AMD|Ryzen' -and $_.Name -match 'Package|Tctl|Tdie|Core'
            } | Sort-Object Value -Descending | Select-Object -First 1
        }
        default {
            $preferred = $script:Temperatures | Where-Object {
                $_.Name -match '(?i)Motherboard|Mainboard|System|VRM|Chipset' -and
                    $_.HardwareName -notmatch '(?i)NVIDIA|GeForce|Radeon'
            } | Sort-Object Value -Descending | Select-Object -First 1
        }
    }
    if ($null -eq $preferred) {
        $preferred = if ($Fan.Kind -eq 'Case') {
            $script:Temperatures | Where-Object { $_.HardwareName -notmatch '(?i)NVIDIA|GeForce|Radeon' } |
                Sort-Object Value -Descending | Select-Object -First 1
        } else {
            $pool | Sort-Object Value -Descending | Select-Object -First 1
        }
    }
    if ($null -eq $preferred) {
        $preferred = $pool | Sort-Object Value -Descending | Select-Object -First 1
    }
    $setting.TemperatureId = $preferred.Id
    return $preferred
}

function Get-ProfileCurve {
    param([string]$FanProfile, [object]$Fan)
    if ($FanProfile -eq 'Своя кривая') {
        return (Get-FanSetting $Fan).CustomCurve
    }
    if ($FanProfile -eq 'Игры') {
        return @(
            @{ Temperature = 30; Speed = 35 },
            @{ Temperature = 40; Speed = 45 },
            @{ Temperature = 50; Speed = 60 },
            @{ Temperature = 60; Speed = 75 },
            @{ Temperature = 70; Speed = 90 },
            @{ Temperature = 80; Speed = 100 }
        )
    }
    return @(
        @{ Temperature = 30; Speed = 30 },
        @{ Temperature = 40; Speed = 32 },
        @{ Temperature = 55; Speed = 42 },
        @{ Temperature = 65; Speed = 58 },
        @{ Temperature = 75; Speed = 80 },
        @{ Temperature = 82; Speed = 100 }
    )
}

function Set-PowerPlan {
    param([string]$Plan)
    $plans = @{
        'Рекомендуемый' = '381b4222-f694-41f0-9685-ff5bb260df2e'
        'Производительность' = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        'Экономичный' = 'a1841308-3541-4fab-bc81-f71556f20b4a'
    }
    if (-not $plans.ContainsKey($Plan)) {
        throw 'Выберите системный профиль питания.'
    }
    $process = Start-Process -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $plans[$Plan]) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "Windows не смогла активировать план «$Plan» (код $($process.ExitCode))."
    }
    return $plans[$Plan]
}

function Set-CpuLimit {
    param([int]$Percent)
    if ($Percent -lt 50 -or $Percent -gt 100) {
        throw 'Ограничение процессора должно быть от 50 до 100%.'
    }
    $active = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $active -notmatch '([0-9a-fA-F-]{36})') {
        throw 'Не удалось определить активный план питания Windows.'
    }
    $guid = $Matches[1]
    $process = Start-Process -FilePath 'powercfg.exe' -ArgumentList @('/setacvalueindex', $guid, 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', $Percent.ToString()) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "Windows не смогла сохранить ограничение процессора (код $($process.ExitCode))."
    }
    $process = Start-Process -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $guid) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "Windows не смогла применить ограничение процессора (код $($process.ExitCode))."
    }
}

function Send-WakePacket {
    param([string]$MacAddress)
    if ($MacAddress -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
        throw 'Введите MAC-адрес в формате AA:BB:CC:DD:EE:FF.'
    }

    $macBytes = [byte[]]@($MacAddress -split '[:-]' | ForEach-Object { [Convert]::ToByte($_, 16) })
    $packet = New-Object byte[] 102
    for ($index = 0; $index -lt 6; $index++) {
        $packet[$index] = 0xFF
    }
    for ($repeat = 0; $repeat -lt 16; $repeat++) {
        [Array]::Copy($macBytes, 0, $packet, 6 + ($repeat * 6), 6)
    }

    $udp = New-Object Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        $destination = New-Object Net.IPEndPoint([Net.IPAddress]::Broadcast, 9)
        $sent = $udp.Send($packet, $packet.Length, $destination)
        if ($sent -ne $packet.Length) {
            throw 'Не удалось отправить полный Wake-on-LAN пакет.'
        }
    } finally {
        $udp.Dispose()
    }
}

function Get-RequestedSpeed {
    param([string]$FanProfile, [object]$Fan, [double]$Temperature)
    if ($FanProfile -eq 'Максимум') {
        return 100.0
    }

    $curve = @(Get-ProfileCurve -FanProfile $FanProfile -Fan $Fan | Sort-Object { [double]$_.Temperature })
    if ($curve.Count -lt 2) {
        throw 'Для кривой вентилятора нужны как минимум две точки.'
    }
    if ($Temperature -le $curve[0].Temperature) {
        $speed = [double]$curve[0].Speed
    } elseif ($Temperature -ge $curve[-1].Temperature) {
        $speed = [double]$curve[-1].Speed
    } else {
        $speed = [double]$curve[-1].Speed
        for ($index = 1; $index -lt $curve.Count; $index++) {
            if ($Temperature -le $curve[$index].Temperature) {
                $left = $curve[$index - 1]
                $right = $curve[$index]
                $fraction = ($Temperature - $left.Temperature) / ($right.Temperature - $left.Temperature)
                $speed = $left.Speed + (($right.Speed - $left.Speed) * $fraction)
                break
            }
        }
    }

    if ($Temperature -ge 85) {
        $speed = 100
    } elseif ($Temperature -ge 80) {
        $speed = [Math]::Max($speed, 80)
    }
    return [Math]::Min(100, [Math]::Max(30, $speed))
}

function Restore-FanDefault {
    param([object]$Fan)
    $channels = if ($Fan.Channels) { @($Fan.Channels) } else { @($Fan) }
    $failures = New-Object System.Collections.ArrayList
    foreach ($channel in $channels) {
        try {
            $channel.Control.SetDefault()
        } catch {
            [void]$failures.Add($channel.Name + ': ' + $_.Exception.Message)
        }
    }
    $setting = Get-FanSetting $Fan
    $setting.LastValue = -1.0
    $setting.LastMode = 'Авто'
    if ($failures.Count -eq 0) {
        Write-AppLog ('Возвращено управление BIOS: ' + $Fan.Name + ' (' + $channels.Count + ' каналов)')
    } else {
        Write-AppLog ('Не удалось вернуть автоматический режим для ' + $Fan.Name + ': ' + ($failures -join '; '))
    }
}

function Set-FanMode {
    param(
        [object]$Fan,
        [string]$FanProfile,
        [switch]$Force
    )
    $setting = Get-FanSetting $Fan
    if ($FanProfile -eq 'Авто') {
        if ($setting.LastMode -ne 'Авто' -or $Force) {
            Restore-FanDefault $Fan
        }
        $setting.Profile = 'Авто'
        return
    }

    if ($FanProfile -ne 'Максимум') {
        $temperature = Find-Temperature $Fan
        if ($null -eq $temperature) {
            Restore-FanDefault $Fan
            throw ('Нет доступного датчика температуры для вентилятора ' + $Fan.Name + '. Оставлен режим BIOS.')
        }
    } else {
        $temperature = $null
    }

    $currentTemperature = if ($null -ne $temperature) { [double]$temperature.Value } else { 0.0 }
    $requestedSpeed = Get-RequestedSpeed -FanProfile $FanProfile -Fan $Fan -Temperature $currentTemperature
    $channels = if ($Fan.Channels) { @($Fan.Channels) } else { @($Fan) }
    $appliedChannels = New-Object System.Collections.ArrayList
    try {
        foreach ($channel in $channels) {
            $minimum = [double]$channel.Control.MinSoftwareValue
            $maximum = [double]$channel.Control.MaxSoftwareValue
            if ($maximum -le $minimum) {
                throw ('Контроллер не сообщил допустимый диапазон для ' + $channel.Name + '.')
            }

            $safeMinimum = [Math]::Max(30.0, $minimum)
            $speed = [Math]::Min($maximum, [Math]::Max($safeMinimum, $requestedSpeed))
            $channelSetting = Get-FanSetting $Fan
            if ($Force -or $channelSetting.LastMode -ne $FanProfile -or [Math]::Abs($channelSetting.LastValue - $speed) -ge 1.0) {
                $channel.Control.SetSoftware([single]$speed)
            }
            [void]$appliedChannels.Add($channel)
        }
    } catch {
        foreach ($channel in $channels) {
            try {
                $channel.Control.SetDefault()
            } catch {
                Write-AppLog ('Ошибка возврата канала ' + $channel.Name + ' в BIOS: ' + $_.Exception.Message)
            }
        }
        $setting.Profile = 'Авто'
        $setting.LastMode = 'Авто'
        $setting.LastValue = -1.0
        throw ('Не удалось синхронно настроить группу «' + $Fan.Name + '»: ' + $_.Exception.Message + ' Все каналы возвращены автоматике BIOS.')
    }
    $setting.LastValue = $requestedSpeed
    $setting.LastMode = $FanProfile
    $setting.Profile = $FanProfile
}

function Set-AllFans {
    param([string]$FanProfile)
    if ($FanProfile -notin @('Тихо', 'Игры', 'Максимум', 'Авто')) {
        $script:StatusLabel.Text = 'Неизвестный профиль; настройки вентиляторов не изменены'
        Write-AppLog ('Отклонён некорректный профиль: "' + $FanProfile + '"')
        return
    }
    if ($script:Fans.Count -eq 0) {
        Write-AppLog 'Контроллеры вентилятора с программным управлением не обнаружены.'
        $script:StatusLabel.Text = 'Совместимых контроллеров вентиляторов не найдено'
        return
    }

    $appliedCount = 0
    $failureCount = 0
    foreach ($fan in $script:Fans) {
        try {
            Set-FanMode -Fan $fan -FanProfile $FanProfile -Force
            $appliedCount++
        } catch {
            $failureCount++
            Write-AppLog $_.Exception.Message
        }
    }
    $script:StatusLabel.Text = "Профиль «$FanProfile»: успешно $appliedCount, ошибок $failureCount."
    Write-AppLog $script:StatusLabel.Text
    Save-AppSettings
    Update-Ui
}

function Set-SelectedFan {
    if ($script:FanList.SelectedIndex -lt 0 -or $script:FanList.SelectedIndex -ge $script:Fans.Count) {
        return
    }
    $fan = $script:Fans[$script:FanList.SelectedIndex]
    $selectedProfile = [string]$script:ProfileBox.SelectedItem
    if (-not $selectedProfile) {
        return
    }
    try {
        Set-FanMode -Fan $fan -FanProfile $selectedProfile -Force
        $script:StatusLabel.Text = 'Профиль «' + $selectedProfile + '» применён к группе «' + $fan.Name + '»'
        Write-AppLog ('Профиль «' + $selectedProfile + '» применён к группе ' + $fan.Name)
        Save-AppSettings
    } catch {
        $script:StatusLabel.Text = $_.Exception.Message
        Write-AppLog $_.Exception.Message
    }
    Update-Ui
}

function Update-Ui {
    if ($script:UpdatingUi -or $null -eq $script:FanList) {
        return
    }
    $script:UpdatingUi = $true
    try {
        $selectedId = $null
        if ($script:FanList.SelectedIndex -ge 0 -and $script:FanList.SelectedIndex -lt $script:Fans.Count) {
            $selectedId = Get-FanKey $script:Fans[$script:FanList.SelectedIndex]
        }

        $script:FanList.Items.Clear()
        $selectedIndex = -1
        for ($index = 0; $index -lt $script:Fans.Count; $index++) {
            $fan = $script:Fans[$index]
            $key = Get-FanKey $fan
            $current = Get-FanGroupSpeed $fan
            $script:FanList.Items.Add($fan.Name + '    ' + $current) | Out-Null
            if ($key -eq $selectedId) {
                $selectedIndex = $index
            }
        }
        if ($selectedIndex -ge 0) {
            $script:FanList.SelectedIndex = $selectedIndex
        } elseif ($script:Fans.Count -gt 0) {
            $script:FanList.SelectedIndex = 0
        }

        $script:TemperatureList.Items.Clear()
        foreach ($temperature in ($script:Temperatures | Sort-Object Value -Descending)) {
            $script:TemperatureList.Items.Add(
                ('{0}  {1:N0} °C' -f $temperature.Label, $temperature.Value)
            ) | Out-Null
        }
        $gpuGroups = @($script:Fans | Where-Object { $_.Kind -eq 'GPU' })
        $cpuGroups = @($script:Fans | Where-Object { $_.Kind -eq 'CPU' })
        $caseGroups = @($script:Fans | Where-Object { $_.Kind -eq 'Case' })
        $gpuCount = if ($gpuGroups.Count -gt 0) { (@($gpuGroups | ForEach-Object { $_.Channels.Count }) | Measure-Object -Sum).Sum } else { 0 }
        $cpuCount = if ($cpuGroups.Count -gt 0) { (@($cpuGroups | ForEach-Object { $_.Channels.Count }) | Measure-Object -Sum).Sum } else { 0 }
        $caseCount = if ($caseGroups.Count -gt 0) { (@($caseGroups | ForEach-Object { $_.Channels.Count }) | Measure-Object -Sum).Sum } else { 0 }
        $gpuStatus = if ($gpuCount -gt 0) { 'Видеокарта: ' + (Format-RussianCount $gpuCount 'канал, общий профиль' 'канала, общий профиль' 'каналов, общий профиль') } else { 'Видеокарта: нет программных каналов' }
        $cpuStatus = if ($cpuCount -gt 0) { 'Вентилятор процессора: ' + (Format-RussianCount $cpuCount 'отдельный канал' 'отдельных канала' 'отдельных каналов') } else { 'Вентилятор процессора: управление BIOS' }
        $caseStatus = if ($caseCount -gt 0) { 'Вентиляторы корпуса: ' + (Format-RussianCount $caseCount 'отдельный канал' 'отдельных канала' 'отдельных каналов') } else { 'Вентиляторы корпуса: управление BIOS' }
        $script:FanCountLabel.Text = "$gpuStatus`r`n$cpuStatus`r`n$caseStatus"
        $script:TemperatureCountLabel.Text = $script:Temperatures.Count.ToString() + ' датчиков'
        if ($script:Fans.Count -eq 0) {
            $script:SelectedFanLabel.Text = 'Нет доступных каналов управления'
            $script:TemperatureBox.Items.Clear()
            $script:ProfileBox.SelectedIndex = -1
            $script:CurveGrid.Rows.Clear()
        }
    } finally {
        $script:UpdatingUi = $false
    }
    Update-SelectedFanPanel
}

function Update-SelectedFanPanel {
    if ($script:UpdatingUi -or $script:FanList.SelectedIndex -lt 0 -or $script:FanList.SelectedIndex -ge $script:Fans.Count) {
        return
    }
    $script:UpdatingUi = $true
    try {
        $fan = $script:Fans[$script:FanList.SelectedIndex]
        $fanKey = Get-FanKey $fan
        if ($script:CurveGrid.IsCurrentCellInEditMode) {
            $script:CurveDirty = $true
        }
        if ($script:CurveDirty -and $script:CurveOwnerId -and $script:CurveOwnerId -ne $fanKey) {
            $previousFan = $script:Fans | Where-Object { (Get-FanKey $_) -eq $script:CurveOwnerId } | Select-Object -First 1
            $answer = [System.Windows.Forms.MessageBox]::Show(
                'Сохранить изменённую кривую вентилятора перед переключением?',
                'Несохранённая кривая',
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) {
                $previousIndex = -1
                for ($index = 0; $index -lt $script:Fans.Count; $index++) {
                    if ((Get-FanKey $script:Fans[$index]) -eq $script:CurveOwnerId) {
                        $previousIndex = $index
                        break
                    }
                }
                if ($previousIndex -ge 0) {
                    $script:FanList.SelectedIndex = $previousIndex
                }
                return
            }
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes -and -not (Save-CustomCurve -Fan $previousFan)) {
                $previousIndex = -1
                for ($index = 0; $index -lt $script:Fans.Count; $index++) {
                    if ((Get-FanKey $script:Fans[$index]) -eq $script:CurveOwnerId) {
                        $previousIndex = $index
                        break
                    }
                }
                if ($previousIndex -ge 0) {
                    $script:FanList.SelectedIndex = $previousIndex
                }
                return
            }
            if ($answer -eq [System.Windows.Forms.DialogResult]::No) {
                $script:CurveDirty = $false
            }
        }
        $script:CurveOwnerId = $fanKey
        $setting = Get-FanSetting $fan
        $script:SelectedFanLabel.Text = $fan.Name
        $channelRanges = @($fan.Channels | ForEach-Object {
            [Math]::Round([double]$_.Control.MinSoftwareValue).ToString() + '–' +
                [Math]::Round([double]$_.Control.MaxSoftwareValue).ToString() + '%'
        } | Select-Object -Unique)
        $script:SelectedFanRangeLabel.Text = 'Каналов: ' + $fan.Channels.Count + '; диапазон каждого: ' + ($channelRanges -join ', ')

        $script:TemperatureBox.Items.Clear()
        $selectedTemperatureIndex = -1
        for ($index = 0; $index -lt $script:Temperatures.Count; $index++) {
            $temperature = $script:Temperatures[$index]
            [void]$script:TemperatureBox.Items.Add($temperature.Label)
            if ($temperature.Id -eq $setting.TemperatureId) {
                $selectedTemperatureIndex = $index
            }
        }
        if ($selectedTemperatureIndex -ge 0) {
            $script:TemperatureBox.SelectedIndex = $selectedTemperatureIndex
        } elseif ($script:TemperatureBox.Items.Count -gt 0) {
            $script:TemperatureBox.SelectedIndex = 0
        }
        $profileIndex = $script:ProfileBox.Items.IndexOf($setting.Profile)
        if ($profileIndex -ge 0) {
            $script:ProfileBox.SelectedIndex = $profileIndex
        } else {
            $script:ProfileBox.SelectedIndex = 0
        }

        if (-not $script:CurveDirty) {
            $script:CurveGrid.Rows.Clear()
            foreach ($point in $setting.CustomCurve) {
                [void]$script:CurveGrid.Rows.Add([string]$point.Temperature, [string]$point.Speed)
            }
        }
    } finally {
        $script:UpdatingUi = $false
    }
}

function Save-CustomCurve {
    param([object]$Fan)
    if ($null -eq $Fan) {
        if ($script:FanList.SelectedIndex -lt 0 -or $script:FanList.SelectedIndex -ge $script:Fans.Count) {
            return $false
        }
        $Fan = $script:Fans[$script:FanList.SelectedIndex]
    }
    if ($null -eq $Fan) {
        return $false
    }
    try {
        $script:CurveGrid.EndEdit()
        $points = New-Object System.Collections.ArrayList
        foreach ($row in $script:CurveGrid.Rows) {
            if ($row.IsNewRow) {
                continue
            }
            $temperature = 0.0
            $speed = 0.0
            if (-not [double]::TryParse([string]$row.Cells[0].Value, [ref]$temperature) -or
                -not [double]::TryParse([string]$row.Cells[1].Value, [ref]$speed)) {
                throw 'В каждой точке укажите числовые температуру и скорость.'
            }
            if ($temperature -lt 0 -or $temperature -gt 120 -or $speed -lt 30 -or $speed -gt 100) {
                throw 'Температура должна быть от 0 до 120 °C, скорость — от 30 до 100%.'
            }
            [void]$points.Add(@{ Temperature = $temperature; Speed = $speed })
        }
        if ($points.Count -lt 2) {
            throw 'Добавьте минимум две точки кривой.'
        }
        $ordered = @($points | Sort-Object { [double]$_.Temperature })
        for ($index = 1; $index -lt $ordered.Count; $index++) {
            if ($ordered[$index].Temperature -le $ordered[$index - 1].Temperature) {
                throw 'Температуры точек должны различаться.'
            }
        }
        (Get-FanSetting $Fan).CustomCurve = $ordered
        $script:CurveDirty = $false
        Write-AppLog ('Сохранена пользовательская кривая для ' + $Fan.Name)
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Проверьте кривую',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PC-PersonalControl — управление охлаждением'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1120, 790)
$form.MinimumSize = New-Object Drawing.Size(1000, 700)
$form.BackColor = $script:Colors.Background
$form.ForeColor = $script:Colors.Text
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$script:MainForm = $form

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 82
$header.BackColor = $script:Colors.Panel
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'PC-PersonalControl'
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 20)
$title.ForeColor = $script:Colors.Text
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(24, 12)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Профили охлаждения для доступных каналов вентиляторов'
$subtitle.ForeColor = $script:Colors.Muted
$subtitle.AutoSize = $true
$subtitle.Location = New-Object Drawing.Point(27, 50)
$header.Controls.Add($subtitle)

$adminBadge = New-Object System.Windows.Forms.Label
$adminBadge.Text = 'ЗАПУЩЕНО ОТ АДМИНИСТРАТОРА'
$adminBadge.ForeColor = $script:Colors.Green
$adminBadge.AutoSize = $true
$adminBadge.Anchor = 'Top,Right'
$adminBadge.Location = New-Object Drawing.Point(815, 30)
$header.Controls.Add($adminBadge)

$quickPanel = New-Object System.Windows.Forms.Panel
$quickPanel.Dock = 'Top'
$quickPanel.Height = 82
$quickPanel.Padding = New-Object System.Windows.Forms.Padding(20, 12, 20, 8)
$quickPanel.BackColor = $script:Colors.Background
$form.Controls.Add($quickPanel)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = 'Подключение к датчикам оборудования…'
$script:StatusLabel.ForeColor = $script:Colors.Muted
$script:StatusLabel.AutoSize = $true
$script:StatusLabel.Location = New-Object Drawing.Point(24, 60)
$quickPanel.Controls.Add($script:StatusLabel)

$buttonDefinitions = @(
    @{ Text = 'Тихо'; Profile = 'Тихо'; Color = $script:Colors.Green; Width = 125 },
    @{ Text = 'Игры'; Profile = 'Игры'; Color = $script:Colors.Accent; Width = 125 },
    @{ Text = 'Максимальный обдув'; Profile = 'Максимум'; Color = $script:Colors.Orange; Width = 190 },
    @{ Text = 'Авто BIOS'; Profile = 'Авто'; Color = $script:Colors.PanelLight; Width = 125 }
)
$buttonX = 20
foreach ($definition in $buttonDefinitions) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $definition.Text
    $clickProfile = [string]$definition.Profile
    $button.Location = New-Object Drawing.Point($buttonX, 10)
    $button.Size = New-Object Drawing.Size($definition.Width, 38)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $definition.Color
    $button.ForeColor = if ($definition.Profile -eq 'Авто') { $script:Colors.Text } else { [Drawing.Color]::FromArgb(15, 20, 28) }
    $button.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
    $button.Add_Click(({
        Set-AllFans -FanProfile $clickProfile
    }.GetNewClosure()))
    $quickPanel.Controls.Add($button)
    $buttonX += $definition.Width + 10
}

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.SplitterDistance = 355
$split.SplitterWidth = 6
$split.BackColor = $script:Colors.Background
$split.Panel1.Padding = New-Object System.Windows.Forms.Padding(18, 4, 8, 12)
$split.Panel2.Padding = New-Object System.Windows.Forms.Padding(8, 4, 18, 12)
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object System.Drawing.Point(18, 7)
$fanPage = New-Object System.Windows.Forms.TabPage
$fanPage.Text = 'Охлаждение'
$fanPage.BackColor = $script:Colors.Background
$powerPage = New-Object System.Windows.Forms.TabPage
$powerPage.Text = 'Питание и пробуждение'
$powerPage.BackColor = $script:Colors.Background
[void]$tabs.TabPages.Add($fanPage)
[void]$tabs.TabPages.Add($powerPage)
$form.Controls.Add($tabs)
$fanPage.Controls.Add($split)

$powerPanel = New-Object System.Windows.Forms.Panel
$powerPanel.Dock = 'Fill'
$powerPanel.AutoScroll = $true
$powerPanel.Padding = New-Object System.Windows.Forms.Padding(36, 24, 36, 24)
$powerPage.Controls.Add($powerPanel)

$powerTitle = New-Object System.Windows.Forms.Label
$powerTitle.Text = 'ПИТАНИЕ И УДАЛЁННОЕ ПРОБУЖДЕНИЕ'
$powerTitle.Location = New-Object Drawing.Point(24, 18)
$powerTitle.Size = New-Object Drawing.Size(760, 32)
$powerTitle.ForeColor = $script:Colors.Text
$powerTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
$powerPanel.Controls.Add($powerTitle)

$powerDescription = New-Object System.Windows.Forms.Label
$powerDescription.Text = 'Здесь можно изменить план питания Windows и отправить Wake-on-LAN пакет в локальной сети. Приложение должно работать на включённом компьютере-отправителе. Температурные лимиты остаются под защитой BIOS и драйвера видеокарты.'
$powerDescription.Location = New-Object Drawing.Point(26, 57)
$powerDescription.Size = New-Object Drawing.Size(900, 48)
$powerDescription.ForeColor = $script:Colors.Muted
$powerPanel.Controls.Add($powerDescription)

$systemPowerHeading = New-Object System.Windows.Forms.Label
$systemPowerHeading.Text = 'ПЛАН ПИТАНИЯ WINDOWS'
$systemPowerHeading.Location = New-Object Drawing.Point(26, 120)
$systemPowerHeading.Size = New-Object Drawing.Size(600, 25)
$systemPowerHeading.ForeColor = $script:Colors.Accent
$systemPowerHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
$powerPanel.Controls.Add($systemPowerHeading)

$planDescription = New-Object System.Windows.Forms.Label
$planDescription.Text = 'Выбор режима меняет только встроенный профиль электропитания Windows.'
$planDescription.Location = New-Object Drawing.Point(26, 150)
$planDescription.Size = New-Object Drawing.Size(700, 24)
$planDescription.ForeColor = $script:Colors.Muted
$powerPanel.Controls.Add($planDescription)

$script:PowerPlanBox = New-Object System.Windows.Forms.ComboBox
$script:PowerPlanBox.DropDownStyle = 'DropDownList'
$script:PowerPlanBox.Location = New-Object Drawing.Point(28, 183)
$script:PowerPlanBox.Size = New-Object Drawing.Size(250, 32)
$script:PowerPlanBox.BackColor = $script:Colors.Panel
$script:PowerPlanBox.ForeColor = $script:Colors.Text
$script:PowerPlanBox.FlatStyle = 'Flat'
[void]$script:PowerPlanBox.Items.AddRange([string[]]@('Рекомендуемый', 'Производительность', 'Экономичный'))
$script:PowerPlanBox.SelectedIndex = $script:PowerPlanBox.Items.IndexOf($script:PowerSettings.Plan)
$powerPanel.Controls.Add($script:PowerPlanBox)

$cpuLimitHeading = New-Object System.Windows.Forms.Label
$cpuLimitHeading.Text = 'Максимальное состояние процессора при питании от сети'
$cpuLimitHeading.Location = New-Object Drawing.Point(28, 233)
$cpuLimitHeading.Size = New-Object Drawing.Size(680, 25)
$cpuLimitHeading.ForeColor = $script:Colors.Text
$powerPanel.Controls.Add($cpuLimitHeading)

$script:CpuLimitTrack = New-Object System.Windows.Forms.TrackBar
$script:CpuLimitTrack.Minimum = 50
$script:CpuLimitTrack.Maximum = 100
$script:CpuLimitTrack.TickFrequency = 10
$script:CpuLimitTrack.SmallChange = 1
$script:CpuLimitTrack.LargeChange = 5
$script:CpuLimitTrack.Value = $script:PowerSettings.CpuLimit
$script:CpuLimitTrack.Location = New-Object Drawing.Point(22, 258)
$script:CpuLimitTrack.Size = New-Object Drawing.Size(420, 48)
$powerPanel.Controls.Add($script:CpuLimitTrack)

$script:CpuLimitLabel = New-Object System.Windows.Forms.Label
$script:CpuLimitLabel.Text = '100% (максимальная производительность)'
$script:CpuLimitLabel.Location = New-Object Drawing.Point(452, 270)
$script:CpuLimitLabel.Size = New-Object Drawing.Size(350, 25)
$script:CpuLimitLabel.ForeColor = $script:Colors.Orange
$powerPanel.Controls.Add($script:CpuLimitLabel)
$script:CpuLimitTrack.Add_ValueChanged({
    if ($script:CpuLimitTrack.Value -eq 100) {
        $script:CpuLimitLabel.Text = '100% (без ограничения)'
    } else {
        $script:CpuLimitLabel.Text = $script:CpuLimitTrack.Value.ToString() + '% (может снизить производительность)'
    }
})

$powerApplyButton = New-Object System.Windows.Forms.Button
$powerApplyButton.Text = 'Применить настройки питания'
$powerApplyButton.Location = New-Object Drawing.Point(28, 318)
$powerApplyButton.Size = New-Object Drawing.Size(250, 40)
$powerApplyButton.FlatStyle = 'Flat'
$powerApplyButton.FlatAppearance.BorderSize = 0
$powerApplyButton.BackColor = $script:Colors.Accent
$powerApplyButton.ForeColor = [Drawing.Color]::FromArgb(15, 20, 28)
$powerApplyButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$powerApplyButton.Add_Click({
    try {
        $plan = [string]$script:PowerPlanBox.SelectedItem
        $null = Set-PowerPlan -Plan $plan
        Set-CpuLimit -Percent $script:CpuLimitTrack.Value
        $script:PowerSettings.Plan = $plan
        $script:PowerSettings.CpuLimit = $script:CpuLimitTrack.Value
        $script:PowerSettings.WolMac = $script:WolMacBox.Text.Trim()
        Save-AppSettings
        $script:StatusLabel.Text = "План «$plan» и ограничение процессора $($script:CpuLimitTrack.Value)% применены."
        Write-AppLog ($script:StatusLabel.Text)
    } catch {
        $script:StatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка настроек питания: ' + $_.Exception.Message)
    }
})
$powerPanel.Controls.Add($powerApplyButton)

$temperatureSafety = New-Object System.Windows.Forms.Label
$temperatureSafety.Text = 'Важно: в Windows нельзя безопасно задавать целевую температуру CPU/GPU. Температура наблюдается датчиками; её регулируют вентиляторные кривые, а предельные значения защищает прошивка устройства. Снижение лимита CPU может уменьшить нагрев, но и производительность.'
$temperatureSafety.Location = New-Object Drawing.Point(28, 373)
$temperatureSafety.Size = New-Object Drawing.Size(900, 58)
$temperatureSafety.ForeColor = $script:Colors.Orange
$powerPanel.Controls.Add($temperatureSafety)

$wolHeading = New-Object System.Windows.Forms.Label
$wolHeading.Text = 'WAKE-ON-LAN — ВКЛЮЧЕНИЕ ПО СЕТИ'
$wolHeading.Location = New-Object Drawing.Point(28, 456)
$wolHeading.Size = New-Object Drawing.Size(620, 26)
$wolHeading.ForeColor = $script:Colors.Accent
$wolHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
$powerPanel.Controls.Add($wolHeading)

$wolHelp = New-Object System.Windows.Forms.Label
$wolHelp.Text = 'Укажите MAC-адрес другого, выключенного компьютера. Нужны поддержка Wake-on-LAN в BIOS/адаптере и соединение с той же локальной сетью. Чтобы разбудить этот ПК телефоном, пакет должен отправить роутер или постоянно включённое устройство; RE220 не заменяет их.'
$wolHelp.Location = New-Object Drawing.Point(28, 487)
$wolHelp.Size = New-Object Drawing.Size(900, 48)
$wolHelp.ForeColor = $script:Colors.Muted
$powerPanel.Controls.Add($wolHelp)

$wolMacLabel = New-Object System.Windows.Forms.Label
$wolMacLabel.Text = 'MAC-адрес компьютера'
$wolMacLabel.Location = New-Object Drawing.Point(28, 548)
$wolMacLabel.Size = New-Object Drawing.Size(240, 22)
$wolMacLabel.ForeColor = $script:Colors.Text
$powerPanel.Controls.Add($wolMacLabel)

$script:WolMacBox = New-Object System.Windows.Forms.TextBox
$script:WolMacBox.Location = New-Object Drawing.Point(28, 574)
$script:WolMacBox.Size = New-Object Drawing.Size(250, 30)
$script:WolMacBox.BackColor = $script:Colors.Panel
$script:WolMacBox.ForeColor = $script:Colors.Text
$script:WolMacBox.BorderStyle = 'FixedSingle'
$script:WolMacBox.Text = $script:PowerSettings.WolMac
$powerPanel.Controls.Add($script:WolMacBox)

$wakeButton = New-Object System.Windows.Forms.Button
$wakeButton.Text = 'Отправить пакет пробуждения'
$wakeButton.Location = New-Object Drawing.Point(294, 571)
$wakeButton.Size = New-Object Drawing.Size(260, 36)
$wakeButton.FlatStyle = 'Flat'
$wakeButton.FlatAppearance.BorderSize = 0
$wakeButton.BackColor = $script:Colors.Green
$wakeButton.ForeColor = [Drawing.Color]::FromArgb(15, 20, 28)
$wakeButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$wakeButton.Add_Click({
    try {
        Send-WakePacket -MacAddress $script:WolMacBox.Text.Trim()
        $script:PowerSettings.WolMac = $script:WolMacBox.Text.Trim()
        Save-AppSettings
        $script:StatusLabel.Text = 'Wake-on-LAN пакет отправлен в локальную сеть.'
        Write-AppLog $script:StatusLabel.Text
    } catch {
        $script:StatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка Wake-on-LAN: ' + $_.Exception.Message)
    }
})
$powerPanel.Controls.Add($wakeButton)

$telegramHeading = New-Object System.Windows.Forms.Label
$telegramHeading.Text = 'TELEGRAM — PC-PERSONALCONTROL'
$telegramHeading.Location = New-Object Drawing.Point(28, 636)
$telegramHeading.Size = New-Object Drawing.Size(700, 26)
$telegramHeading.ForeColor = $script:Colors.Accent
$telegramHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
$powerPanel.Controls.Add($telegramHeading)

$telegramHelp = New-Object System.Windows.Forms.Label
$telegramHelp.Text = 'Бот запускается отдельно от PC-PersonalControl и работает в фоне. Нажмите «Запустить + автозапуск» один раз: задача будет запускать бота при входе в Windows. Кнопки выключения/перезагрузки выполняются сразу без подтверждения.'
$telegramHelp.Location = New-Object Drawing.Point(28, 667)
$telegramHelp.Size = New-Object Drawing.Size(930, 48)
$telegramHelp.ForeColor = $script:Colors.Orange
$powerPanel.Controls.Add($telegramHelp)

$telegramTokenLabel = New-Object System.Windows.Forms.Label
$telegramTokenLabel.Text = 'Новый токен Telegram от BotFather'
$telegramTokenLabel.Location = New-Object Drawing.Point(28, 721)
$telegramTokenLabel.Size = New-Object Drawing.Size(350, 22)
$telegramTokenLabel.ForeColor = $script:Colors.Text
$powerPanel.Controls.Add($telegramTokenLabel)

$script:TelegramTokenBox = New-Object System.Windows.Forms.TextBox
$script:TelegramTokenBox.Location = New-Object Drawing.Point(28, 747)
$script:TelegramTokenBox.Size = New-Object Drawing.Size(390, 30)
$script:TelegramTokenBox.BackColor = $script:Colors.Panel
$script:TelegramTokenBox.ForeColor = $script:Colors.Text
$script:TelegramTokenBox.BorderStyle = 'FixedSingle'
$script:TelegramTokenBox.UseSystemPasswordChar = $true
$powerPanel.Controls.Add($script:TelegramTokenBox)

$script:TelegramSaveButton = New-Object System.Windows.Forms.Button
$script:TelegramSaveButton.Text = 'Сохранить токен'
$script:TelegramSaveButton.Location = New-Object Drawing.Point(432, 744)
$script:TelegramSaveButton.Size = New-Object Drawing.Size(175, 36)
$script:TelegramSaveButton.FlatStyle = 'Flat'
$script:TelegramSaveButton.FlatAppearance.BorderSize = 0
$script:TelegramSaveButton.BackColor = $script:Colors.Accent
$script:TelegramSaveButton.ForeColor = [Drawing.Color]::FromArgb(15, 20, 28)
$script:TelegramSaveButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:TelegramSaveButton.Add_Click({
    try {
        if ($null -ne (Get-BotWorkerProcess)) {
            throw 'Сначала остановите бота, затем измените токен или MAC-адрес.'
        }
        $pairingCode = Save-TelegramConfig -Token $script:TelegramTokenBox.Text.Trim()
        $script:TelegramTokenBox.Clear()
        if ($pairingCode) {
            $script:TelegramPairingLabel.Text = 'Код привязки (действует 10 минут): ' + $pairingCode + ' — отправьте боту: /pair ' + $pairingCode
        } else {
            $script:TelegramPairingLabel.Text = 'Токен сохранён. Уже привязанный владелец сохранён; перезапустите бота.'
        }
        $script:TelegramStatusLabel.Text = 'Токен сохранён в зашифрованном виде.'
        Write-AppLog 'Настройки Telegram сохранены; секретный токен не журналируется.'
    } catch {
        $script:TelegramStatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка сохранения Telegram-настроек: ' + $_.Exception.Message)
    }
})
$powerPanel.Controls.Add($script:TelegramSaveButton)

$telegramMacLabel = New-Object System.Windows.Forms.Label
$telegramMacLabel.Text = 'MAC-адрес устройства для Wake-on-LAN (необязательно)'
$telegramMacLabel.Location = New-Object Drawing.Point(28, 790)
$telegramMacLabel.Size = New-Object Drawing.Size(480, 22)
$telegramMacLabel.ForeColor = $script:Colors.Text
$powerPanel.Controls.Add($telegramMacLabel)

$script:BotWakeMacBox = New-Object System.Windows.Forms.TextBox
$script:BotWakeMacBox.Location = New-Object Drawing.Point(28, 816)
$script:BotWakeMacBox.Size = New-Object Drawing.Size(250, 30)
$script:BotWakeMacBox.BackColor = $script:Colors.Panel
$script:BotWakeMacBox.ForeColor = $script:Colors.Text
$script:BotWakeMacBox.BorderStyle = 'FixedSingle'
$script:BotWakeMacBox.Text = $script:PowerSettings.BotWakeMac
$powerPanel.Controls.Add($script:BotWakeMacBox)

$script:TelegramWakeMacSaveButton = New-Object System.Windows.Forms.Button
$script:TelegramWakeMacSaveButton.Text = 'Сохранить MAC'
$script:TelegramWakeMacSaveButton.Location = New-Object Drawing.Point(294, 813)
$script:TelegramWakeMacSaveButton.Size = New-Object Drawing.Size(150, 36)
$script:TelegramWakeMacSaveButton.FlatStyle = 'Flat'
$script:TelegramWakeMacSaveButton.FlatAppearance.BorderSize = 0
$script:TelegramWakeMacSaveButton.BackColor = $script:Colors.Accent
$script:TelegramWakeMacSaveButton.ForeColor = [Drawing.Color]::FromArgb(15, 20, 28)
$script:TelegramWakeMacSaveButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:TelegramWakeMacSaveButton.Add_Click({
    try {
        Save-TelegramWakeMac
        $script:TelegramStatusLabel.Text = 'MAC-адрес сохранён. Запустите бота или перезапустите его, чтобы применить настройку.'
        Write-AppLog 'MAC-адрес Wake-on-LAN для Telegram сохранён без изменения токена и привязки владельца.'
    } catch {
        $script:TelegramStatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка сохранения MAC-адреса Telegram: ' + $_.Exception.Message)
    }
})
$powerPanel.Controls.Add($script:TelegramWakeMacSaveButton)

$script:TelegramStartButton = New-Object System.Windows.Forms.Button
$script:TelegramStartButton.Text = 'Запустить / обновить меню'
$script:TelegramStartButton.Location = New-Object Drawing.Point(28, 858)
$script:TelegramStartButton.Size = New-Object Drawing.Size(195, 36)
$script:TelegramStartButton.FlatStyle = 'Flat'
$script:TelegramStartButton.FlatAppearance.BorderSize = 0
$script:TelegramStartButton.BackColor = $script:Colors.Green
$script:TelegramStartButton.ForeColor = [Drawing.Color]::FromArgb(15, 20, 28)
$script:TelegramStartButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:TelegramStartButton.Add_Click({
    try {
        Start-BotWorker
        $script:TelegramStatusLabel.Text = 'Бот запущен или обновлён; меню отправлено. Автозапуск при входе в Windows включён.'
        Write-AppLog 'Telegram-бот перезапущен с актуальным меню и автозапуском при входе в Windows.'
    } catch {
        $script:TelegramStatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка запуска Telegram-бота: ' + $_.Exception.Message)
    }
})
$powerPanel.Controls.Add($script:TelegramStartButton)

$script:TelegramStopButton = New-Object System.Windows.Forms.Button
$script:TelegramStopButton.Text = 'Остановить сейчас'
$script:TelegramStopButton.Location = New-Object Drawing.Point(234, 858)
$script:TelegramStopButton.Size = New-Object Drawing.Size(165, 36)
$script:TelegramStopButton.FlatStyle = 'Flat'
$script:TelegramStopButton.FlatAppearance.BorderSize = 0
$script:TelegramStopButton.BackColor = $script:Colors.PanelLight
$script:TelegramStopButton.ForeColor = $script:Colors.Text
$script:TelegramStopButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:TelegramStopButton.Add_Click({
    try {
        Stop-BotWorker
        $script:TelegramStatusLabel.Text = 'Бот остановлен.'
        Write-AppLog 'Telegram-бот остановлен.'
    } catch {
        $script:TelegramStatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка остановки Telegram-бота: ' + $_.Exception.Message)
    }
})
$powerPanel.Controls.Add($script:TelegramStopButton)

$script:TelegramAutostartOffButton = New-Object System.Windows.Forms.Button
$script:TelegramAutostartOffButton.Text = 'Отключить автозапуск'
$script:TelegramAutostartOffButton.Location = New-Object Drawing.Point(414, 858)
$script:TelegramAutostartOffButton.Size = New-Object Drawing.Size(195, 36)
$script:TelegramAutostartOffButton.FlatStyle = 'Flat'
$script:TelegramAutostartOffButton.FlatAppearance.BorderSize = 0
$script:TelegramAutostartOffButton.BackColor = $script:Colors.PanelLight
$script:TelegramAutostartOffButton.ForeColor = $script:Colors.Text
$script:TelegramAutostartOffButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:TelegramAutostartOffButton.Add_Click({
    try {
        Remove-BotLogonTask
        $script:TelegramStatusLabel.Text = 'Автозапуск отключён. Уже запущенный бот продолжает работать до остановки или выхода из Windows.'
        Write-AppLog 'Автозапуск Telegram-бота при входе в Windows отключён.'
    } catch {
        $script:TelegramStatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка отключения автозапуска Telegram: ' + $_.Exception.Message)
    }
})
$powerPanel.Controls.Add($script:TelegramAutostartOffButton)

$script:TelegramPairingLabel = New-Object System.Windows.Forms.Label
$script:TelegramPairingLabel.Text = 'Чтобы бот работал после перезагрузки, включите автозапуск и входите в Windows под этой учётной записью.'
$script:TelegramPairingLabel.Location = New-Object Drawing.Point(28, 902)
$script:TelegramPairingLabel.Size = New-Object Drawing.Size(930, 40)
$script:TelegramPairingLabel.ForeColor = $script:Colors.Text
$powerPanel.Controls.Add($script:TelegramPairingLabel)

$script:TelegramStatusLabel = New-Object System.Windows.Forms.Label
$script:TelegramStatusLabel.Text = 'Бот остановлен.'
$script:TelegramStatusLabel.Location = New-Object Drawing.Point(28, 946)
$script:TelegramStatusLabel.Size = New-Object Drawing.Size(930, 32)
$script:TelegramStatusLabel.ForeColor = $script:Colors.Muted
$powerPanel.Controls.Add($script:TelegramStatusLabel)

$telegramWebAppHeading = New-Object System.Windows.Forms.Label
$telegramWebAppHeading.Text = 'ВЕБ-ПАНЕЛЬ / TELEGRAM MINI APP'
$telegramWebAppHeading.Location = New-Object Drawing.Point(28, 994)
$telegramWebAppHeading.Size = New-Object Drawing.Size(620, 26)
$telegramWebAppHeading.ForeColor = $script:Colors.Accent
$telegramWebAppHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
$powerPanel.Controls.Add($telegramWebAppHeading)

$telegramWebAppHelp = New-Object System.Windows.Forms.Label
$telegramWebAppHelp.Text = 'Опубликуйте web на HTTPS-хостинге. В @BotFather выполните /newapp, выберите своего бота и задайте appname. Вставьте HTTPS URL сайта сюда, перезапустите бота и отправьте /start. BotFather создаст ссылку t.me/botusername/appname.'
$telegramWebAppHelp.Location = New-Object Drawing.Point(28, 1025)
$telegramWebAppHelp.Size = New-Object Drawing.Size(930, 42)
$telegramWebAppHelp.ForeColor = $script:Colors.Muted
$powerPanel.Controls.Add($telegramWebAppHelp)

$telegramWebAppLabel = New-Object System.Windows.Forms.Label
$telegramWebAppLabel.Text = 'Публичный HTTPS-адрес страницы'
$telegramWebAppLabel.Location = New-Object Drawing.Point(28, 1072)
$telegramWebAppLabel.Size = New-Object Drawing.Size(350, 22)
$telegramWebAppLabel.ForeColor = $script:Colors.Text
$powerPanel.Controls.Add($telegramWebAppLabel)

$script:TelegramWebAppUrlBox = New-Object System.Windows.Forms.TextBox
$script:TelegramWebAppUrlBox.Location = New-Object Drawing.Point(28, 1098)
$script:TelegramWebAppUrlBox.Size = New-Object Drawing.Size(520, 30)
$script:TelegramWebAppUrlBox.BackColor = $script:Colors.Panel
$script:TelegramWebAppUrlBox.ForeColor = $script:Colors.Text
$script:TelegramWebAppUrlBox.BorderStyle = 'FixedSingle'
if (Test-Path -LiteralPath $script:BotConfigPath) {
    try {
        $savedTelegramConfig = Get-Content -LiteralPath $script:BotConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$savedTelegramConfig.WebAppUrl -match '^https://') {
            $script:TelegramWebAppUrlBox.Text = [string]$savedTelegramConfig.WebAppUrl
        }
    } catch {
        Write-AppLog ('Не удалось загрузить ссылку Mini App: ' + $_.Exception.Message)
    }
}
$powerPanel.Controls.Add($script:TelegramWebAppUrlBox)

$script:TelegramWebAppSaveButton = New-Object System.Windows.Forms.Button
$script:TelegramWebAppSaveButton.Text = 'Сохранить адрес'
$script:TelegramWebAppSaveButton.Location = New-Object Drawing.Point(565, 1095)
$script:TelegramWebAppSaveButton.Size = New-Object Drawing.Size(175, 36)
$script:TelegramWebAppSaveButton.FlatStyle = 'Flat'
$script:TelegramWebAppSaveButton.FlatAppearance.BorderSize = 0
$script:TelegramWebAppSaveButton.BackColor = $script:Colors.Accent
$script:TelegramWebAppSaveButton.ForeColor = [Drawing.Color]::FromArgb(15, 20, 28)
$script:TelegramWebAppSaveButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:TelegramWebAppSaveButton.Add_Click({
    try {
        Save-TelegramWebAppUrl
        $script:TelegramStatusLabel.Text = 'Ссылка Mini App сохранена. Перезапустите бота, чтобы обновить меню.'
        Write-AppLog 'HTTPS-адрес Mini App сохранён.'
    } catch {
        $script:TelegramStatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка сохранения адреса Mini App: ' + $_.Exception.Message)
    }
})
$powerPanel.Controls.Add($script:TelegramWebAppSaveButton)

$updatesHeading = New-Object System.Windows.Forms.Label
$updatesHeading.Text = 'ОБНОВЛЕНИЯ PC-PERSONALCONTROL'
$updatesHeading.Location = New-Object Drawing.Point(28, 1150)
$updatesHeading.Size = New-Object Drawing.Size(620, 26)
$updatesHeading.ForeColor = $script:Colors.Accent
$updatesHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
$powerPanel.Controls.Add($updatesHeading)

$updatesHelp = New-Object System.Windows.Forms.Label
$updatesHelp.Text = 'Проверяйте GitHub Releases. Если доступна новая версия, скачайте PC-PersonalControl-project.zip (для старых релизов — FanPilot-project.zip).'
$updatesHelp.Location = New-Object Drawing.Point(28, 1180)
$updatesHelp.Size = New-Object Drawing.Size(930, 24)
$updatesHelp.ForeColor = $script:Colors.Muted
$powerPanel.Controls.Add($updatesHelp)

$script:UpdateCheckButton = New-Object System.Windows.Forms.Button
$script:UpdateCheckButton.Text = 'Проверить обновления'
$script:UpdateCheckButton.Location = New-Object Drawing.Point(28, 1213)
$script:UpdateCheckButton.Size = New-Object Drawing.Size(190, 36)
$script:UpdateCheckButton.FlatStyle = 'Flat'
$script:UpdateCheckButton.FlatAppearance.BorderSize = 0
$script:UpdateCheckButton.BackColor = $script:Colors.Accent
$script:UpdateCheckButton.ForeColor = [Drawing.Color]::FromArgb(15, 20, 28)
$script:UpdateCheckButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:UpdateCheckButton.Add_Click({
    $script:UpdateCheckButton.Enabled = $false
    $script:UpdateCheckButton.Text = 'Проверяю…'
    $script:UpdateOpenButton.Enabled = $false
    $script:LatestReleaseUrl = $null
    $script:UpdateStatusLabel.Text = 'Связываюсь с GitHub Releases…'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $release = Get-PCPersonalControlLatestRelease
        if ($release.State -eq 'no-release') {
            $script:LatestReleaseUrl = $null
            $script:UpdateStatusLabel.Text = 'Пока нет опубликованных релизов.'
            Write-AppLog 'Проверка обновлений: в репозитории ещё нет опубликованных релизов.'
        } elseif ($release.State -eq 'current') {
            $script:LatestReleaseUrl = $null
            $script:UpdateStatusLabel.Text = 'Установлена последняя версия PC-PersonalControl ' + $script:PCPersonalControlVersion + '.'
            Write-AppLog 'Проверка обновлений: установлена последняя версия ' + $script:PCPersonalControlVersion + '.'
        } else {
            $script:LatestReleaseUrl = $release.Url
            $script:UpdateOpenButton.Enabled = $true
            if ($release.HasPackage) {
                $script:UpdateStatusLabel.Text = 'Доступна версия ' + $release.Version + '. Откройте релиз и скачайте архив.'
            } else {
                $script:UpdateStatusLabel.Text = 'Версия ' + $release.Version + ' опубликована, но архив PC-PersonalControl-project.zip ещё не приложен.'
            }
            Write-AppLog ('Доступно обновление PC-PersonalControl ' + $release.Version + '.')
        }
    } catch {
        $script:UpdateStatusLabel.Text = $_.Exception.Message
        Write-AppLog ('Ошибка проверки обновлений: ' + $_.Exception.Message)
    } finally {
        $script:UpdateCheckButton.Enabled = $true
        $script:UpdateCheckButton.Text = 'Проверить обновления'
    }
})
$powerPanel.Controls.Add($script:UpdateCheckButton)

$script:UpdateOpenButton = New-Object System.Windows.Forms.Button
$script:UpdateOpenButton.Text = 'Открыть страницу релиза'
$script:UpdateOpenButton.Location = New-Object Drawing.Point(230, 1213)
$script:UpdateOpenButton.Size = New-Object Drawing.Size(205, 36)
$script:UpdateOpenButton.FlatStyle = 'Flat'
$script:UpdateOpenButton.FlatAppearance.BorderSize = 0
$script:UpdateOpenButton.BackColor = $script:Colors.PanelLight
$script:UpdateOpenButton.ForeColor = $script:Colors.Text
$script:UpdateOpenButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:UpdateOpenButton.Enabled = $false
$script:UpdateOpenButton.Add_Click({
    if ($script:LatestReleaseUrl) {
        try {
            Start-Process -FilePath $script:LatestReleaseUrl
        } catch {
            $script:UpdateStatusLabel.Text = 'Не удалось открыть страницу релиза: ' + $_.Exception.Message
            Write-AppLog ('Ошибка открытия страницы GitHub Release: ' + $_.Exception.Message)
        }
    }
})
$powerPanel.Controls.Add($script:UpdateOpenButton)

$script:UpdateStatusLabel = New-Object System.Windows.Forms.Label
$script:UpdateStatusLabel.Text = 'Текущая версия: ' + $script:PCPersonalControlVersion + '.'
$script:UpdateStatusLabel.Location = New-Object Drawing.Point(28, 1255)
$script:UpdateStatusLabel.Size = New-Object Drawing.Size(930, 38)
$script:UpdateStatusLabel.ForeColor = $script:Colors.Muted
$powerPanel.Controls.Add($script:UpdateStatusLabel)

$fanHeading = New-Object System.Windows.Forms.Label
$fanHeading.Text = 'КАНАЛЫ ВЕНТИЛЯТОРОВ'
$fanHeading.Dock = 'Top'
$fanHeading.Height = 29
$fanHeading.ForeColor = $script:Colors.Muted
$fanHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$split.Panel1.Controls.Add($fanHeading)

$script:FanCountLabel = New-Object System.Windows.Forms.Label
$script:FanCountLabel.Text = '0 каналов'
$script:FanCountLabel.Dock = 'Top'
$script:FanCountLabel.Height = 23
$script:FanCountLabel.ForeColor = $script:Colors.Accent
$split.Panel1.Controls.Add($script:FanCountLabel)

$script:FanList = New-Object System.Windows.Forms.ListBox
$script:FanList.Dock = 'Top'
$script:FanList.Height = 206
$script:FanList.BackColor = $script:Colors.Panel
$script:FanList.ForeColor = $script:Colors.Text
$script:FanList.BorderStyle = 'None'
$script:FanList.IntegralHeight = $false
$script:FanList.Add_SelectedIndexChanged({ Update-SelectedFanPanel })
$split.Panel1.Controls.Add($script:FanList)

$temperatureHeading = New-Object System.Windows.Forms.Label
$temperatureHeading.Text = 'ТЕМПЕРАТУРЫ'
$temperatureHeading.Dock = 'Top'
$temperatureHeading.Height = 31
$temperatureHeading.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
$temperatureHeading.ForeColor = $script:Colors.Muted
$temperatureHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$split.Panel1.Controls.Add($temperatureHeading)

$script:TemperatureCountLabel = New-Object System.Windows.Forms.Label
$script:TemperatureCountLabel.Text = '0 датчиков'
$script:TemperatureCountLabel.Dock = 'Top'
$script:TemperatureCountLabel.Height = 22
$script:TemperatureCountLabel.ForeColor = $script:Colors.Accent
$split.Panel1.Controls.Add($script:TemperatureCountLabel)

$script:TemperatureList = New-Object System.Windows.Forms.ListBox
$script:TemperatureList.Dock = 'Fill'
$script:TemperatureList.BackColor = $script:Colors.Panel
$script:TemperatureList.ForeColor = $script:Colors.Text
$script:TemperatureList.BorderStyle = 'None'
$script:TemperatureList.IntegralHeight = $false
$split.Panel1.Controls.Add($script:TemperatureList)

$script:SelectedFanLabel = New-Object System.Windows.Forms.Label
$script:SelectedFanLabel.Text = 'Выберите канал вентилятора'
$script:SelectedFanLabel.Dock = 'Top'
$script:SelectedFanLabel.Height = 33
$script:SelectedFanLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 12)
$script:SelectedFanLabel.ForeColor = $script:Colors.Text
$split.Panel2.Controls.Add($script:SelectedFanLabel)

$temperatureLabel = New-Object System.Windows.Forms.Label
$temperatureLabel.Text = 'Датчик температуры для этого вентилятора'
$temperatureLabel.Dock = 'Top'
$temperatureLabel.Height = 25
$temperatureLabel.ForeColor = $script:Colors.Muted
$split.Panel2.Controls.Add($temperatureLabel)

$script:TemperatureBox = New-Object System.Windows.Forms.ComboBox
$script:TemperatureBox.Dock = 'Top'
$script:TemperatureBox.DropDownStyle = 'DropDownList'
$script:TemperatureBox.BackColor = $script:Colors.Panel
$script:TemperatureBox.ForeColor = $script:Colors.Text
$script:TemperatureBox.FlatStyle = 'Flat'
$script:TemperatureBox.Height = 29
$script:TemperatureBox.Add_SelectedIndexChanged({
    if (-not $script:UpdatingUi -and $script:FanList.SelectedIndex -ge 0 -and $script:TemperatureBox.SelectedIndex -ge 0) {
        $fan = $script:Fans[$script:FanList.SelectedIndex]
        (Get-FanSetting $fan).TemperatureId = $script:Temperatures[$script:TemperatureBox.SelectedIndex].Id
    }
})
$split.Panel2.Controls.Add($script:TemperatureBox)

$profileLabel = New-Object System.Windows.Forms.Label
$profileLabel.Text = 'Профиль выбранного вентилятора'
$profileLabel.Dock = 'Top'
$profileLabel.Height = 30
$profileLabel.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$profileLabel.ForeColor = $script:Colors.Muted
$split.Panel2.Controls.Add($profileLabel)

$script:ProfileBox = New-Object System.Windows.Forms.ComboBox
$script:ProfileBox.Dock = 'Top'
$script:ProfileBox.DropDownStyle = 'DropDownList'
$script:ProfileBox.BackColor = $script:Colors.Panel
$script:ProfileBox.ForeColor = $script:Colors.Text
$script:ProfileBox.FlatStyle = 'Flat'
[void]$script:ProfileBox.Items.AddRange([string[]]@('Тихо', 'Игры', 'Максимум', 'Своя кривая', 'Авто'))
$split.Panel2.Controls.Add($script:ProfileBox)

$script:SelectedFanRangeLabel = New-Object System.Windows.Forms.Label
$script:SelectedFanRangeLabel.Text = ''
$script:SelectedFanRangeLabel.Dock = 'Top'
$script:SelectedFanRangeLabel.Height = 26
$script:SelectedFanRangeLabel.Padding = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
$script:SelectedFanRangeLabel.ForeColor = $script:Colors.Muted
$split.Panel2.Controls.Add($script:SelectedFanRangeLabel)

$curveHeader = New-Object System.Windows.Forms.Label
$curveHeader.Text = 'ПОЛЬЗОВАТЕЛЬСКАЯ КРИВАЯ'
$curveHeader.Dock = 'Top'
$curveHeader.Height = 30
$curveHeader.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$curveHeader.ForeColor = $script:Colors.Muted
$curveHeader.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$split.Panel2.Controls.Add($curveHeader)

$script:CurveGrid = New-Object System.Windows.Forms.DataGridView
$script:CurveGrid.Dock = 'Top'
$script:CurveGrid.Height = 190
$script:CurveGrid.BackgroundColor = $script:Colors.Panel
$script:CurveGrid.ForeColor = [Drawing.Color]::FromArgb(30, 35, 42)
$script:CurveGrid.GridColor = $script:Colors.PanelLight
$script:CurveGrid.BorderStyle = 'None'
$script:CurveGrid.AllowUserToAddRows = $true
$script:CurveGrid.AllowUserToDeleteRows = $true
$script:CurveGrid.RowHeadersVisible = $false
$script:CurveGrid.AutoSizeColumnsMode = 'Fill'
$script:CurveGrid.SelectionMode = 'CellSelect'
$script:CurveGrid.ColumnHeadersDefaultCellStyle.BackColor = $script:Colors.PanelLight
$script:CurveGrid.ColumnHeadersDefaultCellStyle.ForeColor = $script:Colors.Text
$script:CurveGrid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:Colors.PanelLight
$script:CurveGrid.DefaultCellStyle.BackColor = $script:Colors.Panel
$script:CurveGrid.DefaultCellStyle.ForeColor = $script:Colors.Text
$script:CurveGrid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(55, 79, 108)
$script:CurveGrid.DefaultCellStyle.SelectionForeColor = $script:Colors.Text
$script:CurveGrid.Columns.Add('Temperature', 'Температура, °C') | Out-Null
$script:CurveGrid.Columns.Add('Speed', 'Скорость, %') | Out-Null
$script:CurveGrid.Add_CellValueChanged({
    if (-not $script:UpdatingUi) {
        $script:CurveDirty = $true
    }
})
$script:CurveGrid.Add_RowsAdded({
    if (-not $script:UpdatingUi) {
        $script:CurveDirty = $true
    }
})
$script:CurveGrid.Add_RowsRemoved({
    if (-not $script:UpdatingUi) {
        $script:CurveDirty = $true
    }
})
$split.Panel2.Controls.Add($script:CurveGrid)

$script:ApplySelectedButton = New-Object System.Windows.Forms.Button
$script:ApplySelectedButton.Text = 'Применить к выбранному вентилятору'
$script:ApplySelectedButton.Dock = 'Top'
$script:ApplySelectedButton.Height = 39
$script:ApplySelectedButton.FlatStyle = 'Flat'
$script:ApplySelectedButton.FlatAppearance.BorderSize = 0
$script:ApplySelectedButton.BackColor = $script:Colors.Accent
$script:ApplySelectedButton.ForeColor = [Drawing.Color]::FromArgb(15, 20, 28)
$script:ApplySelectedButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:ApplySelectedButton.Add_Click({
    if ([string]$script:ProfileBox.SelectedItem -eq 'Своя кривая' -and -not (Save-CustomCurve)) {
        return
    }
    Set-SelectedFan
})
$split.Panel2.Controls.Add($script:ApplySelectedButton)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = '«Игры» повышает обороты по температуре. «Максимальный обдув» ставит 100%. «Авто BIOS» возвращает управление материнской плате.'
$hint.Dock = 'Top'
$hint.Height = 44
$hint.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$hint.ForeColor = $script:Colors.Muted
$split.Panel2.Controls.Add($hint)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Dock = 'Fill'
$script:LogBox.BackColor = $script:Colors.Panel
$script:LogBox.ForeColor = $script:Colors.Muted
$script:LogBox.BorderStyle = 'None'
$script:LogBox.Font = New-Object Drawing.Font('Consolas', 8.5)
$split.Panel2.Controls.Add($script:LogBox)

$logHeading = New-Object System.Windows.Forms.Label
$logHeading.Text = 'СОБЫТИЯ И ОШИБКИ'
$logHeading.Dock = 'Top'
$logHeading.Height = 28
$logHeading.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$logHeading.ForeColor = $script:Colors.Muted
$logHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$split.Panel2.Controls.Add($logHeading)

$split.Panel1.Controls.Clear()
$split.Panel2.Controls.Clear()

$leftLayout = New-Object System.Windows.Forms.TableLayoutPanel
$leftLayout.Dock = 'Fill'
$leftLayout.BackColor = $script:Colors.Background
$leftLayout.ColumnCount = 1
$leftLayout.RowCount = 6
$leftLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 76))) | Out-Null
$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 44))) | Out-Null
$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24))) | Out-Null
$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 56))) | Out-Null
$fanHeading.Text = 'ГРУППЫ ВЕНТИЛЯТОРОВ'
$script:FanCountLabel.Text = "Видеокарта: —`r`nВентилятор процессора: BIOS`r`nВентиляторы корпуса: BIOS"
$script:FanCountLabel.AutoSize = $false
$script:FanCountLabel.TextAlign = 'MiddleLeft'
$script:FanList.Dock = 'Fill'
$temperatureHeading.Text = 'ТЕМПЕРАТУРНЫЕ ДАТЧИКИ'
$script:TemperatureList.Dock = 'Fill'
$leftLayout.Controls.Add($fanHeading, 0, 0)
$leftLayout.Controls.Add($script:FanCountLabel, 0, 1)
$leftLayout.Controls.Add($script:FanList, 0, 2)
$leftLayout.Controls.Add($temperatureHeading, 0, 3)
$leftLayout.Controls.Add($script:TemperatureCountLabel, 0, 4)
$leftLayout.Controls.Add($script:TemperatureList, 0, 5)
$split.Panel1.Controls.Add($leftLayout)

$rightLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rightLayout.Dock = 'Fill'
$rightLayout.BackColor = $script:Colors.Background
$rightLayout.ColumnCount = 1
$rightLayout.RowCount = 12
$rightLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$rightRows = @(
    @{ Type = 'Absolute'; Height = 36 },
    @{ Type = 'Absolute'; Height = 24 },
    @{ Type = 'Absolute'; Height = 34 },
    @{ Type = 'Absolute'; Height = 24 },
    @{ Type = 'Absolute'; Height = 34 },
    @{ Type = 'Absolute'; Height = 26 },
    @{ Type = 'Absolute'; Height = 28 },
    @{ Type = 'Absolute'; Height = 160 },
    @{ Type = 'Absolute'; Height = 42 },
    @{ Type = 'Absolute'; Height = 52 },
    @{ Type = 'Absolute'; Height = 25 },
    @{ Type = 'Percent'; Height = 100 }
)
foreach ($row in $rightRows) {
    $sizeType = if ($row.Type -eq 'Percent') { [System.Windows.Forms.SizeType]::Percent } else { [System.Windows.Forms.SizeType]::Absolute }
    $rightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($sizeType, [single]$row.Height))) | Out-Null
}
$script:SelectedFanLabel.Dock = 'Fill'
$temperatureLabel.Dock = 'Fill'
$script:TemperatureBox.Dock = 'Fill'
$profileLabel.Dock = 'Fill'
$script:ProfileBox.Dock = 'Fill'
$script:SelectedFanRangeLabel.Dock = 'Fill'
$curveHeader.Dock = 'Fill'
$script:CurveGrid.Dock = 'Fill'
$script:ApplySelectedButton.Dock = 'Fill'
$hint.Dock = 'Fill'
$logHeading.Dock = 'Fill'
$script:LogBox.Dock = 'Fill'
$rightLayout.Controls.Add($script:SelectedFanLabel, 0, 0)
$rightLayout.Controls.Add($temperatureLabel, 0, 1)
$rightLayout.Controls.Add($script:TemperatureBox, 0, 2)
$rightLayout.Controls.Add($profileLabel, 0, 3)
$rightLayout.Controls.Add($script:ProfileBox, 0, 4)
$rightLayout.Controls.Add($script:SelectedFanRangeLabel, 0, 5)
$rightLayout.Controls.Add($curveHeader, 0, 6)
$rightLayout.Controls.Add($script:CurveGrid, 0, 7)
$rightLayout.Controls.Add($script:ApplySelectedButton, 0, 8)
$rightLayout.Controls.Add($hint, 0, 9)
$rightLayout.Controls.Add($logHeading, 0, 10)
$rightLayout.Controls.Add($script:LogBox, 0, 11)
$split.Panel2.Controls.Add($rightLayout)

$form.Controls.Clear()
$rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayout.Dock = 'Fill'
$rootLayout.BackColor = $script:Colors.Background
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 3
$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 82))) | Out-Null
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 82))) | Out-Null
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$header.Dock = 'Fill'
$quickPanel.Dock = 'Fill'
$tabs.Dock = 'Fill'
$rootLayout.Controls.Add($header, 0, 0)
$rootLayout.Controls.Add($quickPanel, 0, 1)
$rootLayout.Controls.Add($tabs, 0, 2)
$form.Controls.Add($rootLayout)

$script:MonitorTimer = New-Object System.Windows.Forms.Timer
$script:MonitorTimer.Interval = 1500
$script:MonitorTimer.Add_Tick({
    if ($script:Busy -or $script:FormClosing) {
        return
    }
if ($null -ne $script:BotProcess) {
    if ($script:BotProcess.HasExited) {
        $script:BotProcess = Get-BotWorkerProcess
    }
}
if ($null -eq $script:BotProcess) {
    $script:BotProcess = Get-BotWorkerProcess
}
if ($null -ne $script:BotProcess) {
    $script:TelegramStatusLabel.Text = 'Бот работает в фоне независимо от PC-PersonalControl.'
} else {
    $startupTask = Get-ScheduledTask -TaskName $script:BotTaskName -ErrorAction SilentlyContinue
    if ($null -ne $startupTask) {
        $script:TelegramStatusLabel.Text = 'Бот остановлен. Автозапуск включён при следующем входе в Windows.'
    } elseif (-not $script:BotExitReported) {
        $script:TelegramStatusLabel.Text = 'Бот остановлен; автозапуск выключен.'
    }
}
$script:Busy = $true
    try {
        Update-HardwareSnapshot
        foreach ($fan in $script:Fans) {
            $setting = Get-FanSetting $fan
            if ($setting.Profile -ne 'Авто') {
                try {
                    Set-FanMode -Fan $fan -FanProfile $setting.Profile
                } catch {
                    Restore-FanDefault $fan
                    $setting.Profile = 'Авто'
                    Write-AppLog ('Аварийный возврат к автоматике: ' + $_.Exception.Message)
                    $script:StatusLabel.Text = 'Сбой датчика или контроллера — возвращено управление BIOS'
                }
            }
        }
        Update-Ui
    } catch {
        foreach ($fan in $script:Fans) {
            Restore-FanDefault $fan
            (Get-FanSetting $fan).Profile = 'Авто'
        }
        $script:StatusLabel.Text = 'Ошибка чтения датчиков; управление возвращено BIOS'
        Write-AppLog ('Ошибка обновления датчиков: ' + $_.Exception.Message)
    } finally {
        $script:Busy = $false
    }
})

$form.Add_FormClosing({
    $script:FormClosing = $true
    $script:MonitorTimer.Stop()
    foreach ($fan in $script:Fans) {
        Restore-FanDefault $fan
    }
    Save-AppSettings
    try {
        $script:Computer.Close()
    } catch {
        Write-AppLog ('Ошибка завершения библиотеки датчиков: ' + $_.Exception.Message)
    }
    if ($null -ne $script:InstanceMutex) {
        $script:InstanceMutex.Dispose()
    }
})

$form.Add_Shown({
    try {
        $script:BotProcess = Get-BotWorkerProcess
        if ($null -ne $script:BotProcess) {
            $script:TelegramStatusLabel.Text = 'Бот работает в фоне независимо от PC-PersonalControl.'
        }
        Write-AppLog 'Подключение к датчикам оборудования…'
        $script:Computer.Open()
        Write-AppLog 'Библиотека датчиков подключена.'
        Update-HardwareSnapshot
        if ($script:Fans.Count -gt 0) {
            foreach ($fan in $script:Fans) {
                (Get-FanSetting $fan).Profile = 'Авто'
                try {
                    $fan.Control.SetDefault()
                } catch {
                    Write-AppLog ('Не удалось подтвердить автоматический режим для ' + $fan.Name + ': ' + $_.Exception.Message)
                }
            }
            $boardFanCount = @($script:Fans | Where-Object { $_.Kind -ne 'GPU' }).Count
            if ($boardFanCount -eq 0) {
                $script:StatusLabel.Text = 'Обнаружены вентиляторы видеокарты; управление CPU/корпусными вентиляторами доступно только через BIOS.'
            } else {
                $script:StatusLabel.Text = 'Датчики подключены. Выберите канал вентилятора для настройки.'
            }
            Write-AppLog ('Найдено датчиков температуры: ' + $script:Temperatures.Count)
            $physicalChannelCount = @($script:Fans | ForEach-Object { $_.Channels.Count } | Measure-Object -Sum).Sum
            Write-AppLog ('Найдено групп управления: ' + $script:Fans.Count + '; физических каналов: ' + $physicalChannelCount)
            if ($boardFanCount -eq 0) {
                Write-AppLog 'Материнская плата не предоставила программные каналы CPU/case fan; эти разъёмы остаются под управлением BIOS.'
            }
        } else {
            $script:StatusLabel.Text = 'Датчики доступны, программно управляемые вентиляторы не обнаружены'
            Write-AppLog 'Контроллеры не предоставили программные каналы управления.'
        }
        Update-Ui
        $script:MonitorTimer.Start()
    } catch {
        $script:StatusLabel.Text = 'Не удалось прочитать оборудование'
        Write-AppLog ('Ошибка подключения: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось подключиться к датчикам оборудования.`r`n$($_.Exception.Message)`r`n`r`nЕсли другая программа мониторинга открыта, закройте её и перезапустите PC-PersonalControl.",
            'PC-PersonalControl — ошибка оборудования',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[System.Windows.Forms.Application]::Run($form)

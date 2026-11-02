param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$configDirectory = Split-Path -Parent $ConfigPath
$stopPath = $ConfigPath + '.stop'
$logPath = Join-Path $configDirectory 'telegram.log'
$mutex = $null
$botToken = $null
$updateOffset = 0
$scheduledAction = $null
$pendingConfirmations = @{}
$script:pidPath = $ConfigPath + '.pid'
$script:timerPath = $ConfigPath + '.timer.json'
$script:chatCleanupPath = Join-Path $configDirectory 'telegram-chat-cleanup.json'
$script:chatCleanupChatId = ''
$script:chatCleanupMessages = New-Object System.Collections.ArrayList
$script:nextChatCleanupAt = [DateTime]::MaxValue
$script:awaitingTimerInput = $null
$script:awaitingVolumeInput = $null

function Write-BotLog {
    param([string]$Message)
    $safeMessage = $Message
    if ($script:botToken) {
        $safeMessage = $safeMessage.Replace($script:botToken, '[REDACTED]')
    }
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $safeMessage
    Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8
}

function Read-BotConfig {
    $data = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ownerId = [string]$data.AllowedUserId
    $ownerChatId = [string]$data.AllowedChatId
    $paired = $ownerId -match '^\d{5,15}$' -and $ownerChatId -match '^\d{5,15}$' -and $ownerId -eq $ownerChatId
    $unpaired = [string]::IsNullOrWhiteSpace($ownerId) -and
        [string]::IsNullOrWhiteSpace($ownerChatId) -and
        [string]$data.PairingCodeHash -match '^[A-Fa-f0-9]{64}$'
    if ($data.Version -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$data.TokenProtected) -or
        (-not $paired -and -not $unpaired)) {
        throw 'Настройки бота повреждены или не содержат доверенного владельца.'
    }
    return $data
}

function Save-BotConfig {
    param([object]$Data)
    $temporaryPath = $script:ConfigPath + '.tmp'
    ConvertTo-Json -InputObject $Data -Depth 5 |
        Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:ConfigPath -Force
}

function Invoke-TelegramApi {
    param(
        [string]$Method,
        [hashtable]$Body
    )
    $uri = 'https://api.telegram.org/bot' + $script:botToken + '/' + $Method
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 35
    } catch {
        $message = $_.Exception.Message.Replace($script:botToken, '[REDACTED]')
        throw ('Telegram API ' + $Method + ': ' + $message)
    }
    if (-not $response.ok) {
        throw ('Telegram API ' + $Method + ' вернул ошибку: ' + [string]$response.description)
    }
    return $response.result
}

function Send-BotMessage {
    param(
        [long]$ChatId,
        [string]$Text,
        [object]$Keyboard
    )
    $body = @{
        chat_id = $ChatId.ToString()
        text = $Text
    }
    if ($null -ne $Keyboard) {
        $body.reply_markup = ConvertTo-Json -InputObject $Keyboard -Depth 8 -Compress
    }
    $sentMessage = Invoke-TelegramApi -Method 'sendMessage' -Body $body
    Add-ChatCleanupMessage -ChatId $ChatId -MessageId ([long]$sentMessage.message_id)
}

function Save-ChatCleanupState {
    if (-not $script:chatCleanupChatId) {
        return
    }

    $data = @{
        Version = 1
        ChatId = $script:chatCleanupChatId
        MessageIds = @($script:chatCleanupMessages.ToArray())
        NextCleanupAt = $script:nextChatCleanupAt.ToString('o')
    }
    $temporaryPath = $script:chatCleanupPath + '.tmp'
    ConvertTo-Json -InputObject $data -Depth 4 |
        Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:chatCleanupPath -Force
}

function Initialize-ChatCleanupState {
    param([string]$ChatId)

    $script:chatCleanupChatId = $ChatId
    $script:chatCleanupMessages.Clear()
    $script:nextChatCleanupAt = (Get-Date).Date.AddDays(1)
    if (-not $ChatId -or -not (Test-Path -LiteralPath $script:chatCleanupPath)) {
        return
    }

    try {
        $state = Get-Content -LiteralPath $script:chatCleanupPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.Version -ne 1 -or [string]$state.ChatId -ne $ChatId) {
            throw 'Файл состояния очистки не соответствует текущему владельцу.'
        }

        $nextCleanupAt = [DateTime]::MinValue
        if (-not [DateTime]::TryParse(
            [string]$state.NextCleanupAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$nextCleanupAt
        )) {
            throw 'Не удалось прочитать время следующей очистки.'
        }
        $script:nextChatCleanupAt = $nextCleanupAt

        foreach ($message in @($state.MessageIds)) {
            $messageId = 0L
            $createdAtUtc = [DateTime]::MinValue
            if ([long]::TryParse([string]$message.MessageId, [ref]$messageId) -and
                $messageId -gt 0 -and
                [DateTime]::TryParse(
                    [string]$message.CreatedAtUtc,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind,
                    [ref]$createdAtUtc
                )) {
                [void]$script:chatCleanupMessages.Add([pscustomobject]@{
                    MessageId = $messageId
                    CreatedAtUtc = $createdAtUtc.ToUniversalTime().ToString('o')
                })
            }
        }
    } catch {
        $script:chatCleanupMessages.Clear()
        $script:nextChatCleanupAt = (Get-Date).Date.AddDays(1)
        Write-BotLog ('Не удалось восстановить очередь ежедневной очистки чата; начат новый список. ' + $_.Exception.Message)
    }

    try {
        Save-ChatCleanupState
    } catch {
        Write-BotLog ('Не удалось сохранить состояние ежедневной очистки чата: ' + $_.Exception.Message)
    }
}

function Add-ChatCleanupMessage {
    param(
        [long]$ChatId,
        [long]$MessageId
    )
    if (-not $script:chatCleanupChatId -or
        [string]$ChatId -ne $script:chatCleanupChatId -or
        $MessageId -le 0) {
        return
    }

    foreach ($message in $script:chatCleanupMessages) {
        if ([long]$message.MessageId -eq $MessageId) {
            return
        }
    }
    [void]$script:chatCleanupMessages.Add([pscustomobject]@{
        MessageId = $MessageId
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    })
    try {
        Save-ChatCleanupState
    } catch {
        Write-BotLog ('Не удалось сохранить ID сообщения для ежедневной очистки: ' + $_.Exception.Message)
    }
}

function Invoke-DailyChatCleanup {
    if (-not $script:chatCleanupChatId -or (Get-Date) -lt $script:nextChatCleanupAt) {
        return
    }

    $remainingMessages = New-Object System.Collections.ArrayList
    $deletedCount = 0
    $alreadyAbsentCount = 0
    $expiredCount = 0
    $failureCount = 0
    $firstFailure = ''
    foreach ($message in $script:chatCleanupMessages) {
        $createdAtUtc = [DateTime]::Parse(
            [string]$message.CreatedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        if (([DateTime]::UtcNow - $createdAtUtc).TotalHours -ge 48) {
            $expiredCount++
            continue
        }

        try {
            $null = Invoke-TelegramApi -Method 'deleteMessage' -Body @{
                chat_id = $script:chatCleanupChatId
                message_id = ([long]$message.MessageId).ToString()
            }
            $deletedCount++
        } catch {
            $failureMessage = $_.Exception.Message
            if ($failureMessage -match '(?i)message to delete not found|message can.t be deleted|message identifier is not specified|сообщени.*не найден|не может быть удалено') {
                $alreadyAbsentCount++
            } else {
                $failureCount++
                if (-not $firstFailure) {
                    $firstFailure = $failureMessage
                }
                [void]$remainingMessages.Add($message)
            }
        }
    }

    $script:chatCleanupMessages = $remainingMessages
    if ($failureCount -gt 0) {
        $script:nextChatCleanupAt = (Get-Date).AddMinutes(5)
    } else {
        $script:nextChatCleanupAt = (Get-Date).Date.AddDays(1)
    }
    try {
        Save-ChatCleanupState
    } catch {
        Write-BotLog ('Не удалось сохранить состояние после очистки чата: ' + $_.Exception.Message)
    }

    if ($deletedCount -gt 0 -or $alreadyAbsentCount -gt 0 -or $expiredCount -gt 0 -or $failureCount -gt 0) {
        Write-BotLog ("Ежедневная очистка чата: удалено $deletedCount, уже отсутствовало $alreadyAbsentCount, старше 48 часов пропущено $expiredCount, ошибок $failureCount.")
    }
    if ($failureCount -gt 0) {
        Write-BotLog ('Очистка чата будет повторена через 5 минут. ' + $firstFailure)
    }
}

function Invoke-PowerCommand {
    param(
        [string[]]$Arguments,
        [string]$FailureMessage
    )
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\shutdown.exe') -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "$FailureMessage (код Windows $($process.ExitCode))."
    }
}

function Invoke-ImmediatePowerAction {
    param(
        [ValidateSet('shutdown', 'restart')]
        [string]$Action,
        [long]$ChatId
    )
    $verb = if ($Action -eq 'shutdown') { 'выключение' } else { 'перезагрузку' }
    if (Test-Path -LiteralPath $script:timerPath) {
        $null = Clear-ManagedShutdownTimer
    }
    Send-BotMessage -ChatId $ChatId -Text "⏻ Выполняю $verb."
    $arguments = if ($Action -eq 'shutdown') { @('/s', '/f', '/t', '0') } else { @('/r', '/f', '/t', '0') }
    Invoke-PowerCommand -Arguments $arguments -FailureMessage "Не удалось запустить $verb"
    $script:scheduledAction = $null
    Write-BotLog "Владелец выполнил $verb через Telegram без задержки."
}

function Invoke-SessionAction {
    param(
        [ValidateSet('sleep', 'lock')]
        [string]$Action,
        [long]$ChatId
    )
    if (-not ('FanPilotSessionActions' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FanPilotSessionActions
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LockWorkStation();

    [DllImport("powrprof.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
}
'@ -ErrorAction Stop
    }
    if ($Action -eq 'lock') {
        Send-BotMessage -ChatId $ChatId -Text '🔒 Блокирую текущий сеанс Windows.'
        if (-not [FanPilotSessionActions]::LockWorkStation()) {
            throw 'Windows не смогла заблокировать текущий интерактивный сеанс.'
        }
        Write-BotLog 'Владелец заблокировал сеанс Windows через Telegram.'
    } else {
        Send-BotMessage -ChatId $ChatId -Text '🌙 Перевожу компьютер в спящий режим.'
        if (-not [FanPilotSessionActions]::SetSuspendState($false, $false, $false)) {
            throw 'Windows не смогла перейти в спящий режим; проверьте поддержку сна в настройках питания.'
        }
        Write-BotLog 'Владелец перевёл компьютер в спящий режим через Telegram.'
    }
}

function Invoke-VolumeAction {
    param(
        [ValidateSet('volume_up', 'volume_down', 'volume_set', 'volume_status', 'mute', 'unmute')]
        [string]$Action,
        [long]$ChatId,
        [ValidateRange(0, 100)]
        [int]$Percent = 0
    )
    if (-not ('PCPersonalControlAudio' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public enum AudioDataFlow { Render = 0, Capture = 1, All = 2 }
public enum AudioRole { Console = 0, Multimedia = 1, Communications = 2 }

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class AudioDeviceEnumerator { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioDeviceEnumerator
{
    [PreserveSig] int EnumAudioEndpoints(AudioDataFlow flow, int stateMask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(AudioDataFlow flow, AudioRole role, out IAudioDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioDevice
{
    [PreserveSig] int Activate(ref Guid interfaceId, uint classContext, IntPtr activationParameters,
        [MarshalAs(UnmanagedType.IUnknown)] out object audioInterface);
    [PreserveSig] int OpenPropertyStore(int access, out IntPtr properties);
    [PreserveSig] int GetId(out IntPtr id);
    [PreserveSig] int GetState(out int state);
}

[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume
{
    [PreserveSig] int RegisterControlChangeNotify(IntPtr callback);
    [PreserveSig] int UnregisterControlChangeNotify(IntPtr callback);
    [PreserveSig] int GetChannelCount(out uint channelCount);
    [PreserveSig] int SetMasterVolumeLevel(float level, ref Guid eventContext);
    [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);
    [PreserveSig] int GetMasterVolumeLevel(out float level);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    [PreserveSig] int SetChannelVolumeLevel(uint channel, float level, ref Guid eventContext);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid eventContext);
    [PreserveSig] int GetChannelVolumeLevel(uint channel, out float level);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted, ref Guid eventContext);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool muted);
    [PreserveSig] int GetVolumeStepInfo(out uint step, out uint stepCount);
    [PreserveSig] int VolumeStepUp(ref Guid eventContext);
    [PreserveSig] int VolumeStepDown(ref Guid eventContext);
    [PreserveSig] int QueryHardwareSupport(out uint hardwareSupportMask);
    [PreserveSig] int GetVolumeRange(out float minimum, out float maximum, out float increment);
}

public static class PCPersonalControlAudio
{
    private static void Check(int result)
    {
        if (result < 0)
            Marshal.ThrowExceptionForHR(result);
    }

    private static IAudioEndpointVolume GetDefaultEndpoint()
    {
        IAudioDeviceEnumerator enumerator = null;
        IAudioDevice device = null;
        object audioInterface = null;
        try
        {
            enumerator = (IAudioDeviceEnumerator)new AudioDeviceEnumerator();
            Check(enumerator.GetDefaultAudioEndpoint(AudioDataFlow.Render, AudioRole.Multimedia, out device));
            Guid interfaceId = typeof(IAudioEndpointVolume).GUID;
            Check(device.Activate(ref interfaceId, 23, IntPtr.Zero, out audioInterface));
            IAudioEndpointVolume endpoint = (IAudioEndpointVolume)audioInterface;
            audioInterface = null;
            return endpoint;
        }
        finally
        {
            if (audioInterface != null)
                Marshal.ReleaseComObject(audioInterface);
            if (device != null)
                Marshal.ReleaseComObject(device);
            if (enumerator != null)
                Marshal.ReleaseComObject(enumerator);
        }
    }

    public static int AdjustVolume(float delta)
    {
        IAudioEndpointVolume endpoint = GetDefaultEndpoint();
        try
        {
            float current;
            Check(endpoint.GetMasterVolumeLevelScalar(out current));
            float updated = Math.Max(0.0f, Math.Min(1.0f, current + delta));
            Guid eventContext = Guid.Empty;
            Check(endpoint.SetMasterVolumeLevelScalar(updated, ref eventContext));
            if (updated > current)
                Check(endpoint.SetMute(false, ref eventContext));
            return (int)Math.Round(updated * 100.0f, MidpointRounding.AwayFromZero);
        }
        finally
        {
            Marshal.ReleaseComObject(endpoint);
        }
    }

    public static int SetVolume(int percent)
    {
        if (percent < 0 || percent > 100)
            throw new ArgumentOutOfRangeException("percent");
        IAudioEndpointVolume endpoint = GetDefaultEndpoint();
        try
        {
            float current;
            Check(endpoint.GetMasterVolumeLevelScalar(out current));
            Guid eventContext = Guid.Empty;
            Check(endpoint.SetMasterVolumeLevelScalar(percent / 100.0f, ref eventContext));
            if (percent / 100.0f > current)
                Check(endpoint.SetMute(false, ref eventContext));
            return percent;
        }
        finally
        {
            Marshal.ReleaseComObject(endpoint);
        }
    }

    public static int GetVolumePercent()
    {
        IAudioEndpointVolume endpoint = GetDefaultEndpoint();
        try
        {
            float current;
            Check(endpoint.GetMasterVolumeLevelScalar(out current));
            return (int)Math.Round(current * 100.0f, MidpointRounding.AwayFromZero);
        }
        finally
        {
            Marshal.ReleaseComObject(endpoint);
        }
    }

    public static bool IsMuted()
    {
        IAudioEndpointVolume endpoint = GetDefaultEndpoint();
        try
        {
            bool muted;
            Check(endpoint.GetMute(out muted));
            return muted;
        }
        finally
        {
            Marshal.ReleaseComObject(endpoint);
        }
    }

    public static bool ToggleMute()
    {
        IAudioEndpointVolume endpoint = GetDefaultEndpoint();
        try
        {
            bool muted;
            Check(endpoint.GetMute(out muted));
            Guid eventContext = Guid.Empty;
            Check(endpoint.SetMute(!muted, ref eventContext));
            return !muted;
        }
        finally
        {
            Marshal.ReleaseComObject(endpoint);
        }
    }

    public static void Unmute()
    {
        IAudioEndpointVolume endpoint = GetDefaultEndpoint();
        try
        {
            Guid eventContext = Guid.Empty;
            Check(endpoint.SetMute(false, ref eventContext));
        }
        finally
        {
            Marshal.ReleaseComObject(endpoint);
        }
    }
}
'@ -ErrorAction Stop
    }

    $message = switch ($Action) {
        'volume_up' { '🔊 Уровень громкости: ' + [PCPersonalControlAudio]::AdjustVolume(0.02) + '%.' }
        'volume_down' { '🔉 Уровень громкости: ' + [PCPersonalControlAudio]::AdjustVolume(-0.02) + '%.' }
        'volume_set' { '🔊 Уровень громкости установлен: ' + [PCPersonalControlAudio]::SetVolume($Percent) + '%.' }
        'volume_status' {
            $volume = [PCPersonalControlAudio]::GetVolumePercent()
            $muted = [PCPersonalControlAudio]::IsMuted()
            $state = if ($muted) { 'звук выключен' } else { 'звук включён' }
            "🔊 Текущая громкость: $volume% ($state)."
        }
        'mute' {
            if ([PCPersonalControlAudio]::ToggleMute()) {
                '🔇 Звук выключен.'
            } else {
                '🔊 Звук включён.'
            }
        }
        'unmute' {
            [PCPersonalControlAudio]::Unmute()
            '🔊 Звук включён.'
        }
    }
    Send-BotMessage -ChatId $ChatId -Text $message
}

function Invoke-MediaAction {
    param(
        [ValidateSet('play_pause', 'previous', 'next')]
        [string]$Action,
        [long]$ChatId
    )
    if (-not ('PCPersonalControlMediaKeys' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PCPersonalControlMediaKeys
{
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);

    public static void Press(byte key)
    {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }
}
'@ -ErrorAction Stop
    }
    $key = switch ($Action) {
        'play_pause' { 0xB3 }
        'previous' { 0xB1 }
        'next' { 0xB0 }
    }
    [PCPersonalControlMediaKeys]::Press([byte]$key)
    $message = switch ($Action) {
        'play_pause' { '⏯ Команда воспроизведения/паузы отправлена.' }
        'previous' { '⏮ Команда «Предыдущий трек» отправлена.' }
        'next' { '⏭ Команда «Следующий трек» отправлена.' }
    }
    Send-BotMessage -ChatId $ChatId -Text $message
}

function Request-VolumeInput {
    param([long]$ChatId)
    $script:awaitingVolumeInput = @{
        ChatId = $ChatId
        Expires = (Get-Date).AddMinutes(5)
    }
    Send-BotMessage -ChatId $ChatId -Text '🎚 Введите уровень громкости от 0 до 100%.'
}

function ConvertTo-DelaySeconds {
    param([string]$Text)
    $pattern = '(?i)(?<value>\d{1,9})\s*(?<unit>дней|дня|день|дн|д|days?|d|часов|часа|час|ч|hours?|h|минут|минута|минуты|мин|м|minutes?|mins?|m|секунд|секунда|секунды|сек|с|seconds?|secs?|s)(?=\s|$)'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -eq 0) {
        throw 'Не понял длительность. Примеры: 30 секунд, 15 мин, 2 часа, 1 день или 1ч 30м.'
    }

    $remaining = [regex]::Replace($Text, $pattern, '')
    $remaining = [regex]::Replace($remaining, '(?i)[\s,;и]+', '')
    if ($remaining.Length -gt 0) {
        throw 'Укажи только число и единицу времени, например: 15 мин или 2 часа.'
    }

    [long]$totalSeconds = 0
    foreach ($match in $matches) {
        [long]$value = 0
        if (-not [long]::TryParse($match.Groups['value'].Value, [ref]$value) -or $value -le 0) {
            throw 'Длительность должна содержать положительные числа.'
        }
        $unit = $match.Groups['unit'].Value.ToLowerInvariant()
        if ($unit -match '^(д|дн|день|дня|дней|d|day|days)$') {
            $multiplier = 86400
        } elseif ($unit -match '^(ч|час|часа|часов|h|hour|hours)$') {
            $multiplier = 3600
        } elseif ($unit -match '^(м|мин|минута|минуты|минут|m|min|mins|minute|minutes)$') {
            $multiplier = 60
        } else {
            $multiplier = 1
        }
        if ($value -gt [long]::MaxValue / $multiplier) {
            throw 'Это время слишком велико.'
        }
        $totalSeconds += $value * $multiplier
        if ($totalSeconds -gt 315360000) {
            throw 'Максимальная длительность таймера — 10 лет.'
        }
    }
    if ($totalSeconds -le 0) {
        throw 'Длительность должна быть больше нуля.'
    }
    return $totalSeconds
}

function Start-ShutdownTimer {
    param(
        [string]$DurationText,
        [long]$ChatId
    )
    $seconds = ConvertTo-DelaySeconds -Text $DurationText
    if (Test-Path -LiteralPath $script:timerPath) {
        $null = Clear-ManagedShutdownTimer
    }
    $timerState = @{
        Version = 1
        ExpiresUtc = [DateTime]::UtcNow.AddSeconds($seconds).ToString('o')
    }
    $timerTemporaryPath = $script:timerPath + '.tmp'
    ConvertTo-Json -InputObject $timerState -Compress |
        Set-Content -LiteralPath $timerTemporaryPath -Encoding UTF8
    Move-Item -LiteralPath $timerTemporaryPath -Destination $script:timerPath -Force
    try {
        Invoke-PowerCommand -Arguments @('/s', '/t', $seconds.ToString()) -FailureMessage 'Не удалось запустить таймер выключения'
    } catch {
        Remove-Item -LiteralPath $script:timerPath -Force -ErrorAction SilentlyContinue
        throw
    }
    $script:scheduledAction = 'shutdown'
    $duration = [TimeSpan]::FromSeconds($seconds)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($duration.Days -gt 0) { $parts.Add("$($duration.Days) дн.") }
    if ($duration.Hours -gt 0) { $parts.Add("$($duration.Hours) ч") }
    if ($duration.Minutes -gt 0) { $parts.Add("$($duration.Minutes) мин") }
    if ($duration.Seconds -gt 0) { $parts.Add("$($duration.Seconds) сек") }
    $displayDuration = $parts -join ' '
    Send-BotMessage -ChatId $ChatId -Text "⏲ Таймер выключения установлен на $displayDuration. Отменить его можно кнопкой «Отменить таймер»."
    Write-BotLog "Владелец установил таймер выключения на $seconds секунд."
}

function Clear-ManagedShutdownTimer {
    if (-not (Test-Path -LiteralPath $script:timerPath)) {
        return $null
    }
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\shutdown.exe') -ArgumentList @('/a') -Wait -PassThru -NoNewWindow
    Remove-Item -LiteralPath $script:timerPath -Force -ErrorAction Stop
    $script:scheduledAction = $null
    return [int]$process.ExitCode
}

function Stop-ShutdownTimer {
    param([long]$ChatId)
    $script:awaitingTimerInput = $null
    $exitCode = Clear-ManagedShutdownTimer
    if ($null -eq $exitCode) {
        Send-BotMessage -ChatId $ChatId -Text 'Таймер PC-PersonalControl не запущен.'
    } elseif ($exitCode -eq 0) {
        Send-BotMessage -ChatId $ChatId -Text '✅ Таймер выключения отменён.'
        Write-BotLog 'Владелец отменил таймер выключения.'
    } elseif ($exitCode -eq 1116) {
        Send-BotMessage -ChatId $ChatId -Text 'Активного таймера Windows уже нет.'
        Write-BotLog 'Удалена устаревшая запись о таймере выключения.'
    } else {
        throw 'Windows не смогла отменить таймер выключения.'
    }
}

function Answer-Callback {
    param(
        [string]$CallbackId,
        [string]$Text
    )
    if (-not $CallbackId) {
        return
    }
    $body = @{ callback_query_id = $CallbackId }
    if ($Text) {
        $body.text = $Text
        $body.show_alert = 'false'
    }
    try {
        $null = Invoke-TelegramApi -Method 'answerCallbackQuery' -Body $body
    } catch {
        Write-BotLog ('Telegram не подтвердил визуальное нажатие кнопки; команда продолжает обрабатываться: ' + $_.Exception.Message)
    }
}

function Get-MainKeyboard {
    return $null
}

function Get-WebAppReplyKeyboard {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $rows.Add(@(
        @{ text = '📊 Статус ПК' },
        @{ text = '🌅 Разбудить ПК' }
    ))
    $rows.Add(@(
        @{ text = '🌙 Спящий режим' },
        @{ text = '🔒 Заблокировать' }
    ))
    $rows.Add(@(
        @{ text = '⏻ Выключить ПК' },
        @{ text = '🔄 Перезагрузить ПК' }
    ))
    $rows.Add(@(
        @{ text = '⏲ Таймер выключения' },
        @{ text = '✖️ Отменить таймер' }
    ))
    $rows.Add(@(
        @{ text = '🔊 Громкость +' },
        @{ text = '🔉 Громкость -' }
    ))
    $rows.Add(@(
        @{ text = '🔇 Mute' },
        @{ text = '🔊 Включить звук' }
    ))
    $rows.Add(@(
        @{ text = '🎚 Своя громкость' },
        @{ text = '📊 Статус звука' }
    ))
    $rows.Add(@(
        @{ text = '⏯ Пуск / пауза' }
    ))
    $rows.Add(@(
        @{ text = '⏮ Предыдущий трек' },
        @{ text = '⏭ Следующий трек' }
    ))
    if ($script:webAppUrl) {
        $rows.Add(@(
            @{ text = '✨ Открыть панель'; web_app = @{ url = $script:webAppUrl } }
        ))
    }
    return @{
        keyboard = $rows.ToArray()
        is_persistent = $true
        resize_keyboard = $true
        one_time_keyboard = $false
        input_field_placeholder = 'Выберите действие'
    }
}

function Send-WebAppReplyKeyboard {
    param([long]$ChatId)
    $keyboard = Get-WebAppReplyKeyboard
    Send-BotMessage -ChatId $ChatId -Text 'PC-PersonalControl на связи. Ожидаю Ваши команды.' -Keyboard $keyboard
}

function Get-DeviceStatus {
    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $computer = [Environment]::MachineName
    $bootTime = $operatingSystem.LastBootUpTime
    $uptime = (Get-Date) - $bootTime
    $power = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $powerText = if ($power) { 'от батареи/ИБП' } else { 'стационарное питание' }
    return "🖥 $computer`n🟢 Компьютер включён`n⏱ Время работы: $([int]$uptime.TotalHours) ч $($uptime.Minutes) мин`n🔋 Питание: $powerText"
}

function Send-WakePacket {
    param([string]$MacAddress)
    if ($MacAddress -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
        throw 'Для Wake-on-LAN не задан правильный целевой MAC-адрес.'
    }
    $bytes = [byte[]]@($MacAddress -split '[:-]' | ForEach-Object { [Convert]::ToByte($_, 16) })
    $packet = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) {
        $packet[$i] = 255
    }
    for ($i = 0; $i -lt 16; $i++) {
        [Array]::Copy($bytes, 0, $packet, 6 + ($i * 6), 6)
    }
    $udp = New-Object Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        $endpoint = New-Object Net.IPEndPoint([Net.IPAddress]::Broadcast, 9)
        if ($udp.Send($packet, $packet.Length, $endpoint) -ne $packet.Length) {
            throw 'Wake-on-LAN пакет отправлен не полностью.'
        }
    } finally {
        $udp.Dispose()
    }
}

function Register-PairedOwner {
    param(
        [string]$PairCode,
        [string]$FromId,
        [string]$ChatId,
        [string]$ChatType
    )
    if ($ChatType -ne 'private' -or $FromId -notmatch '^\d{5,15}$' -or $FromId -ne $ChatId) {
        return $false
    }
    $config = Read-BotConfig
    if ($config.AllowedUserId -or -not $config.PairingCodeHash -or -not $config.PairingExpiresUtc) {
        return $false
    }
    $expiry = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
        [string]$config.PairingExpiresUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$expiry
    ) -or $expiry.ToUniversalTime() -lt [DateTime]::UtcNow) {
        return $false
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($PairCode.ToUpperInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $receivedHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
    if (-not [string]::Equals($receivedHash, [string]$config.PairingCodeHash, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $config.AllowedUserId = $FromId
    $config.AllowedChatId = $ChatId
    $config.PairingCodeHash = ''
    $config.PairingExpiresUtc = ''
    Save-BotConfig -Data $config
    $script:ownerId = $FromId
    Initialize-ChatCleanupState -ChatId $ChatId
    return $true
}

try {
    $createdNew = $false
    $script:instanceMutex = New-Object System.Threading.Mutex($false, 'Local\FanPilotTelegramBot', [ref]$createdNew)
    if (-not $createdNew) {
        Write-BotLog 'Другой экземпляр бота уже выполняется.'
        exit 0
    }

    $config = Read-BotConfig
    $protected = ConvertTo-SecureString ([string]$config.TokenProtected)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($protected)
    try {
        $script:botToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }

    if ($script:botToken -notmatch '^\d{5,15}:[A-Za-z0-9_-]{25,}$') {
        throw 'Защищённый токен бота не соответствует ожидаемому формату.'
    }
    $script:ownerId = [string]$config.AllowedUserId
    Initialize-ChatCleanupState -ChatId $script:ownerId
    $script:targetMac = [string]$config.WakeMac
    $script:webAppUrl = [string]$config.WebAppUrl
    if ($script:webAppUrl) {
        $parsedWebAppUrl = $null
        if (-not [Uri]::TryCreate($script:webAppUrl, [UriKind]::Absolute, [ref]$parsedWebAppUrl) -or
            $parsedWebAppUrl.Scheme -ne 'https' -or
            -not [string]::IsNullOrEmpty($parsedWebAppUrl.UserInfo)) {
            throw 'Ссылка Mini App должна быть безопасным HTTPS-адресом без данных входа.'
        }
    }

    $null = Invoke-TelegramApi -Method 'deleteWebhook' -Body @{ drop_pending_updates = 'true' }
    $bot = Invoke-TelegramApi -Method 'getMe' -Body @{}
    $commands = @(
        @{ command = 'start'; description = 'Открыть меню PC-PersonalControl' },
        @{ command = 'menu'; description = 'Показать кнопки управления' },
        @{ command = 'status'; description = 'Проверить состояние компьютера' },
        @{ command = 'timer'; description = 'Задать таймер выключения' },
        @{ command = 'cancel'; description = 'Отменить таймер выключения' },
        @{ command = 'sleep'; description = 'Спящий режим' },
        @{ command = 'lock'; description = 'Заблокировать' },
        @{ command = 'shutdown'; description = 'Завершение работы' },
        @{ command = 'restart'; description = 'Перезагрузка' },
        @{ command = 'wake'; description = 'Разбудить компьютер' },
        @{ command = 'help'; description = 'Посмотреть подсказку' }
        @{ command = 'volume_up'; description = 'Повысить громкость на 2%' },
        @{ command = 'volume_down'; description = 'Понизить громкость на 2%' },
        @{ command = 'volume'; description = 'Задать свой уровень громкости' },
        @{ command = 'volume_status'; description = 'Проверить громкость и mute' },
        @{ command = 'mute'; description = 'Переключить звук' },
        @{ command = 'unmute'; description = 'Включить звук' },
        @{ command = 'play_pause'; description = 'Воспроизведение или пауза' },
        @{ command = 'previous'; description = 'Предыдущий трек' },
        @{ command = 'next'; description = 'Следующий трек' }
    )
    $null = Invoke-TelegramApi -Method 'setMyCommands' -Body @{
        commands = ConvertTo-Json -InputObject $commands -Compress
    }
    Set-Content -LiteralPath $script:pidPath -Value $PID -Encoding ASCII
    $ownerPaired = [bool]$script:ownerId
    $pairExpiry = [DateTime]::MinValue
    $pairingActive = $false
    if (-not $ownerPaired -and $config.PairingExpiresUtc -and [DateTime]::TryParse(
        [string]$config.PairingExpiresUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$pairExpiry
    )) {
        $pairingActive = $pairExpiry.ToUniversalTime() -gt [DateTime]::UtcNow
    }
    if (-not $ownerPaired -and -not $pairingActive) {
        throw 'Владелец не сопряжён или код привязки истёк. Выпустите новый код в PC-PersonalControl и запустите бота снова.'
    }
    Write-BotLog ('Бот запущен; имя: ' + [string]$bot.username + '; требуется привязка владельца: ' + (-not $ownerPaired) + '.')
    if ($ownerPaired) {
        try {
            Send-WebAppReplyKeyboard -ChatId ([long]$script:ownerId)
            Write-BotLog 'Обновлённое меню управления отправлено привязанному владельцу.'
        } catch {
            Write-BotLog ('Не удалось отправить владельцу обновлённое меню: ' + $_.Exception.Message)
        }
    }

    while (-not (Test-Path -LiteralPath $script:stopPath)) {
        try {
            Invoke-DailyChatCleanup
            $body = @{
                offset = $script:updateOffset.ToString()
                timeout = '20'
                allowed_updates = '["message","callback_query"]'
            }
            $updates = @(Invoke-TelegramApi -Method 'getUpdates' -Body $body)
            Invoke-DailyChatCleanup
            foreach ($update in $updates) {
                $script:updateOffset = [long]$update.update_id + 1
                $message = $update.message
                $callback = $update.callback_query
                $fromId = if ($callback) { [string]$callback.from.id } elseif ($message) { [string]$message.from.id } else { '' }
                $chatId = if ($callback) { [string]$callback.message.chat.id } elseif ($message) { [string]$message.chat.id } else { '' }
                $chatType = if ($callback) { [string]$callback.message.chat.type } elseif ($message) { [string]$message.chat.type } else { '' }

                if (-not $script:ownerId) {
                    if ($message -and [string]$message.text -match '^/pair(?:@\w+)?\s+([A-Fa-f0-9]{10})$') {
                        $pairCode = $Matches[1]
                        if (Register-PairedOwner -PairCode $pairCode -FromId $fromId -ChatId $chatId -ChatType $chatType) {
                            Send-BotMessage -ChatId ([long]$chatId) -Text '✅ Этот Telegram-аккаунт привязан как единственный владелец. Теперь управление доступно только в вашем личном чате.'
                            Send-WebAppReplyKeyboard -ChatId ([long]$chatId)
                            Write-BotLog ('Владелец успешно сопряжён: ' + $fromId + '.')
                        } else {
                            Write-BotLog ('Отклонён неверный, просроченный или непубличный код привязки.')
                        }
                    }
                    continue
                }

                if ($fromId -ne $script:ownerId -or $chatId -ne $script:ownerId -or $chatType -ne 'private') {
                    if ($callback) {
                        Answer-Callback -CallbackId ([string]$callback.id) -Text 'Доступ запрещён.'
                    }
                    continue
                }

                if ($message -and $message.message_id) {
                    Add-ChatCleanupMessage -ChatId ([long]$chatId) -MessageId ([long]$message.message_id)
                } elseif ($callback -and $callback.message.message_id) {
                    Add-ChatCleanupMessage -ChatId ([long]$chatId) -MessageId ([long]$callback.message.message_id)
                }

                if ($message -and $message.web_app_data) {
                    try {
                        $webAppPayload = ConvertFrom-Json -InputObject ([string]$message.web_app_data.data)
                        $webAppAction = [string]$webAppPayload.action
                        if ($webAppAction -notin @('status', 'wake', 'shutdown', 'restart', 'sleep', 'lock', 'timer', 'cancel', 'volume_up', 'volume_down', 'volume_set', 'volume_status', 'mute', 'unmute', 'play_pause', 'previous', 'next')) {
                            throw 'Неизвестное действие панели.'
                        }
                        if ($webAppAction -eq 'status') {
                            Send-BotMessage -ChatId ([long]$chatId) -Text (Get-DeviceStatus) -Keyboard (Get-MainKeyboard)
                        } elseif ($webAppAction -eq 'wake') {
                            if ($script:targetMac -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
                                throw 'Wake-on-LAN не настроен. Сначала задайте MAC-адрес в PC-PersonalControl.'
                            }
                            Send-WakePacket -MacAddress $script:targetMac
                            Send-BotMessage -ChatId ([long]$chatId) -Text ('🌅 Wake-on-LAN отправлен на ' + $script:targetMac + '.')
                            Write-BotLog ('Владелец отправил Wake-on-LAN на ' + $script:targetMac + '.')
                        } elseif ($webAppAction -in @('shutdown', 'restart')) {
                            Invoke-ImmediatePowerAction -Action $webAppAction -ChatId ([long]$chatId)
                        } elseif ($webAppAction -in @('sleep', 'lock')) {
                            Invoke-SessionAction -Action $webAppAction -ChatId ([long]$chatId)
                        } elseif ($webAppAction -in @('volume_up', 'volume_down', 'volume_status', 'mute', 'unmute')) {
                            Invoke-VolumeAction -Action $webAppAction -ChatId ([long]$chatId)
                        } elseif ($webAppAction -eq 'volume_set') {
                            $volumeText = [string]$webAppPayload.value
                            if ($volumeText -notmatch '^(100|[1-9]?\d)$') {
                                throw 'Укажите целый уровень громкости от 0 до 100%.'
                            }
                            Invoke-VolumeAction -Action 'volume_set' -Percent ([int]$volumeText) -ChatId ([long]$chatId)
                        } elseif ($webAppAction -in @('play_pause', 'previous', 'next')) {
                            Invoke-MediaAction -Action $webAppAction -ChatId ([long]$chatId)
                        } elseif ($webAppAction -eq 'timer') {
                            $script:awaitingTimerInput = @{ ChatId = [long]$chatId; Expires = (Get-Date).AddMinutes(10) }
                            Send-BotMessage -ChatId ([long]$chatId) -Text '⏲ Напишите через сколько выключить ПК: например «30 секунд», «15 мин», «2 часа», «1 день» или «1ч 30м». Напишите «отмена», чтобы выйти.'
                        } else {
                            Stop-ShutdownTimer -ChatId ([long]$chatId)
                        }
                    } catch {
                        Send-BotMessage -ChatId ([long]$chatId) -Text ('Не удалось выполнить запрос панели: ' + $_.Exception.Message) -Keyboard (Get-MainKeyboard)
                        Write-BotLog ('Ошибка запроса Mini App: ' + $_.Exception.Message)
                    }
                    continue
                }

                if ($callback) {
                    $data = [string]$callback.data
                    switch -Regex ($data) {
                        '^ask:wake$' { $data = 'wake'; break }
                        '^ask:shutdown$' { $data = 'shutdown'; break }
                        '^ask:restart$' { $data = 'restart'; break }
                    }
                    Answer-Callback -CallbackId ([string]$callback.id) -Text 'Выполняю…'
                    try {
                        if ($data -eq 'menu') {
                            Send-BotMessage -ChatId ([long]$chatId) -Text 'Выберите нужное действие:' -Keyboard (Get-MainKeyboard)
                        } elseif ($data -eq 'status') {
                            Send-BotMessage -ChatId ([long]$chatId) -Text (Get-DeviceStatus) -Keyboard (Get-MainKeyboard)
                        } elseif ($data -eq 'wake') {
                            if ($script:targetMac -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
                                throw 'Wake-on-LAN не настроен. Укажите MAC-адрес устройства в PC-PersonalControl.'
                            }
                            Send-WakePacket -MacAddress $script:targetMac
                            Send-BotMessage -ChatId ([long]$chatId) -Text ('🌅 Wake-on-LAN отправлен на ' + $script:targetMac + '.')
                            Write-BotLog ('Владелец отправил Wake-on-LAN на ' + $script:targetMac + '.')
                        } elseif ($data -in @('shutdown', 'restart')) {
                            Invoke-ImmediatePowerAction -Action $data -ChatId ([long]$chatId)
                        } elseif ($data -in @('sleep', 'lock')) {
                            Invoke-SessionAction -Action $data -ChatId ([long]$chatId)
                        } elseif ($data -in @('volume_up', 'volume_down', 'volume_status', 'mute', 'unmute')) {
                            Invoke-VolumeAction -Action $data -ChatId ([long]$chatId)
                        } elseif ($data -eq 'volume_set') {
                            Request-VolumeInput -ChatId ([long]$chatId)
                        } elseif ($data -in @('play_pause', 'previous', 'next')) {
                            Invoke-MediaAction -Action $data -ChatId ([long]$chatId)
                        } elseif ($data -eq 'timer') {
                            $script:awaitingTimerInput = @{ ChatId = [long]$chatId; Expires = (Get-Date).AddMinutes(10) }
                            Send-BotMessage -ChatId ([long]$chatId) -Text '⏲ Напишите через сколько выключить ПК: например «30 секунд», «15 мин», «2 часа», «1 день» или «1ч 30м». Напишите «отмена», чтобы выйти.'
                        } elseif ($data -eq 'cancel') {
                            Stop-ShutdownTimer -ChatId ([long]$chatId)
                        } else {
                            Send-BotMessage -ChatId ([long]$chatId) -Text 'Неизвестная кнопка. Откройте меню командой /start.' -Keyboard (Get-MainKeyboard)
                        }
                    } catch {
                        Send-BotMessage -ChatId ([long]$chatId) -Text ('⚠️ ' + $_.Exception.Message) -Keyboard (Get-MainKeyboard)
                        Write-BotLog ('Команда завершилась ошибкой: ' + $_.Exception.Message)
                    }
                    continue
                }

                $text = ([string]$message.text).Trim()
                $buttonCommands = @{
                    '📊 Статус ПК' = '/status'
                    '🌅 Разбудить ПК' = '/wake'
                    '🌙 Спящий режим' = '/sleep'
                    '🔒 Заблокировать' = '/lock'
                    '⏻ Выключить ПК' = '/shutdown'
                    '🔄 Перезагрузить ПК' = '/restart'
                    '⏲ Таймер выключения' = '/timer'
                    '✖️ Отменить таймер' = '/cancel'
                    '🔊 Громкость +' = '/volume_up'
                    '🔉 Громкость -' = '/volume_down'
                    '🔇 Mute' = '/mute'
                    '🔊 Включить звук' = '/unmute'
                    '🎚 Своя громкость' = '/volume'
                    '📊 Статус звука' = '/volume_status'
                    '⏯ Пуск / пауза' = '/play_pause'
                    '⏮ Предыдущий трек' = '/previous'
                    '⏭ Следующий трек' = '/next'
                }
                if ($buttonCommands.ContainsKey($text)) {
                    $text = $buttonCommands[$text]
                }
                if ($script:awaitingVolumeInput -and $text -match '^/') {
                    $script:awaitingVolumeInput = $null
                }
                if ($script:awaitingVolumeInput -and
                    $script:awaitingVolumeInput.ChatId -eq [long]$chatId -and
                    $script:awaitingVolumeInput.Expires -ge (Get-Date) -and
                    $text -notmatch '^/') {
                    if ($text -match '^(?<percent>100|[1-9]?\d)\s*%?$') {
                        try {
                            Invoke-VolumeAction -Action 'volume_set' -Percent ([int]$Matches['percent']) -ChatId ([long]$chatId)
                            $script:awaitingVolumeInput = $null
                        } catch {
                            $script:awaitingVolumeInput.Expires = (Get-Date).AddMinutes(5)
                            Write-BotLog ('Не удалось установить громкость: ' + $_.Exception.Message)
                            Send-BotMessage -ChatId ([long]$chatId) -Text ('⚠️ Не удалось установить громкость: ' + $_.Exception.Message)
                        }
                    } else {
                        $script:awaitingVolumeInput.Expires = (Get-Date).AddMinutes(5)
                        Send-BotMessage -ChatId ([long]$chatId) -Text 'Введите целое число от 0 до 100, например 45%.'
                    }
                    continue
                }
                if ($script:awaitingTimerInput -and
                    $script:awaitingTimerInput.ChatId -eq [long]$chatId -and
                    $script:awaitingTimerInput.Expires -ge (Get-Date) -and
                    $text -notmatch '^/') {
                    if ($text -match '^(?i:отмена|cancel)$') {
                        $script:awaitingTimerInput = $null
                        Send-BotMessage -ChatId ([long]$chatId) -Text 'Настройка таймера отменена.' -Keyboard (Get-MainKeyboard)
                    } else {
                        try {
                            Start-ShutdownTimer -DurationText $text -ChatId ([long]$chatId)
                            $script:awaitingTimerInput = $null
                            Send-BotMessage -ChatId ([long]$chatId) -Text 'Меню управления:' -Keyboard (Get-MainKeyboard)
                        } catch {
                            $script:awaitingTimerInput.Expires = (Get-Date).AddMinutes(10)
                            Send-BotMessage -ChatId ([long]$chatId) -Text ('⚠️ ' + $_.Exception.Message + "`nПопробуйте ещё раз или напишите «отмена».")
                        }
                    }
                    continue
                }

                try {
                    if ($text -match '^/(?:start|menu)(?:@\w+)?$') {
                        Send-WebAppReplyKeyboard -ChatId ([long]$chatId)
                    } elseif ($text -match '^/status(?:@\w+)?$') {
                        Send-BotMessage -ChatId ([long]$chatId) -Text (Get-DeviceStatus) -Keyboard (Get-MainKeyboard)
                    } elseif ($text -match '^/timer(?:@\w+)?$') {
                        $script:awaitingTimerInput = @{ ChatId = [long]$chatId; Expires = (Get-Date).AddMinutes(10) }
                        Send-BotMessage -ChatId ([long]$chatId) -Text '⏲ Напишите через сколько выключить ПК: например «30 секунд», «15 мин», «2 часа», «1 день» или «1ч 30м». Напишите «отмена», чтобы выйти.'
                    } elseif ($text -match '^/cancel(?:@\w+)?$') {
                        Stop-ShutdownTimer -ChatId ([long]$chatId)
                    } elseif ($text -match '^/shutdown(?:@\w+)?$') {
                        Invoke-ImmediatePowerAction -Action 'shutdown' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/restart(?:@\w+)?$') {
                        Invoke-ImmediatePowerAction -Action 'restart' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/sleep(?:@\w+)?$') {
                        Invoke-SessionAction -Action 'sleep' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/lock(?:@\w+)?$') {
                        Invoke-SessionAction -Action 'lock' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/wake(?:@\w+)?$') {
                        if ($script:targetMac -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
                            throw 'Wake-on-LAN не настроен. Укажите MAC-адрес устройства в PC-PersonalControl.'
                        }
                        Send-WakePacket -MacAddress $script:targetMac
                        Send-BotMessage -ChatId ([long]$chatId) -Text '🌅 Команда Wake-on-LAN отправлена.'
                    } elseif ($text -match '^/volume_up(?:@\w+)?$') {
                        Invoke-VolumeAction -Action 'volume_up' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/volume_down(?:@\w+)?$') {
                        Invoke-VolumeAction -Action 'volume_down' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/volume(?:@\w+)?$') {
                        Request-VolumeInput -ChatId ([long]$chatId)
                    } elseif ($text -match '^/mute(?:@\w+)?$') {
                        Invoke-VolumeAction -Action 'mute' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/unmute(?:@\w+)?$') {
                        Invoke-VolumeAction -Action 'unmute' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/volume_status(?:@\w+)?$') {
                        Invoke-VolumeAction -Action 'volume_status' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/play_pause(?:@\w+)?$') {
                        Invoke-MediaAction -Action 'play_pause' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/previous(?:@\w+)?$') {
                        Invoke-MediaAction -Action 'previous' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/next(?:@\w+)?$') {
                        Invoke-MediaAction -Action 'next' -ChatId ([long]$chatId)
                    } elseif ($text -match '^/help(?:@\w+)?$') {
                        Send-WebAppReplyKeyboard -ChatId ([long]$chatId)
                        Send-BotMessage -ChatId ([long]$chatId) -Text 'Команды:`n/status — состояние ПК`n/timer — задать таймер выключения (до 10 лет)`n/cancel — отменить таймер`n/shutdown — выключить`n/restart — перезагрузить`n/sleep — спящий режим`n/lock — блокировка Windows`n/wake — Wake-on-LAN`n/volume_up и /volume_down — громкость ±2%`n/volume — задать уровень громкости 0–100%`n/volume_status — проверить громкость и звук`n/mute — переключить звук`n/unmute — включить звук`n/play_pause, /previous, /next — управление воспроизведением`n/menu — показать клавиатуру`n`nДоступ только владельцу в личном чате.' -Keyboard (Get-MainKeyboard)
                    } elseif ($text -match '^/pair(?:@\w+)?\s+([A-Fa-f0-9]{10})$') {
                        Send-BotMessage -ChatId ([long]$chatId) -Text 'Бот уже привязан. Повторное сопряжение отклонено.'
                    } else {
                        Send-BotMessage -ChatId ([long]$chatId) -Text 'Неизвестная команда. Используйте кнопки ниже.' -Keyboard (Get-MainKeyboard)
                    }
                } catch {
                    $errorMessage = $_.Exception.Message
                    Write-BotLog ('Ошибка текстовой команды: ' + $errorMessage)
                    Send-BotMessage -ChatId ([long]$chatId) -Text ('⚠️ Не удалось выполнить команду: ' + $errorMessage)
                }
            }
        } catch {
            Write-BotLog ('Ошибка цикла: ' + $_.Exception.Message)
            Start-Sleep -Seconds 3
        }
    }
    Write-BotLog 'Получен запрос на штатную остановку.'
} catch {
    Write-BotLog ('Бот остановлен из-за ошибки: ' + $_.Exception.Message)
    throw
} finally {
    if (Test-Path -LiteralPath $script:pidPath) {
        $runningPid = Get-Content -LiteralPath $script:pidPath -Raw -ErrorAction SilentlyContinue
        if ([string]$runningPid -eq [string]$PID) {
            Remove-Item -LiteralPath $script:pidPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $script:instanceMutex) {
        $script:instanceMutex.Dispose()
    }
    if ($script:botToken) {
        $script:botToken = $null
    }
}

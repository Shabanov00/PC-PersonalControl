$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$libraryDirectory = Join-Path $root 'lib'
$outputPath = Join-Path $root 'PC-PersonalControl.exe'
$scriptPath = Join-Path $root 'PC-PersonalControl.ps1'
$workerPath = Join-Path $root 'TelegramBotWorker.ps1'
$iconPath = Join-Path $root 'PC-PersonalControl.ico'

$runtimeHashes = @{
    'PC-PersonalControl.ps1' = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
    'TelegramBotWorker.ps1' = (Get-FileHash -LiteralPath $workerPath -Algorithm SHA256).Hash
    'LibreHardwareMonitorLib.dll' = 'D98DD015CA25AB680FC05030F503700C89B8E9E3DA2450F2D8D07B25116453CB'
    'HidSharp.dll' = '61EB2E22A5620D789A23D389F1AF9D38FAFF4D85F46ADEDBC28FB22CFEC61BF9'
    'System.Management.dll' = 'BD5F1996598212B6532957570C6C8C699BE4C808E59547EC0AFE76F4CE39B0B9'
    'System.CodeDom.dll' = 'D4047CDC0C372B06AFC9CBED39B717FAC18DCED723E5851806A19F1BF42DE1A3'
}

foreach ($name in $runtimeHashes.Keys) {
    $path = if ($name -eq 'PC-PersonalControl.ps1') {
        $scriptPath
    } elseif ($name -eq 'TelegramBotWorker.ps1') {
        $workerPath
    } else {
        Join-Path $libraryDirectory $name
    }
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Не найден компонент $name. Сначала запустите PC-PersonalControl.ps1, чтобы загрузить библиотеку датчиков."
    }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actualHash -ne $runtimeHashes[$name]) {
        throw "Контрольная сумма $name не совпадает. Сборка остановлена."
    }
}

Add-Type -AssemblyName System.Drawing
$bitmap = New-Object System.Drawing.Bitmap(64, 64)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$pngStream = New-Object System.IO.MemoryStream
try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $background = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 27, 40))
    $accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(89, 205, 255))
    $center = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(232, 244, 255))
    try {
        $graphics.FillEllipse($background, 2, 2, 60, 60)
        foreach ($angle in @(0, 120, 240)) {
            $graphics.ResetTransform()
            $graphics.TranslateTransform(32, 32)
            $graphics.RotateTransform([single]$angle)
            $graphics.FillPie($accent, -8, -25, 25, 28, 190, 210)
        }
        $graphics.ResetTransform()
        $graphics.FillEllipse($center, 25, 25, 14, 14)
        $bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $background.Dispose()
        $accent.Dispose()
        $center.Dispose()
    }

    $pngBytes = $pngStream.ToArray()
    $iconStream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($iconStream)
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]1)
        $writer.Write([byte]64)
        $writer.Write([byte]64)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$pngBytes.Length)
        $writer.Write([UInt32]22)
        $writer.Write($pngBytes)
        [IO.File]::WriteAllBytes($iconPath, $iconStream.ToArray())
    } finally {
        $writer.Dispose()
        $iconStream.Dispose()
    }
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
    $pngStream.Dispose()
}

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows.Forms;

internal static class PCPersonalControlLauncher
{
    private static readonly Dictionary<string, string> Hashes =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "PC-PersonalControl.ps1", "__SCRIPT_HASH__" },
            { "TelegramBotWorker.ps1", "__WORKER_HASH__" },
            { "LibreHardwareMonitorLib.dll", "D98DD015CA25AB680FC05030F503700C89B8E9E3DA2450F2D8D07B25116453CB" },
            { "HidSharp.dll", "61EB2E22A5620D789A23D389F1AF9D38FAFF4D85F46ADEDBC28FB22CFEC61BF9" },
            { "System.Management.dll", "BD5F1996598212B6532957570C6C8C699BE4C808E59547EC0AFE76F4CE39B0B9" },
            { "System.CodeDom.dll", "D4047CDC0C372B06AFC9CBED39B717FAC18DCED723E5851806A19F1BF42DE1A3" }
        };

    [STAThread]
    private static void Main(string[] args)
    {
        try
        {
            string restoreArguments = ParseArguments(args);
            string root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FanPilot", "Runtime");
            string libraries = Path.Combine(root, "lib");
            Directory.CreateDirectory(libraries);

            Assembly assembly = Assembly.GetExecutingAssembly();
            foreach (KeyValuePair<string, string> item in Hashes)
            {
                string resource = FindResource(assembly, item.Key);
                string destination = item.Key.Equals("PC-PersonalControl.ps1", StringComparison.OrdinalIgnoreCase) ||
                    item.Key.Equals("TelegramBotWorker.ps1", StringComparison.OrdinalIgnoreCase)
                    ? Path.Combine(root, item.Key)
                    : Path.Combine(libraries, item.Key);
                ExtractVerified(assembly, resource, destination, item.Value);
            }

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            string script = Path.Combine(root, "PC-PersonalControl.ps1");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = powershell;
            start.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" +
                script + "\"" + restoreArguments;
            start.WorkingDirectory = root;
            start.UseShellExecute = true;
            start.Verb = "runas";
            Process.Start(start);
        }
        catch (System.ComponentModel.Win32Exception ex)
        {
            if (ex.NativeErrorCode != 1223)
                ShowError(ex.Message);
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private static string ParseArguments(string[] args)
    {
        if (args.Length == 0)
            return String.Empty;

        if (args.Length == 1 && args[0].Equals("-RestoreDefaults", StringComparison.OrdinalIgnoreCase))
            return " -RestoreDefaults";

        if (args.Length == 3 &&
            args[0].Equals("-RestoreDefaults", StringComparison.OrdinalIgnoreCase) &&
            args[1].Equals("-CloseProcessId", StringComparison.OrdinalIgnoreCase))
        {
            int processId;
            if (Int32.TryParse(args[2], out processId) && processId > 0)
                return " -RestoreDefaults -CloseProcessId " + processId.ToString();
        }

        throw new ArgumentException("Допустимые аргументы: -RestoreDefaults [-CloseProcessId PID].");
    }

    private static string FindResource(Assembly assembly, string fileName)
    {
        foreach (string name in assembly.GetManifestResourceNames())
        {
            if (name.EndsWith(fileName, StringComparison.OrdinalIgnoreCase))
                return name;
        }
        throw new FileNotFoundException("В приложении отсутствует встроенный компонент " + fileName + ".");
    }

    private static void ExtractVerified(Assembly assembly, string resourceName, string destination, string expectedHash)
    {
        using (Stream input = assembly.GetManifestResourceStream(resourceName))
        using (MemoryStream memory = new MemoryStream())
        {
            if (input == null)
                throw new FileNotFoundException("Не удалось прочитать компонент " + resourceName + ".");
            input.CopyTo(memory);
            byte[] bytes = memory.ToArray();
            string actualHash;
            using (SHA256 sha = SHA256.Create())
            {
                byte[] digest = sha.ComputeHash(bytes);
                actualHash = BitConverter.ToString(digest).Replace("-", String.Empty);
            }
            if (!actualHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Контрольная сумма встроенного компонента " +
                    Path.GetFileName(destination) + " не совпадает.");

            if (File.Exists(destination))
            {
                using (FileStream existing = File.OpenRead(destination))
                using (SHA256 sha = SHA256.Create())
                {
                    string existingHash = BitConverter.ToString(sha.ComputeHash(existing)).Replace("-", String.Empty);
                    if (existingHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
                        return;
                }
                File.Delete(destination);
            }

            string temporary = destination + ".tmp";
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, destination);
        }
    }

    private static void ShowError(string message)
    {
        MessageBox.Show(message, "PC-PersonalControl — ошибка запуска",
            MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
'@

$source = $source.Replace('__SCRIPT_HASH__', $runtimeHashes['PC-PersonalControl.ps1'])
$source = $source.Replace('__WORKER_HASH__', $runtimeHashes['TelegramBotWorker.ps1'])
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$parameters = New-Object System.CodeDom.Compiler.CompilerParameters
$parameters.GenerateExecutable = $true
$parameters.GenerateInMemory = $false
$parameters.OutputAssembly = $outputPath
$parameters.CompilerOptions = '/target:winexe /platform:x64 /optimize+ /win32icon:"' + $iconPath + '"'
$parameters.ReferencedAssemblies.Add('System.dll') | Out-Null
$parameters.ReferencedAssemblies.Add('System.Windows.Forms.dll') | Out-Null
$null = $parameters.EmbeddedResources.Add($scriptPath)
$null = $parameters.EmbeddedResources.Add($workerPath)
foreach ($name in @('LibreHardwareMonitorLib.dll', 'HidSharp.dll', 'System.Management.dll', 'System.CodeDom.dll')) {
    $null = $parameters.EmbeddedResources.Add((Join-Path $libraryDirectory $name))
}

$results = $provider.CompileAssemblyFromSource($parameters, $source)
if ($results.Errors.HasErrors) {
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    $messages = @($results.Errors | Where-Object { -not $_.IsWarning } | ForEach-Object {
        "Строка $($_.Line): $($_.ErrorText)"
    })
    throw ("Не удалось собрать PC-PersonalControl.exe:`r`n" + ($messages -join "`r`n"))
}

Write-Output "Готово: $outputPath"
Write-Output "SHA256: $((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash)"

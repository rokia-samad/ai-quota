param([string]$Executable = (Join-Path $PSScriptRoot '../../artifacts/windows/win-x64/AIQuota.exe'))
$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$isolated = Join-Path ([IO.Path]::GetTempPath()) ('aiquota-smoke-' + [guid]::NewGuid().ToString('N'))
function Invoke-Quota([string]$Argument, [string]$InputJson = '', [string]$Command = $Executable) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Command
    $info.Arguments = $Argument
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['LOCALAPPDATA'] = $isolated
    $info.EnvironmentVariables['AIQUOTA_DATA_DIR'] = (Join-Path $isolated 'AIQuota')
    $process = [Diagnostics.Process]::Start($info)
    $process.StandardInput.Write($InputJson)
    $process.StandardInput.Close()
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Diagnostic timeout' }
    $result = @{ Code = $process.ExitCode; Output = $output.GetAwaiter().GetResult(); Error = $errors.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}
try {
    $reset = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
    $inputJson = '{"session_id":"must-not-be-stored","rate_limits":{"five_hour":{"used_percentage":0,"resets_at":' + $reset + '},"seven_day":{"used_percentage":100}}}'
    $capture = Invoke-Quota '--claude-statusline' $inputJson
    if ($capture.Code -ne 0) { throw "Claude capture failed (exit $($capture.Code)): $($capture.Output) $($capture.Error)" }
    $script = '$OutputEncoding = [Text.UTF8Encoding]::new($false); [Console]::InputEncoding = $OutputEncoding; $data = [Console]::In.ReadToEnd(); $data | & ''' + $Executable.Replace("'", "''") + ''' --claude-statusline'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $wrapped = Invoke-Quota "-NoProfile -NonInteractive -EncodedCommand $encoded" $inputJson 'powershell.exe'
    if ($wrapped.Code -ne 0 -or -not $wrapped.Output.Contains('Claude')) { throw 'PowerShell status line wrapper failed' }
    $cache = Join-Path $isolated 'AIQuota/claude-usage.json'
    if ((Get-Content -LiteralPath $cache -Raw).Contains('must-not-be-stored')) { throw 'Unexpected session data in cache' }
    $diagnose = Invoke-Quota '--diagnose-claude'
    if ($diagnose.Code -ne 0 -or -not $diagnose.Output.Contains('100 % disponibles') -or -not $diagnose.Output.Contains('0 % disponibles')) { throw 'Claude diagnostics failed' }
    $invalid = Invoke-Quota '--claude-statusline' 'invalid'
    if ($invalid.Code -ne 1) { throw 'Invalid input accepted' }
    $after = Invoke-Quota '--diagnose-claude'
    if ($after.Code -ne 1) { throw 'Invalid cache not rejected' }
    Write-Output 'PASS: published WinExe stdin/stdout, PowerShell wrapper, Claude 0/100, reset, sanitized cache and invalid input.'
}
finally {
    # Delete only this script's own unique temporary directory after checking its parent.
    $resolved = [IO.Path]::GetFullPath($isolated)
    if ([IO.Path]::GetDirectoryName($resolved) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and (Split-Path $resolved -Leaf).StartsWith('aiquota-smoke-')) {
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}

[CmdletBinding()]
param(
    [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
    [string]$With,

    [ValidateSet('review', 'translate', 'translate-review')]
    [string]$Mode = 'translate',

    [string]$ReportFile,

    [string]$ReportId,

    [switch]$UseLastCodexSession = $true,

    [string]$CodexSessionId,

    [string]$Base,

    [string]$OutFile,

    [int]$ProviderTimeoutSeconds = 90,

    [int]$MaxCodexReportChars = 12000,

    [int]$MaxReportChars = 20000,

    [int]$MaxDiffChars = 80000,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$polishSettingsPath = Join-Path $PSScriptRoot 'codex-polish-settings.ps1'
if (-not (Test-Path -LiteralPath $polishSettingsPath -PathType Leaf)) {
    throw "找不到润色配置脚本: $polishSettingsPath"
}

. $polishSettingsPath

if ([string]::IsNullOrWhiteSpace($With)) {
    $With = Get-CodexPolishDefaultProvider
}

if ($UseLastCodexSession -and -not [string]::IsNullOrWhiteSpace($CodexSessionId)) {
    throw '不能同时传入 -UseLastCodexSession 和 -CodexSessionId。'
}

if (-not [string]::IsNullOrWhiteSpace($ReportId) -and -not [string]::IsNullOrWhiteSpace($ReportFile)) {
    throw '不能同时传入 -ReportId 和 -ReportFile。'
}

function Get-FileText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [int]$MaxChars
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到文件: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($content.Length -le $MaxChars) {
        return $content
    }

    return $content.Substring(0, $MaxChars) + "`n`n[内容已截断，原文更长]"
}

function Get-OptionalFileText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [int]$MaxChars
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    return Get-FileText -Path $Path -MaxChars $MaxChars
}

function Get-PolishBundlePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundleId
    )

    $bundleRoot = Get-PolishRootDirectory
    $bundleDirectory = Join-Path $bundleRoot $BundleId

    return [pscustomobject]@{
        Root = $bundleRoot
        Directory = $bundleDirectory
        ReportFile = Join-Path $bundleDirectory 'report.md'
        ContextFile = Join-Path $bundleDirectory 'context.md'
        MetaFile = Join-Path $bundleDirectory 'meta.json'
        ResultFile = Join-Path $bundleDirectory 'result.md'
    }
}

function Get-PowerShellExecutablePath {
    $candidates = New-Object System.Collections.Generic.List[string]

    $currentPwsh = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $currentPwsh -PathType Leaf) {
        [void]$candidates.Add($currentPwsh)
    }

    foreach ($programFilesRoot in @(
        $env:ProgramFiles,
        $env:ProgramW6432,
        ${env:ProgramFiles(x86)},
        'C:\Program Files',
        'C:\Program Files (x86)'
    )) {
        if ([string]::IsNullOrWhiteSpace($programFilesRoot)) {
            continue
        }

        $candidate = Join-Path $programFilesRoot 'PowerShell\7\pwsh.exe'
        [void]$candidates.Add($candidate)
    }

    try {
        $currentProcessPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not [string]::IsNullOrWhiteSpace($currentProcessPath)) {
            [void]$candidates.Add($currentProcessPath)
        }
    }
    catch {
    }

    try {
        $pwshCommand = Get-Command pwsh.exe -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $pwshCommand) {
            if (-not [string]::IsNullOrWhiteSpace([string]$pwshCommand.Path)) {
                [void]$candidates.Add([string]$pwshCommand.Path)
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$pwshCommand.Source)) {
                [void]$candidates.Add([string]$pwshCommand.Source)
            }
        }
    }
    catch {
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($windowsRoot in @($env:WINDIR, 'C:\Windows')) {
        if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
            continue
        }

        $legacyPowerShell = Join-Path $windowsRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $legacyPowerShell -PathType Leaf) {
            return (Resolve-Path -LiteralPath $legacyPowerShell).Path
        }
    }

    throw '找不到可用的 PowerShell 可执行文件。'
}

function Get-CommandFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    try {
        $command = Get-Command $CommandName -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        return ''
    }

    foreach ($propertyName in @('Path', 'Source', 'Definition')) {
        $property = $command.PSObject.Properties[$propertyName]
        if ($null -eq $property) {
            continue
        }

        $value = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        if (Test-Path -LiteralPath $value -PathType Leaf) {
            return (Resolve-Path -LiteralPath $value).Path
        }
    }

    return ''
}

function Get-DelimitedPathEntries {
    param(
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return @()
    }

    return @(
        $PathValue.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) |
            ForEach-Object { $_.Trim().Trim('"') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Get-KiroCliExecutablePath {
    $candidateFiles = New-Object System.Collections.Generic.List[string]

    foreach ($commandName in (Get-CodexPolishProviderCommandNames -Provider 'kiro')) {
        $commandPath = Get-CommandFilePath -CommandName $commandName
        if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
            [void]$candidateFiles.Add($commandPath)
        }
    }

    foreach ($envVariableName in @('KIRO_CLI_EXE', 'KIRO_CLI_PATH')) {
        $envValue = [Environment]::GetEnvironmentVariable($envVariableName)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            [void]$candidateFiles.Add($envValue)
        }
    }

    foreach ($localAppDataRoot in @(
        $env:LOCALAPPDATA,
        (Join-Path (Get-UserHomeDirectory) 'AppData\Local')
    )) {
        if ([string]::IsNullOrWhiteSpace($localAppDataRoot)) {
            continue
        }

        [void]$candidateFiles.Add((Join-Path $localAppDataRoot 'Kiro-Cli\kiro-cli.exe'))
        [void]$candidateFiles.Add((Join-Path $localAppDataRoot 'Kiro-Cli\kiro-cli.cmd'))
    }

    foreach ($programFilesRoot in @(
        $env:ProgramFiles,
        $env:ProgramW6432,
        ${env:ProgramFiles(x86)},
        'C:\Program Files',
        'C:\Program Files (x86)'
    )) {
        if ([string]::IsNullOrWhiteSpace($programFilesRoot)) {
            continue
        }

        [void]$candidateFiles.Add((Join-Path $programFilesRoot 'Kiro-Cli\kiro-cli.exe'))
        [void]$candidateFiles.Add((Join-Path $programFilesRoot 'Kiro-Cli\kiro-cli.cmd'))
    }

    foreach ($pathValue in @(
        [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User),
        [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine),
        $env:Path
    )) {
        foreach ($pathEntry in (Get-DelimitedPathEntries -PathValue $pathValue)) {
            [void]$candidateFiles.Add((Join-Path $pathEntry 'kiro-cli.exe'))
            [void]$candidateFiles.Add((Join-Path $pathEntry 'kiro-cli.cmd'))
        }
    }

    foreach ($candidateFile in ($candidateFiles | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidateFile)) {
            continue
        }

        if (Test-Path -LiteralPath $candidateFile -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidateFile).Path
        }
    }

    return ''
}

function Remove-AnsiEscapeSequences {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $ansiCsiPattern = [string]([char]27) + '\[[0-9;?]*[ -/]*[@-~]'
    $withoutCsi = [regex]::Replace($Text, $ansiCsiPattern, '')
    $ansiOscPattern = [string]([char]27) + '\][^\a]*(?:\a|' + [string]([char]27) + '\\)'
    return [regex]::Replace($withoutCsi, $ansiOscPattern, '')
}

function Get-KiroFinalText {
    param(
        [string]$StdoutText,
        [string]$StderrText
    )

    $cleanStdoutText = Remove-AnsiEscapeSequences -Text $StdoutText
    $cleanStderrText = Remove-AnsiEscapeSequences -Text $StderrText
    $combinedText = @($cleanStdoutText.Trim(), $cleanStderrText.Trim()) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Join-String -Separator "`n"

    if ([string]::IsNullOrWhiteSpace($combinedText)) {
        return ''
    }

    $segments = [regex]::Split($combinedText, '(?m)^\s*>\s?')
    $candidateText = ($segments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($candidateText)) {
        $candidateText = $combinedText
    }

    $lines = $candidateText -split "`r?`n"
    $filteredLines = foreach ($line in $lines) {
        if ($line -match '^\s*▸ Credits:') { continue }
        if ($line -match '^\s*Reading file:') { continue }
        if ($line -match '^\s*✓\s+Successfully read') { continue }
        if ($line -match '^\s*-\s+Completed in ') { continue }
        $line
    }

    return (($filteredLines -join "`n").Trim())
}

function Get-SystemProxyUrl {
    try {
        $internetSettings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    }
    catch {
        return ''
    }

    if ([int]$internetSettings.ProxyEnable -ne 1) {
        return ''
    }

    $proxyServer = [string]$internetSettings.ProxyServer
    if ([string]::IsNullOrWhiteSpace($proxyServer)) {
        return ''
    }

    $selectedProxy = $proxyServer.Trim()
    if ($selectedProxy.Contains('=')) {
        $proxyEntries = @{}
        foreach ($entry in ($selectedProxy -split ';')) {
            if ([string]::IsNullOrWhiteSpace($entry) -or -not $entry.Contains('=')) {
                continue
            }

            $parts = $entry.Split('=', 2)
            $proxyEntries[$parts[0].Trim().ToLowerInvariant()] = $parts[1].Trim()
        }

        foreach ($scheme in @('https', 'http', 'socks', 'socks5')) {
            if ($proxyEntries.ContainsKey($scheme) -and -not [string]::IsNullOrWhiteSpace([string]$proxyEntries[$scheme])) {
                $selectedProxy = [string]$proxyEntries[$scheme]
                break
            }
        }
    }

    if ($selectedProxy -notmatch '^[a-z][a-z0-9+\-.]*://') {
        $selectedProxy = "http://$selectedProxy"
    }

    return $selectedProxy
}

function Initialize-ChildProcessEnvironment {
    $systemDirectory = [Environment]::SystemDirectory
    $windowsDirectory = ''

    if (-not [string]::IsNullOrWhiteSpace($systemDirectory)) {
        $windowsDirectory = Split-Path -Path $systemDirectory -Parent
    }

    if ([string]::IsNullOrWhiteSpace($windowsDirectory) -and (Test-Path -LiteralPath 'C:\Windows' -PathType Container)) {
        $windowsDirectory = 'C:\Windows'
    }

    if (-not [string]::IsNullOrWhiteSpace($windowsDirectory)) {
        if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
            $env:SystemRoot = $windowsDirectory
        }

        if ([string]::IsNullOrWhiteSpace($env:WINDIR)) {
            $env:WINDIR = $windowsDirectory
        }
    }

    if ([string]::IsNullOrWhiteSpace($env:ComSpec) -and -not [string]::IsNullOrWhiteSpace($systemDirectory)) {
        $commandProcessor = Join-Path $systemDirectory 'cmd.exe'
        if (Test-Path -LiteralPath $commandProcessor -PathType Leaf) {
            $env:ComSpec = $commandProcessor
        }
    }

    $systemProxyUrl = Get-SystemProxyUrl
    if (-not [string]::IsNullOrWhiteSpace($systemProxyUrl)) {
        foreach ($proxyVariableName in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
            if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($proxyVariableName))) {
                Set-Item -Path "Env:$proxyVariableName" -Value $systemProxyUrl
            }
        }
    }
}

function Get-ProviderLaunchInfo {
    param(
        [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
        [string]$Provider
    )

    $resolvedProvider = Resolve-CodexPolishProvider -Provider $Provider
    if ($resolvedProvider -eq 'kelivo') {
        return [pscustomobject]@{
            Provider = $resolvedProvider
            LaunchMode = 'api'
            ExecutablePath = ''
            PrefixArguments = @()
            EntryScriptPath = ''
        }
    }

    if ($resolvedProvider -eq 'kiro' -or $resolvedProvider -eq 'opencode') {
        $displayName = Get-CodexPolishProviderDisplayName -Provider $Provider
        $providerCliPath = ''
        if ($resolvedProvider -eq 'kiro') {
            $providerCliPath = Get-KiroCliExecutablePath
        }
        else {
            foreach ($commandName in (Get-CodexPolishProviderCommandNames -Provider $Provider)) {
                $providerCliPath = Get-CommandFilePath -CommandName $commandName
                if (-not [string]::IsNullOrWhiteSpace($providerCliPath)) {
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($providerCliPath)) {
            throw "找不到 $displayName CLI，请确认已安装 $displayName，并确保其命令可被当前进程发现。"
        }

        return [pscustomobject]@{
            Provider = $resolvedProvider
            LaunchMode = 'direct'
            ExecutablePath = $providerCliPath
            PrefixArguments = @()
            EntryScriptPath = ''
        }
    }

    $providerShimPath = ''
    foreach ($commandName in (Get-CodexPolishProviderCommandNames -Provider $Provider)) {
        $providerShimPath = Get-CommandFilePath -CommandName $commandName
        if (-not [string]::IsNullOrWhiteSpace($providerShimPath)) {
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($providerShimPath)) {
        throw "找不到 $Provider 的启动脚本，请确认对应 CLI 已正确安装。"
    }

    $providerBaseDirectory = Split-Path -Path $providerShimPath -Parent
    $nodeExecutable = Join-Path $providerBaseDirectory 'node.exe'
    if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)) {
        $nodeExecutable = Get-CommandFilePath -CommandName 'node.exe'
    }

    if ([string]::IsNullOrWhiteSpace($nodeExecutable)) {
        throw '找不到可用的 node.exe，请确认 Node.js 已正确安装。'
    }

    $entryScriptRelativePath = switch ($resolvedProvider) {
        'claude' { 'node_modules\@anthropic-ai\claude-code\cli.js' }
        'gemini' { 'node_modules\@google\gemini-cli\bundle\gemini.js' }
    }

    $entryScriptPath = Join-Path $providerBaseDirectory $entryScriptRelativePath
    if (-not (Test-Path -LiteralPath $entryScriptPath -PathType Leaf)) {
        throw "找不到 $Provider CLI 入口脚本: $entryScriptPath"
    }

    $prefixArguments = @()
    if ($resolvedProvider -eq 'gemini') {
        $prefixArguments += '--no-warnings=DEP0040'
    }

    return [pscustomobject]@{
        Provider = $resolvedProvider
        LaunchMode = 'node'
        ExecutablePath = (Resolve-Path -LiteralPath $nodeExecutable).Path
        EntryScriptPath = (Resolve-Path -LiteralPath $entryScriptPath).Path
        PrefixArguments = $prefixArguments
    }
}

function Invoke-KiroTranslator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,
        [string]$Model
    )

    $workspaceRoot = Get-WorkspaceRoot -AdditionalCandidates @((Get-Location).Path)
    $tempDirectory = Join-Path $workspaceRoot '.codex-temp'
    New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
    $tempPromptFile = Join-Path $tempDirectory ("kiro-polish-" + [guid]::NewGuid().ToString('N') + '.txt')

    try {
        Set-Content -LiteralPath $tempPromptFile -Value $PromptText -Encoding UTF8

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $ExecutablePath
        $startInfo.WorkingDirectory = (Get-Location).Path
        [void]$startInfo.ArgumentList.Add('chat')
        [void]$startInfo.ArgumentList.Add('--no-interactive')
        if (-not [string]::IsNullOrWhiteSpace($Model)) {
            [void]$startInfo.ArgumentList.Add('--model')
            [void]$startInfo.ArgumentList.Add($Model)
        }
        [void]$startInfo.ArgumentList.Add('--trust-tools')
        [void]$startInfo.ArgumentList.Add('fs_read')
        [void]$startInfo.ArgumentList.Add('--wrap')
        [void]$startInfo.ArgumentList.Add('never')
        [void]$startInfo.ArgumentList.Add("请读取文件 $tempPromptFile 的完整内容，并严格按其中的任务说明执行。直接输出最终结果，不要解释你的过程。")
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        try {
            [void]$process.Start()

            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()

            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try {
                    $process.Kill($true)
                }
                catch {
                    $process.Kill()
                }

                throw "调用 kiro 超时：${TimeoutSeconds} 秒内未返回。"
            }

            $stdoutTask.Wait()
            $stderrTask.Wait()

            $stdoutText = $stdoutTask.Result
            $stderrText = $stderrTask.Result
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        }
        finally {
            $process.Dispose()
        }
    }
    finally {
        Remove-Item -LiteralPath $tempPromptFile -Force -ErrorAction SilentlyContinue
    }

    $cleanStdoutText = Remove-AnsiEscapeSequences -Text $stdoutText
    $cleanStderrText = Remove-AnsiEscapeSequences -Text $stderrText
    $resultText = @($cleanStdoutText.Trim(), $cleanStderrText.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Join-String -Separator "`n"
    $cleanText = Get-KiroFinalText -StdoutText $stdoutText -StderrText $stderrText

    if ($exitCode -ne 0) {
        $errorText = $resultText
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $errorText = 'CLI 没有返回可读的错误信息。'
        }

        if ($errorText -match 'Not logged in|KIRO_API_KEY|kiro-cli login') {
            throw "调用 Kiro 失败：Kiro CLI 尚未登录。请先运行 `kiro-cli login` 完成登录；如果需要无头自动化，也可以设置 KIRO_API_KEY。`n$errorText"
        }

        throw "调用 kiro 失败：`n$errorText"
    }

    if ([string]::IsNullOrWhiteSpace($cleanText)) {
        return $resultText
    }

    return $cleanText
}

function Get-OpencodeFinalText {
    param(
        [string]$StdoutText
    )

    $cleanStdoutText = Remove-AnsiEscapeSequences -Text $StdoutText
    $textParts = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($cleanStdoutText -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
            if (
                $event.type -eq 'text' -and
                $null -ne $event.part -and
                -not [string]::IsNullOrWhiteSpace([string]$event.part.text)
            ) {
                [void]$textParts.Add([string]$event.part.text)
            }
        }
        catch {
        }
    }

    return (($textParts.ToArray()) -join '')
}

function Invoke-OpencodeTranslator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,
        [string]$Model
    )

    $workspaceRoot = Get-WorkspaceRoot -AdditionalCandidates @((Get-Location).Path)
    $tempDirectory = Join-Path $workspaceRoot '.codex-temp'
    New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
    $tempPromptFile = Join-Path $tempDirectory ("opencode-polish-" + [guid]::NewGuid().ToString('N') + '.txt')

    try {
        Set-Content -LiteralPath $tempPromptFile -Value $PromptText -Encoding UTF8

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $ExecutablePath
        $startInfo.WorkingDirectory = (Get-Location).Path
        [void]$startInfo.ArgumentList.Add('run')
        if (-not [string]::IsNullOrWhiteSpace($Model)) {
            [void]$startInfo.ArgumentList.Add('--model')
            [void]$startInfo.ArgumentList.Add($Model)
        }
        [void]$startInfo.ArgumentList.Add('--format')
        [void]$startInfo.ArgumentList.Add('json')
        [void]$startInfo.ArgumentList.Add('--title')
        [void]$startInfo.ArgumentList.Add('codex-polish')
        [void]$startInfo.ArgumentList.Add('请读取附件里的完整任务说明并执行。直接输出最终结果，不要解释你的过程。')
        [void]$startInfo.ArgumentList.Add('--file')
        [void]$startInfo.ArgumentList.Add($tempPromptFile)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        try {
            [void]$process.Start()

            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()

            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try {
                    $process.Kill($true)
                }
                catch {
                    $process.Kill()
                }

                throw "调用 opencode 超时：${TimeoutSeconds} 秒内未返回。"
            }

            $stdoutTask.Wait()
            $stderrTask.Wait()

            $stdoutText = $stdoutTask.Result
            $stderrText = $stderrTask.Result
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        }
        finally {
            $process.Dispose()
        }
    }
    finally {
        Remove-Item -LiteralPath $tempPromptFile -Force -ErrorAction SilentlyContinue
    }

    $cleanStdoutText = Remove-AnsiEscapeSequences -Text $stdoutText
    $cleanStderrText = Remove-AnsiEscapeSequences -Text $stderrText
    $resultText = @($cleanStdoutText.Trim(), $cleanStderrText.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Join-String -Separator "`n"
    $cleanText = Get-OpencodeFinalText -StdoutText $stdoutText

    if ($exitCode -ne 0) {
        $errorText = $resultText
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $errorText = 'CLI 没有返回可读的错误信息。'
        }

        throw "调用 opencode 失败：`n$errorText"
    }

    if ([string]::IsNullOrWhiteSpace($cleanText)) {
        return $resultText
    }

    return $cleanText.Trim()
}

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-PlainText {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string]) {
        return [string]$Value
    }

    if ($Value -is [System.Array]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($Value)) {
            $text = ConvertTo-PlainText -Value $item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                [void]$parts.Add($text)
            }
        }

        return (($parts.ToArray()) -join '')
    }

    $textProperty = Get-ObjectPropertyValue -InputObject $Value -Name 'text'
    if ($null -ne $textProperty) {
        return ConvertTo-PlainText -Value $textProperty
    }

    $contentProperty = Get-ObjectPropertyValue -InputObject $Value -Name 'content'
    if ($null -ne $contentProperty) {
        return ConvertTo-PlainText -Value $contentProperty
    }

    return [string]$Value
}

function ConvertTo-BooleanDefault {
    param(
        [object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    return ($text -in @('1', 'true', 'True', 'TRUE', 'yes', 'Yes', 'YES'))
}

function Get-KelivoPreferences {
    $preferencesPath = Get-CodexPolishKelivoPreferencesPath
    if ([string]::IsNullOrWhiteSpace($preferencesPath) -or -not (Test-Path -LiteralPath $preferencesPath -PathType Leaf)) {
        throw '找不到 Kelivo shared_preferences.json。可以用 CODEX_POLISH_KELIVO_PREFS 指定路径。'
    }

    $rawPreferences = Get-Content -LiteralPath $preferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $providerConfigsText = [string](Get-ObjectPropertyValue -InputObject $rawPreferences -Name 'flutter.provider_configs_v1')
    if ([string]::IsNullOrWhiteSpace($providerConfigsText)) {
        throw "Kelivo 配置里没有 flutter.provider_configs_v1: $preferencesPath"
    }

    $providerConfigs = $providerConfigsText | ConvertFrom-Json
    $providersOrderValue = Get-ObjectPropertyValue -InputObject $rawPreferences -Name 'flutter.providers_order_v1'
    $providersOrder = @()
    if ($null -ne $providersOrderValue) {
        $providersOrder = @($providersOrderValue | ForEach-Object { [string]$_ })
    }

    return [pscustomobject]@{
        Path = $preferencesPath
        ProviderConfigs = $providerConfigs
        ProvidersOrder = $providersOrder
        SelectedModel = [string](Get-ObjectPropertyValue -InputObject $rawPreferences -Name 'flutter.selected_model_v1')
    }
}

function Get-KelivoProviderEntries {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProviderConfigs,
        [string[]]$ProvidersOrder = @()
    )

    $entries = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($providerName in $ProvidersOrder) {
        if ([string]::IsNullOrWhiteSpace($providerName)) {
            continue
        }

        $property = $ProviderConfigs.PSObject.Properties[$providerName]
        if ($null -eq $property) {
            continue
        }

        [void]$seen.Add($property.Name)
        [void]$entries.Add([pscustomobject]@{
            Name = $property.Name
            Config = $property.Value
        })
    }

    foreach ($property in @($ProviderConfigs.PSObject.Properties)) {
        if ($seen.Contains($property.Name)) {
            continue
        }

        [void]$entries.Add([pscustomobject]@{
            Name = $property.Name
            Config = $property.Value
        })
    }

    return @($entries.ToArray())
}

function Get-KelivoApiKeyCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProviderConfig
    )

    $keyCandidates = New-Object System.Collections.Generic.List[object]
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $ordinal = 0

    $apiKeysValue = Get-ObjectPropertyValue -InputObject $ProviderConfig -Name 'apiKeys'
    if ($null -ne $apiKeysValue) {
        foreach ($apiKeyConfig in @($apiKeysValue)) {
            $key = [string](Get-ObjectPropertyValue -InputObject $apiKeyConfig -Name 'key')
            if ([string]::IsNullOrWhiteSpace($key)) {
                continue
            }

            $isEnabled = ConvertTo-BooleanDefault -Value (Get-ObjectPropertyValue -InputObject $apiKeyConfig -Name 'isEnabled') -Default $true
            if (-not $isEnabled) {
                continue
            }

            $status = [string](Get-ObjectPropertyValue -InputObject $apiKeyConfig -Name 'status')
            if (-not [string]::IsNullOrWhiteSpace($status) -and $status -notin @('active', 'Active', 'ACTIVE')) {
                continue
            }

            $priorityValue = Get-ObjectPropertyValue -InputObject $apiKeyConfig -Name 'priority'
            $priority = 5
            if ($null -ne $priorityValue) {
                try {
                    $priority = [int]$priorityValue
                }
                catch {
                    $priority = 5
                }
            }

            if ($seenKeys.Add($key)) {
                [void]$keyCandidates.Add([pscustomobject]@{
                    Key = $key
                    Priority = $priority
                    Source = 'multi'
                    Ordinal = $ordinal
                })
                $ordinal++
            }
        }
    }

    $mainKey = [string](Get-ObjectPropertyValue -InputObject $ProviderConfig -Name 'apiKey')
    if (-not [string]::IsNullOrWhiteSpace($mainKey) -and $seenKeys.Add($mainKey)) {
        [void]$keyCandidates.Add([pscustomobject]@{
            Key = $mainKey
            Priority = 999
            Source = 'main'
            Ordinal = $ordinal
        })
    }

    return @($keyCandidates.ToArray() | Sort-Object Priority, Ordinal)
}

function Get-KelivoApiKey {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProviderConfig
    )

    $candidates = @(Get-KelivoApiKeyCandidates -ProviderConfig $ProviderConfig)
    if ($candidates.Count -eq 0) {
        return ''
    }

    return [string]$candidates[0].Key
}

function ConvertTo-KelivoStateKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $key = [regex]::Replace($Value.Trim(), '[^A-Za-z0-9_.-]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($key)) {
        return 'default'
    }

    return $key
}

function Get-KelivoKeyStatePath {
    $stateDirectory = Join-Path (Get-CodexPolishGlobalDirectory) 'state'
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    return (Join-Path $stateDirectory 'kelivo-key-rotation.json')
}

function Get-KelivoRotatedApiKeyCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderName,
        [Parameter(Mandatory = $true)]
        [object]$ProviderConfig
    )

    $candidates = @(Get-KelivoApiKeyCandidates -ProviderConfig $ProviderConfig)
    if ($candidates.Count -le 1) {
        return $candidates
    }

    $statePath = Get-KelivoKeyStatePath
    $state = [ordered]@{}
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $rawState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in @($rawState.PSObject.Properties)) {
                $state[$property.Name] = $property.Value
            }
        }
        catch {
            $state = [ordered]@{}
        }
    }

    $stateKey = ConvertTo-KelivoStateKey -Value $ProviderName
    $nextIndex = 0
    if ($state.Contains($stateKey)) {
        $savedIndex = Get-ObjectPropertyValue -InputObject $state[$stateKey] -Name 'nextIndex'
        if ($null -ne $savedIndex) {
            try {
                $nextIndex = [int]$savedIndex
            }
            catch {
                $nextIndex = 0
            }
        }
    }

    if ($nextIndex -lt 0) {
        $nextIndex = 0
    }
    $nextIndex = $nextIndex % $candidates.Count

    $orderedCandidates = New-Object System.Collections.Generic.List[object]
    for ($offset = 0; $offset -lt $candidates.Count; $offset++) {
        $candidateIndex = ($nextIndex + $offset) % $candidates.Count
        [void]$orderedCandidates.Add($candidates[$candidateIndex])
    }

    $state[$stateKey] = [ordered]@{
        provider = $ProviderName
        nextIndex = (($nextIndex + 1) % $candidates.Count)
        keyCount = $candidates.Count
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    try {
        Set-Content -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 8) -Encoding UTF8
    }
    catch {
    }

    return @($orderedCandidates.ToArray())
}

function Test-KelivoProviderUsable {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProviderConfig
    )

    $enabled = ConvertTo-BooleanDefault -Value (Get-ObjectPropertyValue -InputObject $ProviderConfig -Name 'enabled') -Default $true
    if (-not $enabled) {
        return $false
    }

    $baseUrl = [string](Get-ObjectPropertyValue -InputObject $ProviderConfig -Name 'baseUrl')
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        return $false
    }

    $apiKey = Get-KelivoApiKey -ProviderConfig $ProviderConfig
    return (-not [string]::IsNullOrWhiteSpace($apiKey))
}

function Resolve-KelivoProviderConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$KelivoPreferences
    )

    $entries = Get-KelivoProviderEntries -ProviderConfigs $KelivoPreferences.ProviderConfigs -ProvidersOrder $KelivoPreferences.ProvidersOrder
    $preferredName = Get-CodexPolishKelivoProviderName
    if (-not [string]::IsNullOrWhiteSpace($preferredName)) {
        foreach ($entry in $entries) {
            $configId = [string](Get-ObjectPropertyValue -InputObject $entry.Config -Name 'id')
            $displayName = [string](Get-ObjectPropertyValue -InputObject $entry.Config -Name 'name')
            if ($entry.Name -ieq $preferredName -or $configId -ieq $preferredName -or $displayName -ieq $preferredName) {
                return $entry
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_POLISH_KELIVO_PROVIDER)) {
            throw "Kelivo 配置里找不到指定供应商: $preferredName"
        }
    }

    foreach ($entry in $entries) {
        if (Test-KelivoProviderUsable -ProviderConfig $entry.Config) {
            return $entry
        }
    }

    throw 'Kelivo 配置里没有找到可用的启用供应商（需要 baseUrl 和 API key）。'
}

function Resolve-KelivoModel {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProviderEntry,
        [string]$RequestedModel,
        [string]$SelectedModel
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedModel)) {
        return $RequestedModel
    }

    if (-not [string]::IsNullOrWhiteSpace($SelectedModel) -and $SelectedModel -match '^(.+)::(.+)$') {
        $selectedProvider = $Matches[1]
        $selectedModelId = $Matches[2]
        $configId = [string](Get-ObjectPropertyValue -InputObject $ProviderEntry.Config -Name 'id')
        $displayName = [string](Get-ObjectPropertyValue -InputObject $ProviderEntry.Config -Name 'name')
        if ($ProviderEntry.Name -ieq $selectedProvider -or $configId -ieq $selectedProvider -or $displayName -ieq $selectedProvider) {
            return $selectedModelId
        }
    }

    $modelsValue = Get-ObjectPropertyValue -InputObject $ProviderEntry.Config -Name 'models'
    foreach ($model in @($modelsValue)) {
        $modelText = [string]$model
        if (-not [string]::IsNullOrWhiteSpace($modelText)) {
            return $modelText
        }
    }

    $modelOverrides = Get-ObjectPropertyValue -InputObject $ProviderEntry.Config -Name 'modelOverrides'
    if ($null -ne $modelOverrides) {
        foreach ($property in @($modelOverrides.PSObject.Properties)) {
            if (-not [string]::IsNullOrWhiteSpace($property.Name)) {
                return $property.Name
            }
        }
    }

    throw "Kelivo 供应商 $($ProviderEntry.Name) 没有可用模型；可以设置 CODEX_POLISH_KELIVO_MODEL。"
}

function Get-KelivoChatCompletionsUrl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProviderConfig
    )

    $baseUrl = [string](Get-ObjectPropertyValue -InputObject $ProviderConfig -Name 'baseUrl')
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        throw 'Kelivo 供应商缺少 baseUrl。'
    }

    $chatPath = [string](Get-ObjectPropertyValue -InputObject $ProviderConfig -Name 'chatPath')
    if ([string]::IsNullOrWhiteSpace($chatPath)) {
        $chatPath = '/chat/completions'
    }

    if (-not $chatPath.StartsWith('/')) {
        $chatPath = '/' + $chatPath
    }

    $trimmedBaseUrl = $baseUrl.TrimEnd('/')
    if ($trimmedBaseUrl -match '/chat/completions$') {
        return $trimmedBaseUrl
    }

    return ($trimmedBaseUrl + $chatPath)
}

function Get-OpenAICompatibleResponseText {
    param(
        [object]$Response
    )

    $choices = Get-ObjectPropertyValue -InputObject $Response -Name 'choices'
    if ($null -ne $choices -and @($choices).Count -gt 0) {
        $choice = @($choices)[0]
        $message = Get-ObjectPropertyValue -InputObject $choice -Name 'message'
        if ($null -ne $message) {
            $content = Get-ObjectPropertyValue -InputObject $message -Name 'content'
            $text = ConvertTo-PlainText -Value $content
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text.Trim()
            }
        }

        $choiceText = ConvertTo-PlainText -Value (Get-ObjectPropertyValue -InputObject $choice -Name 'text')
        if (-not [string]::IsNullOrWhiteSpace($choiceText)) {
            return $choiceText.Trim()
        }
    }

    $outputText = ConvertTo-PlainText -Value (Get-ObjectPropertyValue -InputObject $Response -Name 'output_text')
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        return $outputText.Trim()
    }

    return ''
}

function Remove-SecretValues {
    param(
        [string]$Text,
        [string[]]$Secrets = @()
    )

    $redacted = [string]$Text
    foreach ($secret in $Secrets) {
        if ([string]::IsNullOrWhiteSpace($secret) -or $secret.Length -lt 4) {
            continue
        }

        $redacted = [regex]::Replace($redacted, [regex]::Escape($secret), '[REDACTED]')
    }

    return $redacted
}

function Get-ExceptionMessageChain {
    param(
        [object]$Exception
    )

    $messages = New-Object System.Collections.Generic.List[string]
    $currentException = $Exception
    while ($null -ne $currentException) {
        $message = [string]$currentException.Message
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            [void]$messages.Add($message)
        }

        $innerProperty = $currentException.PSObject.Properties['InnerException']
        if ($null -eq $innerProperty) {
            break
        }

        $currentException = $innerProperty.Value
    }

    return (($messages.ToArray()) -join "`n")
}

function Get-KelivoMaxAttemptsPerKey {
    $rawValue = [Environment]::GetEnvironmentVariable('CODEX_POLISH_KELIVO_MAX_ATTEMPTS_PER_KEY')
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return 2
    }

    $parsedValue = 0
    if (-not [int]::TryParse($rawValue, [ref]$parsedValue)) {
        return 2
    }

    return [Math]::Min([Math]::Max($parsedValue, 1), 5)
}

function Test-KelivoTransientError {
    param(
        [string]$ErrorText
    )

    if ([string]::IsNullOrWhiteSpace($ErrorText)) {
        return $false
    }

    return $ErrorText -match '(?i)(An error occurred while sending the request|decryption operation failed|TLS|SSL|timeout|timed out|temporar|connection|forcibly closed|reset by peer|502|503|504|429|rate limit|too many requests)'
}

function Invoke-KelivoTranslator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,
        [string]$Model
    )

    $preferences = Get-KelivoPreferences
    $providerEntry = Resolve-KelivoProviderConfig -KelivoPreferences $preferences
    $providerConfig = $providerEntry.Config
    $keyCandidates = @(Get-KelivoRotatedApiKeyCandidates -ProviderName $providerEntry.Name -ProviderConfig $providerConfig)
    if ($keyCandidates.Count -eq 0) {
        throw "Kelivo 供应商 $($providerEntry.Name) 没有可用 API key。"
    }

    $resolvedModel = Resolve-KelivoModel -ProviderEntry $providerEntry -RequestedModel $Model -SelectedModel $preferences.SelectedModel
    $uri = Get-KelivoChatCompletionsUrl -ProviderConfig $providerConfig
    $payload = [ordered]@{
        model = $resolvedModel
        messages = @(
            @{
                role = 'system'
                content = '你是一个中文报告润色器。严格保留事实，不编造，不把条件、否定、待确认或排查方向改写成已发生事实。直接输出最终结果，不解释过程。'
            },
            @{
                role = 'user'
                content = $PromptText
            }
        )
        temperature = 0.2
        stream = $false
    }
    $body = $payload | ConvertTo-Json -Depth 12
    $allSecrets = @($keyCandidates | ForEach-Object { [string]$_.Key })
    $lastErrorText = ''
    $attemptedRequestCount = 0
    $maxAttemptsPerKey = Get-KelivoMaxAttemptsPerKey
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max($TimeoutSeconds, 1))

:keyLoop
    foreach ($keyCandidate in $keyCandidates) {
        $apiKey = [string]$keyCandidate.Key
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            continue
        }

        $headers = @{
            Authorization = "Bearer $apiKey"
            Accept = 'application/json'
        }

        for ($attempt = 1; $attempt -le $maxAttemptsPerKey; $attempt++) {
            $remainingSeconds = [int][Math]::Ceiling(($deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
            if ($remainingSeconds -le 0) {
                $lastErrorText = "Kelivo API 调用超过总超时限制：${TimeoutSeconds} 秒。"
                break keyLoop
            }

            $attemptedRequestCount++
            $requestTimeoutSeconds = [Math]::Max($remainingSeconds, 1)

            try {
                $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec $requestTimeoutSeconds -ErrorAction Stop
                $responseText = Get-OpenAICompatibleResponseText -Response $response
                if (-not [string]::IsNullOrWhiteSpace($responseText)) {
                    return $responseText.Trim()
                }

                $lastErrorText = "Kelivo API 没有返回可读文本。"
                break
            }
            catch {
                $errorText = Get-ExceptionMessageChain -Exception $_.Exception
                if ([string]::IsNullOrWhiteSpace($errorText)) {
                    $errorText = $_.Exception.Message
                }

                if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
                    $errorText = "$errorText`n$($_.ErrorDetails.Message)"
                }

                $lastErrorText = "key_source=$($keyCandidate.Source), attempt=$attempt/$maxAttemptsPerKey`n$errorText"
                if ($attempt -lt $maxAttemptsPerKey -and (Test-KelivoTransientError -ErrorText $errorText)) {
                    $remainingMilliseconds = [int][Math]::Max(0, ($deadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
                    $sleepMilliseconds = [Math]::Min((500 * $attempt), $remainingMilliseconds)
                    if ($sleepMilliseconds -gt 0) {
                        Start-Sleep -Milliseconds $sleepMilliseconds
                    }

                    continue
                }

                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($lastErrorText)) {
        $lastErrorText = '所有 Kelivo key 都没有返回可读结果。'
    }

    $safeErrorText = Remove-SecretValues -Text $lastErrorText -Secrets $allSecrets
    throw "调用 Kelivo API 失败（provider: $($providerEntry.Name), model: $resolvedModel, tried_keys: $($keyCandidates.Count), attempts: $attemptedRequestCount）：`n$safeErrorText"
}

function Get-PromptTemplateText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateName
    )

    $templatePath = Get-PromptTemplatePath -TemplateName $TemplateName
    return Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
}

function Render-PromptTemplate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateText,
        [Parameter(Mandatory = $true)]
        [hashtable]$Variables
    )

    $rendered = $TemplateText
    foreach ($key in $Variables.Keys) {
        $placeholder = '{{' + $key + '}}'
        $value = [string]$Variables[$key]
        $rendered = $rendered.Replace($placeholder, $value)
    }

    return $rendered
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "git 命令执行失败: git $($Arguments -join ' ')"
    }

    if ($null -eq $output) {
        return ''
    }

    return (($output | Out-String).TrimEnd())
}

function Get-CodexSessionReport {
    param(
        [string]$SessionId,
        [switch]$UseLastSession,
        [Parameter(Mandatory = $true)]
        [int]$MaxChars
    )

    $tempFile = [System.IO.Path]::GetTempFileName()
    $prompt = @"
Read-only task. Create a concise handoff report for the work already completed in this Codex session.

Rules:
- Do not make any file changes.
- Do not propose new implementation work unless it belongs in Remaining risks.
- Base the report only on work already completed in this session and the current repository state.
- If anything is uncertain, say so explicitly.

Output format:
# One-line summary
# Files changed
# What changed
# Validation
# Remaining risks
"@

    try {
        $arguments = @('exec', 'resume', '--skip-git-repo-check')

        if ($UseLastSession) {
            $arguments += '--last'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($SessionId)) {
            $arguments += $SessionId
        }
        else {
            throw '缺少 Codex 会话信息，无法自动生成交接摘要。'
        }

        $arguments += @('-o', $tempFile, $prompt)
        $output = & codex @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Codex 交接摘要生成失败:`n$($output | Out-String)"
        }

        $summary = Get-FileText -Path $tempFile -MaxChars $MaxChars
        if ([string]::IsNullOrWhiteSpace($summary)) {
            throw 'Codex 没有返回可用的交接摘要。'
        }

        return $summary
    }
    finally {
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
    }
}

function Get-CodexSessionFile {
    param(
        [string]$SessionId,
        [switch]$UseLastSession
    )

    $userHomeDirectory = Get-UserHomeDirectory
    if ([string]::IsNullOrWhiteSpace($userHomeDirectory)) {
        return ''
    }

    $sessionRoot = Join-Path $userHomeDirectory '.codex\sessions'
    $archivedRoot = Join-Path $userHomeDirectory '.codex\archived_sessions'

    if ($UseLastSession) {
        $latestSession = Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -eq $latestSession) {
            return ''
        }

        return $latestSession.FullName
    }

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return ''
    }

    $matches = @()
    foreach ($root in @($sessionRoot, $archivedRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $matches += Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*$SessionId*.jsonl" -ErrorAction SilentlyContinue
    }

    $matchedFile = $matches | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $matchedFile) {
        return ''
    }

    return $matchedFile.FullName
}

function Get-SessionMessageText {
    param(
        [object[]]$ContentItems
    )

    if ($null -eq $ContentItems) {
        return ''
    }

    $parts = @()
    foreach ($item in $ContentItems) {
        if ($null -eq $item) {
            continue
        }

        $textProperty = $item.PSObject.Properties['text']
        if ($null -eq $textProperty) {
            continue
        }

        $text = [string]$textProperty.Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $parts += $text
    }

    return ($parts -join "`n").Trim()
}

function Get-FocusedSessionUserText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $normalized = $Text.Trim()
    $requestMatch = [regex]::Match($normalized, '(?s)## My request for Codex:\s*(.+)$')
    if ($requestMatch.Success) {
        return $requestMatch.Groups[1].Value.Trim()
    }

    return $normalized
}

function Test-IgnorableSessionMessage {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true
    }

    return $Text -match '(?s)^\s*<turn_aborted>.*</turn_aborted>\s*$'
}

function Format-RecentConversationTurns {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Turns
    )

    if ($Turns.Count -eq 0) {
        return ''
    }

    $latestTurn = $Turns[-1]
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('### 当前要回答的最后一条 user 消息')
    [void]$builder.AppendLine($latestTurn.user.Trim())

    if (-not [string]::IsNullOrWhiteSpace($latestTurn.assistant)) {
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('### 这条消息前 assistant 刚回复过')
        [void]$builder.AppendLine($latestTurn.assistant.Trim())
    }

    if ($Turns.Count -gt 1) {
        $olderTurns = @($Turns | Select-Object -SkipLast 1)
        $turnNumber = 1
        foreach ($turn in $olderTurns) {
            [void]$builder.AppendLine()
            [void]$builder.AppendLine("### 更早的上下文 $turnNumber")
            [void]$builder.AppendLine('user:')
            [void]$builder.AppendLine($turn.user.Trim())

            if (-not [string]::IsNullOrWhiteSpace($turn.assistant)) {
                [void]$builder.AppendLine()
                [void]$builder.AppendLine('assistant:')
                [void]$builder.AppendLine($turn.assistant.Trim())
            }

            $turnNumber += 1
        }
    }

    return $builder.ToString().TrimEnd()
}

function Get-RecentConversationHistory {
    param(
        [string]$SessionId,
        [switch]$UseLastSession,
        [Parameter(Mandatory = $true)]
        [int]$MaxUserMessages,
        [Parameter(Mandatory = $true)]
        [int]$MaxChars
    )

    $sessionFile = Get-CodexSessionFile -SessionId $SessionId -UseLastSession:$UseLastSession
    if ([string]::IsNullOrWhiteSpace($sessionFile) -or -not (Test-Path -LiteralPath $sessionFile -PathType Leaf)) {
        return ''
    }

    $turns = New-Object System.Collections.Generic.List[object]
    $currentTurn = $null

    foreach ($line in Get-Content -LiteralPath $sessionFile -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json -Depth 20
        }
        catch {
            continue
        }

        if ($null -eq $entry -or $entry.type -ne 'response_item') {
            continue
        }

        $payload = $entry.payload
        if ($null -eq $payload -or $payload.type -ne 'message') {
            continue
        }

        $role = [string]$payload.role
        if ($role -ne 'user' -and $role -ne 'assistant') {
            continue
        }

        if ($role -eq 'assistant' -and [string]$payload.phase -eq 'commentary') {
            continue
        }

        $text = Get-SessionMessageText -ContentItems $payload.content
        if ($role -eq 'user') {
            $text = Get-FocusedSessionUserText -Text $text
        }

        if (Test-IgnorableSessionMessage -Text $text) {
            continue
        }

        if ($role -eq 'user') {
            if ($null -ne $currentTurn) {
                $turns.Add([pscustomobject]@{
                    user = $currentTurn.user
                    assistant = $currentTurn.assistant
                })
            }

            $currentTurn = [ordered]@{
                user = $text
                assistant = ''
            }
            continue
        }

        if ($null -eq $currentTurn) {
            continue
        }

        $currentTurn.assistant = $text
    }

    if ($null -ne $currentTurn) {
        $turns.Add([pscustomobject]@{
            user = $currentTurn.user
            assistant = $currentTurn.assistant
        })
    }

    if ($turns.Count -eq 0) {
        return ''
    }

    $selectedTurns = @($turns | Select-Object -Last $MaxUserMessages)
    $historyText = Format-RecentConversationTurns -Turns $selectedTurns
    if ($historyText.Length -le $MaxChars) {
        return $historyText
    }

    return ($historyText.Substring(0, $MaxChars) + "`n`n[最近对话历史已截断]").TrimEnd()
}

function Test-InGitRepo {
    try {
        return (Invoke-GitText -Arguments @('rev-parse', '--is-inside-work-tree')) -eq 'true'
    }
    catch {
        return $false
    }
}

function Get-UntrackedFilesText {
    param(
        [Parameter(Mandatory = $true)]
        [int]$MaxChars
    )

    $filesRaw = Invoke-GitText -Arguments @('ls-files', '--others', '--exclude-standard')
    if ([string]::IsNullOrWhiteSpace($filesRaw)) {
        return ''
    }

    $binaryExtensions = @(
        '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.pdf', '.zip', '.7z',
        '.gz', '.tar', '.exe', '.dll', '.so', '.dylib', '.mp3', '.mp4', '.mov',
        '.avi', '.woff', '.woff2', '.ttf', '.otf', '.eot', '.class', '.jar'
    )

    $builder = New-Object System.Text.StringBuilder
    $usedChars = 0

    foreach ($relativePath in ($filesRaw -split "`r?`n" | Where-Object { $_.Trim() })) {
        $absolutePath = Join-Path (Get-Location) $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            continue
        }

        $fileInfo = Get-Item -LiteralPath $absolutePath
        [void]$builder.AppendLine("### $relativePath")

        if ($binaryExtensions -contains $fileInfo.Extension.ToLowerInvariant()) {
            [void]$builder.AppendLine('[已跳过：疑似二进制文件]')
            [void]$builder.AppendLine()
            continue
        }

        if ($fileInfo.Length -gt 65536) {
            [void]$builder.AppendLine("[已跳过：文件过大，$($fileInfo.Length) bytes]")
            [void]$builder.AppendLine()
            continue
        }

        $content = Get-Content -LiteralPath $absolutePath -Raw -Encoding UTF8
        $remaining = $MaxChars - $usedChars
        if ($remaining -le 0) {
            [void]$builder.AppendLine('[已跳过：未跟踪文件内容总量达到上限]')
            [void]$builder.AppendLine()
            continue
        }

        if ($content.Length -gt $remaining) {
            $content = $content.Substring(0, $remaining) + "`n[内容已截断]"
        }

        [void]$builder.AppendLine($content.TrimEnd())
        [void]$builder.AppendLine()
        $usedChars += $content.Length
    }

    return $builder.ToString().TrimEnd()
}

function Get-DiffBundle {
    param(
        [string]$BaseBranch,
        [int]$MaxChars
    )

    $status = Invoke-GitText -Arguments @('status', '--short')

    if ([string]::IsNullOrWhiteSpace($BaseBranch)) {
        $stagedStat = Invoke-GitText -Arguments @('diff', '--cached', '--stat', '--no-ext-diff', '--no-color')
        $unstagedStat = Invoke-GitText -Arguments @('diff', '--stat', '--no-ext-diff', '--no-color')
        $stagedDiff = Invoke-GitText -Arguments @('diff', '--cached', '--no-ext-diff', '--no-color', '--unified=3')
        $unstagedDiff = Invoke-GitText -Arguments @('diff', '--no-ext-diff', '--no-color', '--unified=3')
        $untrackedText = Get-UntrackedFilesText -MaxChars ([Math]::Max([int]($MaxChars / 3), 12000))

        $fullText = @"
## git status --short
$status

## staged diff --stat
$stagedStat

## unstaged diff --stat
$unstagedStat

## staged diff
$stagedDiff

## unstaged diff
$unstagedDiff

## untracked file contents
$untrackedText
"@
    }
    else {
        $range = "$BaseBranch...HEAD"
        $rangeStat = Invoke-GitText -Arguments @('diff', '--stat', '--no-ext-diff', '--no-color', $range)
        $rangeDiff = Invoke-GitText -Arguments @('diff', '--no-ext-diff', '--no-color', '--unified=3', $range)

        $fullText = @"
## git status --short
$status

## diff --stat against $range
$rangeStat

## diff against $range
$rangeDiff
"@
    }

    if ($fullText.Length -le $MaxChars) {
        return $fullText.Trim()
    }

    return ($fullText.Substring(0, $MaxChars) + "`n`n[diff 内容已截断，原始变更更大]").Trim()
}

function Build-Prompt {
    param(
        [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
        [string]$Provider,
        [ValidateSet('review', 'translate', 'translate-review')]
        [string]$SelectedMode,
        [string]$ReportText,
        [string]$DiffText,
        [string]$BaseBranch,
        [string]$RecentConversationText
    )

    if ($SelectedMode -eq 'translate') {
        if ([string]::IsNullOrWhiteSpace($RecentConversationText)) {
            $RecentConversationText = '[未读取到可用的最近对话历史；这可能是开场消息，或当前 Codex 会话历史不可用。]'
        }

        $templateText = Get-PromptTemplateText -TemplateName 'report-finalize.md'
        return Render-PromptTemplate -TemplateText $templateText -Variables @{
            RECENT_CONVERSATION_HISTORY = $RecentConversationText
            CODEX_REPORT = $ReportText
        }
    }

    $scopeLine = switch ($SelectedMode) {
        'translate' {
            '只处理工作报告本身，不检查代码仓库。'
        }
        default {
            if ([string]::IsNullOrWhiteSpace($BaseBranch)) {
                '结合当前仓库里尚未提交的改动一起理解。'
            }
            else {
                "结合相对于 $BaseBranch 的代码改动一起理解。"
            }
        }
    }

    $taskBlock = switch ($SelectedMode) {
        'translate' {
            @"
你的任务只有一件事：把这份 AI 工作报告润色成自然、清楚、好读的简体中文。

要求：
- 保留原意，不要擅自补充不存在的实现细节。
- 可以自由组织结构，不必强行套固定标题。
- 允许压缩重复内容，把套话和官话去掉。
- 如果原文有明显含糊、前后矛盾或说不清楚的地方，可以自然点出来。
- 直接输出适合发给用户的最终中文报告，不要解释你做了哪些润色动作。
"@
        }
        'review' {
            @"
请直接基于代码改动写一份自然的中文说明，重点讲清楚：
- 这次到底改了什么。
- 哪些文件或模块最关键。
- 有没有需要注意的风险、边界情况或待确认点。
- 用户接下来应该怎么验证。

要求：
- 结构自由，不必强行套固定标题。
- 语言尽量自然，不要写成审计表格。
"@
        }
        'translate-review' {
            @"
先把这份 AI 工作报告整理成自然、清楚、好读的简体中文，再结合代码改动检查它有没有明显说过头、说漏了或者和实际不一致的地方。

要求：
- 优先保证最终报告好读、像正常人写的汇报。
- 可以自由组织结构，不必强行套固定标题。
- 如果发现报告和实际改动有出入，直接自然地点出来。
- 最终输出仍然是一份给用户看的中文报告，不要写成内部审计清单。
"@
        }
    }

    $evidenceBlock = @()
    if (-not [string]::IsNullOrWhiteSpace($ReportText)) {
        $evidenceBlock += @"
<codex_report>
$ReportText
</codex_report>
"@
    }

    if (-not [string]::IsNullOrWhiteSpace($RecentConversationText)) {
        $evidenceBlock += @"
<recent_conversation_history>
$RecentConversationText
</recent_conversation_history>
"@
    }

    if (-not [string]::IsNullOrWhiteSpace($DiffText)) {
        $evidenceBlock += @"
<code_changes>
$DiffText
</code_changes>
"@
    }

    $providerDisplayName = Get-CodexPolishProviderDisplayName -Provider $Provider

    return @"
你是 $providerDisplayName，有很强的中文生成能力。你的任务是转述 GPT 晦涩难懂的报告，把这份报告用通俗易懂的语言讲给编码小白。

你要尽量做到：
- 通俗易懂地解释做了什么；如果材料里提到 bug，可以用类比说明原因，尽量避免专有技术名词，也不要用文件名直接当代词。
- 说清楚改了哪个文件，以及这个文件负责什么功能。
- 让用户能建立“功能 <-> 文件”的对应关系，下次出问题知道去哪找。
- 遇到报错时，除了检查代码，也要考虑用户是否遗漏了基础操作，例如没装依赖、没启动服务、没改配置；如果材料不足，要明确这只是排查方向，不是已经确认的结论。
- 如果提供了 `<recent_conversation_history>`，它只是帮助你理解用户最后一条消息和最近语境的辅助材料，不是正式报告正文，也不是已确认完成的事实。

基本规则：
- 只根据提供的材料回答，不要脑补。
- 全程使用简体中文。
- 不要输出补丁、代码或命令说明，除非材料里本身就在解释这些内容。
- 优先让结果自然、顺畅、像人写的正常汇报。
- 如果材料不足，就直接说你不确定。

$scopeLine

$taskBlock

$($evidenceBlock -join "`n`n")
"@
}

function Invoke-Translator {
    param(
        [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
        [string]$Provider,
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    Initialize-ChildProcessEnvironment
    $providerLaunchInfo = Get-ProviderLaunchInfo -Provider $Provider
    $providerModel = Get-CodexPolishProviderModel -Provider $Provider

    if ($providerLaunchInfo.Provider -eq 'kelivo') {
        return Invoke-KelivoTranslator -PromptText $PromptText -TimeoutSeconds $TimeoutSeconds -Model $providerModel
    }

    if ($providerLaunchInfo.Provider -eq 'kiro') {
        return Invoke-KiroTranslator -ExecutablePath $providerLaunchInfo.ExecutablePath -PromptText $PromptText -TimeoutSeconds $TimeoutSeconds -Model $providerModel
    }

    if ($providerLaunchInfo.Provider -eq 'opencode') {
        return Invoke-OpencodeTranslator -ExecutablePath $providerLaunchInfo.ExecutablePath -PromptText $PromptText -TimeoutSeconds $TimeoutSeconds -Model $providerModel
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $providerLaunchInfo.ExecutablePath
    $startInfo.WorkingDirectory = (Get-Location).Path
    foreach ($argument in $providerLaunchInfo.PrefixArguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    switch ($providerLaunchInfo.LaunchMode) {
        'node' {
            [void]$startInfo.ArgumentList.Add($providerLaunchInfo.EntryScriptPath)

            if ($providerLaunchInfo.Provider -eq 'claude') {
                [void]$startInfo.ArgumentList.Add('-p')
            }
            elseif ($providerLaunchInfo.Provider -eq 'gemini') {
                [void]$startInfo.ArgumentList.Add('-p')
                [void]$startInfo.ArgumentList.Add('请阅读标准输入中的完整任务说明并直接输出最终结果，不要额外解释。')
            }
            [void]$startInfo.ArgumentList.Add('--output-format')
            [void]$startInfo.ArgumentList.Add('text')
        }
        'direct' {
            if ($providerLaunchInfo.Provider -eq 'kiro') {
                [void]$startInfo.ArgumentList.Add('chat')
                [void]$startInfo.ArgumentList.Add('--no-interactive')
                if (-not [string]::IsNullOrWhiteSpace($providerModel)) {
                    [void]$startInfo.ArgumentList.Add('--model')
                    [void]$startInfo.ArgumentList.Add($providerModel)
                }
                [void]$startInfo.ArgumentList.Add('--wrap')
                [void]$startInfo.ArgumentList.Add('never')
                [void]$startInfo.ArgumentList.Add('请阅读标准输入中的完整任务说明并直接输出最终结果，不要额外解释。')
            }
        }
        default {
            throw "不支持的 provider 启动模式: $($providerLaunchInfo.LaunchMode)"
        }
    }

    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.StandardInput.Write($PromptText)
        $process.StandardInput.Close()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
                $process.Kill()
            }

            throw "调用 $Provider 超时：${TimeoutSeconds} 秒内未返回。"
        }

        $stdoutTask.Wait()
        $stderrTask.Wait()

        $stdoutText = $stdoutTask.Result
        $stderrText = $stderrTask.Result
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    $cleanStdoutText = Remove-AnsiEscapeSequences -Text $stdoutText
    $cleanStderrText = Remove-AnsiEscapeSequences -Text $stderrText
    $resultText = @($cleanStdoutText.Trim(), $cleanStderrText.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Join-String -Separator "`n"
    $cleanText = $cleanStdoutText.Trim()

    if ($exitCode -ne 0) {
        $errorText = $resultText
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $errorText = 'CLI 没有返回可读的错误信息。'
        }

        if (
            $providerLaunchInfo.Provider -eq 'kiro' -and
            $errorText -match 'Not logged in|KIRO_API_KEY|kiro-cli login'
        ) {
            throw "调用 Kiro 失败：Kiro CLI 尚未登录。请先运行 `kiro-cli login` 完成登录；如果需要无头自动化，也可以设置 KIRO_API_KEY。`n$errorText"
        }

        throw "调用 $Provider 失败：`n$errorText"
    }

    if ([string]::IsNullOrWhiteSpace($cleanText)) {
        return $resultText
    }

    return $cleanText
}

$reportText = ''
$bundlePaths = $null
$bundleContextText = ''
$hasExplicitReportSource = -not [string]::IsNullOrWhiteSpace($ReportId) -or -not [string]::IsNullOrWhiteSpace($ReportFile)
$useLastCodexSessionWasExplicit = $PSBoundParameters.ContainsKey('UseLastCodexSession')
$shouldFetchCodexReport = (-not $hasExplicitReportSource) -and ($UseLastCodexSession -or -not [string]::IsNullOrWhiteSpace($CodexSessionId))
$shouldFetchStandaloneConversation = (-not [string]::IsNullOrWhiteSpace($CodexSessionId)) -or ($useLastCodexSessionWasExplicit -and $UseLastCodexSession)

if (-not [string]::IsNullOrWhiteSpace($ReportId)) {
    $bundlePaths = Get-PolishBundlePaths -BundleId $ReportId

    if (-not (Test-Path -LiteralPath $bundlePaths.ReportFile -PathType Leaf)) {
        throw "找不到 ReportId 对应的报告文件: $($bundlePaths.ReportFile)"
    }

    $reportText = Get-FileText -Path $bundlePaths.ReportFile -MaxChars $MaxReportChars
    $bundleContextText = Get-OptionalFileText -Path $bundlePaths.ContextFile -MaxChars ([Math]::Max([int]($MaxReportChars / 2), 6000))
}
elseif (-not [string]::IsNullOrWhiteSpace($ReportFile)) {
    $reportText = Get-FileText -Path $ReportFile -MaxChars $MaxReportChars
}
elseif ($DryRun -and $shouldFetchCodexReport) {
    $reportText = @"
[dry-run placeholder]
这里原本会自动续接 Codex 会话并生成交接摘要。
"@
}
elseif ($shouldFetchCodexReport) {
    $reportText = Get-CodexSessionReport -SessionId $CodexSessionId -UseLastSession:$UseLastCodexSession -MaxChars $MaxCodexReportChars
}

if (($Mode -eq 'translate' -or $Mode -eq 'translate-review') -and [string]::IsNullOrWhiteSpace($reportText)) {
    throw "模式 $Mode 需要传入 -ReportId、-ReportFile，或使用 -UseLastCodexSession / -CodexSessionId 自动获取 Codex 交接摘要。"
}

$diffText = ''
if ($Mode -ne 'translate') {
    if ($DryRun -and -not (Test-InGitRepo)) {
        $diffText = @"
[dry-run placeholder]
这里原本会读取当前 Git 仓库的代码改动。
"@
    }
    elseif (-not (Test-InGitRepo)) {
        throw '当前目录不是 Git 仓库，review 模式无法检查实际代码改动。'
    }
    else {
        $diffText = Get-DiffBundle -BaseBranch $Base -MaxChars $MaxDiffChars
        if ([string]::IsNullOrWhiteSpace($diffText)) {
            throw '没有检测到可供复核的代码改动。'
        }
    }
}

$recentConversationText = ''
if ($Mode -eq 'translate' -or $Mode -eq 'translate-review') {
    if (-not [string]::IsNullOrWhiteSpace($ReportId)) {
        $recentConversationText = $bundleContextText
    }
    elseif ($shouldFetchStandaloneConversation) {
        $recentConversationText = Get-RecentConversationHistory -SessionId $CodexSessionId -UseLastSession:$UseLastCodexSession -MaxUserMessages 1 -MaxChars 2000
    }
}

$prompt = Build-Prompt -Provider $With -SelectedMode $Mode -ReportText $reportText -DiffText $diffText -BaseBranch $Base -RecentConversationText $recentConversationText

if ($DryRun) {
    $preview = @"
[dry-run]
provider: $With
mode: $Mode
provider_timeout_seconds: $ProviderTimeoutSeconds
base: $Base
report_id: $ReportId
report_file: $ReportFile
use_last_codex_session: $UseLastCodexSession
codex_session_id: $CodexSessionId
out_file: $OutFile
bundle_directory: $(if ($null -ne $bundlePaths) { $bundlePaths.Directory } else { '' })
recent_conversation_chars: $($recentConversationText.Length)

$prompt
"@

    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        $preview
    }
    else {
        Set-Content -LiteralPath $OutFile -Value $preview -Encoding UTF8
        "dry-run 内容已写入: $OutFile"
    }

    return
}

$response = Invoke-Translator -Provider $With -PromptText $prompt -TimeoutSeconds $ProviderTimeoutSeconds

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $response
}
else {
    Set-Content -LiteralPath $OutFile -Value $response -Encoding UTF8
    "结果已写入: $OutFile"
}

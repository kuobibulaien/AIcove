[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DraftFile,

    [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
    [string]$With,

    [ValidateSet('review', 'translate', 'translate-review')]
    [string]$Mode = 'translate',

    [string]$ThreadId,

    [string]$RunId,

    [string]$OutFile,

    [int]$ProviderTimeoutSeconds = 90,

    [int]$MaxUserMessages = 1,

    [int]$MaxContextChars = 2000,

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
}

function ConvertTo-SafePathSegment {
    param(
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Fallback
    }

    $sanitized = [regex]::Replace($Value.Trim(), '[\\/:*?"<>|]', '_')
    $sanitized = $sanitized.Trim(' ', '.')
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return $Fallback
    }

    return $sanitized
}

function New-GeneratedRunId {
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "$timestamp-$suffix"
}

function Resolve-DraftFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DraftFile,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot
    )

    $resolvedDraftPath = (Resolve-Path -LiteralPath $DraftFile).Path
    $draftDirectory = Split-Path -Path $resolvedDraftPath -Parent
    $draftFileName = Split-Path -Path $resolvedDraftPath -Leaf
    $workspaceRootPath = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $managedDraftDirectory = Get-ManagedDraftDirectory

    if (
        $draftDirectory -ieq $workspaceRootPath -and
        $draftFileName -match '^\.codex-polish-draft(?:-.+)?\.md$'
    ) {
        New-Item -ItemType Directory -Path $managedDraftDirectory -Force | Out-Null
        $managedDraftPath = Join-Path $managedDraftDirectory $draftFileName

        if ($resolvedDraftPath -ine $managedDraftPath) {
            Move-Item -LiteralPath $resolvedDraftPath -Destination $managedDraftPath -Force
        }

        return (Resolve-Path -LiteralPath $managedDraftPath).Path
    }

    return $resolvedDraftPath
}

function Get-SessionFile {
    param(
        [string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return ''
    }

    $userHomeDirectory = Get-UserHomeDirectory
    if ([string]::IsNullOrWhiteSpace($userHomeDirectory)) {
        return ''
    }

    $roots = @(
        (Join-Path $userHomeDirectory '.codex\sessions'),
        (Join-Path $userHomeDirectory '.codex\archived_sessions')
    )

    $matches = @()
    foreach ($root in $roots) {
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

function Get-RecentConversationContext {
    param(
        [string]$SessionId,
        [Parameter(Mandatory = $true)]
        [int]$MaxUserMessages,
        [Parameter(Mandatory = $true)]
        [int]$MaxChars
    )

    $sessionFile = Get-SessionFile -SessionId $SessionId
    if ([string]::IsNullOrWhiteSpace($sessionFile) -or -not (Test-Path -LiteralPath $sessionFile -PathType Leaf)) {
        return [pscustomobject]@{
            SessionFile = ''
            HistoryText = ''
            TurnCount = 0
            LastUserMessage = ''
        }
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
        return [pscustomobject]@{
            SessionFile = $sessionFile
            HistoryText = ''
            TurnCount = 0
            LastUserMessage = ''
        }
    }

    $selectedTurns = @($turns | Select-Object -Last $MaxUserMessages)
    $historyText = Format-RecentConversationTurns -Turns $selectedTurns
    if ($historyText.Length -gt $MaxChars) {
        $historyText = ($historyText.Substring(0, $MaxChars) + "`n`n[最近对话历史已截断]").TrimEnd()
    }

    $lastUserMessage = [string]$selectedTurns[-1].user
    return [pscustomobject]@{
        SessionFile = $sessionFile
        HistoryText = $historyText
        TurnCount = $selectedTurns.Count
        LastUserMessage = $lastUserMessage
    }
}

function Get-TextSha256 {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha256.ComputeHash($bytes)
        return ([Convert]::ToHexString($hash)).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-MetaFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$Data
    )

    $json = $Data | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

$workspaceRoot = Get-WorkspaceRoot -AdditionalCandidates @((Split-Path -Path $DraftFile -Parent))
$draftPath = Resolve-DraftFilePath -DraftFile $DraftFile -WorkspaceRoot $workspaceRoot
$draftText = Get-Content -LiteralPath $draftPath -Raw -Encoding UTF8

if ([string]::IsNullOrWhiteSpace($draftText)) {
    throw "草稿文件为空: $draftPath"
}

$rawThreadId = if (-not [string]::IsNullOrWhiteSpace($ThreadId)) { $ThreadId } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { $env:CODEX_THREAD_ID } else { 'manual' }
$rawRunId = if (-not [string]::IsNullOrWhiteSpace($RunId)) { $RunId } else { New-GeneratedRunId }

$safeThreadId = ConvertTo-SafePathSegment -Value $rawThreadId -Fallback 'manual'
$safeRunId = ConvertTo-SafePathSegment -Value $rawRunId -Fallback (New-GeneratedRunId)
$bundleId = "$safeThreadId\$safeRunId"
$bundleDirectory = Join-Path (Get-PolishRootDirectory) $bundleId

New-Item -ItemType Directory -Path $bundleDirectory -Force | Out-Null

$reportPath = Join-Path $bundleDirectory 'report.md'
$contextPath = Join-Path $bundleDirectory 'context.md'
$metaPath = Join-Path $bundleDirectory 'meta.json'
$resultPath = Join-Path $bundleDirectory 'result.md'

Set-Content -LiteralPath $reportPath -Value $draftText -Encoding UTF8

$contextInfo = [pscustomobject]@{
    SessionFile = ''
    HistoryText = ''
    TurnCount = 0
    LastUserMessage = ''
}

if ($Mode -eq 'translate' -or $Mode -eq 'translate-review') {
    $contextInfo = Get-RecentConversationContext -SessionId $rawThreadId -MaxUserMessages $MaxUserMessages -MaxChars $MaxContextChars
    if (-not [string]::IsNullOrWhiteSpace($contextInfo.HistoryText)) {
        Set-Content -LiteralPath $contextPath -Value $contextInfo.HistoryText -Encoding UTF8
    }
}

$meta = [ordered]@{
    thread_id = $rawThreadId
    safe_thread_id = $safeThreadId
    run_id = $rawRunId
    safe_run_id = $safeRunId
    report_id = $bundleId
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    workspace_root = $workspaceRoot
    requested_draft_file = $DraftFile
    draft_file = $draftPath
    bundle_id = $bundleId
    bundle_directory = $bundleDirectory
    report_file = $reportPath
    context_file = $(if (Test-Path -LiteralPath $contextPath -PathType Leaf) { $contextPath } else { '' })
    result_file = $resultPath
    provider = $With
    provider_timeout_seconds = $ProviderTimeoutSeconds
    mode = $Mode
    session_file = $contextInfo.SessionFile
    context_turn_count = $contextInfo.TurnCount
    source_user_message_hash = (Get-TextSha256 -Text $contextInfo.LastUserMessage)
    polish_invoked = $false
    polish_status = 'pending'
    polish_error = ''
}

Write-MetaFile -Path $metaPath -Data $meta

$polishScriptPath = Join-Path $PSScriptRoot 'codex-polish.ps1'
if (-not (Test-Path -LiteralPath $polishScriptPath -PathType Leaf)) {
    throw "找不到润色脚本: $polishScriptPath"
}

Initialize-ChildProcessEnvironment

function Invoke-PolishCommand {
    param(
        [switch]$PreviewOnly
    )

    $arguments = @{
        With = $With
        Mode = $Mode
        ReportId = $bundleId
        ProviderTimeoutSeconds = $ProviderTimeoutSeconds
    }

    if ($PreviewOnly) {
        $arguments['DryRun'] = $true
    }

    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath $workspaceRoot
        $output = & $polishScriptPath @arguments 2>&1
    }
    finally {
        Set-Location -LiteralPath $previousLocation
    }

    $outputText = ($output | Out-String).Trim()
    return $outputText
}

if ($DryRun) {
    $preview = Invoke-PolishCommand -PreviewOnly
    $meta.polish_status = 'dry-run'
    Write-MetaFile -Path $metaPath -Data $meta

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        Set-Content -LiteralPath $OutFile -Value $preview -Encoding UTF8
        "dry-run 内容已写入: $OutFile"
        exit 0
    }

    $preview
    exit 0
}

try {
    $response = Invoke-PolishCommand
    if ([string]::IsNullOrWhiteSpace($response)) {
        throw '润色命令没有返回内容。'
    }

    Set-Content -LiteralPath $resultPath -Value $response -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        Set-Content -LiteralPath $OutFile -Value $response -Encoding UTF8
    }

    $meta.polish_invoked = $true
    $meta.polish_status = 'success'
    Write-MetaFile -Path $metaPath -Data $meta

    $response
}
catch {
    $fallback = @"
[润色失败，已回退到原始草稿]

$draftText
"@.Trim()

    Set-Content -LiteralPath $resultPath -Value $fallback -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        Set-Content -LiteralPath $OutFile -Value $fallback -Encoding UTF8
    }

    $meta.polish_invoked = $true
    $meta.polish_status = 'failed'
    $meta.polish_error = $_.Exception.Message
    Write-MetaFile -Path $metaPath -Data $meta

    $fallback
}

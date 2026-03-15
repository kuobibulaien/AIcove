[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DraftFile,

    [ValidateSet('claude', 'gemini')]
    [string]$With = 'gemini',

    [ValidateSet('review', 'translate', 'translate-review')]
    [string]$Mode = 'translate',

    [string]$ThreadId,

    [string]$RunId,

    [string]$OutFile,

    [int]$ProviderTimeoutSeconds = 90,

    [int]$MaxUserMessages = 3,

    [int]$MaxContextChars = 6000,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-WorkspaceRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartPath
    )

    if (-not (Test-Path -LiteralPath $StartPath)) {
        return ''
    }

    $resolved = Resolve-Path -LiteralPath $StartPath
    $current = $resolved.Path

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath (Join-Path $current '.codex-prompts') -PathType Container) {
            return $current
        }

        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }

        $current = $parent
    }

    return ''
}

function Get-WorkspaceRoot {
    $workspaceRootVariable = Get-Variable -Name WorkspaceRoot -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $workspaceRootVariable -and -not [string]::IsNullOrWhiteSpace([string]$workspaceRootVariable.Value)) {
        return [string]$workspaceRootVariable.Value
    }

    $candidates = @(
        (Get-Location).Path,
        (Split-Path -Path $PSScriptRoot -Parent)
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $workspaceRoot = Resolve-WorkspaceRoot -StartPath $candidate
        if (-not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
            $script:WorkspaceRoot = $workspaceRoot
            return $workspaceRoot
        }
    }

    $script:WorkspaceRoot = (Get-Location).Path
    return $script:WorkspaceRoot
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

function Get-SessionFile {
    param(
        [string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return ''
    }

    $roots = @(
        (Join-Path $env:USERPROFILE '.codex\sessions'),
        (Join-Path $env:USERPROFILE '.codex\archived_sessions')
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

function Test-IgnorableSessionMessage {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true
    }

    return $Text -match '(?s)^\s*<turn_aborted>.*</turn_aborted>\s*$'
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
    $builder = New-Object System.Text.StringBuilder
    $turnNumber = 1

    foreach ($turn in $selectedTurns) {
        [void]$builder.AppendLine("### 最近第 $turnNumber 轮")
        [void]$builder.AppendLine('user:')
        [void]$builder.AppendLine($turn.user.Trim())

        if (-not [string]::IsNullOrWhiteSpace($turn.assistant)) {
            [void]$builder.AppendLine()
            [void]$builder.AppendLine('assistant:')
            [void]$builder.AppendLine($turn.assistant.Trim())
        }

        [void]$builder.AppendLine()
        [void]$builder.AppendLine()
        $turnNumber += 1
    }

    $historyText = $builder.ToString().TrimEnd()
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

$workspaceRoot = Get-WorkspaceRoot
$draftPath = (Resolve-Path -LiteralPath $DraftFile).Path
$draftText = Get-Content -LiteralPath $draftPath -Raw -Encoding UTF8

if ([string]::IsNullOrWhiteSpace($draftText)) {
    throw "草稿文件为空: $draftPath"
}

$rawThreadId = if (-not [string]::IsNullOrWhiteSpace($ThreadId)) { $ThreadId } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { $env:CODEX_THREAD_ID } else { 'manual' }
$rawRunId = if (-not [string]::IsNullOrWhiteSpace($RunId)) { $RunId } else { New-GeneratedRunId }

$safeThreadId = ConvertTo-SafePathSegment -Value $rawThreadId -Fallback 'manual'
$safeRunId = ConvertTo-SafePathSegment -Value $rawRunId -Fallback (New-GeneratedRunId)
$bundleId = "$safeThreadId\$safeRunId"
$bundleDirectory = Join-Path (Join-Path $workspaceRoot '.codex-polish') $bundleId

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
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    workspace_root = $workspaceRoot
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

function Invoke-PolishCommand {
    param(
        [switch]$PreviewOnly
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $polishScriptPath,
        '-With', $With,
        '-Mode', $Mode,
        '-ReportId', $bundleId,
        '-ProviderTimeoutSeconds', $ProviderTimeoutSeconds
    )

    if ($PreviewOnly) {
        $arguments += '-DryRun'
    }

    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath $workspaceRoot
        $output = & pwsh @arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Set-Location -LiteralPath $previousLocation
    }

    $outputText = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            $outputText = '润色命令失败，但没有返回可读错误。'
        }

        throw $outputText
    }

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

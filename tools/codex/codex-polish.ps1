[CmdletBinding()]
param(
    [ValidateSet('claude', 'gemini')]
    [string]$With = 'gemini',

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

    $bundleRoot = Join-Path (Get-WorkspaceRoot) '.codex-polish'
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

function Resolve-WorkspaceRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartPath
    )

    $candidate = $StartPath
    if (-not (Test-Path -LiteralPath $candidate)) {
        return ''
    }

    $resolved = Resolve-Path -LiteralPath $candidate
    $current = $resolved.Path

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $promptDirectory = Join-Path $current '.codex-prompts'
        if (Test-Path -LiteralPath $promptDirectory -PathType Container) {
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

function Get-WorkspacePromptDirectory {
    return (Join-Path (Get-WorkspaceRoot) '.codex-prompts')
}

function Get-PromptTemplateText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateName
    )

    $promptDirectory = Get-WorkspacePromptDirectory
    $templatePath = Join-Path $promptDirectory $TemplateName
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "找不到提示词模板: $templatePath"
    }

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

    $sessionRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    $archivedRoot = Join-Path $env:USERPROFILE '.codex\archived_sessions'

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

        $templateText = Get-PromptTemplateText -TemplateName 'gemini-translate-report.txt'
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

    return @"
你是 Gemini，有很强的中文生成能力。你的任务是转述 GPT 晦涩难懂的报告，把这份报告用通俗易懂的语言讲给编码小白。

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
        [ValidateSet('claude', 'gemini')]
        [string]$Provider,
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    if ($Provider -eq 'claude') {
        $startInfo.FileName = 'claude.cmd'
        [void]$startInfo.ArgumentList.Add('-p')
        [void]$startInfo.ArgumentList.Add('--output-format')
        [void]$startInfo.ArgumentList.Add('text')
    }
    else {
        $startInfo.FileName = 'gemini.cmd'
        [void]$startInfo.ArgumentList.Add('--prompt')
        [void]$startInfo.ArgumentList.Add('.')
        [void]$startInfo.ArgumentList.Add('--output-format')
        [void]$startInfo.ArgumentList.Add('text')
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

    $resultText = @($stdoutText.Trim(), $stderrText.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Join-String -Separator "`n"
    $cleanText = $stdoutText.Trim()

    if ($exitCode -ne 0) {
        $errorText = $resultText
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $errorText = 'CLI 没有返回可读的错误信息。'
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

$prompt = Build-Prompt -SelectedMode $Mode -ReportText $reportText -DiffText $diffText -BaseBranch $Base -RecentConversationText $recentConversationText

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

    exit 0
}

$response = Invoke-Translator -Provider $With -PromptText $prompt -TimeoutSeconds $ProviderTimeoutSeconds

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $response
}
else {
    Set-Content -LiteralPath $OutFile -Value $response -Encoding UTF8
    "结果已写入: $OutFile"
}

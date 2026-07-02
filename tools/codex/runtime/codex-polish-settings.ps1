Set-StrictMode -Version Latest

# 手动切换默认润色 provider 时，只改这里。
$script:CodexPolishDefaultProvider = 'kelivo'
$script:CodexPolishDefaultModels = @{
    kelivo = 'accounts/fireworks/models/glm-5p1'
    opencode = 'opencode-go/kimi-k2.6'
}
$script:CodexPolishKelivoProviderName = 'firework'

function Get-CodexPolishDefaultProvider {
    return $script:CodexPolishDefaultProvider
}

function Resolve-CodexPolishProvider {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
        [string]$Provider
    )

    switch ($Provider) {
        'claudecode' { return 'claude' }
        default { return $Provider }
    }
}

function Get-CodexPolishProviderCommandNames {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
        [string]$Provider
    )

    $resolvedProvider = Resolve-CodexPolishProvider -Provider $Provider

    switch ($resolvedProvider) {
        'claude' { return @('claudecode.ps1', 'claudecode.cmd', 'claude.ps1', 'claude.cmd') }
        'gemini' { return @('gemini.ps1', 'gemini.cmd') }
        'kiro' { return @('kiro-cli.exe', 'kiro-cli.cmd', 'kiro-cli') }
        'opencode' { return @('opencode.cmd', 'opencode.exe', 'opencode.ps1', 'opencode') }
        'kelivo' { return @() }
        default { return @("$resolvedProvider.ps1", "$resolvedProvider.cmd") }
    }
}

function Get-CodexPolishProviderDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
        [string]$Provider
    )

    $resolvedProvider = Resolve-CodexPolishProvider -Provider $Provider

    switch ($resolvedProvider) {
        'claude' { return 'Claude Code' }
        'gemini' { return 'Gemini' }
        'kiro' { return 'Kiro' }
        'opencode' { return 'opencode' }
        'kelivo' { return 'Kelivo API' }
        default { return $resolvedProvider }
    }
}

function Get-CodexPolishProviderModel {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('claude', 'claudecode', 'gemini', 'kiro', 'opencode', 'kelivo')]
        [string]$Provider
    )

    $resolvedProvider = Resolve-CodexPolishProvider -Provider $Provider
    $specificModelEnvName = "CODEX_POLISH_$($resolvedProvider.ToUpperInvariant())_MODEL"
    $specificModel = [Environment]::GetEnvironmentVariable($specificModelEnvName)
    if (-not [string]::IsNullOrWhiteSpace($specificModel)) {
        return $specificModel
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_POLISH_MODEL)) {
        return $env:CODEX_POLISH_MODEL
    }

    $providerModels = $script:CodexPolishDefaultModels
    if ($null -eq $providerModels) {
        return ''
    }

    if ($providerModels.ContainsKey($resolvedProvider)) {
        return [string]$providerModels[$resolvedProvider]
    }

    return ''
}

function Get-CodexPolishKelivoProviderName {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_POLISH_KELIVO_PROVIDER)) {
        return $env:CODEX_POLISH_KELIVO_PROVIDER
    }

    $providerNameVariable = Get-Variable -Name CodexPolishKelivoProviderName -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $providerNameVariable -and -not [string]::IsNullOrWhiteSpace([string]$providerNameVariable.Value)) {
        return [string]$providerNameVariable.Value
    }

    return ''
}

function Get-CodexPolishKelivoPreferencesPath {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_POLISH_KELIVO_PREFS)) {
        return [System.IO.Path]::GetFullPath($env:CODEX_POLISH_KELIVO_PREFS)
    }

    $candidateRoots = @(
        $env:APPDATA,
        $env:LOCALAPPDATA
    )

    foreach ($root in $candidateRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        $candidate = Join-Path (Join-Path (Join-Path $root 'com.psyche') 'kelivo') 'shared_preferences.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return ''
}

function Get-UserHomeDirectory {
    $candidates = @(
        $env:USERPROFILE,
        $HOME,
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return ''
}

function Get-CodexPolishHomeDirectory {
    $homeDirectoryVariable = Get-Variable -Name CodexPolishHomeDirectory -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $homeDirectoryVariable -and -not [string]::IsNullOrWhiteSpace([string]$homeDirectoryVariable.Value)) {
        return [string]$homeDirectoryVariable.Value
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $script:CodexPolishHomeDirectory = [System.IO.Path]::GetFullPath($env:CODEX_HOME)
        return $script:CodexPolishHomeDirectory
    }

    $userHomeDirectory = Get-UserHomeDirectory
    if ([string]::IsNullOrWhiteSpace($userHomeDirectory)) {
        throw '找不到用户目录，也没有设置 CODEX_HOME，无法确定全局润色目录。'
    }

    $script:CodexPolishHomeDirectory = Join-Path $userHomeDirectory '.codex'
    return $script:CodexPolishHomeDirectory
}

function Get-CodexPolishGlobalDirectory {
    return (Join-Path (Get-CodexPolishHomeDirectory) 'polish')
}

function Get-CodexPolishToolRootDirectory {
    $toolRootVariable = Get-Variable -Name CodexPolishToolRootDirectory -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $toolRootVariable -and -not [string]::IsNullOrWhiteSpace([string]$toolRootVariable.Value)) {
        return [string]$toolRootVariable.Value
    }

    $toolRoot = $PSScriptRoot
    if ((Split-Path -Path $toolRoot -Leaf) -ieq 'runtime') {
        $toolRoot = Split-Path -Path $toolRoot -Parent
    }

    $script:CodexPolishToolRootDirectory = $toolRoot
    return $script:CodexPolishToolRootDirectory
}

function Get-PolishRootDirectory {
    return (Join-Path (Get-CodexPolishGlobalDirectory) 'runs')
}

function Get-ManagedDraftDirectory {
    return (Join-Path (Get-PolishRootDirectory) 'drafts')
}

function Get-PolishPromptDirectory {
    return (Join-Path (Join-Path (Get-CodexPolishToolRootDirectory) 'prompts') 'polish')
}

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

    try {
        $item = Get-Item -LiteralPath $current -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            $current = Split-Path -Path $current -Parent
        }
    }
    catch {
        return ''
    }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath (Join-Path $current '.git') -PathType Container) {
            return $current
        }

        $toolRootCandidate = Join-Path (Join-Path $current 'tools') 'codex'
        if (Test-Path -LiteralPath $toolRootCandidate -PathType Container) {
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
    param(
        [string[]]$AdditionalCandidates = @()
    )

    $workspaceRootVariable = Get-Variable -Name WorkspaceRoot -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $workspaceRootVariable -and -not [string]::IsNullOrWhiteSpace([string]$workspaceRootVariable.Value)) {
        return [string]$workspaceRootVariable.Value
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($AdditionalCandidates + @((Get-Location).Path))) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        [void]$candidates.Add($candidate)
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $workspaceRoot = Resolve-WorkspaceRoot -StartPath $candidate
        if (-not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
            $script:WorkspaceRoot = $workspaceRoot
            return $workspaceRoot
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        $resolved = Resolve-Path -LiteralPath $candidate
        try {
            $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
            $script:WorkspaceRoot = if ($item.PSIsContainer) { $resolved.Path } else { Split-Path -Path $resolved.Path -Parent }
            return $script:WorkspaceRoot
        }
        catch {
        }
    }

    $script:WorkspaceRoot = (Get-Location).Path
    return $script:WorkspaceRoot
}

function Get-CodexPolishBuiltInPromptTemplateText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateName
    )

    switch ($TemplateName) {
        'gemini-translate-report.txt' {
            return @'
你是一个专业、自然、克制的中文技术助手。
你的任务是把 Codex 生成的原始工作报告润色成适合直接发给用户的简体中文回复。

要求：
- 保留原意，不要编造未发生的实现细节。
- 优先提升可读性，把重复、绕口、机械化的表达改得自然一些。
- 如果原文有不确定项、限制或失败回退，要保留这些信息，不要粉饰。
- `<recent_conversation_history>` 只是帮助你理解用户最后一条消息和最近语境，不是已经完成的事实。
- 真正需要润色并输出给用户的是 `<codex_report>`。
- 直接输出最终可发送内容，不要解释你的润色过程。

<recent_conversation_history>
{{RECENT_CONVERSATION_HISTORY}}
</recent_conversation_history>

<codex_report>
{{CODEX_REPORT}}
</codex_report>
'@.Trim()
        }
        'report-finalize.md' {
            return @'
你是一个专业、自然、克制的中文技术助手。
你的任务是把 Codex 生成的原始工作报告润色成适合直接发给用户的简体中文回复。

要求：
- 保留原意，不要编造未发生的实现细节。
- 优先提升可读性，把重复、绕口、机械化的表达改得自然一些。
- 如果原文有不确定项、限制或失败回退，要保留这些信息，不要粉饰。
- `<recent_conversation_history>` 只是帮助你理解用户最后一条消息和最近语境，不是已经完成的事实。
- 真正需要润色并输出给用户的是 `<codex_report>`。
- 直接输出最终可发送内容，不要解释你的润色过程。

<recent_conversation_history>
{{RECENT_CONVERSATION_HISTORY}}
</recent_conversation_history>

<codex_report>
{{CODEX_REPORT}}
</codex_report>
'@.Trim()
        }
        default {
            return ''
        }
    }
}

function Get-PromptTemplatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateName,
        [string[]]$AdditionalCandidates = @()
    )

    $normalizedTemplateName = switch ($TemplateName) {
        'gemini-translate-report.txt' { 'report-finalize.md' }
        default { $TemplateName }
    }

    $promptDirectory = Get-PolishPromptDirectory
    New-Item -ItemType Directory -Path $promptDirectory -Force | Out-Null

    $templatePath = Join-Path $promptDirectory $normalizedTemplateName
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        $templateText = Get-CodexPolishBuiltInPromptTemplateText -TemplateName $TemplateName
        if ([string]::IsNullOrWhiteSpace($templateText)) {
            throw "找不到提示词模板，也没有内置默认模板: $TemplateName"
        }

        Set-Content -LiteralPath $templatePath -Value $templateText -Encoding UTF8
    }

    return (Resolve-Path -LiteralPath $templatePath).Path
}

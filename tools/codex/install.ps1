[CmdletBinding()]
param(
    [switch]$Uninstall,

    [switch]$SkipAgents,

    [ValidateSet('Auto', 'User', 'Process')]
    [string]$EnvironmentScope = 'Auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ManagedBlockStart = '# >>> codex-polish install begin >>>'
$script:ManagedBlockEnd = '# <<< codex-polish install end <<<'

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Green
}

function Write-WarningText {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Yellow
}

function Write-InfoText {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Gray
}

function Get-UserHomePath {
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

    throw '找不到用户目录。'
}

function Get-EffectiveEnvironmentScope {
    param([string]$RequestedScope)

    if ($RequestedScope -eq 'Auto') {
        if ($IsWindows) {
            return 'User'
        }

        return 'Process'
    }

    if ($RequestedScope -eq 'User' -and -not $IsWindows) {
        Write-WarningText '非 Windows 平台暂不自动持久化用户环境变量，已回退为仅当前进程生效。'
        return 'Process'
    }

    return $RequestedScope
}

function Get-ToolRootPath {
    return $PSScriptRoot
}

function Get-CodexHomeCandidatePath {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    return (Join-Path (Get-UserHomePath) '.codex')
}

function Get-GlobalAgentsPath {
    return (Join-Path (Get-CodexHomeCandidatePath) 'AGENTS.md')
}

function Get-FinalizeCommandPath {
    $runtimeRoot = Join-Path (Get-ToolRootPath) 'runtime'
    return (Join-Path $runtimeRoot 'codex-report-finalize.ps1')
}

function Format-CommandForAgents {
    param([string]$CommandPath)

    if ($IsWindows) {
        return "& '$CommandPath' -DraftFile <草稿路径>"
    }

    return "pwsh -NoProfile -File '$CommandPath' -DraftFile <草稿路径>"
}

function Get-AgentsTemplatePath {
    $promptsRoot = Join-Path (Get-ToolRootPath) 'prompts'
    $codexPromptRoot = Join-Path $promptsRoot 'codex'
    return (Join-Path $codexPromptRoot 'global-agents.md')
}

function Get-AgentsTemplateText {
    $commandExample = Format-CommandForAgents -CommandPath (Get-FinalizeCommandPath)
    $templatePath = Get-AgentsTemplatePath

    if (Test-Path -LiteralPath $templatePath -PathType Leaf) {
        $templateText = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
    }
    else {
        $templateText = @'
## Codex Polish

最终回复前先写原始草稿到本地文件，再调用下面命令：

`{{FINALIZE_COMMAND}}`

以脚本标准输出作为最终回复；如果润色失败，要明确说明失败并回退到草稿原文，不编造内容。

子代理只做内部结果传递，不直接面向用户，跳过润色流程。
'@
    }

    return $templateText.Replace('{{FINALIZE_COMMAND}}', $commandExample).Trim()
}

function Get-ManagedAgentsBlock {
    return @(
        $script:ManagedBlockStart,
        (Get-AgentsTemplateText),
        $script:ManagedBlockEnd
    ) -join [Environment]::NewLine
}

function Remove-ManagedBlock {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ''
    }

    $pattern = "(?ms)(?:^|\r?\n)" + [regex]::Escape($script:ManagedBlockStart) + ".*?" + [regex]::Escape($script:ManagedBlockEnd) + "(?:\r?\n|$)"
    $updated = [regex]::Replace($Content, $pattern, [Environment]::NewLine)
    return $updated.Trim()
}

function Backup-FileIfNeeded {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $backupPath = "$Path.bak"
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    }
}

function Set-ManagedAgentsBlock {
    param([string]$AgentsPath)

    $existingContent = ''
    if (Test-Path -LiteralPath $AgentsPath -PathType Leaf) {
        Backup-FileIfNeeded -Path $AgentsPath
        $existingContent = Get-Content -LiteralPath $AgentsPath -Raw -Encoding UTF8
    }

    $trimmedContent = (Remove-ManagedBlock -Content $existingContent).Trim()
    $managedBlock = Get-ManagedAgentsBlock

    if ([string]::IsNullOrWhiteSpace($trimmedContent)) {
        $newContent = $managedBlock.Trim() + [Environment]::NewLine
    }
    else {
        $newContent = $trimmedContent + [Environment]::NewLine + [Environment]::NewLine + $managedBlock.Trim() + [Environment]::NewLine
    }

    Set-Content -LiteralPath $AgentsPath -Value $newContent -Encoding UTF8
}

function Remove-ManagedAgentsBlock {
    param([string]$AgentsPath)

    if (-not (Test-Path -LiteralPath $AgentsPath -PathType Leaf)) {
        return $false
    }

    Backup-FileIfNeeded -Path $AgentsPath
    $existingContent = Get-Content -LiteralPath $AgentsPath -Raw -Encoding UTF8
    $hadManagedBlock = $existingContent -match [regex]::Escape($script:ManagedBlockStart)
    if (-not $hadManagedBlock) {
        return $false
    }

    $updatedContent = Remove-ManagedBlock -Content $existingContent
    if ([string]::IsNullOrWhiteSpace($updatedContent)) {
        Set-Content -LiteralPath $AgentsPath -Value '' -Encoding UTF8
    }
    else {
        Set-Content -LiteralPath $AgentsPath -Value ($updatedContent.Trim() + [Environment]::NewLine) -Encoding UTF8
    }

    return $true
}

function Set-ScopedEnvironmentVariable {
    param(
        [string]$Name,
        [string]$Value,
        [string]$Scope
    )

    switch ($Scope) {
        'Process' {
            Set-Item -Path "Env:$Name" -Value $Value
        }
        'User' {
            [Environment]::SetEnvironmentVariable($Name, $Value, [EnvironmentVariableTarget]::User)
            Set-Item -Path "Env:$Name" -Value $Value
        }
        default {
            throw "不支持的环境变量作用域: $Scope"
        }
    }
}

function Remove-ScopedEnvironmentVariable {
    param(
        [string]$Name,
        [string]$Scope
    )

    switch ($Scope) {
        'Process' {
            Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
        }
        'User' {
            [Environment]::SetEnvironmentVariable($Name, $null, [EnvironmentVariableTarget]::User)
            Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
        }
        default {
            throw "不支持的环境变量作用域: $Scope"
        }
    }
}

function Invoke-Install {
    param([string]$EffectiveEnvironmentScope)

    $toolRoot = Get-ToolRootPath
    $codexHome = Get-CodexHomeCandidatePath
    $codexHomeExistedBeforeInstall = Test-Path -LiteralPath $codexHome -PathType Container
    $agentsPath = Get-GlobalAgentsPath
    $finalizeCommand = Get-FinalizeCommandPath

    Set-ScopedEnvironmentVariable -Name 'CODEX_POLISH_HOME' -Value $toolRoot -Scope $EffectiveEnvironmentScope
    Set-ScopedEnvironmentVariable -Name 'CODEX_POLISH_CMD' -Value $finalizeCommand -Scope $EffectiveEnvironmentScope

    Write-Success "已登记工具目录: $toolRoot"
    Write-Success "已写入环境变量 CODEX_POLISH_HOME=$toolRoot"
    Write-Success "已写入环境变量 CODEX_POLISH_CMD=$finalizeCommand"
    $promptsRoot = Join-Path $toolRoot 'prompts'
    $polishPromptPath = Join-Path (Join-Path $promptsRoot 'polish') 'report-finalize.md'
    $codexPromptPath = Join-Path (Join-Path $promptsRoot 'codex') 'global-agents.md'
    Write-InfoText "润色提示词: $polishPromptPath"
    Write-InfoText "Codex 提示词: $codexPromptPath"

    if ($SkipAgents) {
        Write-WarningText '已跳过全局 AGENTS.md 自动接入。'
        return
    }

    if (-not $codexHomeExistedBeforeInstall) {
        Write-WarningText '未找到 .codex 目录，已跳过 AGENTS 自动接入。'
        Write-WarningText '未找到 .codex 请自行配置 AGENTS.md。'
        return
    }

    if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
        Write-WarningText '未找到 .codex 目录，已跳过 AGENTS 自动接入。'
        Write-WarningText '未找到 .codex 请自行配置 AGENTS.md。'
        return
    }

    if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
        New-Item -ItemType File -Path $agentsPath -Force | Out-Null
    }

    Set-ManagedAgentsBlock -AgentsPath $agentsPath
    Write-Success "已更新全局 AGENTS.md: $agentsPath"
}

function Invoke-Uninstall {
    param([string]$EffectiveEnvironmentScope)

    Remove-ScopedEnvironmentVariable -Name 'CODEX_POLISH_HOME' -Scope $EffectiveEnvironmentScope
    Remove-ScopedEnvironmentVariable -Name 'CODEX_POLISH_CMD' -Scope $EffectiveEnvironmentScope

    $agentsPath = Get-GlobalAgentsPath
    $removedAgentsBlock = Remove-ManagedAgentsBlock -AgentsPath $agentsPath

    if ($removedAgentsBlock) {
        Write-Success "已移除 AGENTS 托管片段: $agentsPath"
    }
    else {
        Write-WarningText '未检测到可移除的 AGENTS 托管片段。'
    }

    Write-Success '已清理环境变量 CODEX_POLISH_HOME / CODEX_POLISH_CMD'
    Write-InfoText "工具文件仍保留在: $(Get-ToolRootPath)"
}

$effectiveEnvironmentScope = Get-EffectiveEnvironmentScope -RequestedScope $EnvironmentScope

if ($Uninstall) {
    Write-Section '执行卸载：清理环境变量与全局 AGENTS 托管片段'
    Invoke-Uninstall -EffectiveEnvironmentScope $effectiveEnvironmentScope
}
else {
    Write-Section '执行安装：登记工具目录并接入全局 AGENTS.md'
    Invoke-Install -EffectiveEnvironmentScope $effectiveEnvironmentScope
}

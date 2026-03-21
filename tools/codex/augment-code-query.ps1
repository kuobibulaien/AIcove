[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Query,

    [string]$WorkspaceRoot,

    [int]$TimeoutSeconds = 900,

    [int]$MaxTurns = 6,

    [string]$Model,

    [string]$AuggiePath,

    [string]$AugmentSessionAuth,

    [string]$AugmentApiToken,

    [string]$AugmentApiUrl,

    [switch]$Json,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-WorkspaceRoot {
    param(
        [string]$StartPath
    )

    if ([string]::IsNullOrWhiteSpace($StartPath) -or -not (Test-Path -LiteralPath $StartPath)) {
        return ''
    }

    $resolved = Resolve-Path -LiteralPath $StartPath
    $current = $resolved.Path

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            return $current
        }

        if (Test-Path -LiteralPath (Join-Path $current '.codex-prompts')) {
            return $current
        }

        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }

        $current = $parent
    }

    return $resolved.Path
}

function Get-DefaultWorkspaceRoot {
    $candidates = @(
        $WorkspaceRoot,
        (Get-Location).Path,
        (Split-Path -Path $PSScriptRoot -Parent)
    )

    foreach ($candidate in $candidates) {
        $resolved = Resolve-WorkspaceRoot -StartPath $candidate
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            return $resolved
        }
    }

    return (Get-Location).Path
}

function Resolve-AuggieRuntime {
    param(
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "Auggie bootstrap file not found: $ExplicitPath"
        }

        $resolvedExplicitPath = (Resolve-Path -LiteralPath $ExplicitPath).Path
        $explicitDirectory = Split-Path -Path $resolvedExplicitPath -Parent
        $explicitExtension = [System.IO.Path]::GetExtension($resolvedExplicitPath)

        if ($explicitExtension -ieq '.mjs') {
            $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
            if ($null -eq $nodeCommand) {
                throw 'Unable to locate node. Add node to PATH or pass a bootstrap path next to node.exe.'
            }

            return [pscustomobject]@{
                NodePath = $nodeCommand.Source
                ScriptPath = $resolvedExplicitPath
            }
        }

        $nodeCandidate = Join-Path $explicitDirectory 'node.exe'
        $scriptCandidate = Join-Path $explicitDirectory 'node_modules\@augmentcode\auggie\augment.mjs'
        if ((Test-Path -LiteralPath $nodeCandidate -PathType Leaf) -and (Test-Path -LiteralPath $scriptCandidate -PathType Leaf)) {
            return [pscustomobject]@{
                NodePath = $nodeCandidate
                ScriptPath = $scriptCandidate
            }
        }
    }

    $commandCandidates = @('auggie.cmd', 'auggie', 'auggie.ps1')
    foreach ($candidate in $commandCandidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $commandPath = $command.Source
            $commandDirectory = Split-Path -Path $commandPath -Parent
            $nodeCandidate = Join-Path $commandDirectory 'node.exe'
            $scriptCandidate = Join-Path $commandDirectory 'node_modules\@augmentcode\auggie\augment.mjs'

            if (Test-Path -LiteralPath $scriptCandidate -PathType Leaf) {
                $resolvedNodePath = if (Test-Path -LiteralPath $nodeCandidate -PathType Leaf) {
                    $nodeCandidate
                }
                else {
                    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
                    if ($null -eq $nodeCommand) {
                        throw 'Unable to locate node. Add node to PATH.'
                    }

                    $nodeCommand.Source
                }

                return [pscustomobject]@{
                    NodePath = $resolvedNodePath
                    ScriptPath = $scriptCandidate
                }
            }
        }
    }

    throw 'Unable to locate auggie runtime. Pass -AuggiePath or add auggie to PATH.'
}

function Stop-ProcessTree {
    param(
        [int]$Pid
    )

    if ($Pid -le 0) {
        return
    }

    try {
        & taskkill /PID $Pid /T /F | Out-Null
    }
    catch {
    }
}

function New-TempOutputFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    $fileName = '{0}-{1}-{2}.log' -f $Prefix, (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N')
    return (Join-Path ([System.IO.Path]::GetTempPath()) $fileName)
}

$resolvedWorkspaceRoot = Get-DefaultWorkspaceRoot
$resolvedAuggieRuntime = Resolve-AuggieRuntime -ExplicitPath $AuggiePath

$sessionAuth = if (-not [string]::IsNullOrWhiteSpace($AugmentSessionAuth)) {
    $AugmentSessionAuth
}
elseif (-not [string]::IsNullOrWhiteSpace($env:AUGMENT_SESSION_AUTH)) {
    $env:AUGMENT_SESSION_AUTH
}
elseif (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.augment\session.json') -PathType Leaf) {
    Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.augment\session.json') -Raw -Encoding UTF8
}
else {
    ''
}

$apiToken = if (-not [string]::IsNullOrWhiteSpace($AugmentApiToken)) {
    $AugmentApiToken
}
elseif (-not [string]::IsNullOrWhiteSpace($env:AUGMENT_API_TOKEN)) {
    $env:AUGMENT_API_TOKEN
}
else {
    ''
}

$apiUrl = if (-not [string]::IsNullOrWhiteSpace($AugmentApiUrl)) {
    $AugmentApiUrl
}
elseif (-not [string]::IsNullOrWhiteSpace($env:AUGMENT_API_URL)) {
    $env:AUGMENT_API_URL
}
else {
    ''
}

if ([string]::IsNullOrWhiteSpace($sessionAuth) -and [string]::IsNullOrWhiteSpace($apiToken)) {
    throw 'Missing Augment credentials. Set AUGMENT_SESSION_AUTH or AUGMENT_API_TOKEN, or pass -AugmentSessionAuth / -AugmentApiToken.'
}

$instruction = @"
Read-only codebase query. Do not modify files.
Prioritize locating entry points, key files, data flow, and concrete code references.
Keep the answer concise and practical.

Question:
$Query
"@

$arguments = [System.Collections.Generic.List[string]]::new()
$arguments.Add($resolvedAuggieRuntime.ScriptPath)
$arguments.Add('--print')
$arguments.Add('--ask')
$arguments.Add('--dont-save-session')
$arguments.Add('--allow-indexing')
$arguments.Add('--shell')
$arguments.Add('powershell')
$arguments.Add('--workspace-root')
$arguments.Add($resolvedWorkspaceRoot)
$arguments.Add('--max-turns')
$arguments.Add([string]$MaxTurns)

if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $arguments.Add('--model')
    $arguments.Add($Model)
}

if ($Json) {
    $arguments.Add('--output-format')
    $arguments.Add('json')
}

if ($Quiet) {
    $arguments.Add('--quiet')
}

$arguments.Add('--instruction')
$arguments.Add($instruction)

$stdoutPath = New-TempOutputFile -Prefix 'augment-query-stdout'
$stderrPath = New-TempOutputFile -Prefix 'augment-query-stderr'

$process = $null

try {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $resolvedAuggieRuntime.NodePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $resolvedWorkspaceRoot

    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    if (-not [string]::IsNullOrWhiteSpace($sessionAuth)) {
        $startInfo.Environment['AUGMENT_SESSION_AUTH'] = $sessionAuth
    }

    if ([string]::IsNullOrWhiteSpace($sessionAuth) -and -not [string]::IsNullOrWhiteSpace($apiToken)) {
        $startInfo.Environment['AUGMENT_API_TOKEN'] = $apiToken
    }

    if ([string]::IsNullOrWhiteSpace($sessionAuth) -and -not [string]::IsNullOrWhiteSpace($apiUrl)) {
        $startInfo.Environment['AUGMENT_API_URL'] = $apiUrl
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw 'Failed to start auggie.'
    }

    $stdoutStream = [System.IO.File]::Open($stdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $stderrStream = [System.IO.File]::Open($stderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)

    try {
        $stdoutCopyTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrCopyTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-ProcessTree -Pid $process.Id
            throw "Auggie query timed out after $TimeoutSeconds seconds."
        }

        $process.WaitForExit()
        [void]$stdoutCopyTask.GetAwaiter().GetResult()
        [void]$stderrCopyTask.GetAwaiter().GetResult()
    }
    finally {
        $stdoutStream.Dispose()
        $stderrStream.Dispose()
    }

    $stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
    }
    else {
        ''
    }

    $stderrText = if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8
    }
    else {
        ''
    }

    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        Write-Output $stdoutText.TrimEnd()
    }

    if ($process.ExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Error $stderrText.TrimEnd()
        }

        throw "Auggie exited with code $($process.ExitCode)."
    }

    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Information $stderrText.TrimEnd() -InformationAction Continue
    }
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-ProcessTree -Pid $process.Id
    }

    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -ne $process) {
        $process.Dispose()
    }
}

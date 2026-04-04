Set-StrictMode -Version Latest

# 手动切换默认润色 provider 时，只改这里。
$script:CodexPolishDefaultProvider = 'claude'

function Get-CodexPolishDefaultProvider {
    return $script:CodexPolishDefaultProvider
}

function Get-CodexPolishProviderDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('claude', 'gemini')]
        [string]$Provider
    )

    switch ($Provider) {
        'claude' { return 'Claude' }
        'gemini' { return 'Gemini' }
        default { return $Provider }
    }
}

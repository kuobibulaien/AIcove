$root = 'c:\ide\aicove'
$textExts = @('.dart','.md','.yaml','.yml','.json','.xml','.kt','.kts','.html','.cc','.cpp','.h','.cmake','.rc','.plist','.xcconfig','.xcscheme','.pbxproj','.ps1','.sh','.py','.txt','.gitignore','.env','.lock','.toml','.cfg','.ini','.properties','.gradle','.bat','.cmd','.js','.ts','.css','.scss','.svg')
$textNames = @('Dockerfile','Makefile','LICENSE','CHANGELOG')

$files = Get-ChildItem -Path $root -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.FullName -notmatch '[\\/]build[\\/]' -and
    $_.FullName -notmatch '[\\/]\.dart_tool[\\/]' -and
    ($textExts -contains $_.Extension.ToLower() -or $textNames -contains $_.Name)
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$count = 0

foreach ($file in $files) {
    try {
        $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        if ($null -eq $content -or $content.Length -eq 0) { continue }

        $original = $content
        $content = $content -creplace 'aicove_flutter', 'aicove_flutter'
        $content = $content -creplace 'aicove_flutter', 'aicove_flutter'
        $content = $content -creplace 'AIcove', 'AIcove'
        $content = $content -creplace 'AIcove', 'AIcove'
        $content = $content -creplace 'AICOVE', 'AICOVE'
        $content = $content -creplace 'AICOVE', 'AICOVE'
        $content = $content -creplace 'aicove', 'aicove'
        $content = $content -creplace 'aicove', 'aicove'

        if ($content -ne $original) {
            [System.IO.File]::WriteAllText($file.FullName, $content, $utf8NoBom)
            $count++
            Write-Host ("Updated: " + $file.FullName.Replace($root + '\', ''))
        }
    } catch {
        Write-Host ("ERROR: " + $file.FullName + " - " + $_.Exception.Message)
    }
}
Write-Host ""
Write-Host ("Total files updated: " + $count)

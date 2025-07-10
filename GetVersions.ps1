using namespace System.Text
using namespace System.Collections.Specialized

[CmdletBinding()]
param(
    [string]$VersionFile = "$PSScriptRoot\Versions.txt",
    [string]$BatchCommit = 'e2b5bf501151bf851443233d5274605477c34eaa',
    [string]$WorkflowCommit = '4eba50e0d666d3972870e97b8e49bd85b9363cb1'
)
process {
    $VersionTemp = New-TemporaryFile
    $WorkflowTemp = New-TemporaryFile
    Invoke-WebRequest "https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc/$BatchCommit/versions.bat" -OutFile $VersionTemp
    Invoke-WebRequest "https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/$WorkflowCommit/.github/workflows/build.yml" -OutFile $WorkflowTemp
    if (-not $?) { return }

    $VERSIONS = [OrderedDictionary]::new()
    $SB = [StringBuilder]::new()

    Get-Content $VersionTemp | ForEach-Object {
        if ($_ -inotmatch '^\s*@?set ([^\s=]+_VERSION)\s*=\s*([^%].*)$') {
            $PSCmdlet.WriteVerbose("Skipped line '$_'")
            return
        }
        $Key = $Matches[1].ToUpperInvariant() -replace 'WINFLEXBISON_VERSION', 'WIN_FLEX_BISON_VERSION' -replace 'LIBJPEG_VERSION', 'LIBJPEG_TURBO_VERSION' -replace
        'SQLITE_VERSION', 'SQLITE3_VERSION' -replace 'GSTREAMER_GST_PLUGINS_RS_VERSION', 'GSTREAMER_PLUGINS_RS_VERSION' -creplace '_7Z', '7Z'
        $PSCmdlet.WriteVerbose("${Key}: $($Matches[2])")
        $VERSIONS[$Key] = $Matches[2]
    }

    $Workflow = Get-Content $WorkflowTemp
    $Start = $Workflow.IndexOf('env:') + 1
    $End = $Workflow.IndexOf('jobs:')

    for ($Line = $Start; $Line -lt $End; $Line++) {
        $Text = $Workflow[$Line]
        if ([string]::IsNullOrWhiteSpace($Text)) { continue }
        if ($Text -inotmatch '^\s*([^\s:]+_version)\s*:\s*["'']?([^"'']*)["'']?') { continue }
        $Key = $Matches[1].ToUpperInvariant()
        $Value = $Matches[2]
        if ($Key -ieq 'GETTEXT_VERSION' -and $Value -match '([\d\.]+)-v([\d\.]+)') {
            $PSCmdlet.WriteVerbose("${Key}: $($VERSIONS[$Key]) -> $($Matches[1])")
            $PSCmdlet.WriteVerbose("ICONV_VERSION: $($Matches[2])")
            $VERSIONS[$Key] = $Matches[1]
            $VERSIONS['ICONV_VERSION'] = $Matches[2]
            continue
        }
        $PSCmdlet.WriteVerbose("${Key}: $($VERSIONS[$Key]) -> $Value")
        $VERSIONS[$Matches[1].ToUpperInvariant()] = $Matches[2]
    }

    # Write version file
    foreach ($Name in $VERSIONS.Keys) {
        [void]$SB.AppendFormat('{0,-40} = {1}', $Name, $VERSIONS[$Name]).AppendLine()
    }
    Set-Content $VersionFile $SB.ToString() -Force -NoNewline
}
end {
    Remove-Item $VersionTemp -Force -ErrorAction Ignore
    Remove-Item $WorkflowTemp -Force -ErrorAction Ignore
}

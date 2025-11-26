using namespace System.Text
using namespace System.Collections.Specialized

[CmdletBinding()]
param(
    [string]$VersionFile = "$PSScriptRoot\Versions.txt",
    [string]$MsvcCommit = '2e70dfef8a748e2ffdfb956aa9fc54178b67ab38', # https://github.com/strawberrymusicplayer/strawberry-msvc/commits/master/
    [string]$MsvcDepsCommit = 'f7ceff9a5b11effca085209437d76a5a288bbced', # https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/commits/master/
    [string]$MsvcDepsRelease = '19686038772', # https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/releases
    [string]$StrawberryCommit = 'd2205cfe8165aaa3226917f5bdf45ec35bb03df7' # https://github.com/strawberrymusicplayer/strawberry/commits/master/
)
process {
    $VersionTemp = New-TemporaryFile
    $WorkflowTemp = New-TemporaryFile
    Invoke-WebRequest "https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc/$MsvcCommit/versions.bat" -OutFile $VersionTemp
    Invoke-WebRequest "https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/$MsvcDepsCommit/.github/workflows/build.yml" -OutFile $WorkflowTemp
    if (-not $?) { return }

    $VERSIONS = [OrderedDictionary]::new()
    $SB = [StringBuilder]::new()

    Get-Content $VersionTemp | ForEach-Object {
        if ($_ -inotmatch '^\s*@?set ([^\s=]+_VERSION)\s*=\s*([^%].*)$') {
            $PSCmdlet.WriteVerbose("Skipped line '$_'")
            return
        }
        $Key = $Matches[1].ToUpperInvariant() -replace 'WINFLEXBISON_VERSION', 'WIN_FLEX_BISON_VERSION' -replace 'LIBJPEG_VERSION', 'LIBJPEG_TURBO_VERSION' -replace
        'SQLITE_VERSION', 'SQLITE3_VERSION' -replace 'GSTREAMER_GST_PLUGINS_RS_VERSION', 'GSTREAMER_PLUGINS_RS_VERSION' -creplace '_7Z', '7Z' -replace
        'PEPARSE_VERSION', 'PE_PARSE_VERSION'
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
            # Special case: iconv & gettext are bundled together but don't have unified version numbers
            $PSCmdlet.WriteVerbose("${Key}: $($VERSIONS[$Key]) -> $($Matches[1])")
            $PSCmdlet.WriteVerbose("ICONV_VERSION: $($Matches[2])")
            $VERSIONS[$Key] = $Matches[1]
            $VERSIONS['ICONV_VERSION'] = $Matches[2]
            continue
        }
        $PSCmdlet.WriteVerbose("${Key}: $($VERSIONS[$Key]) -> $Value")
        $VERSIONS[$Matches[1].ToUpperInvariant()] = $Matches[2]
    }

    # Overrides
    $VERSIONS['FFMPEG_X86_VERSION'] = '7.1.2' # ffmpeg meson-8.x port has 32-bit build issues

    # Commits
    $VERSIONS['STRAWBERRY_REPO_COMMIT'] = $StrawberryCommit
    $VERSIONS['MSVC_DEPS_REPO_COMMIT'] = $MsvcDepsCommit
    $VERSIONS['MSVC_DEPS_REPO_RELEASE'] = $MsvcDepsRelease
    $VERSIONS['MSVC_REPO_COMMIT'] = $MsvcCommit

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

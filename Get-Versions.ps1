# Copyright 2026 Nicholas Bissell (TheFreeman193)
# SPDX-License-Identifier: GPL-3.0-or-later

using namespace System.Text
using namespace System.Collections.Specialized

[CmdletBinding()]
param(
    [string]$VersionFile = "$PSScriptRoot\Versions.txt",
    [string]$MsvcCommit = '7d565a99ebbbf2f8fbafa539d3e54adda098260d', # https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools/commits/master/
    [string]$MsvcDepsCommit = 'f3876923db3993933a36de71ba288f0a6b90a15c', # https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/commits/master/
    [string]$MsvcDepsRelease = '24508996352', # https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/releases
    [string]$StrawberryCommit = '999407e4f41bb4895d159b289763befc613ee3d8', # https://github.com/strawberrymusicplayer/strawberry/commits/master/
    [string]$CMakeVersion = '4.2.3',
    [string]$7ZipVersion = '2600',
    [string]$GitVersion = '2.53.0',
    [string]$MesonVersion = '1.10.1',
    [string]$StrawberryPerlVersion = '5.42.2',
    [string]$PythonVersion = '3.14.3'
)
process {
    $VersionTemp = New-TemporaryFile
    $WorkflowTemp = New-TemporaryFile
    Invoke-WebRequest "https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-build-tools/$MsvcCommit/StrawberryPackageVersions.txt" -OutFile $VersionTemp
    Invoke-WebRequest "https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/$MsvcDepsCommit/.github/workflows/build.yml" -OutFile $WorkflowTemp
    if (-not $?) { return }

    $SB = [StringBuilder]::new()
    $VERSIONS = (Get-Content $VersionTemp -Raw | ConvertFrom-StringData)
    foreach ($Key in $VERSIONS.Keys) {
        $PSCmdlet.WriteVerbose("${Key}: $($VERSIONS[$Key])")
    }

    $Workflow = Get-Content $WorkflowTemp
    $Start = $Workflow.IndexOf('env:') + 1
    $End = $Workflow.IndexOf('jobs:')
    $NameMap = @{
        GSTREAMER_PLUGINS_RS_VERSION = 'GSTREAMER_GST_PLUGINS_RS_VERSION'
        LIBJPEG_TURBO_VERSION        = 'LIBJPEG_VERSION'
        PE_PARSE_VERSION             = 'PEPARSE_VERSION'
        SQLITE3_VERSION              = 'SQLITE_VERSION'
        WINFLEXBISON_VERSION         = 'WIN_FLEX_BISON_VERSION'
    }
    for ($Line = $Start; $Line -lt $End; $Line++) {
        $Text = $Workflow[$Line]
        if ([string]::IsNullOrWhiteSpace($Text)) { continue }
        if ($Text -inotmatch '^\s*([^\s:]+_version)\s*:\s*["'']?([^"'']*)["'']?') { continue }
        $Key = $Matches[1].ToUpperInvariant()
        if ($NameMap.Contains($Key)) {
            $Key = $NameMap[$Key]
        }
        $Value = $Matches[2]
        $PSCmdlet.WriteVerbose("${Key}: $($VERSIONS[$Key]) -> $Value")
        $VERSIONS[$Key] = $Value
    }

    # Overrides
    $VERSIONS['FFMPEG_X86_VERSION'] = '7.1.2' # ffmpeg meson-8.x port has 32-bit build issues

    # Build tools
    $VERSIONS['CMAKE_VERSION'] = $CMakeVersion
    $VERSIONS['7ZIP_VERSION'] = $7ZipVersion
    $VERSIONS['GIT_VERSION'] = $GitVersion
    $VERSIONS['MESON_VERSION'] = $MesonVersion
    $VERSIONS['STRAWBERRY_PERL_VERSION'] = $StrawberryPerlVersion
    $VERSIONS['PYTHON_VERSION'] = $PythonVersion

    # Commits
    $VERSIONS['STRAWBERRY_REPO_COMMIT'] = $StrawberryCommit
    $VERSIONS['MSVC_DEPS_REPO_COMMIT'] = $MsvcDepsCommit
    $VERSIONS['MSVC_DEPS_REPO_RELEASE'] = $MsvcDepsRelease
    $VERSIONS['MSVC_REPO_COMMIT'] = $MsvcCommit

    # Write version file
    $SortedKeys = $VERSIONS.Keys | Sort-Object
    foreach ($Name in $SortedKeys) {
        [void]$SB.AppendFormat('{0,-40} = {1}', $Name, $VERSIONS[$Name]).AppendLine()
    }
    Set-Content $VersionFile $SB.ToString() -Force -NoNewline
}
end {
    Remove-Item $VersionTemp -Force -ErrorAction Ignore
    Remove-Item $WorkflowTemp -Force -ErrorAction Ignore
}

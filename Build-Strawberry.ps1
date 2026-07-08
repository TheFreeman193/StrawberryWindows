# Copyright 2026 Nicholas Bissell (TheFreeman193)
# SPDX-License-Identifier: GPL-3.0-or-later

using namespace System.Management.Automation
using namespace System.IO
using namespace System.Collections.Generic

[CmdletBinding()]
param(
    [string]$DownloadPath = 'S:\downloads',
    [string]$BuildPathRoot = 'R:\msvc_\build',
    [string]$DependsPathRoot = 'R:\strawberry_msvc',
    [string]$TempPath = 'R:\TEMP',
    [string]$VersionFile = "$PSScriptRoot\Versions.txt",
    [ValidateSet('Release', 'Debug', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$BuildType = 'Release',
    [ValidateSet('x64', 'x86')]
    [string]$BuildArch = 'x64',
    [ValidateRange(1, 1e6)]
    [uint32]$MaxBuildTries = 1,
    [string[]]$ForceBuild,
    [string[]]$SkipBuild,
    [switch]$QTDevMode,
    [switch]$GStreamerDevMode,
    [switch]$EnableStrawberryConsole,
    [switch]$PrintVersions,
    [switch]$NoBuild,
    [switch]$NoStrawberry,
    [switch]$FromScratch,
    [switch]$NoFailFast,
    [switch]$PreCleanup,
    [switch]$PostCleanup
)

begin {
    if ($PSVersionTable.PSVersion -ge '6.0' -and -not $IsWindows) {
        $PSCmdlet.WriteWarning("This build script runs only on Windows platforms! This platform: $($PSVersionTable.Platform), OS: $($PSVersionTable.OS)")
        return
    }
    #region Setup
    $DoContinue = $false
    switch ($BuildType) {
        'RelWithDebInfo' {
            $BuildType = 'release'
            [string]$BuildTypeCMake = 'RelWithDebInfo'
            [string]$BuildTypeMeson = 'debugoptimized'
        }
        'MinSizeRel' {
            $BuildType = 'release'
            [string]$BuildTypeCMake = 'MinSizeRel'
            [string]$BuildTypeMeson = 'minsize'
        }
        default {
            $BuildType = $BuildType.ToLowerInvariant()
            [string]$BuildTypeCMake = [cultureinfo]::InvariantCulture.TextInfo.ToTitleCase($BuildType)
            [string]$BuildTypeMeson = $BuildType
        }
    }
    [string]$BuildPath = "${BuildPathRoot}_${BuildType}_$BuildArch"
    if (-not $NoBuild) {
        try { Stop-Transcript } catch {}
        Start-Transcript -Path "$BuildPath\StrawberryBuild_${BuildType}_${BuildArch}_$([datetime]::Now.ToString('yyyy-MM-ddTHH-mm-ss')).log" -Force
    }

    Write-Host -fo White ('=' * $Host.UI.RawUI.BufferSize.Width)
    Write-Host -fo White 'Strawberry Windows MSVC Builder'

    [string]$CMakeGenerator = 'Ninja'
    [bool]$ISDEBUG = $BuildType -eq 'debug'
    [string]$DebugPostfix = if ($ISDEBUG) { 'd' } else { '' }
    if ($ISDEBUG) { $EnableStrawberryConsole = $true }
    [string]$BuildArch64Alt = $BuildArch.ToLowerInvariant() -replace 'x64', 'amd64'
    [string]$BuildArch32Alt = $BuildArch -replace 'x86', 'Win32'
    [string]$BuildAddressSize = if ($BuildArch -like '*86' -or $BuildArch -like '*32') { '32' } else { '64' }
    [string]$PerlArch = @{x64 = 'VC-WIN64A'; x86 = 'VC-WIN32'; arm64 = 'VC-WIN64-ARM' }[$BuildArch]
    [string]$StrawbArch = $BuildArch -creplace 'x64', 'x86_64'
    [string]$DependsPath = "${DependsPathRoot}_${StrawbArch}_$BuildType"
    [string]$DependsPathForward = $DependsPath -replace '\\', '/'
    [string]$DefaultName = "strawberry_msvc_${StrawbArch}_$BuildType"
    [string]$PkgconfTemplate = @"
prefix=$DependsPathForward
exec_prefix=`${prefix}
libdir=`${exec_prefix}/lib
includedir=`${prefix}/include
"@
    [int]$ConWidth = 80

    $env:PKG_CONFIG_EXECUTABLE = "$DependsPath\bin\pkgconf.exe"
    $env:PKG_CONFIG_PATH = "$DependsPath\lib\pkgconfig"
    $env:CL = '-MP'
    $env:PATH = $env:PATH -replace 'C:\\Strawberry\\c\\bin'
    $env:PATH = ("$DependsPath\bin", "$env:PATH" -join ';').Trim(';') -replace ';{2,}', ';'

    [string[]]$GlobalCMakeArgs = @(
        '--log-level=DEBUG'
        "-DCMAKE_BUILD_TYPE=$BuildTypeCMake"
        "-DCMAKE_INSTALL_PREFIX=$DependsPathForward"
        "-DCMAKE_PREFIX_PATH=$DependsPathForward/lib/cmake"
        '-DCMAKE_IGNORE_PATH=C:\Strawberry\perl\lib;C:\Strawberry\c\lib'
        "-DPKG_CONFIG_EXECUTABLE=$DependsPathForward/bin/pkgconf.exe"
    )

    Write-Host -fo Gray 'Configuring Visual Studio 2022 Dev Console...'
    if ([string]::IsNullOrWhiteSpace($env:VSCMD_VER) -or $env:VSCMD_VER -notmatch '^17\.\d+\.\d+$' -or $env:VSCMD_ARG_TGT_ARCH -ne $BuildArch) {
        $VSToolsPath = Get-Item 'C:\Program Files\Microsoft Visual Studio\2022\*\Common7\Tools\' -ErrorAction Ignore | Select-Object -Last 1 -ExpandProperty FullName
        $VSPSPath = "$VSToolsPath\Launch-VsDevShell.ps1"
        if ([string]::IsNullOrWhiteSpace($VSToolsPath) -or -not (Test-Path $VSToolsPath -PathType Container) -or -not (Test-Path $VSPSPath -PathType Leaf)) {
            $Err = [ErrorRecord]::new(
                [DirectoryNotFoundException]::new('Visual Studio 2022 not found.'), 'VisualStudioNotFound', 'ObjectNotFound', 'C:\Program Files\Microsoft Visual Studio\2022'
            )
            $PSCmdlet.WriteError($Err)
            return
        }
        & $VSPSPath -Latest -ExcludePrerelease -SkipAutomaticLocation -HostArch $env:PROCESSOR_ARCHITECTURE -Arch $BuildArch64Alt
        if ($env:VSCMD_VER -notmatch '^17\.\d+\.\d+$' -or $env:VSCMD_ARG_TGT_ARCH -ne $BuildArch -or $null -eq (Get-Command -CommandType Application 'nmake.exe')) {
            $Err = [ErrorRecord]::new(
                [InvalidPowerShellStateException]::new('Unable to properly configure the VS 2002 Dev Shell'),
                'VisualStudioConfigError', 'ResourceUnavailable', 'C:\Program Files\Microsoft Visual Studio\2022'
            )
            $PSCmdlet.WriteError($Err)
            return
        }
        $env:Platform = $env:VSCMD_ARG_TGT_ARCH
    }
    $VCPath = Get-Item 'C:\Program Files\Microsoft Visual Studio\2022\*\VC\' -ErrorAction Ignore | Select-Object -Last 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($VCPath)) {
        $Err = [ErrorRecord]::new(
            [InvalidPowerShellStateException]::new('VS2022 MSVC path not found!'),
            'VisualStudioConfigError', 'ResourceUnavailable', 'C:\Program Files\Microsoft Visual Studio\2022\*\VC'
        )
        $PSCmdlet.WriteError($Err)
        return
    }
    $env:YASMPATH = "$DependsPath\bin\"

    Write-Host -fo Cyan ('{0,25}' -f 'Type: ') -no
    Write-Host -fo $(if ($ISDEBUG) { 'Magenta' } else { 'Green' }) $BuildType
    Write-Host -fo Cyan ('{0,25}' -f 'Architecture: ') -no
    Write-Host -fo White "$BuildArch ($BuildArch64Alt)"
    Write-Host -fo Cyan ('{0,25}' -f 'QT Dev Mode: ') -no
    Write-Host -fo $(if ($QTDevMode) { 'Magenta' } else { 'Green' }) $QTDevMode
    Write-Host -fo Cyan ('{0,25}' -f 'GStreamer Dev Mode: ') -no
    Write-Host -fo $(if ($GStreamerDevMode) { 'Magenta' } else { 'Green' }) $GStreamerDevMode
    Write-Host -fo Cyan ('{0,25}' -f 'Download Path: ') -no
    Write-Host -fo White $DownloadPath
    Write-Host -fo Cyan ('{0,25}' -f 'Build Path: ') -no
    Write-Host -fo White $BuildPath
    Write-Host -fo Cyan ('{0,25}' -f 'Dependencies Path: ') -no
    Write-Host -fo White $DependsPath
    Write-Host "`n"

    Write-Host -fo White "Parsing version file '$VersionFile'..."

    if (-not (Test-Path $VersionFile)) {
        $Err = [ErrorRecord]::new(
            [FileNotFoundException]::new("Version file '$VersionFile' not found. Please run Get-Dependencies.ps1 first.", $VersionFile),
            'FileNotFound', 'ObjectNotFound', $VersionFile
        )
        $PSCmdlet.WriteError($Err)
        return
    }

    $VersionBase = Get-Content $VersionFile -Raw | ConvertFrom-StringData
    foreach ($Name in $VersionBase.Keys) {
        New-Variable -Name $Name -Value ($VersionBase[$Name]) -Force -Scope Script
        New-Variable -Name "${Name}_UNDERSCORE" -Value ($VersionBase[$Name] -creplace '\.', '_') -Force -Scope Script
        New-Variable -Name "${Name}_DASH" -Value ($VersionBase[$Name] -creplace '\.', '-') -Force -Scope Script
        New-Variable -Name "${Name}_STRIPPED" -Value ($VersionBase[$Name] -creplace '\.') -Force -Scope Script
    }

    if ($PrintVersions) {
        Write-Host -fo White "`nDependency Versions:"
        Get-ChildItem Variable:\*_VERSION | ForEach-Object {
            Write-Host -fo Cyan ('{0,32}: ' -f $_.Name) -no
            Write-Host -fo White $_.Value
        }
    }

    #endregion
    #region Directories
    Write-Host -fo Gray "`nChecking paths..."
    Write-Host -fo White ('{0,-80}' -f "Checking downloads path '$DownloadPath'...  ") -NoNewline
    if (-not (Test-Path $DownloadPath -PathType Container)) {
        Write-Host -fo Red 'NOT FOUND'
        $Err = [ErrorRecord]::new(
            [DirectoryNotFoundException]::new("Downloads path '$DownloadPath' not found. Please run Get-Dependencies.ps1 first."),
            'DirectoryNotFound', 'ObjectNotFound', $DownloadPath
        )
        $PSCmdlet.WriteError($Err)
        return
    }
    Write-Host -fo Green 'GOOD'
    $BasePaths = $BuildPath, $DependsPath, $TempPath
    $FromScratchPaths = "$DependsPath\bin", "$DependsPath\lib", "$DependsPath\include"
    $SearchPaths = if ($FromScratch) { $BasePaths + $FromScratchPaths } else { $BasePaths }
    foreach ($CriticalPath in $SearchPaths) {
        Write-Host -fo White ('{0,-80}' -f "Checking source/build path '$CriticalPath'...  ") -NoNewline
        if (-not (Test-Path $CriticalPath -PathType Container)) {
            $null = New-Item $CriticalPath -ItemType Directory -Force -ErrorAction SilentlyContinue
            if (-not $? -or -not (Test-Path $CriticalPath -PathType Container)) { Write-Host -fo Red 'FAILED TO CREATE'; return }
            Write-Host -fo Cyan 'CREATED'
        } else { Write-Host -fo Green 'GOOD' }
    }

    $SPerlPkgConfig = Get-Command pkg-config -All -ErrorAction Ignore | Where-Object Source -Like '*\perl\bin\pkg-config*'
    Write-Host -fo White ('{0,-80}' -f 'Removing pkg-config instances from Strawberry Perl...') -NoNewline
    if ($null -ne $SPerlPkgConfig) {
        $SPerlBin = Split-Path ($SPerlPkgConfig | Select-Object -First 1 -ExpandProperty Source)
        Compress-Archive -LiteralPath $SPerlPkgConfig.Source -DestinationPath "$SPerlBin\_disabled_pkgconfig.zip" -CompressionLevel Fastest -Update
        if (-not $?) { Write-Host -fo Red 'FAILED TO ARCHIVE'; return }
        Remove-Item -LiteralPath $SPerlPkgConfig.Source
        if (-not $? -or (Test-Path $SPerlPkgConfig.Source -ErrorAction Ignore) -contains $true) {
            Write-Host -fo Red 'FAILED TO DELETE'; return
        }
        Write-Host -fo Cyan 'REMOVED'
    } else { Write-Host -fo Green 'GOOD' }

    #endregion
    #region Build Tools

    Write-Host -fo Gray "`nChecking build tools..."
    $Git4Win = 'Git for Windows: https://github.com/git-for-windows/git/releases/latest'
    $WFlexBison = 'Win-Flex-Bison (Extract to C:\Program Files\win_flex_bison): https://sourceforge.net/projects/winflexbison/'
    $ToolsList = @{
        "$env:ProgramFiles\Git\usr\bin\patch.exe"        = $Git4Win
        "$env:ProgramFiles\Git\usr\bin\sed.exe"          = $Git4Win
        "$env:ProgramFiles\Git\usr\bin\tar.exe"          = $Git4Win
        "$env:ProgramFiles\Git\usr\bin\bzip2.exe"        = $Git4Win
        "$env:ProgramFiles\nasm\nasm.exe"                = 'NASM: https://www.nasm.us/'
        "$env:ProgramFiles\win_flex_bison\win_flex.exe"  = $WFlexBison
        "$env:ProgramFiles\win_flex_bison\win_bison.exe" = $WFlexBison
        "$env:SystemDrive\Strawberry\perl\bin\perl.exe"  = 'Strawberry Perl: https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/latest'
        "$env:ProgramFiles\Python3*\python.exe"          = 'Python (All users, add to PATH): https://www.python.org/downloads/'
        "$env:ProgramFiles\7-Zip\7z.exe"                 = '7-Zip: https://www.7-zip.org/download.html'
        "$env:ProgramFiles\CMake\bin\cmake.exe"          = 'CMake: https://cmake.org/download/'
        "$env:ProgramFiles\Meson\meson.exe"              = 'Meson: https://github.com/mesonbuild/meson/releases/latest'
        'nmake.exe'                                      = 'Visual Studio 2022 Community (Check "Desktop development with C++"): https://visualstudio.microsoft.com/vs/'
    }

    foreach ($BinPath in $ToolsList.Keys) {
        $Command = Split-Path $BinPath -Leaf
        Write-Host -fo White ('{0,-80}' -f "Checking '$Command'...  ") -NoNewline
        if ($null -eq (Get-Command -CommandType Application $Command -ErrorAction Ignore)) {
            $Success = $false
            if (Test-Path $BinPath -PathType Leaf) {
                $BinDir = Split-Path $BinPath -Parent | Get-Item | Select-Object -Last 1 -ExpandProperty FullName
                $env:PATH = "$env:PATH;$BinDir"
                $Success = $null -ne (Get-Command -CommandType Application $Command -ErrorAction Ignore)
            }
            if (-not $Success) {
                Write-Host -fo Red 'FAILED'
                $Err = [ErrorRecord]::new(
                    [CommandNotFoundException]::new("Build tool '$Command' not found! Please install $($ToolsList[$BinPath])"),
                    'CommandNotFound', 'ObjectNotFound', $BinPath
                )
                $PSCmdlet.WriteError($Err)
                return
            }
            Write-Host -fo Cyan 'ADDED TO PATH'
        } else {
            Write-Host -fo Green 'GOOD'
        }
    }

    if ((Test-Path "$DependsPath\bin\pkgconf.exe") -and -not (Test-Path "$DependsPath\bin\pkg-config.exe")) {
        Write-Host -fo Cyan '    Copy pkgconf -> pkg-config...'
        Copy-Item "$DependsPath\bin\pkgconf.exe" "$DependsPath\bin\pkg-config.exe" -Force
    }

    function GetRepoCommit {
        param([string]$Folder)
        $Branch = git.exe --git-dir="$DownloadPath\$Folder\.git" rev-parse --abbrev-ref HEAD
        $Commit = git.exe --git-dir="$DownloadPath\$Folder\.git" rev-parse --short HEAD
        "${Branch}@$Commit"
    }

    $env:PATH = ($env:PATH -split [Path]::PathSeparator | Select-Object -Unique) -join [Path]::PathSeparator
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    $env:TMP = $env:TEMP = $TempPath

    $DoContinue = $true
    #endregion
}

process {

    if (-not $DoContinue) { return }

    #region Build Steps

    function BuildYasm {
        $LocalBuildPath = "$BuildPath\yasm"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\yasm" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\yasm-cmake.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildPkgConf {
        $LocalBuildPath = "$BuildPath\pkgconf-pkgconf-$PKGCONF_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\pkgconf-$PKGCONF_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --prefix="$DependsPath" `
                --wrap-mode=nodownload "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy pkgconf -> pkg-config...'
        Copy-Item "$DependsPath\bin\pkgconf.exe" "$DependsPath\bin\pkg-config.exe" -Force
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGetOpt {
        $LocalBuildPath = "$BuildPath\getopt-win"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\getopt-win" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        # Get-Content "$DownloadPath\getopt-win-cmake.patch" | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_TESTING=OFF `
            -DBUILD_STATIC_LIBS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildZlib {
        $LocalBuildPath = "$BuildPath\zlib-$ZLIB_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\zlib-$ZLIB_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ((Test-Path "$DependsPath\share\pkgconfig\zlib.pc") -and -not (Test-Path "$DependsPath\lib\pkgconfig\zlib.pc")) {
            Write-Host -fo Cyan '    Copy pkgconfig...'
            Copy-Item "$DependsPath\share\pkgconfig\zlib.pc" "$DependsPath\lib\pkgconfig\" -Force
        }
        if (-not $?) { return }
        if ($ISDEBUG) {
            Write-Host -fo Cyan "    Patch pkgconfig z -> z$DebugPostfix..."
            foreach ($File in (Get-ChildItem "$DependsPath\*\pkgconfig\zlib.pc")) {
                (Get-Content $File) -creplace '-lz\b', "-lz$DebugPostfix" | Set-Content $File
                if (-not $?) { return }
            }
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Copy libraries...'
        if ((Test-Path "$DependsPath\lib\z$DebugPostfix.lib") -and -not (Test-Path "$DependsPath\lib\z.lib")) {
            Copy-Item "$DependsPath\lib\z$DebugPostfix.lib" "$DependsPath\lib\z.lib" -Force
            if (-not $?) { return }
        }
        if (-not (Test-Path "$DependsPath\lib\zlib$DebugPostfix.lib")) { Copy-Item "$DependsPath\lib\z$DebugPostfix.lib" "$DependsPath\lib\zlib$DebugPostfix.lib" -Force }
        # Write-Host -fo Cyan '    Remove static libraries...'
        # Remove-Item "$DependsPath\lib\zlibstatic*.lib" -Force
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildOpenSSL {
        $LocalBuildPath = "$BuildPath\openssl-$OPENSSL_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\openssl-$OPENSSL_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Push-Location $LocalBuildPath
        Write-Host -fo Cyan '    Perl configure...'
        $ZLibInfix = if ($BuildArch -eq 'arm64') { '' } else { 'zlib' }
        perl.exe Configure $PerlArch shared $ZLibInfix no-tests --prefix="$DependsPath" `
            --libdir="lib" `
            --openssldir="$DependsPath\ssl" `
            --$BuildType `
            --with-zlib-include="$DependsPath\include" `
            --with-zlib-lib="$DependsPath\lib\zlib$DebugPostfix.lib" | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Write-Host -fo Cyan '    NMake build...'
        nmake.exe /f "$LocalBuildPath\makefile" MAKEDIR="$LocalBuildPath" | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Write-Host -fo Cyan '    NMake install...'
        nmake.exe /f "$LocalBuildPath\makefile" MAKEDIR="$LocalBuildPath" install_sw | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Pop-Location
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$DependsPath\lib\libssl.lib" "$DependsPath\lib\ssl.lib" -Force
        if (-not $?) { return }
        Copy-Item "$DependsPath\lib\libcrypto.lib" "$DependsPath\lib\crypto.lib" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfigs...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\libcrypto.pc" -Force -Value @"
$PkgconfTemplate
enginesdir=`${libdir}/engines-3
modulesdir=`${libdir}/ossl-modules

Name: OpenSSL-libcrypto
Description: OpenSSL cryptography library
Version: $OPENSSL_VERSION
Libs: -L`${libdir} -lcrypto
Libs.private: -lz -ldl -pthread
Cflags: -DOPENSSL_LOAD_CONF -I`${includedir}
"@
        if (-not $?) { return }
        Set-Content -Path "$DependsPath\lib\pkgconfig\libssl.pc" -Value @"
$PkgconfTemplate

Name: OpenSSL-libssl
Description: Secure Sockets Layer and cryptography libraries
Version: $OPENSSL_VERSION
Requires.private: libcrypto
Libs: -L`${libdir} -lssl
Cflags: -DOPENSSL_LOAD_CONF -I`${includedir}
"@
        if (-not $?) { return }
        Set-Content -Path "$DependsPath\lib\pkgconfig\openssl.pc" -Value @"
$PkgconfTemplate

Name: OpenSSL
Description: Secure Sockets Layer and cryptography libraries and tools
Version: $OPENSSL_VERSION
Requires: libssl libcrypto
"@
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibpng {
        $LocalBuildPath = "$BuildPath\libpng-$LIBPNG_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\libpng-$LIBPNG_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        # Get-Content "$DownloadPath\libpng-pkgconf.patch" | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        (Get-Content "$LocalBuildPath\CMakeLists.txt" -Raw) -replace
        '(?ms)^(\s*)(if\(NOT (?:CMAKE_HOST_)?WIN32 OR CYGWIN OR MINGW\))(.+?)^\1(endif\(\))', '$1# $2$3$1# $4' -replace
        '(set\(LIBS "-lz -lm"\))', '# $1' | Set-Content "$LocalBuildPath\CMakeLists.txt" -NoNewline
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($ISDEBUG) {
            Write-Host -fo Cyan '    Copy libraries...'
            Copy-Item "$DependsPath\lib\libpng16$DebugPostfix.lib" "$DependsPath\lib\png16.lib" -Force
        }
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibjpeg {
        $LocalBuildPath = "$BuildPath\libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        $SIMD = if ($BuildArch -in 'x86', 'x64') { 'ON' } else { 'OFF' }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DENABLE_SHARED=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" `
            -DENABLE_STATIC=OFF `
            -DWITH_SIMD="$SIMD" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildPcre2 {
        $LocalBuildPath = "$BuildPath\pcre2-$PCRE2_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\pcre2-$PCRE2_VERSION.tar.bz2" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DPCRE2_BUILD_PCRE2_16=ON `
            -DPCRE2_BUILD_PCRE2_32=ON `
            -DPCRE2_BUILD_PCRE2_8=ON `
            -DPCRE2_BUILD_TESTS=OFF `
            -DPCRE2_SUPPORT_UNICODE=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildBzip2 {
        $LocalBuildPath = "$BuildPath\bzip2-$BZIP2_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\bzip2-$BZIP2_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\bzip2-cmake.patch" | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildXz {
        $LocalBuildPath = "$BuildPath\xz-$XZ_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\xz-$XZ_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DBUILD_TESTING=OFF `
            -DXZ_NLS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildBrotli {
        $LocalBuildPath = "$BuildPath\brotli-$BROTLI_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\brotli-$BROTLI_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_TESTING=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildIcu4c {
        $LocalBuildPath = "$BuildPath\icu"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            if (Test-Path "$DownloadPath\icu4c-$ICU4C_VERSION-sources.zip") {
                7z.exe x "$DownloadPath\icu4c-$ICU4C_VERSION-sources.zip" -o"$BuildPath" | Out-Default
            } elseif (Test-Path "$DownloadPath\icu4c-$ICU4C_VERSION_UNDERSCORE-src.zip") {
                7z.exe x "$DownloadPath\icu4c-$ICU4C_VERSION_UNDERSCORE-src.zip" -o"$BuildPath" | Out-Default
            } else {
                Write-Error "Icu4c not found at '$DownloadPath\icu4c-$ICU4C_VERSION-sources.zip'."; return
            }
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\source\allinone\Backup\allinone.sln")) {
            Write-Host -fo Cyan '    Upgrade VS solution...'
            Start-Process devenv.exe -ArgumentList "$LocalBuildPath\source\allinone\allinone.sln", '/upgrade' -Wait
            if ($LASTEXITCODE -ne 0) { return }
        }
        (Get-Content -Raw "$LocalBuildPath\source\allinone\Build.Windows.ProjectConfiguration.props") -replace
        '\b10\.0\.\d{5}\.\d+\b', $env:WindowsSDKVersion | Set-Content -NoNewline "$LocalBuildPath\source\allinone\Build.Windows.ProjectConfiguration.props"
        Write-Host -fo Cyan '    MSBuild build...'
        msbuild.exe "$LocalBuildPath\source\allinone\allinone.sln" -p:Configuration="$BuildType" -p:Platform="$BuildArch32Alt" -p:SkipUWP=true | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if (-not (Test-Path "$DependsPath\include\unicode" -PathType Container)) {
            Write-Host -fo Cyan '    Create includes subdirectory...'
            $null = New-Item "$DependsPath\include\unicode" -ItemType Directory -Force
            if (-not $?) { return }
        }
        $ArchSuffix = if ($BuildArch -eq 'x64') { '64' } else { '' }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\include\unicode\*.h" "$DependsPath\include\unicode\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\lib$ArchSuffix\*.*" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\bin$ArchSuffix\*.*" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfigs...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\icu-uc.pc" -Value @"
$PkgconfTemplate

Name: icu-uc
Description: International Components for Unicode: Common and Data libraries
Version: $ICU4C_VERSION
Libs: -L`${libdir} -licuuc$DebugPostfix -licudt
Libs.private: -lpthread -lm
"@
        if (-not $?) { return }
        Set-Content -Path "$DependsPath\lib\pkgconfig\icu-i18n.pc" -Value @"
$PkgconfTemplate

Name: icu-i18n
Description: International Components for Unicode: Internationalization Library
Version: $ICU4C_VERSION
Libs: -licuin$DebugPostfix
Requires: icu-uc
"@
        if (-not $?) { return }
        Set-Content -Path "$DependsPath\lib\pkgconfig\icu-io.pc" -Value @"
$PkgconfTemplate

Name: icu-io
Description: International Components for Unicode: Stream and I/O Library
Version: $ICU4C_VERSION
Libs: -licuio$DebugPostfix
Requires: icu-i18n
"@
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildPixman {
        $LocalBuildPath = "$BuildPath\pixman-$PIXMAN_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\pixman-$PIXMAN_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dgtk=disabled `
                -Dlibpng=enabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildExpat {
        $LocalBuildPath = "$BuildPath\expat-$EXPAT_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\expat-$EXPAT_VERSION.tar.bz2" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DEXPAT_SHARED_LIBS=ON `
            -DEXPAT_BUILD_DOCS=OFF `
            -DEXPAT_BUILD_EXAMPLES=OFF `
            -DEXPAT_BUILD_FUZZERS=OFF `
            -DEXPAT_BUILD_TESTS=OFF `
            -DEXPAT_BUILD_TOOLS=OFF `
            -DEXPAT_BUILD_PKGCONFIG=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildBoost {
        $LocalBuildPath = "$BuildPath\boost_$BOOST_VERSION_UNDERSCORE"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        $B2Arch = if ($BuildArch -like 'arm*' ) { 'arm' } else { 'x86' }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\boost_$BOOST_VERSION_UNDERSCORE.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        foreach ($DelPath in 'b2.exe', 'bjam.exe', 'stage') {
            if (Test-Path "$LocalBuildPath\$DelPath") { Remove-Item "$LocalBuildPath\$DelPath" -Force -Recurse }
            if (-not $?) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Push-Location $LocalBuildPath
        .\bootstrap.bat msvc | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        .\b2.exe -a -q -j $env:NUMBER_OF_PROCESSORS -d2 --ignore-site-config `
            --stagedir="$LocalBuildPath\stage" `
            --build-dir="$LocalBuildPath\build" `
            --layout="tagged" `
            --prefix="$DependsPath" `
            --exec-prefix="$DependsPath\bin" `
            --libdir="$DependsPath\lib" `
            --includedir="$DependsPath\include" `
            --with-headers architecture=$B2Arch `
            address-model=$BuildAddressSize `
            variant=$BuildType `
            toolset=msvc `
            link=shared `
            runtime-link=shared `
            threadapi=win32 `
            threading=multi `
            install | Out-Default
        Pop-Location
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibxml2 {
        $LocalBuildPath = "$BuildPath\libxml2-v$LIBXML2_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\libxml2-v$LIBXML2_VERSION.tar.bz2" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DICU_ROOT="$DependsPathForward" `
            -DBUILD_SHARED_LIBS=ON `
            -DLIBXML2_WITH_PYTHON=OFF `
            -DLIBXML2_WITH_ZLIB=ON `
            -DLIBXML2_WITH_LZMA=ON `
            -DLIBXML2_WITH_ICONV=OFF `
            -DLIBXML2_WITH_ICU=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($ISDEBUG) {
            Write-Host -fo Cyan '    Duplicate debug library...'
            Copy-Item "$DependsPath\lib\libxml2$DebugPostfix.lib" "$DependsPath\lib\libxml2.lib" -Force
        }
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildNghttp2 {
        $LocalBuildPath = "$BuildPath\nghttp2-$NGHTTP2_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\nghttp2-$NGHTTP2_VERSION.tar.bz2" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibffi {
        $LocalBuildPath = "$BuildPath\libffi"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\libffi" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --wrap-mode=nodownload `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibintl {
        $LocalBuildPath = "$BuildPath\proxy-libintl-${PROXY_LIBINTL_VERSION}"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\proxy-libintl-${PROXY_LIBINTL_VERSION}.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --wrap-mode=nodownload `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildDlfcn {
        $LocalBuildPath = "$BuildPath\dlfcn-win32-$DLFCN_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\dlfcn-win32-$DLFCN_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibpsl {
        $LocalBuildPath = "$BuildPath\libpsl-$LIBPSL_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\libpsl-$LIBPSL_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --wrap-mode=nodownload `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                -Dc_args="-I$DependsPathForward/include" `
                -Dc_link_args="-L$DependsPath\lib" `
                -Druntime=libicu `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildOrc {
        $LocalBuildPath = "$BuildPath\orc-$ORC_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            7z.exe x -aos "$DownloadPath\orc-$ORC_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            7z.exe x -aoa "$DownloadPath\orc-$ORC_VERSION.tar" -o"$BuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --wrap-mode=nodownload `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildSqlite {
        $LocalBuildPath = "$BuildPath\sqlite-autoconf-$SQLITE_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\sqlite-autoconf-$SQLITE_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    CL build...'
        Push-Location $LocalBuildPath
        cl -DSQLITE_API='__declspec(dllexport)' -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_COLUMN_METADATA 'sqlite3.c' -link -dll -out:'sqlite3.dll'
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        cl 'shell.c' 'sqlite3.c' -Fe:'sqlite3.exe'
        Pop-Location
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\*.h" "$DependsPath\include\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\*.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\*.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Copy-Item "$LocalBuildPath\*.exe" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\sqlite3.pc" -Value @"
$PkgconfTemplate

Name: SQLite
Description: SQL database engine
URL: https://www.sqlite.org/
Version: 3.38.1
Libs: -L`${libdir} -lsqlite3
Libs.private: -lz -ldl
Cflags: -I`${includedir}
"@
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGlib {
        $LocalBuildPath = "$BuildPath\glib-$GLIB_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            7z.exe x -aos "$DownloadPath\glib-$GLIB_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            7z.exe x -snld -aoa "$DownloadPath\glib-$GLIB_VERSION.tar" -o"$BuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPathForward" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --includedir="$DependsPath\include" `
                --libdir="$DependsPath\lib" `
                --wrap-mode=nodownload `
                -Dtests=false `
                -Dc_args="-I$DependsPath\include" `
                -Dcpp_args="-I$DependsPath\include" `
                -Dc_link_args="-L$DependsPath\lib" `
                -Dcpp_link_args="-L$DependsPath\lib" `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibsoup {
        $LocalBuildPath = "$BuildPath\libsoup-$LIBSOUP_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            7z.exe x -aos "$DownloadPath\libsoup-$LIBSOUP_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            7z.exe x -aoa "$DownloadPath\libsoup-$LIBSOUP_VERSION.tar" -o"$BuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                -Dc_args="-I$DependsPathForward/include" `
                --includedir="$DependsPath\include" `
                --libdir="$DependsPath\lib" `
                -Dtests=false `
                -Dvapi=disabled `
                -Dgssapi=disabled `
                -Dintrospection=disabled `
                -Dtests=false `
                -Dsysprof=disabled `
                -Dtls_check=false `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGlibNetworking {
        $LocalBuildPath = "$BuildPath\glib-networking"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\glib-networking" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\glib-networking.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                -Dc_args="-I$DependsPathForward/include" `
                --includedir="$DependsPath\include" `
                --libdir="$DependsPath\lib" `
                -Dgnutls=disabled `
                -Dopenssl=enabled `
                -Dgnome_proxy=disabled `
                -Dlibproxy=disabled `
                -Dtests=false `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildFreetype {
        param(
            [switch]$NoHarfbuzz
        )
        $LocalBuildPath = "$BuildPath\freetype-$FREETYPE_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\freetype-$FREETYPE_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        $HarfbuzzDisable = if (-not $NoHarfbuzz -and (Test-Path ($BUILD_TARGETS["Harfbuzz $HARFBUZZ_VERSION"][2]))) { 'OFF' } else { 'ON' }
        Write-Host -fo White '    Harfbuzz available: ' -NoNewline
        if ($HarfbuzzDisable -eq 'OFF') { Write-Host -fo Green 'YES' } else { Write-Host -fo Red 'NO' }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DFT_DISABLE_HARFBUZZ="$HarfbuzzDisable" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($ISDEBUG) {
            Write-Host -fo Cyan '    Duplicate debug library...'
            Copy-Item "$DependsPath\lib\freetype$DebugPostfix.lib" "$DependsPath\lib\freetype.lib" -Force
        }
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildHarfbuzz {
        $LocalBuildPath = "$BuildPath\harfbuzz-$HARFBUZZ_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            7z.exe x -aos "$DownloadPath\harfbuzz-$HARFBUZZ_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            7z.exe x -aoa "$DownloadPath\harfbuzz-$HARFBUZZ_VERSION.tar" -o"$BuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                -Dc_args="-I$DependsPathForward/include" `
                -Dcpp_args="-I$DependsPathForward/include" `
                -Dc_link_args="-L$DependsPath\lib" `
                --includedir="$DependsPath\include" `
                --libdir="$DependsPath\lib" `
                -Dcpp_std="c++17" `
                -Dtests=disabled `
                -Ddocs=disabled `
                -Dicu=enabled `
                -Dfreetype=enabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibogg {
        $LocalBuildPath = "$BuildPath\libogg-$LIBOGG_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\libogg-$LIBOGG_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DINSTALL_DOCS=OFF `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibvorbis {
        $LocalBuildPath = "$BuildPath\libvorbis-$LIBVORBIS_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\libvorbis-$LIBVORBIS_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DINSTALL_DOCS=OFF `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildFlac {
        $LocalBuildPath = "$BuildPath\flac-$FLAC_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            7z.exe x -aos "$DownloadPath\flac-$FLAC_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            7z.exe x -aoa "$DownloadPath\flac-$FLAC_VERSION.tar" -o"$BuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_DOCS=OFF `
            -DBUILD_EXAMPLES=OFF `
            -DINSTALL_MANPAGES=OFF `
            -DBUILD_TESTING=OFF `
            -DBUILD_PROGRAMS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildWavpack {
        $LocalBuildPath = "$BuildPath\wavpack-$WAVPACK_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\wavpack-$WAVPACK_VERSION.tar.bz2" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_TESTING=OFF `
            -DWAVPACK_BUILD_DOCS=OFF `
            -DWAVPACK_BUILD_PROGRAMS=OFF `
            -DWAVPACK_ENABLE_ASM=OFF `
            -DWAVPACK_ENABLE_LEGACY=OFF `
            -DWAVPACK_BUILD_WINAMP_PLUGIN=OFF `
            -DWAVPACK_BUILD_COOLEDIT_PLUGIN=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        Write-Host -fo Cyan '    Duplicate library...'
        switch ("$DependsPath\lib") {
            { Test-Path "$_\wavpackdll.lib" } { Copy-Item "$_\wavpackdll.lib" "$_\wavpack.lib" }
            { Test-Path "$_\libwavpack.dll.a" } { Copy-Item "$_\libwavpack.dll.a" "$_\wavpack.lib" }
            default { Write-Error "Unable to find output lib in path '$_'!" }
        }
        if (-not $?) { return }
        Write-Host -fo Cyan '    Duplicate binary...'
        switch ("$DependsPath\bin") {
            { Test-Path "$_\wavpackdll.dll" } { Copy-Item "$_\wavpackdll.dll" "$_\wavpack.dll" }
            { Test-Path "$_\libwavpack-1.dll" } { Copy-Item "$_\libwavpack-1.dll" "$_\wavpack.dll" }
            default { Write-Error "Unable to find output binary in path '$_'!" }
        }
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildOpus {
        $LocalBuildPath = "$BuildPath\opus-$OPUS_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\opus-$OPUS_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildOpusfile {
        $LocalBuildPath = "$BuildPath\opusfile-$OPUSFILE_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\opusfile-$OPUSFILE_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\opusfile-cmake.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildSpeex {
        $LocalBuildPath = "$BuildPath\speex-Speex-$SPEEX_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\speex-Speex-$SPEEX_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\speex-cmake.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($ISDEBUG) {
            Write-Host -fo Cyan '    Duplicate debug library...'
            Copy-Item "$DependsPath\lib\libspeexd.lib" "$DependsPath\lib\libspeex.lib" -Force
            if (-not $?) { return }
            Write-Host -fo Cyan '    Duplicate debug binary...'
            Copy-Item "$DependsPath\bin\libspeexd.dll" "$DependsPath\bin\libspeex.dll" -Force
        }
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibmpg123 {
        $LocalBuildPath = "$BuildPath\mpg123-$MPG123_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\mpg123-$MPG123_VERSION.tar.bz2" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build_cmake" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build_cmake" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S "$LocalBuildPath\ports\cmake" -B "$LocalBuildPath\build_cmake" -G $CMakeGenerator `
            -DYASM_ASSEMBLER="$DependsPathForward/bin/vsyasm.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_PROGRAMS=OFF `
            -DBUILD_LIBOUT123=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build_cmake" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build_cmake" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLame {
        $LocalBuildPath = "$BuildPath\lame-$LAME_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\lame-$LAME_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        (Get-Content "$LocalBuildPath\Makefile.MSVC") -creplace '^(MACHINE = /machine:).+$', "`$1$($BuildArch.ToUpperInvariant())" | Set-Content "$LocalBuildPath\Makefile.MSVC"
        if (-not $?) { return }
        Push-Location $LocalBuildPath
        Write-Host -fo Cyan '    NMake build...'
        nmake.exe /F "$LocalBuildPath\Makefile.MSVC" MSVCVER=Win64 MAKEDIR="$LocalBuildPath" libmp3lame.dll | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Pop-Location
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\output\libmp3lame*.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\output\libmp3lame*.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\include\*.h" "$DependsPath\include\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\mp3lame.pc" -Force -Value @"
$PkgconfTemplate

Name: lame
Description: encoder that converts audio to the MP3 file format.
URL: https://lame.sourceforge.io/
Version: $LAME_VERSION
Libs: -L`${libdir} -lmp3lame
Cflags: -I`${includedir}
"@
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildTwolame {
        $LocalBuildPath = "$BuildPath\twolame-$TWOLAME_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\twolame-$TWOLAME_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\twolame.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\win32\Backup\libtwolame_dll.sln")) {
            Write-Host -fo Cyan '    Upgrade VS solution...'
            Start-Process devenv.exe -ArgumentList "$LocalBuildPath\win32\libtwolame_dll.sln", '/upgrade' -Wait
            if ($LASTEXITCODE -ne 0) { return }
        }
        if ($BuildArch -ne 'x86') {
            Write-Host -fo Cyan "    Patch solution for $BuildArch build..."
            foreach ($File in (Get-ChildItem "$LocalBuildPath\win32\*" -Include 'libtwolame_dll.sln', 'libtwolame_dll.vcxproj')) {
                (Get-Content $File) -creplace '\bWin32\b', $BuildArch -creplace '\bMachineX86\b', "Machine$($BuildArch.ToUpperInvariant())" | Set-Content $File
                if (-not $?) { return }
            }
        }
        Push-Location "$LocalBuildPath\win32"
        Write-Host -fo Cyan '    MSBuild build...'
        msbuild.exe 'libtwolame_dll.sln' -p:Configuration="$BuildType" -p:Platform="$BuildArch32Alt" -p:SkipUWP=true | Out-Default
        Pop-Location
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\libtwolame\twolame.h" "$DependsPath\include\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\win32\lib\*.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\win32\lib\*.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\twolame.pc" -Force -Value @"
$PkgconfTemplate

Name: lame
Description: optimised MPEG Audio Layer 2 (MP2) encoder based on tooLAME
URL: https://www.twolame.org/
Version: $TWOLAME_VERSION
Libs: -L`${libdir} -ltwolame_dll
Cflags: -I`${includedir}
"@
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildFftw3 {
        $LocalBuildPath = "$BuildPath\fftw-$FFTW_SOURCE_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            # 7z.exe x -aoa "$DownloadPath\fftw-$FFTW_VERSION-$BuildArch-$BuildType.zip" -o"$LocalBuildPath" | Out-Default
            # tar.exe -xf "$DownloadPath\fftw-x86_64-w64-mingw32-$BuildType-$FFTW_VERSION.tar.xz" -C $BuildPath | Out-Default
            tar.exe -xf "$DownloadPath\fftw-${FFTW_SOURCE_VERSION}.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Get-Content "$DownloadPath\fftw-fixes.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        if ($BuildArch -eq 'x86') { $UseAVX = 'OFF' } else { $UseAVX = 'ON' } # 32-bit version likely to run on older HW
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_TESTS=OFF `
            -DENABLE_AVX="$UseAVX" `
            -DENABLE_AVX2=OFF `
            -DENABLE_SSE=ON `
            -DENABLE_SSE2=ON `
            -DENABLE_THREADS=ON `
            -DWITH_COMBINED_THREADS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if (-not (Test-Path "$DependsPath\bin\fftw3.dll") -and (Test-Path "$DependsPath\bin\libfftw3-3.dll")) {
            Copy-Item "$DependsPath\bin\libfftw3-3.dll" "$DependsPath\bin\fftw3.dll"
        }
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildMusepack {
        $LocalBuildPath = "$BuildPath\musepack_src_r$MUSEPACK_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\musepack_src_r$MUSEPACK_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\musepack-fixes.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Patch log2() collision...'
        foreach ($File in (Get-ChildItem "$LocalBuildPath\libmpc*\*.c")) {
            (Get-Content $File) -creplace '\blog2\b', 'log2_arr' | Set-Content $File
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DSHARED=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" `
            -DCMAKE_POLICY_DEFAULT_CMP0115="OLD" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\build\libmpcdec\*.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\build\libmpcdec\*.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\mpcdec.pc" -Force -Value @"
$PkgconfTemplate

Name: mpc
Description: An audio compression format with a strong emphasis on high quality
URL: https://www.musepack.net/
Version: $MUSEPACK_VERSION
Libs: -L`${libdir} -lmpcdec
Cflags: -I`${includedir}
"@
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibopenmpt {
        $LocalBuildPath = "$BuildPath\libopenmpt-$LIBOPENMPT_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            7z.exe x -aoa "$DownloadPath\libopenmpt-${LIBOPENMPT_VERSION}+release.msvc.zip" -o"$LocalBuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\libopenmpt-cmake.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build_cmake" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build_cmake" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build_cmake" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build_cmake" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build_cmake" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibgme {
        $LocalBuildPath = "$BuildPath\libgme-$LIBGME_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\libgme-$LIBGME_VERSION-src.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        # Get-Content "$DownloadPath\libgme-pkgconf.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildFdkaac {
        $LocalBuildPath = "$BuildPath\fdk-aac-$FDK_AAC_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\fdk-aac-$FDK_AAC_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_PROGRAMS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildFaad2 {
        $LocalBuildPath = "$BuildPath\faad2-$FAAD2_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\faad2-$FAAD2_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            Get-Item "$BuildPath\knik0-faad2-*" | Rename-Item -NewName $LocalBuildPath -Force
            if (-not $?) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildFaac {
        $LocalBuildPath = "$BuildPath\faac-faac-$FAAC_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\faac-$FAAC_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dc_args="-I$DependsPathForward/include" `
                -Dcpp_args="-I$DependsPathForward/include" `
                -Dfrontend=false `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildUtfcpp {
        $LocalBuildPath = "$BuildPath\utfcpp-$UTFCPP_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\utfcpp-$UTFCPP_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildTaglib {
        $LocalBuildPath = "$BuildPath\taglib-$TAGLIB_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\taglib-$TAGLIB_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibbs2b {
        $LocalBuildPath = "$BuildPath\libbs2b-$LIBBS2B_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\libbs2b-$LIBBS2B_VERSION.tar.bz2" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\libbs2b-msvc.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibebur128 {
        $LocalBuildPath = "$BuildPath\libebur128-$LIBEBUR128_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\libebur128-$LIBEBUR128_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        (Get-Content "$LocalBuildPath\ebur128\libebur128.pc.cmake") -creplace '^Libs\.private:.+' | Set-Content "$LocalBuildPath\ebur128\libebur128.pc.cmake"
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildFfmpeg {
        $LocalBuildPath = "$BuildPath\ffmpeg"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\ffmpeg" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        $TargetBranch = if ($BuildArch -eq 'x86') { $FFMPEG_X86_VERSION } else { $FFMPEG_VERSION }
        git.exe -C $LocalBuildPath checkout "meson-$TargetBranch"
        git.exe -C $LocalBuildPath pull
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=both `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dtests=disabled `
                -Dgpl=enabled `
                -Diconv=disabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildChromaprint {
        $LocalBuildPath = "$BuildPath\chromaprint-$CHROMAPRINT_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\chromaprint-$CHROMAPRINT_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DFFMPEG_ROOT="$DependsPath" `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGstreamer {
        if ($GStreamerDevMode) {
            $LocalBuildPath = "$BuildPath\gstreamer"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\gstreamer\subprojects\gstreamer" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
            }
        } else {
            $LocalBuildPath = "$BuildPath\gstreamer-$GSTREAMER_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\gstreamer-$GSTREAMER_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\gstreamer-$GSTREAMER_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        # Write-Host -fo Cyan '    Patch build configuration...'
        # Get-Content "$DownloadPath\gstreamer-macros-restrict.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dc_args="-I$DependsPathForward/include" `
                -Dexamples=disabled `
                -Dtests=disabled `
                -Dbenchmarks=disabled `
                -Dtools=enabled `
                -Dintrospection=disabled `
                -Dnls=disabled `
                -Ddoc=disabled `
                -Dgst_debug=true `
                -Dgst_parse=true `
                -Dregistry=true `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGstpluginsbase {
        if ($GStreamerDevMode) {
            $LocalBuildPath = "$BuildPath\gst-plugins-base"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\gstreamer\subprojects\gst-plugins-base" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
            }
        } else {
            $LocalBuildPath = "$BuildPath\gst-plugins-base-$GSTREAMER_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\gst-plugins-base-$GSTREAMER_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\gst-plugins-base-$GSTREAMER_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --prefix="$DependsPath" --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dc_args="-I$DependsPathForward/include -I$DependsPathForward/include/opus" `
                --auto-features=disabled `
                -Dexamples=disabled `
                -Dtests=disabled `
                -Dtools=enabled `
                -Dintrospection=disabled `
                -Dnls=disabled `
                -Dorc=enabled `
                -Ddoc=disabled `
                -Dadder=enabled `
                -Dapp=enabled `
                -Daudioconvert=enabled `
                -Daudiomixer=enabled `
                -Daudiorate=enabled `
                -Daudioresample=enabled `
                -Daudiotestsrc=enabled `
                -Ddsd=enabled `
                -Dencoding=enabled `
                -Dgio=enabled `
                -Dgio-typefinder=enabled `
                -Dpbtypes=enabled `
                -Dplayback=enabled `
                -Dtcp=enabled `
                -Dtypefind=enabled `
                -Dvolume=enabled `
                -Dogg=enabled `
                -Dopus=enabled `
                -Dvorbis=enabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGstpluginsgood {
        if ($GStreamerDevMode) {
            $LocalBuildPath = "$BuildPath\gst-plugins-good"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\gstreamer\subprojects\gst-plugins-good" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
            }
        } else {
            $LocalBuildPath = "$BuildPath\gst-plugins-good-$GSTREAMER_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\gst-plugins-good-$GSTREAMER_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\gst-plugins-good-$GSTREAMER_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --prefix="$DependsPath" --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dc_args="-I$DependsPathForward/include" `
                --auto-features=disabled `
                -Dexamples=disabled `
                -Dtests=disabled `
                -Dnls=disabled `
                -Dorc=enabled `
                -Dasm=enabled `
                -Ddoc=disabled `
                -Dapetag=enabled `
                -Daudiofx=enabled `
                -Daudioparsers=enabled `
                -Dautodetect=enabled `
                -Dequalizer=enabled `
                -Dicydemux=enabled `
                -Did3demux=enabled `
                -Disomp4=enabled `
                -Dreplaygain=enabled `
                -Drtp=enabled `
                -Drtsp=enabled `
                -Dspectrum=enabled `
                -Dudp=enabled `
                -Dwavenc=enabled `
                -Dwavparse=enabled `
                -Dxingmux=enabled `
                -Dadaptivedemux2=enabled `
                -Ddirectsound=enabled `
                -Dflac=enabled `
                -Dlame=enabled `
                -Dmpg123=enabled `
                -Dspeex=enabled `
                -Dtaglib=enabled `
                -Dtwolame=enabled `
                -Dwaveform=enabled `
                -Dwavpack=enabled `
                -Dsoup=enabled `
                -Dmatroska=enabled `
                -Dhls-crypto=openssl `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGstpluginsbad {
        if ($GStreamerDevMode) {
            $LocalBuildPath = "$BuildPath\gst-plugins-bad"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\gstreamer\subprojects\gst-plugins-bad" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
            }
        } else {
            $LocalBuildPath = "$BuildPath\gst-plugins-bad-$GSTREAMER_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\gst-plugins-bad-$GSTREAMER_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\gst-plugins-bad-$GSTREAMER_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --prefix="$DependsPathForward" --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dc_args="-I$DependsPathForward/include" `
                -Dcpp_args="-I$DependsPathForward/include" `
                -Dc_link_args="-L$DependsPath\lib" `
                -Dcpp_link_args="-L$DependsPath\lib" `
                --auto-features=disabled `
                -Dexamples=disabled `
                -Dtools=enabled `
                -Dtests=disabled `
                -Dintrospection=disabled `
                -Dnls=disabled `
                -Dorc=enabled `
                -Dgpl=enabled `
                -Daiff=enabled `
                -Dasfmux=enabled `
                -Did3tag=enabled `
                -Dmpegdemux=enabled `
                -Dmpegpsmux=enabled `
                -Dmpegtsdemux=enabled `
                -Dmpegtsmux=enabled `
                -Dremovesilence=enabled `
                -Daes=enabled `
                -Dasio=enabled `
                -Dbluez=enabled `
                -Dbs2b=enabled `
                -Dchromaprint=enabled `
                -Ddash=enabled `
                -Ddirectsound=enabled `
                -Dfaac=enabled `
                -Dfaad=enabled `
                -Dfdkaac=enabled `
                -Dgme=enabled `
                -Dmusepack=enabled `
                -Dopenmpt=enabled `
                -Dopus=enabled `
                -Dwasapi=enabled `
                -Dwasapi2=enabled `
                -Dhls=enabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE `
                    -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGstpluginsugly {
        if ($GStreamerDevMode) {
            $LocalBuildPath = "$BuildPath\gst-plugins-ugly"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\gstreamer\subprojects\gst-plugins-ugly" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
            }
        } else {
            $LocalBuildPath = "$BuildPath\gst-plugins-ugly-$GSTREAMER_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\gst-plugins-ugly-$GSTREAMER_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\gst-plugins-ugly-$GSTREAMER_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dc_args="-I$DependsPathForward/include" `
                --auto-features=disabled `
                -Dnls=disabled `
                -Dorc=enabled `
                -Dtests=disabled `
                -Ddoc=disabled `
                -Dgpl=enabled `
                -Dasfdemux=enabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGstlibav {
        if ($GStreamerDevMode) {
            $LocalBuildPath = "$BuildPath\gst-libav"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\gstreamer\subprojects\gst-libav" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
            }
        } else {
            $LocalBuildPath = "$BuildPath\gst-libav-$GSTREAMER_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\gst-libav-$GSTREAMER_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\gst-libav-$GSTREAMER_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dc_args="-I$DependsPathForward/include" `
                -Dtests=disabled `
                -Ddoc=disabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGstspotify {
        $LocalBuildPath = "$BuildPath\gst-plugins-rs"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\gst-plugins-rs" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        if ($GStreamerDevMode) {
            git.exe -C "$LocalBuildPath" checkout main
            if ($LASTEXITCODE -ne 0) { return }
            git.exe -C "$LocalBuildPath" pull --rebase --autostash
        } else {
            git.exe -C "$LocalBuildPath" checkout $GSTREAMER_GST_PLUGINS_RS_VERSION
        }
        if ($LASTEXITCODE -ne 0) { return }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="" `
                -Dc_link_args="-L$DependsPath\lib" `
                --wrap-mode=nodownload `
                --auto-features=disabled `
                -Dexamples=disabled `
                -Dtests=disabled `
                -Dspotify=enabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildAbseil {
        $LocalBuildPath = "$BuildPath\abseil-cpp-$ABSEIL_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\abseil-cpp-$ABSEIL_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_TESTING=OFF `
            -DCMAKE_CXX_STANDARD=17 `
            -DCMAKE_CXX_STANDARD_REQUIRED=ON `
            -DABSL_INTERNAL_AT_LEAST_CXX17=ON `
            -DABSL_USE_EXTERNAL_GOOGLETEST=OFF `
            -DABSL_BUILD_TESTING=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildProtobuf {
        $LocalBuildPath = "$BuildPath\protobuf-$PROTOBUF_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\protobuf-$PROTOBUF_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -Dprotobuf_ABSL_PROVIDER="package" `
            -DBUILD_SHARED_LIBS=ON `
            -Dprotobuf_BUILD_SHARED_LIBS=ON `
            -Dprotobuf_BUILD_TESTS=OFF `
            -Dprotobuf_BUILD_EXAMPLES=OFF `
            -Dprotobuf_BUILD_LIBPROTOC=OFF `
            -Dprotobuf_BUILD_PROTOC_BINARIES=ON `
            -Dprotobuf_WITH_ZLIB=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy pkgconfig...'
        Copy-Item "$LocalBuildPath\build\protobuf.pc" "$DependsPath\lib\pkgconfig\"
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildQtbase {
        if ($QTDevMode) {
            $LocalBuildPath = "$BuildPath\qtbase"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\qtbase" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
                git.exe -C "$LocalBuildPath" pull --rebase --autostash
            }
        } else {
            $LocalBuildPath = "$BuildPath\qtbase-everywhere-src-$QT_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\qtbase-everywhere-src-$QT_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\qtbase-everywhere-src-$QT_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        Write-Host -fo Cyan '    Patch build configuration...'
        if ($BuildArch -eq 'x86') { $QWinRing = 'OFF' } else { $QWinRing = 'ON' }
        Get-Content "$DownloadPath\qtbase-qwindowswindow.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        Get-Content "$DownloadPath\qtbase-openssl4.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        # Get-Content "$DownloadPath\qtbase-networkcache.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G Ninja `
            -DICU_ROOT="$DependsPath" `
            -DBUILD_SHARED_LIBS=ON `
            -DQT_BUILD_EXAMPLES=OFF `
            -DQT_BUILD_BENCHMARKS=OFF `
            -DQT_BUILD_TESTS=OFF `
            -DQT_BUILD_EXAMPLES_BY_DEFAULT=OFF `
            -DQT_BUILD_TOOLS_BY_DEFAULT=ON `
            -DQT_WILL_BUILD_TOOLS=ON `
            -DBUILD_WITH_PCH=OFF `
            -DFEATURE_rpath=OFF `
            -DFEATURE_pkg_config=ON `
            -DFEATURE_accessibility=ON `
            -DFEATURE_fontconfig=OFF `
            -DFEATURE_freetype=ON `
            -DFEATURE_harfbuzz=ON `
            -DFEATURE_pcre2=ON `
            -DFEATURE_openssl=ON `
            -DFEATURE_openssl_linked=ON `
            -DFEATURE_opengl=ON `
            -DFEATURE_opengl_dynamic=ON `
            -DFEATURE_use_gold_linker_alias=OFF `
            -DFEATURE_glib=ON `
            -DFEATURE_icu=ON `
            -DFEATURE_directfb=OFF `
            -DFEATURE_dbus=OFF `
            -DFEATURE_sql=ON `
            -DFEATURE_sql_sqlite=ON `
            -DFEATURE_sql_odbc=OFF `
            -DFEATURE_sql_mysql=OFF `
            -DFEATURE_sql_psql=OFF `
            -DFEATURE_jpeg=ON `
            -DFEATURE_png=ON `
            -DFEATURE_gif=ON `
            -DFEATURE_style_windows=ON `
            -DFEATURE_style_windowsvista=ON `
            -DFEATURE_style_windows11=ON `
            -DFEATURE_system_zlib=ON `
            -DFEATURE_system_png=ON `
            -DFEATURE_system_jpeg=ON `
            -DFEATURE_system_pcre2=ON `
            -DFEATURE_system_freetype=ON `
            -DFEATURE_system_harfbuzz=ON `
            -DFEATURE_windows_ioring="$QWinRing" `
            -DFEATURE_system_sqlite=ON | Out-Default

        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildQttools {
        if ($QTDevMode) {
            $LocalBuildPath = "$BuildPath\qttools"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\qttools" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
                git.exe -C "$LocalBuildPath" pull --rebase --autostash
            }
        } else {
            $LocalBuildPath = "$BuildPath\qttools-everywhere-src-$QT_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\qttools-everywhere-src-$QT_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\qttools-everywhere-src-$QT_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            $null = New-Item -ItemType Directory "$LocalBuildPath\build"
            Write-Host -fo Cyan '    QTTools configure...'
            Push-Location "$LocalBuildPath\build"
            & "$DependsPath\bin\qt-configure-module.bat" "$LocalBuildPath" -feature-linguist -no-feature-assistant -no-feature-designer
            Pop-Location
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildQtimageformats {
        if ($QTDevMode) {
            $LocalBuildPath = "$BuildPath\qtimageformats"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\qtimageformats" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
                git.exe -C "$LocalBuildPath" pull --rebase --autostash
            }
        } else {
            $LocalBuildPath = "$BuildPath\qtimageformats-everywhere-src-$QT_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\qtimageformats-everywhere-src-$QT_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\qtimageformats-everywhere-src-$QT_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DFEATURE_jasper=ON `
            -DFEATURE_tiff=ON `
            -DFEATURE_webp=ON `
            -DFEATURE_system_tiff=ON `
            -DFEATURE_system_webp=ON | Out-Default
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildQtgrpc {
        if ($QTDevMode) {
            $LocalBuildPath = "$BuildPath\qtgrpc"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Copy source repo...'
                Copy-Item "$DownloadPath\qtgrpc" $LocalBuildPath -Recurse -Force
                if (-not $?) { return }
                git.exe -C "$LocalBuildPath" pull --rebase --autostash
            }
        } else {
            $LocalBuildPath = "$BuildPath\qtgrpc-everywhere-src-$QT_VERSION"
            if (-not (Test-Path $LocalBuildPath -PathType Container)) {
                Write-Host -fo Cyan '    Extract source...'
                7z.exe x -aos "$DownloadPath\qtgrpc-everywhere-src-$QT_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
                7z.exe x -aoa "$DownloadPath\qtgrpc-everywhere-src-$QT_VERSION.tar" -o"$BuildPath" | Out-Default
                if ($LASTEXITCODE -ne 0) { return }
            }
        }
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DQT_BUILD_EXAMPLES=OFF `
            -DQT_BUILD_TESTS=OFF `
            -DQT_BUILD_EXAMPLES_BY_DEFAULT=OFF `
            -DQT_BUILD_TOOLS_WHEN_CROSSCOMPILING=ON | Out-Default
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildQtsparkle {
        $LocalBuildPath = "$BuildPath\qtsparkle"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\qtsparkle" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_WITH_QT6=ON `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildSparsehash {
        $LocalBuildPath = "$BuildPath\sparsehash-sparsehash-$SPARSEHASH_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\sparsehash-$SPARSEHASH_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\sparsehash-msvc.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        Write-Host -fo Cyan '    Create include directories...'
        foreach ($Dir in 'google', 'sparsehash') {
            if (-not (Test-Path "$LocalBuildPath\include\$Dir" -PathType Container)) {
                $null = New-Item "$DependsPath\include\$Dir" -ItemType Directory -Force
                if (-not $?) { return }
            }
        }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\src\google\*" "$DependsPath\include\google" -Force -Recurse
        if (-not $?) { return }
        Copy-Item "$LocalBuildPath\src\sparsehash\*" "$DependsPath\include\sparsehash" -Force -Recurse
        if (-not $?) { return }
        Copy-Item "$LocalBuildPath\src\windows\sparsehash\internal\sparseconfig.h" "$DependsPath\include\sparsehash\internal\" -Force -Recurse
        if (-not $?) { return }
        Copy-Item "$LocalBuildPath\src\windows\google\sparsehash\sparseconfig.h" "$DependsPath\include\google\sparsehash\" -Force -Recurse
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\libsparsehash.pc" -Force -Value @"
$PkgconfTemplate

Name: sparsehash
Description: C++ associative containers
URL: https://github.com/sparsehash/sparsehash
Version: $SPARSEHASH_VERSION
Cflags: -I`${includedir}
"@
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildKdsingleapp {
        $LocalBuildPath = "$BuildPath\kdsingleapplication-$KDSINGLEAPPLICATION_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\kdsingleapplication-$KDSINGLEAPPLICATION_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DKDSingleApplication_QT6=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildGlew {
        $LocalBuildPath = "$BuildPath\glew-$GLEW_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\glew-$GLEW_VERSION.tgz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        (Get-Content "$LocalBuildPath\build\cmake\CMakeLists.txt" -Raw) -replace
        '(?m)^(\s*)(target_link_libraries\s*\(\s*glew\s*LINK_PRIVATE\s*-BASE:0x[0-9a-f]+\s*\)\s*)(\r?\n)',
        '$1$2$3$1target_link_libraries (glew LINK_PRIVATE libvcruntime.lib)$3$1target_link_libraries (glew LINK_PRIVATE msvcrt.lib)$3' |
            Set-Content "$LocalBuildPath\build\cmake\CMakeLists.txt" -NoNewline
        if (-not $?) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S "$LocalBuildPath\build\cmake" -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibprojectm {
        $LocalBuildPath = "$BuildPath\libprojectm-$LIBPROJECTM_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\libprojectm-$LIBPROJECTM_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildTinysvcmdns {
        $LocalBuildPath = "$BuildPath\tinysvcmdns"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\tinysvcmdns" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\build\*.h", "$LocalBuildPath\*.h" "$DependsPath\include\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\build\*.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\build\*.exe", "$LocalBuildPath\build\*.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\tinysvcmdns.pc" -Force -Value @"
$PkgconfTemplate

Name: tinysvcmdns
Description: tinysvcmdns
Version: $(GetRepoCommit tinysvcmdns)
Libs: -L`${libdir} -ltinysvcmdns
Cflags: -I`${includedir}
"@
        if (-not $?) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildPeParse {
        $LocalBuildPath = "$BuildPath\pe-parse-${PEPARSE_VERSION}"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\pe-parse-${PEPARSE_VERSION}.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DBUILD_COMMAND_LINE_TOOLS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildPeUtil {
        $LocalBuildPath = "$BuildPath\pe-util"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\pe-util" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DBUILD_COMMAND_LINE_TOOLS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildJasper {
        $LocalBuildPath = "$BuildPath\jasper-$JASPER_VERSION-build"
        $LocalSourcePath = "$BuildPath\jasper-$JASPER_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath, $LocalSourcePath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalSourcePath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\jasper-$JASPER_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item $LocalBuildPath -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        (Get-Content "$LocalSourcePath\CMakeLists.txt" -ErrorAction Stop).Where{ $_ -inotmatch '^\s*include\(InstallRequiredSystemLibraries\)\s*$' } | Set-Content "$LocalSourcePath\CMakeLists.txt"
        if (-not $?) { return }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalSourcePath -B $LocalBuildPath -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DJAS_ENABLE_JP2_CODEC=ON `
            -DJAS_ENABLE_JPC_CODEC=ON `
            -DJAS_ENABLE_JPG_CODEC=ON `
            -DJAS_ENABLE_LIBJPEG=ON `
            -DJAS_ENABLE_OPENGL=ON `
            -DJAS_INCLUDE_BMP_CODEC=ON `
            -DJAS_INCLUDE_JP2_CODEC=ON `
            -DJAS_INCLUDE_JPC_CODEC=ON `
            -DJAS_INCLUDE_JPG_CODEC=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build $LocalBuildPath | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install $LocalBuildPath | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath, $LocalSourcePath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildTiff {
        $LocalBuildPath = "$BuildPath\tiff-$TIFF_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\tiff-${TIFF_VERSION}.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -Djpeg=ON `
            -Dtiff-static=OFF `
            -Dtiff-docs=OFF `
            -Dtiff-tests=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function BuildLibWebp {
        $LocalBuildPath = "$BuildPath\libwebp-$LIBWEBP_VERSION"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\libwebp-$LIBWEBP_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DWEBP_LINK_STATIC=OFF `
            -DWEBP_UNICODE=ON `
            -DWEBP_USE_THREAD=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        if ($PostCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
    }

    function Get-DependenciesFromNsi {
        [CmdletBinding()]
        param(
            [string]$NSIFile
        )
        begin {
            $NSISVars = @{
                arch_x64   = $BuildArch -eq 'x64'
                arch_x86   = $BuildArch -eq 'x86'
                arch_arm64 = $BuildArch -eq 'arm64'
                arch       = $BuildArch
                debug      = $BuildType -eq 'debug'
                release    = $BuildType -eq 'release'
                build_type = $BuildType
                mingw      = $false
                msvc       = $true
                compiler   = $true
            }
            $null = $NSISVars
            $IncludeSections = 'Strawberry', 'GIO modules', 'Qt Platform plugins', 'Qt styles', 'Qt TLS plugins',
            'Qt SQL Drivers', 'Qt imageformats', 'Gstreamer plugins'
            $FilenameVars = @{
                vc_redist_file = "vc_redist.$BuildArch.exe"
            }
            function TokenizeNsisIf {
                param(
                    [Parameter(Mandatory)]
                    [string]$Line,
                    [Parameter(Mandatory)]
                    [ValidateScript({ $_ -match '^\w+$' })]
                    [string]$VarName
                )
                $M = [regex]::Match($Line, '^\s*!(?<n>ifn?def)\s+(?<t>(?:\w+|&{1,2}|\|{1,2})\s+)*(?<t>\w+|&{1,2}|\|{1,2})\s*$')
                if (-not $M.Success) { return }
                $Tokens = $M.Groups['t'].Captures.Where{ $_.Value.Trim() -match '^(?:&{1,2}|\|{1,2}|\w+)$' }.ForEach{
                    $_.Value.Trim().ToLowerInvariant() } -replace '^&{1,2}$', '-and' -replace '^\|{1,2}$', '-or' -replace '^(\w+)$', '$${NSISVars}.''$1'''
                $SafeTokens = if ($M.Groups['n'].Value -eq 'ifndef') { '-not (' + ($Tokens -join ' ') + ')' } else { $Tokens -join ' ' }
                $Result = $false
                try {
                    $Result = Invoke-Expression $SafeTokens
                } catch {
                    $PSCmdlet.WriteWarning("$(' ' * $Indent)Unable to parse NSIS ifdef/ifndef statement: '$Line'.")
                }
                $Result
            }
        }
        process {
            $NSIS = Get-Content $NSIFile
            if (-not $?) { return }

            $RootSectStart = $NSIS.IndexOf('Section "Strawberry" Strawberry')
            if ($RootSectStart -lt 0) {
                $PSCmdlet.WriteWarning("Couldn't find Strawberry section of NSI file!")
                return
            }

            $NeededFiles = [List[string]]::new()
            $CurrentSection = ''
            $IfStack = [Stack[bool]]::new()
            $Indent = 0

            for ($line = $RootSectStart; $line -lt $NSIS.Count; $line++) {
                $LineText = $NSIS[$line] -replace '^\s*;.+$' -replace '\s+;[^"'']+$'
                if ([string]::IsNullOrWhiteSpace($LineText)) { continue }

                # Section handling
                if (-not [string]::IsNullOrEmpty($CurrentSection)) {
                    if ($LineText -match '^\s*SectionEnd') {
                        $Indent -= 4
                        $PSCmdlet.WriteVerbose("$(' ' * $Indent)End of section '$CurrentSection'.")
                        $CurrentSection = ''
                        continue
                    }
                } else {
                    if ($LineText -match '^\s*Section (["''])(.+)\1') {
                        $CurrentSection = $Matches[2].Trim()
                        $PSCmdlet.WriteVerbose("$(' ' * $Indent)Processing section '$CurrentSection'.")
                        $Indent += 4
                        continue
                    }
                    # If inside a section that doesn't apply to us, skip
                    if ($CurrentSection -notin $IncludeSections) { continue }
                }

                # Conditional handling
                if ($LineText -match '^\s*!ifn?def\s+(?:(?:\w+|&{1,2}|\|{1,2})\s+)*(?:\w+|&{1,2}|\|{1,2})\s*$') {
                    $Include = TokenizeNsisIf $LineText -VarName 'NSISVars'
                    $IfStack.Push($Include)
                    $PSCmdlet.WriteVerbose("$(' ' * $Indent)Start conditional block '$LineText', include = $Include.")
                    $Indent += 4
                    continue
                } elseif ($LineText -match '^\s*!else\s*$') {
                    $Prev = $IfStack.Pop()
                    $IfStack.Push(-not $Prev)
                    $PSCmdlet.WriteVerbose("$(' ' * ($Indent - 4))Else conditional block")
                    continue
                } elseif ($LineText -match '^\s*!endif\s*$') {
                    [void]$IfStack.Pop()
                    $Indent -= 4
                    $PSCmdlet.WriteVerbose("$(' ' * $Indent)End conditional block")
                    continue
                }
                # If in a conditional that excludes current config, skip
                if ($IfStack.Count -gt 0 -and $IfStack.Contains($false)) { continue }

                # File include handling
                if ($LineText -match '^\s*File ([''"])(.+)\1') {
                    $Filename = $Matches[2].Trim() -replace '^/oname=[^"'']+["'']\s+["'']'
                    if ($Filename -match '^\$\{(.+)\}$') { $Filename = $FilenameVars[$Matches[1]] }
                    if ([string]::IsNullOrWhiteSpace($Filename)) { $PSCmdlet.WriteWarning("$(' ' * $Indent)Skipped file '$Filename'"); continue }
                    $NeededFiles.Add($Filename)
                    $PSCmdlet.WriteVerbose("$(' ' * $Indent)Added dependency file '$($NeededFiles[$NeededFiles.Count - 1])'.")
                }
            }
            $NeededFiles
        }
    }


    function BuildStrawberry {
        $LocalBuildPath = "$BuildPath\_strawberry"
        if ($PreCleanup) { Remove-Item $LocalBuildPath -Recurse -Force -ErrorAction Ignore }
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\strawberry" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        $IncludeSpotify = if (Test-Path "$DependsPath\lib\gstreamer-*\gstspotify.dll") { 'ON' } else { 'OFF' }
        $EnableCon = if ($EnableStrawberryConsole) { 'ON' } else { 'OFF' }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe @GlobalCMakeArgs -S $LocalBuildPath -B "$LocalBuildPath\build" -G 'Visual Studio 17 2022' -A $BuildArch32Alt `
            -DICU_ROOT="$DependsPathForward" `
            -DARCH="$StrawbArch" `
            -DENABLE_WIN32_CONSOLE="$EnableCon" `
            -DENABLE_GIO=OFF `
            -DENABLE_AUDIOCD=OFF `
            -DENABLE_MTP=OFF `
            -DENABLE_GPOD=OFF `
            -DENABLE_SPOTIFY="$IncludeSpotify" `
            -DENABLE_DISCORD_RPC=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" --config $BuildTypeCMake --verbose | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" --prefix "$LocalBuildPath\build" --config $BuildTypeCMake --verbose | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Move-Item "$LocalBuildPath\build\bin\*" "$LocalBuildPath\build\" -Force
        if (-not $?) { return }
        foreach ($Dir in 'platforms', 'styles', 'tls', 'sqldrivers', 'imageformats', 'gio-modules', 'gstreamer-plugins') {
            if (-not (Test-Path "$LocalBuildPath\build\$Dir" -PathType Container)) {
                Write-Host -fo Cyan "    Create build subdirectory '$Dir'..."
                $null = New-Item "$LocalBuildPath\build\$Dir" -ItemType Directory -Force
                if (-not $?) { return }
            }
        }
        Write-Host -fo Cyan '    Copy resources...'
        Copy-Item "$LocalBuildPath\COPYING" "$LocalBuildPath\build\" -Force
        if (-not $?) { return }
        foreach ($Type in 'nsh', 'ico') {
            Copy-Item "$LocalBuildPath\dist\windows\*.$Type" "$LocalBuildPath\build\" -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Copy MSVC redistributable...'
        Copy-Item "$DownloadPath\vc_redist.$BuildArch.exe" "$LocalBuildPath\build\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Patch NSIS target libfftw3-3.dll -> fftw3.dll, MinGW -> MSVC...'
        (Get-Content "$LocalBuildPath\build\strawberry.nsi" -Raw) -ireplace 'libfftw3-3\.dll', 'fftw3.dll' -ireplace
            '(!define (?:compiler )?["'']?)mingw', '$1msvc' -ireplace
            '\s*(?:File ["'']|Delete ["'']\$INSTDIR\\)libgcc_s_sjlj-1\.dll["'']' -ireplace
            '\s*(?:File ["'']|Delete ["'']\$INSTDIR\\)libwinpthread-1\.dll["'']' |
            Set-Content "$LocalBuildPath\build\strawberry.nsi" -NoNewline
        Write-Host -fo Cyan '    Copy dependency binaries...'
        [list[string]]$FileList = Get-DependenciesFromNsi -NSIFile "$LocalBuildPath\build\strawberry.nsi"
        if (-not $? -or $FileList.Count -eq 0) { return }
        $Sources = @{
            'gstreamer-plugins' = "$DependsPath\lib\gstreamer-1.0"
            'imageformats'      = "$DependsPath\plugins\imageformats"
            'sqldrivers'        = "$DependsPath\plugins\sqldrivers"
            'tls'               = "$DependsPath\plugins\tls"
            'styles'            = "$DependsPath\plugins\styles"
            'platforms'         = "$DependsPath\plugins\platforms"
            'gio-modules'       = "$DependsPath\lib\gio\modules"
            _DEFAULT            = "$DependsPath\bin\$Bin"
            _SEARCH             = $DependsPath
        }
        $NeedSearch = [List[string]]::new()
        foreach ($Dep in $FileList) {
            if (Test-Path "$LocalBuildPath\build\$Dep") {
                Write-Host -fo Green "    Dependency '$Dep' already exists in build path."
                continue
            }
            if ($Dep -match '^(.+)\\' -and $Sources.ContainsKey($Matches[1])) {
                $DirName = $Matches[1]
                $SourcePath = Join-Path $Sources[$DirName] ($Dep -replace '^.+\\')
                $PsCmdlet.WriteVerbose("        Expected source: $SourcePath")
                $DestPath = Join-Path "$LocalBuildPath\build" $DirName
            } elseif ($Dep -notmatch '\\') {
                $SourcePath = Join-Path $Sources._DEFAULT $Dep
                $PsCmdlet.WriteVerbose("        Expected source: $SourcePath")
                $DestPath = "$LocalBuildPath\build"
            } else {
                Write-Host -fo Yellow "        No expected source found for '$Dep'."
                $NeedSearch.Add($Dep)
                continue
            }
            if (-not (Test-Path $SourcePath)) {
                Write-Host -fo Yellow "    Source '$SourcePath' doesn't exist. Will search."
                $NeedSearch.Add($Dep); continue
            }
            if (-not (Test-Path $DestPath)) { $null = New-Item -ItemType Directory $DestPath }
            Write-Host -fo Gray "    Copy '$SourcePath' to '$DestPath'"
            Copy-Item $SourcePath $DestPath -Force
            if (-not $?) { return }
        }
        if ($NeedSearch.Count -gt 0) {
            Write-Host -fo Yellow "    Number of dependencies with unknown source: $($NeedSearch.Count)"
            $AllDeps = @{}
            Get-ChildItem $Sources._SEARCH -Recurse -Force -File | ForEach-Object {

                $AllDeps[$_.Name] = $_.FullName
            }
            foreach ($Dep in $NeedSearch) {
                if (Test-Path "$LocalBuildPath\build\$Dep") {
                    Write-Host -fo Green "    Dependency '$Dep' already exists in build path."
                    continue
                }
                if (-not $AllDeps.ContainsKey($Dep)) {
                    Write-Host -fo Red "    Strawberry dependency not found: '$Dep'."
                    Write-Error 'Missing dependencies.'
                    return
                }
                Write-Host -fo Green "    Found dependency '$Dep' at '$($AllDeps[$Dep])'."
                $SourcePath = $AllDeps[$Dep]
                $DirName = $Dep -replace '\\[^\\]+$'
                if ([string]::IsNullOrWhiteSpace($DirName)) {
                    $DestPath = Join-Path "$LocalBuildPath\build"
                } else {
                    $DestPath = Join-Path "$LocalBuildPath\build" $DirName
                }
                if (-not (Test-Path $DestPath)) { $null = New-Item -ItemType Directory $DestPath }
                Write-Host -fo Gray "    Copy '$SourcePath' to '$DestPath'"
                Copy-Item $SourcePath $DestPath -Force
                if (-not $?) { return }
            }
        }

        Write-Host -fo Cyan '    Build NSIS installer...'
        makensis.exe "$LocalBuildPath\build\strawberry.nsi" | Out-Default
    }

    #endregion

    #region Build Strategy

    if ($QTDevMode) {
        $QTBaseVer = if ($QTDevMode) { "($(GetRepoCommit qtbase))" } else { $QT_VERSION }
        $QTToolsVer = if ($QTDevMode) { "($(GetRepoCommit qttools))" } else { $QT_VERSION }
        # $QTGrpcVer = if ($QTDevMode) { "($(GetRepoCommit qtgrpc))" } else { $QT_VERSION }
    } else {
        $QTBaseVer = $QTToolsVer = <# $QTGrpcVer =  #>$QT_VERSION
    }
    $BUILD_TARGETS = [ordered]@{
        "pkgconf $PKGCONF_VERSION"                     = 'BuildPkgConf', '*', "$DependsPath\bin\pkgconf.exe"
        "Yasm $YASM_VERSION"                           = 'BuildYasm', '*', "$DependsPath\bin\yasm.exe"
        "Libintl $PROXY_LIBINTL_VERSION"               = 'BuildLibintl', '*', "$DependsPath\lib\intl.lib"
        "getopt-win ($(GetRepoCommit getopt-win))"     = 'BuildGetOpt', '*', "$DependsPath\lib\getopt.lib"
        "zlib $ZLIB_VERSION"                           = 'BuildZlib', '*', "$DependsPath\lib\z.lib"
        "OpenSSL $OPENSSL_VERSION"                     = 'BuildOpenSSL', '*', "$DependsPath\lib\pkgconfig\openssl.pc"
        "libpng $LIBPNG_VERSION"                       = 'BuildLibpng', '*', "$DependsPath\lib\pkgconfig\libpng.pc"
        "libjpeg $LIBJPEG_TURBO_VERSION"               = 'BuildLibjpeg', '*', "$DependsPath\lib\pkgconfig\libjpeg.pc"
        "PCRE2 $PCRE2_VERSION"                         = 'BuildPcre2', '*', "$DependsPath\lib\pkgconfig\libpcre2-16.pc"
        "bzip2 $BZIP2_VERSION"                         = 'BuildBzip2', '*', "$DependsPath\lib\pkgconfig\bzip2.pc"
        "xz $XZ_VERSION"                               = 'BuildXz', '*', "$DependsPath\lib\pkgconfig\liblzma.pc"
        "Brotli $BROTLI_VERSION"                       = 'BuildBrotli', '*', "$DependsPath\lib\pkgconfig\libbrotlicommon.pc"
        "Icu4c $ICU4C_VERSION"                         = 'BuildIcu4c', '*', "$DependsPath\lib\pkgconfig\icu-uc.pc"
        "Pixman $PIXMAN_VERSION"                       = 'BuildPixman', '*', "$DependsPath\lib\pkgconfig\pixman-1.pc"
        "Expat $EXPAT_VERSION"                         = 'BuildExpat', '*', "$DependsPath\lib\pkgconfig\expat.pc"
        "Boost $BOOST_VERSION"                         = 'BuildBoost', '*', "$DependsPath\include\boost\config.hpp"
        "Libxml2 $LIBXML2_VERSION"                     = 'BuildLibxml2', '*', "$DependsPath\lib\pkgconfig\libxml-2.0.pc"
        "Nghttp2 $NGHTTP2_VERSION"                     = 'BuildNghttp2', '*', "$DependsPath\lib\pkgconfig\libnghttp2.pc"
        "Libffi ($(GetRepoCommit libffi))"             = 'BuildLibffi', '*', "$DependsPath\lib\pkgconfig\libffi.pc"
        "Dlfcn $DLFCN_VERSION"                         = 'BuildDlfcn', '*', "$DependsPath\include\dlfcn.h"
        "Libpsl $LIBPSL_VERSION"                       = 'BuildLibpsl', '*', "$DependsPath\lib\pkgconfig\libpsl.pc"
        "Orc $ORC_VERSION"                             = 'BuildOrc', '*', "$DependsPath\lib\pkgconfig\orc-0.4.pc"
        "Sqlite $SQLITE_VERSION"                       = 'BuildSqlite', '*', "$DependsPath\lib\pkgconfig\sqlite3.pc"
        "Glib $GLIB_VERSION"                           = 'BuildGlib', '*', "$DependsPath\lib\pkgconfig\glib-2.0.pc"
        "Libsoup $LIBSOUP_VERSION"                     = 'BuildLibsoup', '*', "$DependsPath\lib\pkgconfig\libsoup-3.0.pc"
        "GlibNetworking $GLIB_NETWORKING_VERSION"      = 'BuildGlibNetworking', '*', "$DependsPath\lib\gio\modules\gioopenssl.lib"
        "Freetype $FREETYPE_VERSION"                   = 'BuildFreetype', '*', "$DependsPath\lib\freetype.lib"
        "Harfbuzz $HARFBUZZ_VERSION"                   = 'BuildHarfbuzz', '*', "$DependsPath\lib\harfbuzz*.lib"
        "Jasper $JASPER_VERSION"                       = 'BuildJasper', '*', "$DependsPath\lib\pkgconfig\jasper.pc"
        "Tiff $TIFF_VERSION"                           = 'BuildTiff', '*', "$DependsPath\lib\pkgconfig\libtiff-4.pc"
        "Libwebp $LIBWEBP_VERSION"                     = 'BuildLibWebp', '*', "$DependsPath\lib\pkgconfig\libwebp.pc"
        "Libogg $LIBOGG_VERSION"                       = 'BuildLibogg', '*', "$DependsPath\lib\pkgconfig\ogg.pc"
        "Libvorbis $LIBVORBIS_VERSION"                 = 'BuildLibvorbis', '*', "$DependsPath\lib\pkgconfig\vorbis.pc"
        "Flac $FLAC_VERSION"                           = 'BuildFlac', '*', "$DependsPath\lib\pkgconfig\flac.pc"
        "Wavpack $WAVPACK_VERSION"                     = 'BuildWavpack', '*', "$DependsPath\lib\pkgconfig\wavpack.pc"
        "Opus $OPUS_VERSION"                           = 'BuildOpus', '*', "$DependsPath\lib\pkgconfig\opus.pc"
        "Opusfile $OPUSFILE_VERSION"                   = 'BuildOpusfile', '*', "$DependsPath\bin\opusfile.dll"
        "Speex $SPEEX_VERSION"                         = 'BuildSpeex', '*', "$DependsPath\lib\pkgconfig\speex.pc"
        "Libmpg123 $MPG123_VERSION"                    = 'BuildLibmpg123', '*', "$DependsPath\lib\pkgconfig\libmpg123.pc"
        "Mp3lame $LAME_VERSION"                        = 'BuildLame', '*', "$DependsPath\lib\pkgconfig\mp3lame.pc"
        "Twolame $TWOLAME_VERSION"                     = 'BuildTwolame', '*', "$DependsPath\lib\libtwolame_dll.lib"
        "Fftw3 $FFTW_VERSION"                          = 'BuildFftw3', '*', "$DependsPath\lib\pkgconfig\fftw3.pc"
        "Musepack $MUSEPACK_VERSION"                   = 'BuildMusepack', '*', "$DependsPath\lib\pkgconfig\mpcdec.pc"
        "Libopenmpt $LIBOPENMPT_VERSION"               = 'BuildLibopenmpt', '*', "$DependsPath\lib\pkgconfig\libopenmpt.pc"
        "Libgme $LIBGME_VERSION"                       = 'BuildLibgme', '*', "$DependsPath\lib\pkgconfig\libgme.pc"
        "Fdkaac $FDK_AAC_VERSION"                      = 'BuildFdkaac', '*', "$DependsPath\lib\pkgconfig\fdk-aac.pc"
        "Faad2 $FAAD2_VERSION"                         = 'BuildFaad2', '*', "$DependsPath\lib\pkgconfig\faad2.pc"
        "Faac $FAAC_VERSION"                           = 'BuildFaac', '*', "$DependsPath\lib\pkgconfig\faac.pc"
        "Utfcpp $UTFCPP_VERSION"                       = 'BuildUtfcpp', '*', "$DependsPath\include\utf8cpp\utf8.h"
        "Taglib $TAGLIB_VERSION"                       = 'BuildTaglib', '*', "$DependsPath\lib\pkgconfig\taglib.pc"
        "Libbs2b $LIBBS2B_VERSION"                     = 'BuildLibbs2b', '*', "$DependsPath\lib\libbs2b.lib"
        "Libebur128 $LIBEBUR128_VERSION"               = 'BuildLibebur128', '*', "$DependsPath\lib\pkgconfig\libebur128.pc"
        "Ffmpeg $FFMPEG_VERSION"                       = 'BuildFfmpeg', '*', "$DependsPath\lib\avutil.lib"
        "Chromaprint $CHROMAPRINT_VERSION"             = 'BuildChromaprint', '*', "$DependsPath\lib\pkgconfig\libchromaprint.pc"
        "Gstreamer $GSTREAMER_VERSION"                 = 'BuildGstreamer', '*', "$DependsPath\lib\pkgconfig\gstreamer-1.0.pc"
        "Gstpluginsbase $GSTREAMER_VERSION"            = 'BuildGstpluginsbase', '*', "$DependsPath\lib\pkgconfig\gstreamer-plugins-base-1.0.pc"
        "Gstpluginsgood $GSTREAMER_VERSION"            = 'BuildGstpluginsgood', '*', "$DependsPath\lib\gstreamer-1.0\gstdirectsound.lib"
        "Gstpluginsbad $GSTREAMER_VERSION"             = 'BuildGstpluginsbad', '*', "$DependsPath\lib\pkgconfig\gstreamer-plugins-bad-1.0.pc"
        "Gstpluginsugly $GSTREAMER_VERSION"            = 'BuildGstpluginsugly', '*', "$DependsPath\lib\gstreamer-1.0\gstasf.lib"
        "Gstlibav $GSTREAMER_VERSION"                  = 'BuildGstlibav', '*', "$DependsPath\lib\gstreamer-1.0\gstlibav.lib"
        "Gstspotify $GSTREAMER_GST_PLUGINS_RS_VERSION" = 'BuildGstspotify', 'x64', "$DependsPath\lib\gstreamer-1.0\gstspotify.dll"
        "Abseil $ABSEIL_VERSION"                       = 'BuildAbseil', '*', "$DependsPath\lib\pkgconfig\absl_any.pc"
        "Protobuf $PROTOBUF_VERSION"                   = 'BuildProtobuf', '*', "$DependsPath\lib\pkgconfig\protobuf.pc"
        "Qtbase $QTBaseVer"                            = 'BuildQtbase', '*', "$DependsPath\bin\qt-configure-module.bat"
        "Qttools $QTToolsVer"                          = 'BuildQttools', '*', "$DependsPath\lib\cmake\Qt6Linguist\Qt6LinguistConfig.cmake"
        "Qtimageformats $QTToolsVer"                   = 'BuildQtimageformats', '*', "$DependsPath\plugins\imageformats\qwebp$DebugPostfix.dll"
        "Qtgrpc $QTGrpcVer"                            = 'BuildQtgrpc', '*', "$DependsPath\lib\cmake\Qt6\FindWrapProtoc.cmake"
        "KDsingleapp $KDSINGLEAPPLICATION_VERSION"     = 'BuildKdsingleapp', '*', "$DependsPath\lib\kdsingleapplication-qt6.lib"
        "Qtsparkle ($(GetRepoCommit qtsparkle))"       = 'BuildQtsparkle', '*', "$DependsPath\lib\cmake\qtsparkle-qt6\qtsparkle-qt6Config.cmake"
        "Sparsehash $SPARSEHASH_VERSION"               = 'BuildSparsehash', '*', "$DependsPath\lib\pkgconfig\libsparsehash.pc"
        "Glew $GLEW_VERSION"                           = 'BuildGlew', '*', "$DependsPath\lib\pkgconfig\glew.pc"
        "Libprojectm $LIBPROJECTM_VERSION"             = 'BuildLibprojectm', '*', "$DependsPath\lib\cmake\projectM4\projectM4Config.cmake"
        "Tinysvcmdns ($(GetRepoCommit tinysvcmdns))"   = 'BuildTinysvcmdns', '*', "$DependsPath\lib\pkgconfig\tinysvcmdns.pc"
        "Pe-parse $PEPARSE_VERSION"                    = 'BuildPeParse', '*', "$DependsPath\lib\pe-parse.lib"
        "Pe-util ($(GetRepoCommit pe-util))"           = 'BuildPeUtil', '*', "$DependsPath\bin\peldd.exe"
    }

    if (-not $NoStrawberry) {
        $BUILD_TARGETS["Strawberry ($(GetRepoCommit strawberry))"] = 'BuildStrawberry', '*', "$BuildPath\_strawberry\build\strawberrysetup*.exe"
    }

    $Skip = [HashSet[string]]::new()
    $Force = [HashSet[string]]::new()
    Write-Host -fo Gray "`nBuild strategy:"
    :TargetLoop foreach ($Target in $BUILD_TARGETS.Keys) {
        $NeedsBuild = $false
        $WasForced = $false
        foreach ($SkipPattern in $SkipBuild) {
            if ($Target -match $SkipPattern) {
                [void]$Skip.Add($Target)
                Write-Host -fo Gray ('{0,-80}{1}' -f "${Target}...  ", 'SKIP (exclude pattern)')
                continue TargetLoop
            }
        }
        foreach ($ForcePattern in $ForceBuild) {
            if ($Target -like $ForcePattern) {
                $NeedsBuild = $true
                $WasForced = $true
                [void]$Force.Add($Target)
                break
            }
        }
        if (-not $NeedsBuild) {
            for ($i = 2; $i -lt $BUILD_TARGETS[$Target].Count; $i++) {
                if (-not (Test-Path $BUILD_TARGETS[$Target][$i])) {
                    $NeedsBuild = $true
                    break
                }
            }
        }
        if (-not $FromScratch -and $NeedsBuild -and $Target -notmatch '^Strawberry ') {
            [void]$Skip.Add($Target)
            Write-Host -fo Gray ('{0,-80}{1}' -f "${Target}...  ", 'SKIP (no -FromScratch)')
            continue TargetLoop
        }
        Write-Host -fo White ('{0,-80}' -f "${Target}...  ") -NoNewline
        if ($NeedsBuild) {
            if ($WasForced) { Write-Host -fo Magenta 'NEEDS BUILD (FORCED)' } else { Write-Host -fo Cyan 'NEEDS BUILD' }
        } else {
            [void]$Skip.Add($Target)
            Write-Host -fo Green 'BUILT'
        }
    }
    #endregion

    if ($NoBuild) { return }

    #region Precompiled dependencies
    $CreatedReparse = $false
    if (-not $FromScratch -and -not (Test-Path "$DependsPath\bin\peldd.exe" -PathType Leaf)) {
        $DepsTar = "$DownloadPath\strawberry-msvc-$StrawbArch-$BuildType.tar"
        $DepsArchive = "$DepsTar.xz"
        if (-not (Test-Path $DepsTar)) {
            if (-not (Test-Path $DepsArchive)) {
                $PSCmdlet.WriteWarning("Precompiled MSVC dependencies not found at path '$DepsArchive'. " +
                    'Please download them from https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/releases or use -FromScratch.')
                return
            }
            Write-Host -fo Cyan '    Extract MSVC dependencies archive...'
            7z.exe x -aos $DepsArchive -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Extract MSVC dependencies tarball...'
        if ((Split-Path $DependsPath -Leaf) -eq $DefaultName) {
            7z.exe x -aoa $DepsTar -o"$(Split-Path $DependsPath -Parent)" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        } else {
            7z.exe x -aoa $DepsTar -o"$TempPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            Copy-Item "$TempPath\$DefaultName\*" $DependsPath -Recurse -Force
            if (-not $?) { return }
            Remove-Item "$TempPath\$DefaultName" -Recurse -Force
            if (-not $?) { return }
        }
        if ($DependsPath -ne "C:\$DefaultName") {
            Get-ChildItem $DependsPath -File -Recurse |
                Where-Object { [string]::IsNullOrEmpty($_.Extension) -or $_.Extension -in '.cmake', '.pc', '.pri', '.sh', '.bat', '.cmd' } |
                ForEach-Object {
                    $Config = Get-Content $_.FullName -Raw
                    $NewTarget = $DependsPath -replace '\$', '$$' -replace '[\\/]', '$$1'
                    $NewConfig = $Config -ireplace "C:([\\/])$([regex]::Escape($DefaultName))", $NewTarget
                    if ($Config -ne $NewConfig) {
                        Set-Content $_.FullName -Value $NewConfig
                        if (-not $?) { return }
                        Write-Host -fo Gray "    Replaced dependency path in '$($_.FullName)'"
                    }
                }
        }
    }
    if (-not $FromScratch -and $DependsPath -ne "C:\$DefaultName" -and -not (Test-Path "C:\$DefaultName")) {
        $null = New-Item -ItemType Junction -Path "C:\$DefaultName" -Value $DependsPath
        if (-not $?) { return }
        Write-Host -fo Cyan "    Created directory junction C:\$DefaultName -> $DependsPath"
        $CreatedReparse = $true
    }
    #endregion

    #region Build Loop
    Write-Host -fo Gray "`nRunning build steps..."
    $OverallSuccess = $true
    $FailTarget = ''
    :TargetLoop foreach ($Target in $BUILD_TARGETS.Keys) {
        if ($Skip.Contains($Target)) { continue TargetLoop }
        $WasForced = $false
        $BuildFunction = Get-Item "Function:\$($BUILD_TARGETS[$Target][0])" -ErrorAction Ignore
        if ($null -eq $BuildFunction) {
            $PSCmdlet.WriteWarning("No build function found for $Target - skipping.")
            continue TargetLoop
        }
        $ArchFilter = $BUILD_TARGETS[$Target][1]
        if ($ArchFilter -cne '*' -and $BuildArch -notmatch $ArchFilter) {
            if (-not $Force.Contains($Target)) {
                Write-Host -fo White ('{0,-80}' -f "${Target}...  ") -NoNewline
                Write-Host -fo Yellow 'SKIPPED (ARCH FILTER)'
                continue TargetLoop
            } else { $WasForced = $true }
        }
        $Title = if ($WasForced) { " $Target (FORCED) " } else { " $Target " }
        Write-Host -fo White ($Title.PadLeft(($ConWidth - $Title.Length) / 2 + $Title.Length, '=').PadRight($ConWidth, '='))
        $Error.Clear()
        & $BuildFunction
        $Success = $LASTEXITCODE -eq 0 -and $Error.Count -eq 0
        Write-Progress -Completed
        if ($Success) {
            Start-Sleep -Milliseconds 500
            $Exists = $true
            for ($i = 2; $i -lt $BUILD_TARGETS[$Target].Count; $i++) {
                if (-not (Test-Path $BUILD_TARGETS[$Target][$i])) {
                    $Exists = $false
                    break
                }
            }
        }
        Write-Host -fo White ('=' * $ConWidth)
        if (-not ($Success -and $Exists)) {
            $Err = [ErrorRecord]::new(
                [OperationCanceledException]::new("Failed to build '$Target' after $MaxBuildTries attempts."),
                'BuildFailed', 'OperationStopped', $Target
            )
            $PSCmdlet.WriteError($Err)
            $OverallSuccess = $false
            $FailTarget = $Target
            if ($NoFailFast) {
                continue TargetLoop
            } else {
                break TargetLoop
            }
        }
    }

    #endregion
}

end {
    [gc]::Collect()
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    if (-not $NoBuild) {
        if ($OverallSuccess) {
            $Msg = 'Build process completed.'
            if (-not $NoStrawberry) {  }
            $TextColor = 'Green'
        } else {
            $Msg = "Build process failed! Failing target: '$FailTarget'"
            $TextColor = 'Red'
        }
        Write-Host -fo White ('=' * $ConWidth)
        Write-Host -fo $TextColor ((' ' * (($ConWidth - $Msg.Length) / 2)) + $Msg)
        Write-Host -fo White ('=' * $ConWidth)
        if ($OverallSuccess -and -not $NoStrawberry) {
            $InstPath = Get-Item "$BuildPath\_strawberry\build\strawberrysetup*.exe" -ErrorAction Ignore | Select-Object -ExpandProperty FullName
            if ($null -ne $InstPath) {
                Write-Host -fo Cyan 'Installer package: ' -NoNewline
                Write-Host $InstPath
            }
        }
    }
    if ($CreatedReparse -and -not [string]::IsNullOrWhiteSpace($DefaultName) -and
        $null -ne (Get-Item "C:\$DefaultName" -ErrorAction Ignore | Where-Object { $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) })) {
        Remove-Item "C:\$DefaultName" -Force
    }
    if (-not $NoBuild) { Stop-Transcript }
}

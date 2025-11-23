#requires -Version 5.0

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
    [ValidateSet('release', 'debug')]
    [string]$BuildType = 'release',
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
    [switch]$NoFailFast
)

begin {
    if ($PSVersionTable.PSVersion -ge '6.0' -and -not $IsWindows) {
        $PSCmdlet.WriteWarning("This build script runs only on Windows platforms! This platform: $($PSVersionTable.Platform), OS: $($PSVersionTable.OS)")
        return
    }
    #region Setup
    $DoContinue = $false
    [string]$BuildPath = "${BuildPathRoot}_${BuildType}_$BuildArch"
    if (-not $NoBuild) {
        try { Stop-Transcript } catch {}
        Start-Transcript -Path "$BuildPath\StrawberryBuild_${BuildType}_${BuildArch}_$([datetime]::Now.ToString('yyyy-MM-ddTHH-mm-ss')).log" -Force
    }

    Write-Host -fo White ('=' * $Host.UI.RawUI.BufferSize.Width)
    Write-Host -fo White 'Strawberry Windows MSVC Builder'

    [string]$BuildTypeCMake = [cultureinfo]::InvariantCulture.TextInfo.ToTitleCase($BuildType)
    [string]$BuildTypeMeson = [cultureinfo]::InvariantCulture.TextInfo.ToLower($BuildType)
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
    $env:YASMPATH = "$VCPath\"

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
        $LocalBuildPath = "$BuildPath\yasm-$YASM_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\yasm-$YASM_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildPkgConf {
        $LocalBuildPath = "$BuildPath\pkgconf-pkgconf-$PKGCONF_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\pkgconf-$PKGCONF_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --prefix="$DependsPath" `
                --wrap-mode=nodownload -Dtests=disabled "$LocalBuildPath\build" $LocalBuildPath | Out-Default
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
    }

    function BuildMimAlloc {
        $LocalBuildPath = "$BuildPath\mimalloc-$MIMALLOC_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\mimalloc-$MIMALLOC_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DMI_BUILD_SHARED=ON `
            -DMI_BUILD_STATIC=OFF `
            -DMI_BUILD_TESTS=OFF `
            -DMI_CHECK_FULL=OFF `
            -DMI_DEBUG_FULL=OFF `
            -DMI_DEBUG_TSAN=OFF `
            -DMI_DEBUG_UBSAN=OFF `
            -DMI_OVERRIDE=ON `
            -DMI_USE_CXX=ON `
            -DMI_WIN_REDIRECT=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Move-Item "$DependsPath\lib\mimalloc*.dll" "$DependsPath\bin\" -Force
    }

    function BuildGetOpt {
        $LocalBuildPath = "$BuildPath\getopt-win"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_TESTING=OFF `
            -DBUILD_STATIC_LIBS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildZlib {
        $LocalBuildPath = "$BuildPath\zlib-$ZLIB_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy pkgconfig...'
        Copy-Item "$DependsPath\share\pkgconfig\zlib.pc" "$DependsPath\lib\pkgconfig\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan "    Patch pkgconfig z -> zlib$DebugPostfix..."
        foreach ($File in (Get-ChildItem "$DependsPath\*\pkgconfig\zlib.pc")) {
            (Get-Content $File) -creplace '-lz', "-lzlib$DebugPostfix" | Set-Content $File
            if (-not $?) { return }
        }
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$DependsPath\lib\zlib$DebugPostfix.lib" "$DependsPath\lib\z.lib" -Force
        if (-not (Test-Path "$DependsPath\lib\zlib.lib")) { Copy-Item "$DependsPath\lib\zlib$DebugPostfix.lib" "$DependsPath\lib\zlib.lib" -Force }
        if (-not $?) { return }
        Write-Host -fo Cyan '    Remove static libraries...'
        Remove-Item "$DependsPath\lib\zlibstatic*.lib" -Force
    }

    function BuildOpenSSL {
        $LocalBuildPath = "$BuildPath\openssl-$OPENSSL_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\openssl-$OPENSSL_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Push-Location $LocalBuildPath
        Write-Host -fo Cyan '    Perl configure...'
        $ZLibInfix = if ($BuildArch -eq 'arm64') { '' } else { 'zlib' }
        perl.exe Configure $PerlArch shared $ZLibInfix no-capieng no-tests --prefix="$DependsPath" `
            --libdir="lib" `
            --openssldir="$DependsPath\ssl" `
            --$BuildType `
            --with-zlib-include="$DependsPath\include" `
            --with-zlib-lib="$DependsPath\lib\zlib.lib" | Out-Default
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
    }
    function BuildGmp {
        $LocalBuildPath = "$BuildPath\ShiftMediaProject\build"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            $null = New-Item -ItemType Directory $LocalBuildPath
        }
        if (-not (Test-Path "$LocalBuildPath\gmp" -PathType Container)) {
            $null = New-Item -ItemType Directory "$LocalBuildPath\gmp"
            Write-Host -fo Cyan '    Copy source repo...'
            xcopy.exe /B /Y /R /I /H /E /Q "$DownloadPath\gmp" "$LocalBuildPath\gmp" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    MSBuild build...'
        msbuild.exe "$LocalBuildPath\gmp\SMP\libgmp.vcxproj" -p:Configuration="${BuildType}DLL" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy library...'
        Copy-Item "$LocalBuildPath\..\msvc\lib\$BuildArch\gmp${DebugPostfix}.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binary...'
        Copy-Item "$LocalBuildPath\..\msvc\bin\$BuildArch\gmp${DebugPostfix}.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy includes...'
        Copy-Item "$LocalBuildPath\..\msvc\include\gmp*.h" "$DependsPath\include\" -Force
        if (-not $?) { return }
        Set-Content -Path "$DependsPath\lib\pkgconfig\gmp.pc" -Force -Value @"
$PkgconfTemplate

Name: gmp
Description: ShiftMediaProject GMP
Version: $GMP_VERSION
Libs: -L`${libdir} -lgmp${DebugPostfix}
Cflags: -I`${includedir}
"@
    }
    function BuildNettle {
        $LocalBuildPath = "$BuildPath\ShiftMediaProject\build"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            $null = New-Item -ItemType Directory $LocalBuildPath
        }
        if (-not (Test-Path "$LocalBuildPath\nettle" -PathType Container)) {
            $null = New-Item -ItemType Directory "$LocalBuildPath\nettle"
            Write-Host -fo Cyan '    Copy source repo...'
            xcopy.exe /B /Y /R /I /H /E /Q "$DownloadPath\nettle" "$LocalBuildPath\nettle" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    nettle MSBuild build...'
        msbuild.exe "$LocalBuildPath\nettle\SMP\libnettle.vcxproj" -p:Configuration="${BuildType}DLL" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy library...'
        Copy-Item "$LocalBuildPath\..\msvc\lib\$BuildArch\nettle${DebugPostfix}.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binary...'
        Copy-Item "$LocalBuildPath\..\msvc\bin\$BuildArch\nettle${DebugPostfix}.dll" "$DependsPath\bin\" -Force
        if (-not (Test-Path "$DependsPath\include\nettle" -PathType Container)) {
            Write-Host -fo Cyan '    Create include path...'
            $null = New-Item -ItemType Directory "$DependsPath\include\nettle"
        }
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy includes...'
        Copy-Item "$LocalBuildPath\..\msvc\include\nettle\*.h" "$DependsPath\include\nettle" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    hogweed MSBuild build...'
        msbuild.exe "$LocalBuildPath\nettle\SMP\libhogweed.vcxproj" -p:Configuration="${BuildType}DLL" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy library...'
        Copy-Item "$LocalBuildPath\..\msvc\lib\$BuildArch\hogweed${DebugPostfix}.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binary...'
        Copy-Item "$LocalBuildPath\..\msvc\bin\$BuildArch\hogweed${DebugPostfix}.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy includes...'
        Copy-Item "$LocalBuildPath\..\msvc\include\nettle\*.h" "$DependsPath\include\nettle" -Force
        if (-not $?) { return }
        Set-Content -Path "$DependsPath\lib\pkgconfig\nettle.pc" -Force -Value @"
$PkgconfTemplate

Name: nettle
Description: ShiftMediaProject nettle
URL: https://www.lysator.liu.se/~nisse/nettle/
Version: $NETTLE_VERSION
Libs: -L`${libdir} -lnettle${DebugPostfix}
Cflags: -I`${includedir}
"@
        if (-not $?) { return }
        Set-Content -Path "$DependsPath\lib\pkgconfig\hogweed.pc" -Force -Value @"
$PkgconfTemplate

Name: hogweed
Description: ShiftMediaProject hogweed
URL: https://www.lysator.liu.se/~nisse/nettle/
Version: $NETTLE_VERSION
Libs: -L`${libdir} -lhogweed${DebugPostfix}
Cflags: -I`${includedir}
"@
        if (-not $?) { return }
    }

    function BuildGnutls {
        $LocalBuildPath = "$BuildPath\ShiftMediaProject\build"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            $null = New-Item -ItemType Directory $LocalBuildPath
        }
        if (-not (Test-Path "$LocalBuildPath\gnutls" -PathType Container)) {
            $null = New-Item -ItemType Directory "$LocalBuildPath\gnutls"
            Write-Host -fo Cyan '    Copy source repo...'
            xcopy.exe /B /Y /R /I /H /E /Q "$DownloadPath\gnutls" "$LocalBuildPath\gnutls" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Set-Content "$LocalBuildPath\gnutls\SMP\inject_zlib.props" -Value @"
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemDefinitionGroup>
    <ClCompile>
      <AdditionalIncludeDirectories>$DependsPath\include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
    <Link>
      <AdditionalLibraryDirectories>$DependsPath\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
    </Link>
  </ItemDefinitionGroup>
</Project>
"@
        Push-Location "$LocalBuildPath\gnutls\SMP\"
        "`r`n" | & '.\project_get_dependencies.bat'
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Write-Host -fo Cyan '    GMP static dependency build...'
        msbuild.exe "$LocalBuildPath\gmp\SMP\libgmp.vcxproj" -p:Configuration=Release | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Write-Host -fo Cyan '    zlib static dependency build...'
        msbuild.exe "$LocalBuildPath\zlib\SMP\libzlib.vcxproj" -p:Configuration=Release | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Write-Host -fo Cyan '    nettle static dependency build...'
        msbuild.exe "$LocalBuildPath\nettle\SMP\libnettle.vcxproj" -p:Configuration=Release | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Write-Host -fo Cyan '    hogweed static dependency build...'
        msbuild.exe "$LocalBuildPath\nettle\SMP\libhogweed.vcxproj" -p:Configuration=Release | Out-Default
        if ($LASTEXITCODE -ne 0) { Pop-Location; return }
        Write-Host -fo Cyan '    GNUTLS MSBuild build...'
        msbuild.exe "$LocalBuildPath\gnutls\SMP\libgnutls.vcxproj" -p:Configuration=ReleaseDLLStaticDeps | Out-Default
        Pop-Location
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy library...'
        Copy-Item "$LocalBuildPath\..\msvc\lib\$BuildArch\gnutls.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binary...'
        Copy-Item "$LocalBuildPath\..\msvc\bin\$BuildArch\gnutls.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy includes...'
        if (-not (Test-Path "$DependsPath\include\gnutls\" -PathType Container)) {
            $null = New-Item -ItemType Directory "$DependsPath\include\gnutls"
        }
        Copy-Item "$LocalBuildPath\..\msvc\include\gnutls\*.h" "$DependsPath\include\gnutls\" -Force
        if (-not $?) { return }
        Set-Content -Path "$DependsPath\lib\pkgconfig\gnutls.pc" -Force -Value @"
$PkgconfTemplate

Name: gnutls
Description: gnutls (static deps)
URL: https://www.gnutls.org/
Version: $GNUTLS_VERSION
Libs: -L`${libdir} -lgnutls
Cflags: -I`${includedir}
"@ # No $DebugPostfix?
        if (-not $?) { return }
    }
    <#
    function BuildGnutls {
        $LocalBuildPath = "$BuildPath\gnutls-$GNUTLS_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            7z.exe x -aoa "$DownloadPath\libgnutls_${GNUTLS_VERSION}_msvc17.zip" -o"$LocalBuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\bin\$BuildArch\*" "$DependsPath\bin\" -Recurse -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\lib\$BuildArch\gnutls.*" "$DependsPath\lib\" -Recurse -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy headers...'
        if (-not (Test-Path "$DependsPath\include\gnutls" -PathType Container)) {
            $null = New-Item "$DependsPath\include\gnutls" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Copy-Item "$LocalBuildPath\include\gnutls\*.h" "$DependsPath\include\gnutls" -Recurse -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\gnutls.pc" -Value @"
$PkgconfTemplate

Name: gnutls
Description: gnutls
URL: https://www.gnutls.org/
Version: $GNUTLS_VERSION
Libs: -L`${libdir} -lgnutls
Cflags: -I`${includedir}
"@
    }
#>
    function BuildLibpng {
        $LocalBuildPath = "$BuildPath\libpng-$LIBPNG_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" | Out-Default
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
    }

    function BuildLibjpeg {
        $LocalBuildPath = "$BuildPath\libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DENABLE_SHARED=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" `
            -DWITH_SIMD="$SIMD" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildPcre2 {
        $LocalBuildPath = "$BuildPath\pcre2-$PCRE2_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
    }

    function BuildBzip2 {
        $LocalBuildPath = "$BuildPath\bzip2-$BZIP2_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildXz {
        $LocalBuildPath = "$BuildPath\xz-$XZ_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
    }

    function BuildBrotli {
        $LocalBuildPath = "$BuildPath\brotli-$BROTLI_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_TESTING=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildLibiconv {
        $LocalBuildPath = "$BuildPath\libiconv-for-Windows"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\libiconv-for-Windows" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    MSBuild build...'
        msbuild.exe "$LocalBuildPath\libiconv.sln" -p:Configuration="$BuildType" -p:Platform="$BuildArch" -p:SkipUWP=true | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\output\$BuildArch32Alt\$BuildType\*.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\output\$BuildArch32Alt\$BuildType\*.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\include\*.h" "$DependsPath\include\" -Force
        if (-not $?) { return }
        if ($ISDEBUG) {
            Write-Host -fo Cyan '    Duplicate debug library...'
            Copy-Item "$DependsPath\lib\libiconv$DebugPostfix.lib" "$DependsPath\lib\libiconv.lib" -Force
            if (-not $?) { return }
        }
    }

    function BuildIcu4c {
        $LocalBuildPath = "$BuildPath\icu"
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
    }

    function BuildPixman {
        $LocalBuildPath = "$BuildPath\pixman-$PIXMAN_VERSION"
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
    }

    function BuildExpat {
        $LocalBuildPath = "$BuildPath\expat-$EXPAT_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
    }

    function BuildBoost {
        $LocalBuildPath = "$BuildPath\boost_$BOOST_VERSION_UNDERSCORE"
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
    }

    function BuildLibxml2 {
        $LocalBuildPath = "$BuildPath\libxml2-v$LIBXML2_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DICU_ROOT="$DependsPathForward" `
            -DBUILD_SHARED_LIBS=ON `
            -DLIBXML2_WITH_PYTHON=OFF `
            -DLIBXML2_WITH_ZLIB=ON `
            -DLIBXML2_WITH_LZMA=ON `
            -DLIBXML2_WITH_ICONV=ON `
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
            if (-not $?) { return }
        }
    }

    function BuildNghttp2 {
        $LocalBuildPath = "$BuildPath\nghttp2-$NGHTTP2_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildLibffi {
        $LocalBuildPath = "$BuildPath\libffi"
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
    }

    function BuildLibintl {
        $LocalBuildPath = "$BuildPath\proxy-libintl"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\proxy-libintl" $LocalBuildPath -Recurse -Force
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
    }

    function BuildDlfcn {
        $LocalBuildPath = "$BuildPath\dlfcn-win32-$DLFCN_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildLibpsl {
        $LocalBuildPath = "$BuildPath\libpsl-$LIBPSL_VERSION"
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
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
    }

    function BuildOrc {
        $LocalBuildPath = "$BuildPath\orc-$ORC_VERSION"
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
    }

    function BuildLibcurl {
        $LocalBuildPath = "$BuildPath\curl-$CURL_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\curl-$CURL_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildSqlite {
        $LocalBuildPath = "$BuildPath\sqlite-autoconf-$SQLITE3_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\sqlite-autoconf-$SQLITE3_VERSION.tar.gz" -C $BuildPath | Out-Default
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
    }

    function BuildGlib {
        $LocalBuildPath = "$BuildPath\glib-$GLIB_VERSION"
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
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --includedir="$DependsPath\include" `
                --libdir="$DependsPath\lib" `
                -Dtests=false `
                -Dc_args="-I$DependsPathForward/include" `
                -Dc_link_args="-L$DependsPath\lib" `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
    }

    function BuildLibproxy {
        # Doesn't compile with MSVC
        $LocalBuildPath = "$BuildPath\libproxy-$LIBPROXY_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\libproxy-$LIBPROXY_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Push-Location $LocalBuildPath
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup `
                --buildtype="$BuildTypeMeson" `
                --default-library=shared `
                --wrap-mode=nodownload `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --includedir="$DependsPath\include" `
                --libdir="$DependsPath\lib" `
                -Dc_args="-I$DependsPathForward/include" `
                -Drelease="$IsRelease" `
                -Ddocs=false `
                -Dtests=false `
                -Dconfig-xdp=false `
                -Dconfig-kde=false `
                -Dconfig-osx=false `
                -Dconfig-gnome=false `
                -Dpacrunner-duktape=false `
                -Dintrospection=false `
                -DHAVE_CURL=false `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Pop-Location
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Move binaries to bin...'
        Move-Item "$DependsPath\lib\libproxy.dll" "$DependsPath\bin\libproxy.dll" -Force
    }

    function BuildLibsoup {
        $LocalBuildPath = "$BuildPath\libsoup-$LIBSOUP_VERSION"
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
    }

    function BuildGlibNetworking {
        $LocalBuildPath = "$BuildPath\glib-networking-$GLIB_NETWORKING_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            7z.exe x -aos "$DownloadPath\glib-networking-$GLIB_NETWORKING_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            7z.exe x -aoa "$DownloadPath\glib-networking-$GLIB_NETWORKING_VERSION.tar" -o"$BuildPath" | Out-Default
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
                -Dgnutls=enabled `
                -Dopenssl=enabled `
                -Dgnome_proxy=disabled `
                -Dlibproxy=disabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
    }

    function BuildFreetype {
        param(
            [switch]$NoHarfbuzz
        )
        $LocalBuildPath = "$BuildPath\freetype-$FREETYPE_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
            if (-not $?) { return }
        }
    }

    function BuildCairo {
        $LocalBuildPath = "$BuildPath\cairo-$CAIRO_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            7z.exe x -aos "$DownloadPath\cairo-$CAIRO_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            7z.exe x -aoa "$DownloadPath\cairo-$CAIRO_VERSION.tar" -o"$BuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch alloca (Linux) -> _alloca (MSVC)...'
        foreach ($File in (Get-ChildItem "$LocalBuildPath\src\*.c")) {
            (Get-Content $File) -creplace '\balloca(\s*\()', '_alloca$1' | Set-Content $File
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Copy libpng lib...'
        Copy-Item "$DependsPath\lib\libpng16$DebugPostfix.lib" "$DependsPath\lib\png16.lib" -Force
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                -Dc_args="-I$DependsPathForward/include" `
                --includedir="$DependsPath\include" `
                --libdir="$DependsPath\lib" `
                -Dfontconfig=disabled `
                -Dfreetype=enabled `
                -Dzlib=enabled `
                -Dpng=enabled `
                -Dtests=disabled `
                -Dgtk_doc=false `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
    }

    function BuildHarfbuzz {
        $LocalBuildPath = "$BuildPath\harfbuzz-$HARFBUZZ_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            7z.exe x -aos "$DownloadPath\harfbuzz-$HARFBUZZ_VERSION.tar.xz" -o"$DownloadPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
            7z.exe x -aoa "$DownloadPath\harfbuzz-$HARFBUZZ_VERSION.tar" -o"$BuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch alloca (Linux) -> _alloca (MSVC)...'
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
    }

    function BuildLibogg {
        $LocalBuildPath = "$BuildPath\libogg-$LIBOGG_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DINSTALL_DOCS=OFF `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildLibvorbis {
        $LocalBuildPath = "$BuildPath\libvorbis-$LIBVORBIS_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DINSTALL_DOCS=OFF `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildFlac {
        $LocalBuildPath = "$BuildPath\flac-$FLAC_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
    }

    function BuildWavpack {
        $LocalBuildPath = "$BuildPath\wavpack-$WAVPACK_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
    }

    function BuildOpus {
        $LocalBuildPath = "$BuildPath\opus-$OPUS_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildOpusfile {
        $LocalBuildPath = "$BuildPath\opusfile-$OPUSFILE_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildSpeex {
        $LocalBuildPath = "$BuildPath\speex-Speex-$SPEEX_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
            if (-not $?) { return }
        }
    }

    function BuildLibmpg123 {
        $LocalBuildPath = "$BuildPath\mpg123-$MPG123_VERSION"
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
        cmake.exe --log-level="DEBUG" -S "$LocalBuildPath\ports\cmake" -B "$LocalBuildPath\build_cmake" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
    }

    function BuildLame {
        $LocalBuildPath = "$BuildPath\lame-$LAME_VERSION"
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
    }

    function BuildTwolame {
        $LocalBuildPath = "$BuildPath\twolame-$TWOLAME_VERSION"
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
    }

    function BuildFftw3 {
        $LocalBuildPath = "$BuildPath\fftw-$FFTW_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            7z.exe x -aoa "$DownloadPath\fftw-$FFTW_VERSION-$BuildArch-$BuildType.zip" -o"$LocalBuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Generate library...'
        lib.exe /MACHINE:"$BuildArch" /DEF:"$LocalBuildPath\libfftw3-3.def" /OUT:"$LocalBuildPath\libfftw3-3.lib" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\fftw3.h" "$DependsPath\include\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\libfftw3-3.lib" "$DependsPath\lib\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\libfftw3-3.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        if ($BuildAddressSize -eq '32') {
            Copy-Item "$LocalBuildPath\libgcc_s_sjlj-1.dll", "$LocalBuildPath\libwinpthread-1.dll" "$DependsPath\bin\" -Force
        }
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\fftw3.pc" -Force -Value @"
$PkgconfTemplate

Name: fftw3
Description: A C subroutine library for discrete Fourier transform (DFT)
URL: https://www.fftw.org/
Version: $FFTW_VERSION
Libs: -L`${libdir} -lfftw3-3
Cflags: -I`${includedir}
"@
    }

    function BuildMusepack {
        $LocalBuildPath = "$BuildPath\musepack_src_r$MUSEPACK_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="Debug" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
    }

    function BuildLibopenmpt {
        $LocalBuildPath = "$BuildPath\libopenmpt-$LIBOPENMPT_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build_cmake" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build_cmake" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build_cmake" | Out-Default
    }

    function BuildLibgme {
        $LocalBuildPath = "$BuildPath\libgme-$LIBGME_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\libgme-$LIBGME_VERSION-src.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\libgme-pkgconf.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildFdkaac {
        $LocalBuildPath = "$BuildPath\fdk-aac-$FDK_AAC_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_PROGRAMS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildFaad2 {
        $LocalBuildPath = "$BuildPath\faad2-$FAAD2_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildFaac {
        $LocalBuildPath = "$BuildPath\faac-faac-$FAAC_VERSION"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract source...'
            tar.exe -xf "$DownloadPath\faac-$FAAC_VERSION.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\faac-msvc.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\project\msvc\Backup\faac.sln")) {
            Write-Host -fo Cyan '    Upgrade VS solution...'
            Start-Process devenv.exe -ArgumentList "$LocalBuildPath\project\msvc\faac.sln", '/upgrade' -Wait
            if ($LASTEXITCODE -ne 0) { return }
        }
        Push-Location "$LocalBuildPath\project\msvc"
        Write-Host -fo Cyan '    MSBuild build...'
        msbuild.exe 'faac.sln' -p:Configuration="$BuildType" -p:Platform="$BuildArch32Alt" -p:SkipUWP=true | Out-Default
        Pop-Location
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Copy headers...'
        Copy-Item "$LocalBuildPath\include\*.h" "$DependsPath\include\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy libraries...'
        Copy-Item "$LocalBuildPath\project\msvc\bin\$BuildType\libfaac_dll.lib" "$DependsPath\lib\libfaac.lib" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\project\msvc\bin\$BuildType\*.dll" "$DependsPath\bin\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Write pkgconfig...'
        Set-Content -Path "$DependsPath\lib\pkgconfig\faac.pc" -Force -Value @"
$PkgconfTemplate

Name: faac
Description: An Advanced Audio Coder (MPEG2-AAC, MPEG4-AAC)
URL: https://github.com/knik0/faac
Version: $FAAC_VERSION
Libs: -L`${libdir} -lfaac
Cflags: -I`${includedir}
"@
    }

    function BuildUtfcpp {
        $LocalBuildPath = "$BuildPath\utfcpp-$UTFCPP_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildTaglib {
        $LocalBuildPath = "$BuildPath\taglib-$TAGLIB_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildLibbs2b {
        $LocalBuildPath = "$BuildPath\libbs2b-$LIBBS2B_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildLibebur128 {
        $LocalBuildPath = "$BuildPath\libebur128-$LIBEBUR128_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildFfmpeg {
        $LocalBuildPath = "$BuildPath\ffmpeg"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\ffmpeg" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=both `
                --prefix="$DependsPath" `
                --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dtests=disabled `
                -Dgpl=enabled `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
    }

    function BuildChromaprint {
        $LocalBuildPath = "$BuildPath\chromaprint-$CHROMAPRINT_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DFFMPEG_ROOT="$DependsPath" `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
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
                -Dhls-crypto=openssl `
                "$LocalBuildPath\build" $LocalBuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Ninja build...'
        ninja.exe -C "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    Ninja install...'
        ninja.exe -C "$LocalBuildPath\build" install | Out-Default
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
        Write-Host -fo Cyan '    Patch build configuration...'
        Get-Content "$DownloadPath\gst-plugins-bad-meson-dependency.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        if ($Error.Count -gt 0 -or $LASTEXITCODE -gt 1) { return }
        if (-not (Test-Path "$LocalBuildPath\build\build.ninja")) {
            Write-Host -fo Cyan '    Meson configure...'
            meson.exe setup --buildtype="$BuildTypeMeson" --default-library=shared --prefix="$DependsPath" --pkg-config-path="$DependsPath\lib\pkgconfig" `
                --wrap-mode=nodownload `
                -Dc_args="-I$DependsPathForward/include -I$DependsPathForward/include/opus" `
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
    }

    function BuildGstspotify {
        $LocalBuildPath = "$BuildPath\gst-plugins-rs"
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
            git.exe -C "$LocalBuildPath" checkout $GSTREAMER_PLUGINS_RS_VERSION
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
    }

    function BuildAbseil {
        $LocalBuildPath = "$BuildPath\abseil-cpp-$ABSEIL_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_TESTING=OFF `
            -DABSL_BUILD_TESTING=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildProtobuf {
        $LocalBuildPath = "$BuildPath\protobuf-$PROTOBUF_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
        Get-Content "$DownloadPath\qtbase-qwindowswindow.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        # Get-Content "$DownloadPath\qtbase-networkcache.patch" -ErrorAction Stop | patch.exe -p1 -N -d $LocalBuildPath | Out-Default
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G Ninja `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
            -DFEATURE_system_sqlite=ON | Out-Default

        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
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
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DCMAKE_PREFIX_PATH="$DependsPathForward/lib/cmake" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DQT_BUILD_EXAMPLES=OFF `
            -DQT_BUILD_EXAMPLES_BY_DEFAULT=OFF `
            -DQT_BUILD_TOOLS_WHEN_CROSSCOMPILING=ON | Out-Default
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildQtsparkle {
        $LocalBuildPath = "$BuildPath\qtsparkle"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\qtsparkle" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DCMAKE_PREFIX_PATH="$DependsPathForward/lib/cmake" `
            -DBUILD_WITH_QT6=ON `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildSparsehash {
        $LocalBuildPath = "$BuildPath\sparsehash-sparsehash-$SPARSEHASH_VERSION"
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
    }

    function BuildRapidjson {
        $LocalBuildPath = "$BuildPath\rapidjson"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Copy source repo...'
            Copy-Item "$DownloadPath\rapidjson" $LocalBuildPath -Recurse -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DCMAKE_INSTALL_DIR="$DependsPath\lib\cmake\RapidJSON" `
            -DBUILD_SHARED_LIBS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" `
            -DBUILD_TESTING=OFF `
            -DRAPIDJSON_BUILD_TESTS=OFF `
            -DRAPIDJSON_BUILD_EXAMPLES=OFF `
            -DRAPIDJSON_BUILD_DOC=OFF | Out-Default
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildKdsingleapp {
        $LocalBuildPath = "$BuildPath\kdsingleapplication-$KDSINGLEAPPLICATION_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DCMAKE_PREFIX_PATH="$DependsPathForward/lib/cmake" `
            -DBUILD_SHARED_LIBS=ON `
            -DKDSingleApplication_QT6=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildGlew {
        $LocalBuildPath = "$BuildPath\glew-$GLEW_VERSION"
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
        cmake.exe --log-level="DEBUG" -S "$LocalBuildPath\build\cmake" -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DCMAKE_POLICY_VERSION_MINIMUM="3.5" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildLibprojectm {
        $LocalBuildPath = "$BuildPath\libprojectm-$LIBPROJECTM_VERSION"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildGettext {
        $LocalBuildPath = "$BuildPath\gettext${GETTEXT_VERSION}-iconv${ICONV_VERSION}"
        if (-not (Test-Path "$BuildPath\gettext${GETTEXT_VERSION}-iconv*" -PathType Container)) {
            $SourceZip = Get-Item "$DownloadPath\gettext${GETTEXT_VERSION}-iconv${ICONV_VERSION}-static-$BuildAddressSize.zip"
            Write-Host -fo Cyan '    Extract archive...'
            7z.exe x -aoa $SourceZip -o"$LocalBuildPath" | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        Write-Host -fo Cyan '    Copy binaries...'
        Copy-Item "$LocalBuildPath\bin\*.exe" "$DependsPath\bin\"
    }

    function BuildTinysvcmdns {
        $LocalBuildPath = "$BuildPath\tinysvcmdns"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
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
    }

    function BuildPeParse {
        $LocalBuildPath = "$BuildPath\pe-parse-${PE_PARSE_VERSION}"
        if (-not (Test-Path $LocalBuildPath -PathType Container)) {
            Write-Host -fo Cyan '    Extract archive...'
            tar.exe -xf "$DownloadPath\pe-parse-${PE_PARSE_VERSION}.tar.gz" -C $BuildPath | Out-Default
            if ($LASTEXITCODE -ne 0) { return }
        }
        if (-not (Test-Path "$LocalBuildPath\build" -PathType Container)) {
            Write-Host -fo Cyan '    Create build directory...'
            $null = New-Item "$LocalBuildPath\build" -ItemType Directory -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DBUILD_COMMAND_LINE_TOOLS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildPeUtil {
        $LocalBuildPath = "$BuildPath\pe-util"
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
        cmake.exe --log-level="DEBUG" -S $LocalBuildPath -B "$LocalBuildPath\build" -G $CMakeGenerator `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_INSTALL_PREFIX="$DependsPathForward" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkgconf.exe" `
            -DBUILD_SHARED_LIBS=ON `
            -DBUILD_STATIC_LIBS=OFF `
            -DBUILD_COMMAND_LINE_TOOLS=OFF | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake build...'
        cmake.exe --build "$LocalBuildPath\build" | Out-Default
        if ($LASTEXITCODE -ne 0) { return }
        Write-Host -fo Cyan '    CMake install...'
        cmake.exe --install "$LocalBuildPath\build" | Out-Default
    }

    function BuildStrawberry {
        $LocalBuildPath = "$BuildPath\_strawberry"
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
        if ($BuildArch -eq 'x86') {
            Write-Host -fo Cyan '    Patch build configuration guint64 -> gsize...'
            (Get-Content "$LocalBuildPath\src\engine\gstfastspectrum.cpp" -Raw) -replace
            'size -= block_size \* bpf;', 'size -= static_cast<gsize>(block_size * bpf);' |
                Set-Content "$LocalBuildPath\src\engine\gstfastspectrum.cpp" -NoNewline
            if (-not $?) { return }
        }
        $IncludeSpotify = if (Test-Path "$DependsPath\lib\gstreamer-*\gstspotify.dll") { 'ON' } else { 'OFF' }
        $EnableCon = if ($EnableStrawberryConsole) { 'ON' } else { 'OFF' }
        Write-Host -fo Cyan '    CMake configure...'
        cmake.exe --log-level="TRACE" -S $LocalBuildPath -B "$LocalBuildPath\build" -G 'Visual Studio 17 2022' -A $BuildArch32Alt `
            -DCMAKE_BUILD_TYPE="$BuildTypeCMake" `
            -DCMAKE_PREFIX_PATH="$DependsPathForward/lib/cmake" `
            -DCMAKE_IGNORE_PATH="C:\Strawberry\perl\lib;C:\Strawberry\c\lib" `
            -DPKG_CONFIG_EXECUTABLE="$DependsPathForward/bin/pkg-config.exe" `
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
        # cmake.exe --install "$LocalBuildPath\build" | Out-Default
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
        Write-Host -fo Cyan '    Copy dependency binaries...'
        foreach ($Bin in 'abseil_dll.dll', 'avcodec*.dll', 'avfilter*.dll', 'avformat*.dll', 'avutil*.dll', 'brotlicommon.dll', 'brotlidec.dll', 'chromaprint.dll', 'ebur128.dll',
            'faad-2.dll', 'fdk-aac.dll', 'ffi-7.dll', 'flac.dll', 'freetype*.dll', 'gio-2.0-0.dll', 'glib-2.0-0.dll', 'gme.dll', 'gmodule-2.0-0.dll', 'gnutls.dll', 'gobject-2.0-0.dll',
            'gst-discoverer-1.0.exe', 'gst-launch-1.0.exe', 'gst-play-1.0.exe', 'gstadaptivedemux-1.0-0.dll', 'gstapp-1.0-0.dll', 'gstaudio-1.0-0.dll', 'gstbadaudio-1.0-0.dll',
            'gstbase-1.0-0.dll', 'gstcodecparsers-1.0-0.dll', 'gstfft-1.0-0.dll', 'gstisoff-1.0-0.dll', 'gstmpegts-1.0-0.dll', 'gstnet-1.0-0.dll', 'gstpbutils-1.0-0.dll',
            'gstreamer-1.0-0.dll', 'gstriff-1.0-0.dll', 'gstrtp-1.0-0.dll', 'gstrtsp-1.0-0.dll', 'gstsdp-1.0-0.dll', 'gsttag-1.0-0.dll', 'gsturidownloader-1.0-0.dll',
            'gstvideo-1.0-0.dll', 'gstwinrt-1.0-0.dll', 'harfbuzz*.dll', 'icudt*.dll', 'icuin*.dll', 'icuuc*.dll', 'intl-8.dll', 'jpeg62.dll', 'libbs2b.dll', 'libcrypto-3*.dll',
            'libfaac_dll.dll', 'libfftw3-3.dll', 'libiconv*.dll', 'liblzma.dll', 'libmp3lame.dll', 'libopenmpt.dll', 'libpng16*.dll', 'libprotobuf*.dll', 'libspeex*.dll',
            'libssl-3*.dll', 'libxml2*.dll', 'mpcdec.dll', 'mpg123.dll', 'nghttp2.dll', 'ogg.dll', 'opus.dll', 'orc-0.4-0.dll', 'pcre2-16*.dll', 'pcre2-8*.dll', 'postproc*.dll',
            'psl-5.dll', 'qt6concurrent*.dll', 'qt6core*.dll', 'qt6gui*.dll', 'qt6network*.dll', 'qt6sql*.dll', 'qt6widgets*.dll', 'qtsparkle-qt6.dll', 'soup-3.0-0.dll',
            'sqlite3.dll', 'sqlite3.exe', 'swresample*.dll', 'swscale*.dll', 'tag.dll', 'twolame*.dll', 'vorbis.dll', 'vorbisfile.dll', 'wavpackdll.dll', 'zlib*.dll',
            'kdsingleapplication*.dll', 'utf8_validity.dll', 'getopt.dll' ) {
            Copy-Item "$DependsPath\bin\$Bin" "$LocalBuildPath\build\" -Force
            if (-not $?) { return }
        }
        if ($BuildAddressSize -eq '32') {
            Copy-Item "$DependsPath\bin\libgcc_s_sjlj-1.dll", "$DependsPath\bin\libwinpthread-1.dll" "$LocalBuildPath\build\" -Force
            if (-not $?) { return }
        }
        Copy-Item "$DependsPath\lib\gio\modules\*.dll" "$LocalBuildPath\build\gio-modules\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy plugins...'
        Copy-Item "$DependsPath\plugins\platforms\qwindows*.dll" "$LocalBuildPath\build\platforms\" -Force
        if (-not $?) { return }
        Copy-Item "$DependsPath\plugins\styles\qmodernwindowsstyle*.dll" "$LocalBuildPath\build\styles\" -Force
        if (-not $?) { return }
        Copy-Item "$DependsPath\plugins\tls\*.dll" "$LocalBuildPath\build\tls\" -Force
        if (-not $?) { return }
        Copy-Item "$DependsPath\plugins\sqldrivers\qsqlite*.dll" "$LocalBuildPath\build\sqldrivers\" -Force
        if (-not $?) { return }
        Copy-Item "$DependsPath\plugins\imageformats\*.dll" "$LocalBuildPath\build\imageformats\" -Force
        if (-not $?) { return }
        Write-Host -fo Cyan '    Copy GStreamer plugins...'
        foreach ($Plug in 'gstadaptivedemux2.dll', 'gstaes.dll', 'gstaiff.dll', 'gstapetag.dll', 'gstapp.dll', 'gstasf.dll', 'gstasfmux.dll', 'gstasio.dll', 'gstaudioconvert.dll',
            'gstaudiofx.dll', 'gstaudioparsers.dll', 'gstaudioresample.dll', 'gstautodetect.dll', 'gstbs2b.dll', 'gstcoreelements.dll', 'gstdash.dll', 'gstdsd.dll', 'gstdirectsound.dll',
            'gstequalizer.dll', 'gstfaac.dll', 'gstfaad.dll', 'gstfdkaac.dll', 'gstflac.dll', 'gstgio.dll', 'gstgme.dll', 'gsthls.dll', 'gsticydemux.dll', 'gstid3demux.dll',
            'gstid3tag.dll', 'gstisomp4.dll', 'gstlame.dll', 'gstlibav.dll', 'gstmpegpsdemux.dll', 'gstmpegpsmux.dll', 'gstmpegtsdemux.dll', 'gstmpegtsmux.dll', 'gstmpg123.dll',
            'gstmusepack.dll', 'gstogg.dll', 'gstopenmpt.dll', 'gstopus.dll', 'gstopusparse.dll', 'gstpbtypes.dll', 'gstplayback.dll', 'gstreplaygain.dll', 'gstrtp.dll', 'gstrtsp.dll',
            'gstsoup.dll', 'gstspectrum.dll', 'gstspeex.dll', 'gsttaglib.dll', 'gsttcp.dll', 'gsttwolame.dll', 'gsttypefindfunctions.dll', 'gstudp.dll', 'gstvolume.dll',
            'gstvorbis.dll', 'gstwasapi.dll', 'gstwasapi2.dll', 'gstwaveform.dll', 'gstwavenc.dll', 'gstwavpack.dll', 'gstwavparse.dll', 'gstxingmux.dll') {
            Copy-Item "$DependsPath\lib\gstreamer-1.0\$Plug" "$LocalBuildPath\build\gstreamer-plugins\" -Force
            if (-not $?) { return }
        }
        if ($IncludeSpotify -eq 'ON') {
            Copy-Item "$DependsPath\lib\gstreamer-1.0\gstspotify.dll" "$LocalBuildPath\build\gstreamer-plugins\" -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Copy resources...'
        Copy-Item "$LocalBuildPath\COPYING" "$LocalBuildPath\build\" -Force
        if (-not $?) { return }
        foreach ($Type in 'nsh', 'ico') {
            Copy-Item "$LocalBuildPath\dist\windows\*.$Type" "$LocalBuildPath\build\" -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Copy MSVC redistributables...'
        foreach ($Arch in '64', '86') {
            Copy-Item "$DownloadPath\vc_redist.x$Arch.exe" "$LocalBuildPath\build\" -Force
            if (-not $?) { return }
        }
        Write-Host -fo Cyan '    Build NSIS installer...'
        makensis.exe "$LocalBuildPath\build\strawberry.nsi" | Out-Default
    }

    #endregion

    #region Build Strategy

    if ($QTDevMode) {
        $QTBaseVer = if ($QTDevMode) { "($(GetRepoCommit qtbase))" } else { $QT_VERSION }
        $QTToolsVer = if ($QTDevMode) { "($(GetRepoCommit qttools))" } else { $QT_VERSION }
        $QTGrpcVer = if ($QTDevMode) { "($(GetRepoCommit qtgrpc))" } else { $QT_VERSION }
    } else {
        $QTBaseVer = $QTToolsVer = <# $QTGrpcVer =  #>$QT_VERSION
    }
    $BUILD_TARGETS = [ordered]@{
        "Yasm $YASM_VERSION"                            = 'BuildYasm', '*', "$DependsPath\bin\yasm.exe"
        "pkgconf $PKGCONF_VERSION"                      = 'BuildPkgConf', '*', "$DependsPath\bin\pkgconf.exe"
        "mimalloc $MIMALLOC_VERSION"                    = 'BuildMimAlloc', 'x(?:86|64)', "$DependsPath\lib\pkgconfig\mimalloc.pc"
        "getopt-win ($(GetRepoCommit getopt-win))"      = 'BuildGetOpt', '*', "$DependsPath\lib\getopt.lib"
        "zlib $ZLIB_VERSION"                            = 'BuildZlib', '*', "$DependsPath\lib\z.lib"
        "OpenSSL $OPENSSL_VERSION"                      = 'BuildOpenSSL', '*', "$DependsPath\lib\pkgconfig\openssl.pc"
        "GMP $GMP_VERSION"                              = 'BuildGmp', '*', "$DependsPath\lib\pkgconfig\gmp.pc"
        "Nettle $NETTLE_VERSION"                        = 'BuildNettle', '*', "$DependsPath\lib\pkgconfig\nettle.pc"
        "GnuTLS $GNUTLS_VERSION"                        = 'BuildGnutls', 'x(?:86|64)', "$DependsPath\lib\pkgconfig\gnutls.pc"
        "libpng $LIBPNG_VERSION"                        = 'BuildLibpng', '*', "$DependsPath\lib\pkgconfig\libpng.pc"
        "libjpeg $LIBJPEG_TURBO_VERSION"                = 'BuildLibjpeg', '*', "$DependsPath\lib\pkgconfig\libjpeg.pc"
        "PCRE2 $PCRE2_VERSION"                          = 'BuildPcre2', '*', "$DependsPath\lib\pkgconfig\libpcre2-16.pc"
        "bzip2 $BZIP2_VERSION"                          = 'BuildBzip2', '*', "$DependsPath\lib\pkgconfig\bzip2.pc"
        "xz $XZ_VERSION"                                = 'BuildXz', '*', "$DependsPath\lib\pkgconfig\liblzma.pc"
        "Brotli $BROTLI_VERSION"                        = 'BuildBrotli', '*', "$DependsPath\lib\pkgconfig\libbrotlicommon.pc"
        "Iconv ($(GetRepoCommit libiconv-for-Windows))" = 'BuildLibiconv', '*', "$DependsPath\lib\libiconv*.lib"
        "Icu4c $ICU4C_VERSION"                          = 'BuildIcu4c', '*', "$DependsPath\lib\pkgconfig\icu-uc.pc"
        "Pixman $PIXMAN_VERSION"                        = 'BuildPixman', '*', "$DependsPath\lib\pkgconfig\pixman-1.pc"
        "Expat $EXPAT_VERSION"                          = 'BuildExpat', '*', "$DependsPath\lib\pkgconfig\expat.pc"
        "Boost $BOOST_VERSION"                          = 'BuildBoost', '*', "$DependsPath\include\boost\config.hpp"
        "Libxml2 $LIBXML2_VERSION"                      = 'BuildLibxml2', '*', "$DependsPath\lib\pkgconfig\libxml-2.0.pc"
        "Nghttp2 $NGHTTP2_VERSION"                      = 'BuildNghttp2', '*', "$DependsPath\lib\pkgconfig\libnghttp2.pc"
        "Libffi ($(GetRepoCommit libffi))"              = 'BuildLibffi', '*', "$DependsPath\lib\pkgconfig\libffi.pc"
        "Libintl ($(GetRepoCommit proxy-libintl))"      = 'BuildLibintl', '*', "$DependsPath\lib\intl.lib"
        "Dlfcn $DLFCN_VERSION"                          = 'BuildDlfcn', '*', "$DependsPath\include\dlfcn.h"
        "Libpsl $LIBPSL_VERSION"                        = 'BuildLibpsl', '*', "$DependsPath\lib\pkgconfig\libpsl.pc"
        "Orc $ORC_VERSION"                              = 'BuildOrc', '*', "$DependsPath\lib\pkgconfig\orc-0.4.pc"
        "Libcurl $CURL_VERSION"                         = 'BuildLibcurl', '*', "$DependsPath\lib\pkgconfig\libcurl.pc"
        "Sqlite $SQLITE3_VERSION"                       = 'BuildSqlite', '*', "$DependsPath\lib\pkgconfig\sqlite3.pc"
        "Glib $GLIB_VERSION"                            = 'BuildGlib', '*', "$DependsPath\lib\pkgconfig\glib-2.0.pc"
        # "Libproxy $LIBPROXY_VERSION"                    = 'BuildLibproxy', '*', "$DependsPath\lib\libproxy.lib" # Doesn't compile with MSVC
        "Libsoup $LIBSOUP_VERSION"                      = 'BuildLibsoup', '*', "$DependsPath\lib\pkgconfig\libsoup-3.0.pc"
        "GlibNetworking $GLIB_NETWORKING_VERSION"       = 'BuildGlibNetworking', '*', "$DependsPath\lib\gio\modules\gioopenssl.lib"
        "Freetype $FREETYPE_VERSION"                    = 'BuildFreetype', '*', "$DependsPath\lib\freetype.lib"
        "Cairo $CAIRO_VERSION"                          = 'BuildCairo', '*', "$DependsPath\lib\pkgconfig\cairo.pc"
        "Harfbuzz $HARFBUZZ_VERSION"                    = 'BuildHarfbuzz', '*', "$DependsPath\lib\harfbuzz*.lib"
        "Libogg $LIBOGG_VERSION"                        = 'BuildLibogg', '*', "$DependsPath\lib\pkgconfig\ogg.pc"
        "Libvorbis $LIBVORBIS_VERSION"                  = 'BuildLibvorbis', '*', "$DependsPath\lib\pkgconfig\vorbis.pc"
        "Flac $FLAC_VERSION"                            = 'BuildFlac', '*', "$DependsPath\lib\pkgconfig\flac.pc"
        "Wavpack $WAVPACK_VERSION"                      = 'BuildWavpack', '*', "$DependsPath\lib\pkgconfig\wavpack.pc"
        "Opus $OPUS_VERSION"                            = 'BuildOpus', '*', "$DependsPath\lib\pkgconfig\opus.pc"
        "Opusfile $OPUSFILE_VERSION"                    = 'BuildOpusfile', '*', "$DependsPath\bin\opusfile.dll"
        "Speex $SPEEX_VERSION"                          = 'BuildSpeex', '*', "$DependsPath\lib\pkgconfig\speex.pc"
        "Libmpg123 $MPG123_VERSION"                     = 'BuildLibmpg123', '*', "$DependsPath\lib\pkgconfig\libmpg123.pc"
        "Mp3lame $LAME_VERSION"                         = 'BuildLame', '*', "$DependsPath\lib\pkgconfig\mp3lame.pc"
        "Twolame $TWOLAME_VERSION"                      = 'BuildTwolame', '*', "$DependsPath\lib\libtwolame_dll.lib"
        "Fftw3 $FFTW_VERSION"                           = 'BuildFftw3', '*', "$DependsPath\lib\pkgconfig\fftw3.pc"
        "Musepack $MUSEPACK_VERSION"                    = 'BuildMusepack', '*', "$DependsPath\lib\pkgconfig\mpcdec.pc"
        "Libopenmpt $LIBOPENMPT_VERSION"                = 'BuildLibopenmpt', '*', "$DependsPath\lib\pkgconfig\libopenmpt.pc"
        "Libgme $LIBGME_VERSION"                        = 'BuildLibgme', '*', "$DependsPath\lib\pkgconfig\libgme.pc"
        "Fdkaac $FDK_AAC_VERSION"                       = 'BuildFdkaac', '*', "$DependsPath\lib\pkgconfig\fdk-aac.pc"
        "Faad2 $FAAD2_VERSION"                          = 'BuildFaad2', '*', "$DependsPath\lib\pkgconfig\faad2.pc"
        "Faac $FAAC_VERSION"                            = 'BuildFaac', '*', "$DependsPath\lib\pkgconfig\faac.pc"
        "Utfcpp $UTFCPP_VERSION"                        = 'BuildUtfcpp', '*', "$DependsPath\include\utf8cpp\utf8.h"
        "Taglib $TAGLIB_VERSION"                        = 'BuildTaglib', '*', "$DependsPath\lib\pkgconfig\taglib.pc"
        "Libbs2b $LIBBS2B_VERSION"                      = 'BuildLibbs2b', '*', "$DependsPath\lib\libbs2b.lib"
        "Libebur128 $LIBEBUR128_VERSION"                = 'BuildLibebur128', '*', "$DependsPath\lib\pkgconfig\libebur128.pc"
        "Ffmpeg $FFMPEG_VERSION"                        = 'BuildFfmpeg', '*', "$DependsPath\lib\avutil.lib"
        "Chromaprint $CHROMAPRINT_VERSION"              = 'BuildChromaprint', '*', "$DependsPath\lib\pkgconfig\libchromaprint.pc"
        "Gstreamer $GSTREAMER_VERSION"                  = 'BuildGstreamer', '*', "$DependsPath\lib\pkgconfig\gstreamer-1.0.pc"
        "Gstpluginsbase $GSTREAMER_VERSION"             = 'BuildGstpluginsbase', '*', "$DependsPath\lib\pkgconfig\gstreamer-plugins-base-1.0.pc"
        "Gstpluginsgood $GSTREAMER_VERSION"             = 'BuildGstpluginsgood', '*', "$DependsPath\lib\gstreamer-1.0\gstdirectsound.lib"
        "Gstpluginsbad $GSTREAMER_VERSION"              = 'BuildGstpluginsbad', '*', "$DependsPath\lib\pkgconfig\gstreamer-plugins-bad-1.0.pc"
        "Gstpluginsugly $GSTREAMER_VERSION"             = 'BuildGstpluginsugly', '*', "$DependsPath\lib\gstreamer-1.0\gstasf.lib"
        "Gstlibav $GSTREAMER_VERSION"                   = 'BuildGstlibav', '*', "$DependsPath\lib\gstreamer-1.0\gstlibav.lib"
        "Gstspotify $GSTREAMER_PLUGINS_RS_VERSION"      = 'BuildGstspotify', 'x64', "$DependsPath\lib\pkgconfig\gstspotify.pc"
        "Abseil $ABSEIL_VERSION"                        = 'BuildAbseil', '*', "$DependsPath\lib\pkgconfig\absl_any.pc"
        "Protobuf $PROTOBUF_VERSION"                    = 'BuildProtobuf', '*', "$DependsPath\lib\pkgconfig\protobuf.pc"
        "Qtbase $QTBaseVer"                             = 'BuildQtbase', '*', "$DependsPath\bin\qt-configure-module.bat"
        "Qttools $QTToolsVer"                           = 'BuildQttools', '*', "$DependsPath\lib\cmake\Qt6Linguist\Qt6LinguistConfig.cmake"
        "Sparsehash $SPARSEHASH_VERSION"                = 'BuildSparsehash', '*', "$DependsPath\lib\pkgconfig\libsparsehash.pc"
        "Rapidjson ($(GetRepoCommit rapidjson))"        = 'BuildRapidjson', '*', "$DependsPath\lib\cmake\RapidJSON\RapidJSONConfig.cmake"
        "Qtgrpc $QTGrpcVer"                             = 'BuildQtgrpc', '*', "$DependsPath\lib\cmake\Qt6\FindWrapProtoc.cmake"
        "Qtsparkle ($(GetRepoCommit qtsparkle))"        = 'BuildQtsparkle', '*', "$DependsPath\lib\cmake\qtsparkle-qt6\qtsparkle-qt6Config.cmake"
        "KDsingleapp $KDSINGLEAPPLICATION_VERSION"      = 'BuildKdsingleapp', '*', "$DependsPath\lib\kdsingleapplication-qt6.lib"
        "Glew $GLEW_VERSION"                            = 'BuildGlew', '*', "$DependsPath\lib\pkgconfig\glew.pc"
        "Libprojectm $LIBPROJECTM_VERSION"              = 'BuildLibprojectm', '*', "$DependsPath\lib\cmake\projectM4\projectM4Config.cmake"
        "Gettext $GETTEXT_VERSION"                      = 'BuildGettext', '*', "$DependsPath\bin\gettext.exe"
        "Tinysvcmdns ($(GetRepoCommit tinysvcmdns))"    = 'BuildTinysvcmdns', '*', "$DependsPath\lib\pkgconfig\tinysvcmdns.pc"
        "Pe-parse $PE_PARSE_VERSION"                    = 'BuildPeParse', '*', "$DependsPath\lib\pe-parse.lib"
        "Pe-util ($(GetRepoCommit pe-util))"            = 'BuildPeUtil', '*', "$DependsPath\bin\peldd.exe"
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
        Write-Host -fo Yellow "Dependencies extracted and retargeted to $DependsPath. Please run the script again to recalculate build steps."
        $OverallSuccess = $true
        return
    }
    if ($DependsPath -ne "C:\$DefaultName" -and -not (Test-Path "C:\$DefaultName")) {
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

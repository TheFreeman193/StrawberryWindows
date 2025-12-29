# 🍓 Windows Builds for Strawberry Music Player

Strawberry is a music player and a music collection organizer.
It is a fork of Clementine originally released in 2018 and aimed at music collectors and audiophiles.
It's written in C++ using the Qt toolkit.

Currently, only Linux binaries are available for free and macOS and Windows users must either subscribe on Patreon or build it from source.
I am therefore building my own release binaries of Strawberry on Windows using Microsoft Visual C++ (MSVC) and making my build configuration and artifacts available here.

I make no guarantees about the functionality of these builds, although I test them on 64-bit Windows 10 & Windows 11 systems before uploading to GitHub to ensure Strawberry starts and can play audio.
I am not currently building for ARM64 as none of my systems run this architecture.

These builds rely on the Microsoft Visual C++ redistributable to run.
This should install automatically when using the NSIS installer.
If it doesn't, or you are extracting from the archive, you can get the latest redistributable from the [Microsoft website](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist#latest-microsoft-visual-c-redistributable-version).

**[Strawberry Project](https://github.com/strawberrymusicplayer/strawberry)**
&nbsp;&bull;&nbsp;
**[Official Strawberry Website](https://www.strawberrymusicplayer.org/)**
&nbsp;&bull;&nbsp;
**[Jonas Kvinge (Strawberry maintainer)](https://github.com/jonaski)**

## Licence

Strawberry's source code is licenced under the [GNU GPLv3](https://github.com/strawberrymusicplayer/strawberry/blob/master/COPYING).

- [Strawberry Source Code](https://github.com/strawberrymusicplayer/strawberry)
- [Strawberry MSVC Build Tools](https://github.com/strawberrymusicplayer/strawberry-msvc)
- [Strawberry MSVC Dependencies & Patches](https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies)

## Build Environment

- Windows 10 Enterprise LTSC 10.0.19044.0 on Hyper-V assigned with:
  - 8c Intel 9th Gen @ 4.8 GHz, 8-64 GB dynamically allocated RAM @ 3600 MT/s
  - 64 GB boot disk, 32 GB RAM disk for staging/build targets
- PowerShell 7.5.4
- Visual Studio 2022 Community 17.14.23
  - C++ core module
  - MSVC v143
  - C++ ATL for MSVC v143
  - JIT debugger
  - C++ profiling tools
  - C++ CMake tools for Win64
  - C++ AddressSanitizer
  - Windows 11 SDK 10.0.22621.7
  - vcpkg manager
- Git for Windows 2.52.0
- Qt 6 build tools for VS2022
- CMake 4.2.1
- Meson Build 1.10.0
- NASM 3.01
- Strawberry Perl 5.42.0
- Python 3.14.0b1
- 7-Zip 25.01
- WinFlex 2.6.4
- WinBison 3.7.4
- Rust Compiler 1.92.0
- NSIS 3.11
  - LockedList Plugin (DigitalMediaServer fork) 3.1.0.0
  - Registry Plugin 4.2
  - Internet Client Plugin (DigitalMediaServer fork) 1.0.5.7

## Code Changes and Build Scripts

The build scripts are derived from the [download.bat](https://github.com/strawberrymusicplayer/strawberry-msvc/blob/master/download.bat) and [build.bat](https://github.com/strawberrymusicplayer/strawberry-msvc/blob/master/build.bat) scripts in the [strawberry-msvc](https://github.com/strawberrymusicplayer/strawberry-msvc) repository, as well as the [build workflow](https://github.com/strawberrymusicplayer/strawberry/blob/master/.github/workflows/build.yml) from the main repository.

These scripts apply the same patches to the Strawberry dependencies as found in the [strawberry-msvc-dependencies](https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/) repo, plus a few tweaks here and there to make sure they compile in my build environment.

No changes are made to the [Strawberry source code](https://github.com/strawberrymusicplayer/strawberry) with the exception of adding a static cast to `gsize` in the [gstfastspectrum.cpp](https://github.com/strawberrymusicplayer/strawberry/blame/d901258f11431a2acade70b25dee365a0f4024d5/src/engine/gstfastspectrum.cpp#L472) file to permit strict building (`BUILD_WERROR=ON`) on x86 builds.
You can view the patch in the [build script](https://github.com/TheFreeman193/StrawberryWindows/blob/main/Build-Strawberry.ps1?plain=1) by searching for 'gstfastspectrum.cpp'.

Each dependency and Strawberry itself are compiled in a separate function in the build script, with the build strategy defined near the end (search for '#region Build Strategy').

### Get-Versions.ps1

This downloads and merges the dependency versions from the [versions.bat](https://github.com/strawberrymusicplayer/strawberry-msvc/blob/master/versions.bat) and [build workflow](https://github.com/strawberrymusicplayer/strawberry/blob/master/.github/workflows/build.yml) files to create an up-to-date dependency mapping in plain text.
This is read by the dependency collector and build scripts to download and compile the correct versions.

The [version file](https://github.com/TheFreeman193/StrawberryWindows/blob/main/Versions.txt) used in the latest "nightly" build is kept in the repository for your reference.

### Get-Dependencies.ps1

This script is derived from the [download.bat](https://github.com/strawberrymusicplayer/strawberry-msvc/blob/master/download.bat) script and retrieves the dependency versions as specified in a version file (see Get-Versions.ps1).
In addition, it can perform cleanup of old/non-dependency files in the target directory and verifies the integrity of downloaded dependency archives (where hashes are present for that version).
It supports syncing specific commits or branch heads of the Git-based dependencies for version-pinning.

### Build-Strawberry.ps1

This is the main build script and consists primarily of individual functions for building each dependency, and then Strawberry itself.
It uses an ordered dictionary to call each build function in a loop until all dependencies are satisfied, before building Strawberry.

### Copy-DebugDependencies.ps1

This script is for use with debug builds.
It copies the debug MSVC libraries from Visual Studio 2022 into the Strawberry debug installation directory, in case you are debugging Strawberry on a different computer without VS2022.

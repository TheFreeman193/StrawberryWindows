# 🍓 Windows Builds for Strawberry Music Player

Strawberry is a music player and a music collection organizer.
It is a fork of Clementine originally released in 2018 and aimed at music collectors and audiophiles.
It's written in C++ using the Qt toolkit.

Currently, only Linux binaries are available for free and macOS and Windows users must either subscribe on Patreon or build it from source.
I am therefore building my own binaries of Strawberry on Windows using Microsoft Visual C++ (MSVC) and making my build configuration and artifacts available here.

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
- [Strawberry MSVC Build Tools](https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools)
- [Strawberry MSVC Dependencies & Patches](https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies)

## Build Environment

- Windows 10 Enterprise LTSC 10.0.19044.0 on Hyper-V assigned with:
  - 8c Intel 9th Gen @ 4.8 GHz, 8-64 GB dynamically allocated RAM @ 3600 MT/s
  - 64 GB boot disk, 32 GB RAM disk for staging/build targets
- PowerShell 7.5.4
- Visual Studio 2022 Community 17.14.25
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
- CMake 4.2.3
- Meson Build 1.10.1
- Ninja 1.13.0
- NASM 3.01
- Strawberry Perl 5.42.0
- Python 3.14.2
- 7-Zip 25.01
- WinFlex 2.6.4
- WinBison 3.7.4
- Rust Compiler 1.93.0
- NSIS 3.11
  - LockedList Plugin (DigitalMediaServer fork) 3.1.0.0
  - Registry Plugin 4.2
  - Internet Client Plugin (DigitalMediaServer fork) 1.0.5.7

## Releases

- The nightly builds in the [Releases](https://github.com/TheFreeman193/StrawberryWindows/releases/) section are built with the precompiled dependencies from [strawberry-msvc-dependencies][deps-releases].

- The release builds use dependencies built from source; the build functions for these are in [Build-Strawberry.ps1][build-script].

## Code Changes and Build Scripts

The build scripts are derived from the original [download.bat][download-bat] and [build.bat](https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools/blob/06b445396f95c780c8af6047aa02f4f1335db39e/build.bat) scripts in the [strawberry-msvc-build-tools](https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools) repository (these have now moved to PowerShell 🎉), as well as the [build workflow](https://github.com/strawberrymusicplayer/strawberry/blob/master/.github/workflows/build.yml) from the main repository.

These scripts apply the same patches to the Strawberry dependencies as found in the [strawberry-msvc-dependencies][deps-releases] repo, plus a few tweaks here and there to make sure they compile in my build environment.

No changes are made to the [Strawberry source code](https://github.com/strawberrymusicplayer/strawberry).

Each dependency and Strawberry itself are compiled in a separate function in the [build script][build-script], with the build strategy defined near the end (search for '#region Build Strategy').

### Get-Versions.ps1

This downloads and merges the dependency versions from the [StrawberryPackageVersions.txt](https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools/blob/master/StrawberryPackageVersions.txt) and [build workflow](https://github.com/strawberrymusicplayer/strawberry/blob/master/.github/workflows/build.yml) files to create an up-to-date dependency mapping in plain text.
This is read by the dependency collector and build scripts to download and compile the correct versions.

The [version file](https://github.com/TheFreeman193/StrawberryWindows/blob/main/Versions.txt) used in the latest "nightly" build is kept in the repository for your reference.

### Get-Dependencies.ps1

This script is derived from the [download.bat][download-bat] script and retrieves the dependency versions as specified in a version file (see Get-Versions.ps1).
In addition, it can perform cleanup of old/non-dependency files in the target directory and verifies the integrity of downloaded dependency archives (where hashes or digital signatures are present for that version).
It supports syncing specific commits or branch heads of the Git-based dependencies for version-pinning.

If you pass `-FromScratch` to the script, all needed dependency sources are downloaded so they can be built from scratch.
Otherwise, only additional dependencies and build tools are downloaded, plus the precompiled dependencies from [strawberry-msvc-dependencies][deps-releases].

### Build-Strawberry.ps1

This is the main build script and consists primarily of individual functions for building each dependency, and then Strawberry itself.
It uses an ordered dictionary to call each build function in a loop until all dependencies are satisfied, before building Strawberry.

If you downloaded the precompiled dependencies by calling Get-Dependencies.ps1 without the `-FromScratch` switch, you can call this script without `-FromScratch` to use these and just build Strawberry.

### Copy-DebugDependencies.ps1

This script is for use with debug builds.
It copies the debug MSVC libraries from Visual Studio 2022 into the Strawberry debug installation directory, in case you are debugging Strawberry on a different computer without VS2022.

[deps-releases]: https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/releases
[build-script]: https://github.com/TheFreeman193/StrawberryWindows/blob/main/Versions.txt
[download-bat]: https://github.com/strawberrymusicplayer/strawberry-msvc-build-tools/blob/06b445396f95c780c8af6047aa02f4f1335db39e/download.bat

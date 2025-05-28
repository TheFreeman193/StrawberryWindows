# 🍓 Windows Builds for Strawberry Music Player

Strawberry is a music player and a music collection organizer. It is a fork of Clementine originally released in 2018 and aimed at music collectors and audiophiles. It's written in C++ using the Qt toolkit.

Currently, only Linux binaries are available for free and macOS and Windows users must either subscribe on Patreon or build it from source.
I am therefore building my own release binaries of Strawberry on Windows using Microsoft Visual C++ (MSVC) and making my build configuration and artifacts available here.

I make no guarantees about the functionality of these builds, although I test them on 64-bit Windows 10 & Windows 11 systems before uploading to GitHub to ensure Strawberry starts and can play audio. I am not currently building for x86 or ARM64 as none of my systems run these architectures.

These builds rely on the Microsoft Visual C++ redistributable to run. This should install automatically when using the NSIS installer. If it doesn't, or you are extracting from the archive, you can get the latest redistributable from the [Microsoft website](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist#latest-microsoft-visual-c-redistributable-version).

**[Strawberry Project](https://github.com/strawberrymusicplayer/strawberry)**
&nbsp;&bull;&nbsp;
**[Official Strawberry Website](https://www.strawberrymusicplayer.org/)**
&nbsp;&bull;&nbsp;
**[Jonas Kvinge (Strawberry maintainer)](https://github.com/jonaski)**

## Licence

Strawberry's source code is licenced under the [GNU GPLv3](https://github.com/strawberrymusicplayer/strawberry/blob/master/COPYING).

- [Strawberry Source Code](https://github.com/strawberrymusicplayer/strawberry)
- [Strawberry MSVC Build Tools](https://github.com/strawberrymusicplayer/strawberry-msvc)
- [Strawberry MSVC Dependency Patches](https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies)

## Build Environment

- Windows 10 Enterprise LTSC on Hyper-V assigned with:
  - 8c Intel 9th Gen @ 4.8 GHz, 8-64 GB dynamically allocated RAM @ 3600 MT/s
  - 64 GB boot disk, 32 GB RAM disk for staging/build targets
- PowerShell 7.4 LTS
- Visual Studio 2022 Community
  - C++ core module
  - MSVC v143
  - C++ ATL for MSVC v143
  - JIT debugger
  - C++ profiling tools
  - C++ CMake tools for Win64
  - C++ AddressSanitizer
  - Windows 11 SDK 10.0.26100.3916
  - vcpkg manager
- Git for Windows 2.49.0
- Qt 6 build tools for VS2022
- CMake 4.0.2
- Meson Build 1.8.1
- NASM 2.16.03
- Strawberry Perl 5.40.2.1
- Python 3.14.0b1
- 7-Zip 24.09
- WinFlex 2.6.4
- WinBison 3.7.4
- Rust Compiler 1.87.0
- NSIS 3.11
  - LockedList Plugin 3.0.0.4
  - Registry Plugin 4.2
  - Internet Client Plugin (DigitalMediaServer fork) 1.0.5.7

## Code Changes

I make no changes to the Strawberry source code. Changes to the build configuration for building on a RAM disk are:

- [strawberry-msvc](https://github.com/strawberrymusicplayer/strawberry-msvc)/build.bat:

    ```diff
    @@ -13,9 +13,10 @@

    @if /I "%BUILD_TYPE%" == "debug" set LIB_POSTFIX=d

    -@set DOWNLOADS_PATH=c:\data\projects\strawberry\msvc_\downloads
    -@set BUILD_PATH=c:\data\projects\strawberry\msvc_\build_%BUILD_TYPE%
    -@set PREFIX_PATH=c:\strawberry_msvc_x86_64_%BUILD_TYPE%
    +@r: || goto end
    +@set DOWNLOADS_PATH=r:\msvc_\downloads
    +@set BUILD_PATH=r:\msvc_\build_%BUILD_TYPE%
    +@set PREFIX_PATH=r:\c%BUILD_TYPE%
    @set PREFIX_PATH_FORWARD=%PREFIX_PATH:\=/%
    @set PREFIX_PATH_ESCAPE=%PREFIX_PATH:\=\\%
    @set QT_DEV=OFF
    ```

- [strawberry-msvc](https://github.com/strawberrymusicplayer/strawberry-msvc)/download.bat:

    ```diff
    @@ -2,13 +2,13 @@

    @setlocal

    -@set DOWNLOADS_PATH="c:\data\projects\strawberry\msvc_\downloads"
    +@set DOWNLOADS_PATH="r:\msvc_\downloads"

    @call versions.bat

    :setup

    -@c: || goto end
    +@r: || goto end
    @cd \ || goto end
    @if not exist  "%DOWNLOADS_PATH%" mkdir "%DOWNLOADS_PATH%"
    @cd "%DOWNLOADS_PATH%" || goto end
    ```

- [strawberry-msvc](https://github.com/strawberrymusicplayer/strawberry-msvc)/install.bat:

    ```diff
    @@ -2,10 +2,11 @@

    @setlocal

    -@set DOWNLOADS_PATH=c:\data\projects\strawberry\msvc_\downloads
    +@set DOWNLOADS_PATH=r:\msvc_\downloads

    @call versions.bat

    +@r: || goto end

    :install
    ```

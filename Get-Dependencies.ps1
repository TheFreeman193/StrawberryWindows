# Copyright 2026 Nicholas Bissell (TheFreeman193)
# SPDX-License-Identifier: GPL-3.0-or-later

using namespace System.Management.Automation
using namespace System.Collections.Generic
using namespace System.IO

[CmdletBinding()]
param(
    [string]$DownloadPath = 'S:\downloads',
    [string]$VersionFile = "$PSScriptRoot\Versions.txt",
    [switch]$WarnNotVerified,
    [switch]$Cleanup,
    [switch]$QTDevMode,
    [switch]$GStreamerDevMode,
    [switch]$FromScratch
)

begin {
    $OldInfoPref = $InformationPreference
    $InformationPreference = 'Continue'

    #region Version Data

    # Additional version data
    $SQLITE_YEAR = '2026'
    $ICONV_DEFAULT_VERSION = '1.17'
    $NSISLOCKEDLIST_VERSION = '3.1.0.0'
    $NSISLOCKEDLISTOLD_VERSION = 'd/d3'
    $NSISREGISTRY_VERSION = '4/47'
    $NSISINETC_VERSION = '1.0.5.7'
    $NSISINETCOLD_VERSION = 'c/c9'
    $MSVC_VERSION = '17'
    $QT_DEV_BRANCH = 'dev'
    $LIBICONV_BRANCH = 'master'
    $QTSPARKLE_BRANCH = 'master'
    $LIBFFI_BRANCH = 'meson'
    # $LIBINTL_BRANCH = 'master'
    $GSTREAMER_BRANCH = 'main'
    $GSTSPOTIFY_BRANCH = 'main'
    $GETOPT_BRANCH = 'getopt_glibc_2.42_port'
    $TINYSVCMDNS_BRANCH = 'master'
    $RAPIDJSON_BRANCH = 'master'
    $GMP_BRANCH = 'master'
    $NETTLE_BRANCH = 'master'
    $GNUTLS_BRANCH = 'master'
    $PEUTIL_BRANCH = 'master'
    $STRAWBERRY_REPO_BRANCH = 'master'

    if (-not (Test-Path $VersionFile)) {
        $VersionScript = Get-Item (Join-Path $PSScriptRoot 'Get-Versions.ps1')
        if (-not $?) { return }
        & $VersionScript
        if (-not $? -or -not (Test-Path $VersionFile)) { return }
    }

    $CurlCmd = Get-Command -CommandType Application curl -ErrorAction Ignore | Where-Object Path -Like 'C:\Windows\*' | Select-Object -ExpandProperty Path

    $VersionBase = Get-Content $VersionFile -Raw | ConvertFrom-StringData
    foreach ($Name in $VersionBase.Keys) {
        New-Variable -Name $Name -Value $VersionBase[$Name] -Force -Scope Script
        New-Variable -Name "${Name}_UNDERSCORE" -Value ($VersionBase[$Name] -creplace '\.', '_') -Force -Scope Script
        New-Variable -Name "${Name}_DASH" -Value ($VersionBase[$Name] -creplace '\.', '-') -Force -Scope Script
        New-Variable -Name "${Name}_STRIPPED" -Value ($VersionBase[$Name] -creplace '\.') -Force -Scope Script
    }

    if ([string]::IsNullOrWhiteSpace($ICONV_VERSION)) {
        $ICONV_VERSION = $ICONV_DEFAULT_VERSION
    }

    #endregion
    #region File Hashes
    $FILE_HASHES = ConvertFrom-StringData @'
7z2501-x64.exe                         = 78afa2a1c773caf3cf7edf62f857d2a8a5da55fb0fff5da416074c0d28b2b55f
abseil-cpp-20260107.0.tar.gz           = 4c124408da902be896a2f368042729655709db5e3004ec99f57e3e14439bc1b2
boost_1_90_0.tar.gz                    = 5e93d582aff26868d581a52ae78c7d8edf3f3064742c6e77901a1f18a437eea9
brotli-1.2.0.tar.gz                    = 816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec
bzip2-1.0.8.tar.gz                     = ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269
cairo-1.18.0.tar.xz                    = 243a0736b978a33dee29f9cca7521733b78a65b5418206fef7bd1c3d4cf10b64
ccache-4.11.3.tar.gz                   = 28a407314f03a7bd7a008038dbaffa83448bc670e2fc119609b1d99fb33bb600
chromaprint-1.6.0.tar.gz               = 9d33482e56a1389a37a0d6742c376139fa43e3b8a63d29003222b93db2cb40da
cmake-4.1.0-windows-x86_64.msi         = 10664a3a59daa9ee47bc04d183b16cafe91235310e728ee3d0c9ba418f0a7bd7
curl-8.11.0.tar.gz                     = 264537d90e58d2b09dddc50944baf3c38e7089151c8986715e2aaeaaf2b8118f
dlfcn-win32-1.4.2.tar.gz               = f61a874bc9163ab488accb364fd681d109870c86e8071f4710cbcdcbaf9f2565
expat-2.7.4.tar.bz2                    = e6af11b01e32e5ef64906a5cca8809eabc4beb7ff2f9a0e6aabbd42e825135d0
faac-1.31.1.tar.gz                     = 3191bf1b131f1213221ed86f65c2dfabf22d41f6b3771e7e65b6d29478433527
faad2-2.11.2.tar.gz                    = 5ecf60648c26df34308d40e7f78e70fc6ca0e4d7c24815d99da87ca82bbec6f4
fdk-aac-2.0.3.tar.gz                   = 829b6b89eef382409cda6857fd82af84fabb63417b08ede9ea7a553f811cb79e
fftw-3.3.10-x86-release.zip            = a5f1f5c3493c33737c118eb8e6ee21d03d27cc3dee4a4ead59d070aa4cefd04b
flac-1.5.0.tar.xz                      = f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920
freetype-2.14.1.tar.gz                 = 174d9e53402e1bf9ec7277e22ec199ba3e55a6be2c0740cb18c0ee9850fc8c34
Git-2.50.1-64-bit.exe                  = 47fe1d46dbb7111f6693b04a8bd95fc869ce2062df7b4822b52849548fb457e4
glew-2.3.1.tgz                         = b64790f94b926acd7e8f84c5d6000a86cb43967bd1e688b03089079799c9e889
glib-2.87.2.tar.xz                     = d6eb74a4f4ffc0b56df79ae3a939463b1d92c623f6c167d51aab24e303a851f3
glib-networking-2.80.1.tar.xz          = b80e2874157cd55071f1b6710fa0b911d5ac5de106a9ee2a4c9c7bee61782f8e
gst-libav-1.28.0.tar.xz                = e3c93db7da2da3b2374ccc2e7394316f9192460abdea81651652791d46ccb8fb
gst-plugins-bad-1.28.0.tar.xz          = 32d825041e5775fc9bf9e8c38e3a5c46c1441eee67f8112572450a9c23c835f0
gst-plugins-base-1.28.0.tar.xz         = eace79d63bd2edeb2048777ea9f432d8b6e7336e656cbc20da450f6235758b31
gst-plugins-good-1.28.0.tar.xz         = d97700f346fdf9ef5461c035e23ed1ce916ca7a31d6ddad987f774774361db77
gst-plugins-ugly-1.28.0.tar.xz         = 743f28b93c941e0af385ab193a2150f9f79bc6269adc639f6475d984794c217c
gstreamer-1.28.0.tar.xz                = 6c8676bc39a2b41084fd4b21d2c37985c69ac979c03ce59575db945a3a623afd
harfbuzz-12.3.2.tar.xz                 = 6f6db164359a2da5a84ef826615b448b33e6306067ad829d85d5b0bf936f1bb8
icu4c-78.2-sources.zip                 = af38c3d4904e47e1bc2dd7587922ee2aec312fefa677804582e3fecca3edb272
InetC.zip                              = b01077e56ebb19c005b45d40f837958ca6a92f51a5a937dc1bb497c7c7f2aa93
jasper-4.2.8.tar.gz                    = 98058a94fbff57ec6e31dcaec37290589de0ba6f47c966f92654681a56c71fae
kdsingleapplication-1.2.0.tar.gz       = ff4ae6a4620beed1cdb3e6a9b78a17d7d1dae7139c3d4746d4856b7547d42c38
lame-3.100.tar.gz                      = ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
libbs2b-3.1.0.tar.bz2                  = 4799974becdeeedf0db00115bc63f60ea3fe4b25f1dfdb6903505839a720e46f
libebur128-1.2.6.tar.gz                = baa7fc293a3d4651e244d8022ad03ab797ca3c2ad8442c43199afe8059faa613
libgme-0.6.4-src.tar.gz                = 6f94eac735d86bca998a7ce1170d007995191ef6d4388345a0dc5ffa1de0bafa
libgnutls_3.8.8_msvc17.zip             = 73abaa5d049e106c2a613d752df228f16588eead3a4e4fd47aa9135f67e562b0
libjpeg-turbo-3.1.3.tar.gz             = 075920b826834ac4ddf97661cc73491047855859affd671d52079c6867c1c6c0
libogg-1.3.6.tar.gz                    = 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638
libopenmpt-0.8.4+release.msvc.zip      = c9204e2cf490b73633b274c6bfa72f09c347e699d3cf9ba959ae1a25b8229bf7
libpng-1.6.54.tar.gz                   = 472db714567391842e410090df5a37e0f5b2ec67148a3007678b0482d2ba5219
libprojectm-4.1.6.tar.gz               = 1b9e6d56c59fe24e5416da4d42e941a34c982811003e43ac88b5aca8afa52c87
libproxy-0.5.9.tar.gz                  = a1976c3ac4affedc17e6d40cf78c9d8eca6751520ea3cbbec1a8850f7ded1565
libpsl-0.21.5.tar.gz                   = 1dcc9ceae8b128f3c0b3f654decd0e1e891afc6ff81098f227ef260449dae208
libsoup-3.6.5.tar.xz                   = 6891765aac3e949017945c3eaebd8cc8216df772456dc9f460976fbdb7ada234
libvorbis-1.3.7.tar.gz                 = 0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab
libwebp-1.6.0.tar.gz                   = e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
libxml2-v2.15.1.tar.bz2                = d0e8dfcc349eb967496f601a881d5b5ee2dcc9202f4748fa381cf926ebee4f92
LockedList.3.1.0.0.zip                 = 2ad420f6481248b5de71ccde8dd2b6d1f51534ba7abc30c1d477d5cca8a5fc30
mimalloc-2.1.2.tar.gz                  = 2b1bff6f717f9725c70bf8d79e4786da13de8a270059e4ba0bdd262ae7be46eb
mpg123-1.33.4.tar.bz2                  = 3ae8c9ff80a97bfc0e22e89fbcd74687eca4fc1db315b12607f27f01cb5a47d9
musepack_src_r475.tar.gz               = a4b1742f997f83e1056142d556a8c20845ba764b70365ff9ccf2e3f81c427b2b
nasm-3.01-installer-x64.exe            = 7881e9febc8b6558581041019b7890f109bef0694d93ed82c9589794c7b5a600
nghttp2-1.68.0.tar.bz2                 = 8d80cb4e45adca546a2005b86251ba5a7b63f5ea322228ae28e9969743f99707
nsis-3.10-setup.exe                    = 4313d352e0dafd1f22b6517126a655cae3b444fa758d2845eddfbe72f24f7bdd
openssl-3.6.1.tar.gz                   = b1bfedcd5b289ff22aee87c9d600f515767ebf45f77168cb6d64f231f518a82e
opus-1.5.2.tar.gz                      = 65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
opusfile-0.12.tar.gz                   = 118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b
orc-0.4.41.tar.xz                      = cb1bfd4f655289cd39bc04642d597be9de5427623f0861c1fc19c08d98467fa2
orc-0.4.42.tar.xz                      = 7ec912ab59af3cc97874c456a56a8ae1eec520c385ec447e8a102b2bd122c90c
pcre2-10.47.tar.bz2                    = 47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7
pe-parse-2.1.1.tar.gz                  = 74c4012274e6e15128a8cf4453f63bb11155bcc14ad56ca7594a259ae8ae0202
pixman-0.46.4.tar.gz                   = d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c
pkg-config-0.29.2.tar.gz               = 6fc69c01688c9458a57eb9a1664c9aba372ccda420a02bf4429fe610e7e7d591
pkgconf-2.5.1.tar.gz                   = 79721badcad1987dead9c3609eb4877ab9b58821c06bdacb824f2c8897c11f2a
protobuf-33.4.tar.gz                   = bc670a4e34992c175137ddda24e76562bb928f849d712a0e3c2fb2e19249bea1
proxy-libintl-0.5.tar.gz               = f7a1cbd7579baaf575c66f9d99fb6295e9b0684a28b095967cfda17857595303
python-3.13.3-amd64.exe                = 698f2df46e1a3dd92f393458eea77bd94ef5ff21f0d5bf5cf676f3d28a9b4b6c
qtbase-everywhere-src-6.10.2.tar.xz    = aeb78d29291a2b5fd53cb55950f8f5065b4978c25fb1d77f627d695ab9adf21e
qtgrpc-everywhere-src-6.10.2.tar.xz    = 7386bfc9c10c7920e5ff22dcf067e95f379bb379e4d916269f4465ab295ed136
qtimageformats-everywhere-src-6.10.2.tar.xz = 8b8f9c718638081e7b3c000e7f31910140b1202a98e98df5d1b496fe6f639d67
qttools-everywhere-src-6.10.2.tar.xz   = 1e3d2c07c1fd76d2425c6eaeeaa62ffaff5f79210c4e1a5bc2a6a9db668d5b24
rapidjson-1.1.0.tar.gz                 = bf7ced29704a1e696fbccf2a2b4ea068e7774fa37f6d7dd4039d0787f8bed98e
Registry.zip                           = 791451f1be34ea1ed6f2ad6d205cf8e54bb0562af11b0160a6bfa5f499624094
rustup-init.exe                        = 88d8258dcf6ae4f7a80c7d1088e1f36fa7025a1cfd1343731b4ee6f385121fc0
sed.exe                                = 4aa7a40b3a0e38e1c56f066d722f8a0c0dd99e6e2842a5d0c57c4f336d80589d
sparsehash-2.0.4.tar.gz                = 8cd1a95827dfd8270927894eb77f62b4087735cbede953884647f16c521c7e58
speex-Speex-1.2.1.tar.gz               = beaf2642e81a822eaade4d9ebf92e1678f301abfc74a29159c4e721ee70fdce0
sqlite-autoconf-3510200.tar.gz         = fbd89f866b1403bb66a143065440089dd76100f2238314d92274a082d4f2b7bb
strawberry-perl-5.40.2.1-64bit.msi     = fdb810474472a769d6a1327a36d0f0a4843d5b1eac3a503428d4d86a1836e222
taglib-2.1.1.tar.gz                    = 3716d31f7c83cbf17b67c8cf44dd82b2a2f17e6780472287a16823e70305ddba
tiff-4.7.1.tar.gz                      = f698d94f3103da8ca7438d84e0344e453fe0ba3b7486e04c5bf7a9a3fabe9b69
twolame-0.4.0.tar.gz                   = cc35424f6019a88c6f52570b63e1baf50f62963a3eac52a03a800bb070d7c87d
utfcpp-4.0.9.tar.gz                    = 397a9a2a6ed5238f854f490b0177b840abc6b62571ec3e07baa0bb94d3f14d5a
VSYASM.zip                             = ec99229ba3ea6f0a0db3c15647266588db3c605301ff3b78bbf427d6657277d5
wavpack-5.9.0.tar.bz2                  = b0038f515d322042aaa6bd352d437729c6f5f904363cc85bbc9b0d8bd4a81927
win_flex_bison-2.5.25.zip              = 8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135
xz-5.8.2.tar.gz                        = ce09c50a5962786b83e5da389c90dd2c15ecd0980a258dd01f70f9e7ce58a8f1
yasm-1.3.0.tar.gz                      = 3dce6601b495f5b3d45b59f7d2492a340ee7e84b5beca17e48f862502bd5603f
zlib-1.3.1.tar.gz                      = 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
bzip2-cmake.patch                      = c6089dcebc75789dd84c2edd6b36fe9cb40fbfcf9c4fd35d1a61204b00e3da8c
faac-msvc.patch                        = 96f53f6411ac621768669d7eb3cd8d94767be4eba4d1b6f209f20f6fb919e9a5
fftw-fixes.patch                       = 4ebdcd7ce363759cc108ec3674da6ae39f7e542f0b14e5f4f329edb8a6877810
libbs2b-msvc.patch                     = 9feb9cc77217d4e9db3690fa3baeec33c4032d5a62a313967f8913d046daca93
libgme-pkgconf.patch                   = 4b5617e0cf302f5ee3b6df88fceba38b2be9a7a42f256c117522dc9f5f896363
libopenmpt-cmake.patch                 = 0b56721a294ab27868246cab7149817edc6a5d82499ff16a9f198bc53a4654eb
libpng-pkgconf.patch                   = 1aeb0c95f012d226ccfa5bb1d621540f9ec113f53ff8d03dd5b5366c9568d645
musepack-fixes.patch                   = 35d789ee87ea41731495698cf13b7525087c335a158e09a075f8158709fe8735
opusfile-cmake.patch                   = a9ee0f8ad67e6982fc17025f77a12912af378c55c0c9a5edfda5ffd5b89b045f
qtbase-qwindowswindow.patch            = 8f4863e7c5c10b503ea405e4eeec47bb8995461c70af37949114a967d3be7aa0
sparsehash-msvc.patch                  = 138f6567120e233329f26a1ee2485b57460395629549c1eed114bfc210b52386
speex-cmake.patch                      = 87e17e7f57660bf884bdf106bbf32972a96bbf4131b2014483f9e14779af9fa1
twolame.patch                          = ad0bf19387e842ce6070a7a812a80237b16591441f6b822909722d3870a01c88
yasm-cmake.patch                       = a0c6f4becb5314dbfcf3f845e143bbaf80c216a76612f5e6cb968d3ee1a795b8
strawberry-msvc-x86_64-debug.tar.xz    = 4edd3ebbeefb8bff7a53d74190028ec3bbf03a79ab573f064f55578aeb367d12
strawberry-msvc-x86_64-release.tar.xz  = 530daa7994876fbe1b6208823f4fce26af5ba1d68e7c2ed95f9933c595ab5cd7
strawberry-msvc-x86-debug.tar.xz       = dcb75aa31ee3ab74d02d5581cdf1eae4da419e7ad114f10b7d132bcb74c4d235
strawberry-msvc-x86-release.tar.xz     = 2a11e110a92d8f2335a8f640b48d7fb1a2b2d96c9029f87b68247a7b54741c4c
'@

    $SIGNED_FILES = @'
cmake-*-windows-x86_64.msi
Git-*-64-bit.exe
python-*-amd64.exe
vc_redist.x64.exe
vc_redist.x86.exe
'@ -split '\r?\n'
    #endregion
    #region Files to Download

    $BaseTargets = @"
https://github.com/projectM-visualizer/projectm/releases/download/v${LIBPROJECTM_VERSION}/libprojectm-${LIBPROJECTM_VERSION}.tar.gz
# https://downloads.sourceforge.net/project/glew/glew/${GLEW_VERSION}/glew-${GLEW_VERSION}.tgz
# https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protobuf-${PROTOBUF_VERSION}.tar.gz
https://github.com/abseil/abseil-cpp/archive/refs/tags/${ABSEIL_VERSION}/abseil-cpp-${ABSEIL_VERSION}.tar.gz
https://github.com/curl/curl/releases/download/curl-${CURL_VERSION_UNDERSCORE}/curl-${CURL_VERSION}.tar.gz
# https://github.com/microsoft/mimalloc/archive/refs/tags/v${MIMALLOC_VERSION}/mimalloc-${MIMALLOC_VERSION}.tar.gz
https://github.com/git-for-windows/git/releases/download/v${GIT_VERSION}.windows.1/Git-${GIT_VERSION}-64-bit.exe
https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-windows-x86_64.msi
https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/win64/nasm-${NASM_VERSION}-installer-x64.exe
http://www.tortall.net/projects/yasm/releases/yasm-${YASM_VERSION}.tar.gz
https://github.com/lexxmark/winflexbison/releases/download/v${WIN_FLEX_BISON_VERSION}/win_flex_bison-${WIN_FLEX_BISON_VERSION}.zip
https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_${STRAWBERRY_PERL_VERSION_STRIPPED}_64bit_UCRT/strawberry-perl-${STRAWBERRY_PERL_VERSION}-64bit.msi
https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-amd64.exe
https://7-zip.org/a/7z${7ZIP_VERSION}-x64.exe
https://prdownloads.sourceforge.net/nsis/nsis-${NSIS_VERSION}-setup.exe
# https://nsis.sourceforge.io/mediawiki/images/${NSISLOCKEDLISTOLD_VERSION}/LockedList.zip
https://github.com/DigitalMediaServer/LockedList/releases/download/v${NSISLOCKEDLIST_VERSION}/LockedList.${NSISLOCKEDLIST_VERSION}.zip
https://nsis.sourceforge.io/mediawiki/images/${NSISREGISTRY_VERSION}/Registry.zip
# https://nsis.sourceforge.io/mediawiki/images/${NSISINETCOLD_VERSION}/Inetc.zip
https://github.com/DigitalMediaServer/NSIS-INetC-plugin/releases/download/v${NSISINETC_VERSION}/InetC.zip
# https://files.jkvinge.net/winbins/sed.exe
https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe
https://aka.ms/vs/${MSVC_VERSION}/release/vc_redist.x86.exe
https://aka.ms/vs/${MSVC_VERSION}/release/vc_redist.x64.exe
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/bzip2-cmake.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/faac-msvc.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/fftw-fixes.patch
# https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/getopt-win-cmake.patch
# https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/gst-plugins-bad-meson-dependency.patch
# https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/gst-plugins-bad-wasapi2.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/libbs2b-msvc.patch
# https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/libbs2b-clipping.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/libgme-pkgconf.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/libopenmpt-cmake.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/libpng-pkgconf.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/musepack-fixes.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/opusfile-cmake.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/qtbase-qwindowswindow.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/sparsehash-msvc.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/speex-cmake.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/twolame.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/yasm-cmake.patch
https://github.com/ShiftMediaProject/VSYASM/releases/download/1.0/VSYASM.zip
https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/ccache-${CCACHE_VERSION}.tar.gz
"@
    $FromScratchTargets = @"
https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_VERSION_UNDERSCORE}.tar.gz
https://pkgconfig.freedesktop.org/releases/pkg-config-${PKG_CONFIG_VERSION}.tar.gz
https://github.com/pkgconf/pkgconf/archive/refs/tags/pkgconf-${PKGCONF_VERSION}.tar.gz
https://github.com/microsoft/mimalloc/archive/refs/tags/v${MIMALLOC_VERSION}/mimalloc-${MIMALLOC_VERSION}.tar.gz
https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz
https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz
https://github.com/ShiftMediaProject/gnutls/releases/download/${GNUTLS_VERSION}/libgnutls_${GNUTLS_VERSION}_msvc17.zip
https://downloads.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.gz
https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_VERSION}/libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz
https://github.com/PhilipHazel/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.bz2
https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz
https://downloads.sourceforge.net/project/lzmautils/xz-${XZ_VERSION}.tar.gz
https://github.com/google/brotli/archive/refs/tags/v${BROTLI_VERSION}/brotli-${BROTLI_VERSION}.tar.gz
https://www.cairographics.org/releases/pixman-${PIXMAN_VERSION}.tar.gz
https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${LIBXML2_VERSION}/libxml2-v${LIBXML2_VERSION}.tar.bz2
https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.bz2
https://sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_VERSION}.tar.gz
https://downloads.xiph.org/releases/ogg/libogg-${LIBOGG_VERSION}.tar.gz
https://downloads.xiph.org/releases/vorbis/libvorbis-${LIBVORBIS_VERSION}.tar.gz
https://ftp.osuosl.org/pub/xiph/releases/flac/flac-${FLAC_VERSION}.tar.xz
https://www.wavpack.com/wavpack-${WAVPACK_VERSION}.tar.bz2
https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz
https://ftp.osuosl.org/pub/xiph/releases/opus/opusfile-${OPUSFILE_VERSION}.tar.gz
https://gitlab.xiph.org/xiph/speex/-/archive/Speex-${SPEEX_VERSION}/speex-Speex-${SPEEX_VERSION}.tar.gz
https://downloads.sourceforge.net/project/mpg123/mpg123/${MPG123_VERSION}/mpg123-${MPG123_VERSION}.tar.bz2
https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz
https://github.com/nemtrif/utfcpp/archive/refs/tags/v${UTFCPP_VERSION}/utfcpp-${UTFCPP_VERSION}.tar.gz
https://taglib.org/releases/taglib-${TAGLIB_VERSION}.tar.gz
https://github.com/dlfcn-win32/dlfcn-win32/archive/refs/tags/v${DLFCN_VERSION}/dlfcn-win32-${DLFCN_VERSION}.tar.gz
https://files.strawberrymusicplayer.org/fftw-${FFTW_VERSION}-x64-debug.zip
https://files.strawberrymusicplayer.org/fftw-${FFTW_VERSION}-x64-release.zip
https://files.strawberrymusicplayer.org/fftw-${FFTW_VERSION}-x86-debug.zip
https://files.strawberrymusicplayer.org/fftw-${FFTW_VERSION}-x86-release.zip
https://github.com/acoustid/chromaprint/releases/download/v${CHROMAPRINT_VERSION}/chromaprint-${CHROMAPRINT_VERSION}.tar.gz
https://download.gnome.org/sources/glib/$($GLIB_VERSION -replace '\.\d+$')/glib-${GLIB_VERSION}.tar.xz
https://download.gnome.org/sources/glib-networking/$($GLIB_NETWORKING_VERSION -replace '\.\d+$')/glib-networking-${GLIB_NETWORKING_VERSION}.tar.xz
https://github.com/rockdaboot/libpsl/releases/download/${LIBPSL_VERSION}/libpsl-${LIBPSL_VERSION}.tar.gz
# https://github.com/libproxy/libproxy/archive/refs/tags/${LIBPROXY_VERSION}/libproxy-${LIBPROXY_VERSION}.tar.gz
https://download.gnome.org/sources/libsoup/$($LIBSOUP_VERSION -replace '\.\d+$')/libsoup-${LIBSOUP_VERSION}.tar.xz
https://gstreamer.freedesktop.org/src/orc/orc-${ORC_VERSION}.tar.xz
https://files.musepack.net/source/musepack_src_r${MUSEPACK_VERSION}.tar.gz
https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-${LIBOPENMPT_VERSION}+release.msvc.zip
https://github.com/knik0/faad2/tarball/${FAAD2_VERSION}/faad2-${FAAD2_VERSION}.tar.gz
https://github.com/knik0/faac/archive/refs/tags/faac-${FAAC_VERSION}.tar.gz
https://downloads.sourceforge.net/project/opencore-amr/fdk-aac/fdk-aac-${FDK_AAC_VERSION}.tar.gz
https://downloads.sourceforge.net/project/bs2b/libbs2b/${LIBBS2B_VERSION}/libbs2b-${LIBBS2B_VERSION}.tar.bz2
https://github.com/jiixyj/libebur128/archive/refs/tags/v${LIBEBUR128_VERSION}/libebur128-${LIBEBUR128_VERSION}.tar.gz
https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-${GSTREAMER_VERSION}.tar.xz
https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-${GSTREAMER_VERSION}.tar.xz
https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-${GSTREAMER_VERSION}.tar.xz
https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-${GSTREAMER_VERSION}.tar.xz
https://gstreamer.freedesktop.org/src/gst-plugins-ugly/gst-plugins-ugly-${GSTREAMER_VERSION}.tar.xz
https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-${GSTREAMER_VERSION}.tar.xz
https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protobuf-${PROTOBUF_VERSION}.tar.gz
https://downloads.sourceforge.net/project/glew/glew/${GLEW_VERSION}/glew-${GLEW_VERSION}.tgz
# https://github.com/projectM-visualizer/projectm/releases/download/v${LIBPROJECTM_VERSION}/libprojectm-${LIBPROJECTM_VERSION}.tar.gz
https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION_UNDERSCORE}/expat-${EXPAT_VERSION}.tar.bz2
https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.gz
# https://github.com/unicode-org/icu/releases/download/release-${ICU4C_VERSION_DASH}/icu4c-${ICU4C_VERSION_UNDERSCORE}-src.zip
https://github.com/unicode-org/icu/releases/download/release-${ICU4C_VERSION}/icu4c-${ICU4C_VERSION}-sources.zip
# https://cairographics.org/releases/cairo-${CAIRO_VERSION}.tar.xz
https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz
https://download.qt.io/official_releases/qt/$($QT_VERSION -replace '\.\d+$')/${QT_VERSION}/submodules/qtbase-everywhere-src-${QT_VERSION}.tar.xz
https://download.qt.io/official_releases/qt/$($QT_VERSION -replace '\.\d+$')/${QT_VERSION}/submodules/qttools-everywhere-src-${QT_VERSION}.tar.xz
https://download.qt.io/official_releases/qt/$($QT_VERSION -replace '\.\d+$')/${QT_VERSION}/submodules/qtgrpc-everywhere-src-${QT_VERSION}.tar.xz
https://download.qt.io/official_releases/qt/$($QT_VERSION -replace '\.\d+$')/${QT_VERSION}/submodules/qtimageformats-everywhere-src-${QT_VERSION}.tar.xz
https://github.com/libgme/game-music-emu/releases/download/${LIBGME_VERSION}/libgme-${LIBGME_VERSION}-src.tar.gz
https://downloads.sourceforge.net/twolame/twolame-${TWOLAME_VERSION}.tar.gz
https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-${SPARSEHASH_VERSION}.tar.gz
https://github.com/Tencent/rapidjson/archive/refs/tags/v${RAPIDJSON_VERSION}/rapidjson-${RAPIDJSON_VERSION}.tar.gz
# https://github.com/abseil/abseil-cpp/archive/refs/tags/${ABSEIL_VERSION}/abseil-cpp-${ABSEIL_VERSION}.tar.gz
https://github.com/KDAB/KDSingleApplication/releases/download/v${KDSINGLEAPPLICATION_VERSION}/kdsingleapplication-${KDSINGLEAPPLICATION_VERSION}.tar.gz
# https://github.com/curl/curl/releases/download/curl-${CURL_VERSION_UNDERSCORE}/curl-${CURL_VERSION}.tar.gz
# https://github.com/mlocati/gettext-iconv-windows/releases/download/v${GETTEXT_VERSION}-v${ICONV_VERSION}/gettext${GETTEXT_VERSION}-iconv${ICONV_VERSION}-static-64.zip
# https://github.com/mlocati/gettext-iconv-windows/releases/download/v${GETTEXT_VERSION}-v${ICONV_VERSION}/gettext${GETTEXT_VERSION}-iconv${ICONV_VERSION}-static-32.zip
https://github.com/trailofbits/pe-parse/archive/refs/tags/v${PEPARSE_VERSION}/pe-parse-${PEPARSE_VERSION}.tar.gz
https://github.com/frida/proxy-libintl/archive/refs/tags/${PROXY_LIBINTL_VERSION}/proxy-libintl-${PROXY_LIBINTL_VERSION}.tar.gz
https://download.osgeo.org/libtiff/tiff-${TIFF_VERSION}.tar.gz
https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP_VERSION}.tar.gz
https://github.com/jasper-software/jasper/releases/download/version-${JASPER_VERSION}/jasper-${JASPER_VERSION}.tar.gz
"@
    $PrecompiledDepsTargets = @"
https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/releases/download/release-$MSVC_DEPS_REPO_RELEASE/strawberry-msvc-x86-release.tar.xz
https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/releases/download/release-$MSVC_DEPS_REPO_RELEASE/strawberry-msvc-x86-debug.tar.xz
https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/releases/download/release-$MSVC_DEPS_REPO_RELEASE/strawberry-msvc-x86_64-release.tar.xz
https://github.com/strawberrymusicplayer/strawberry-msvc-dependencies/releases/download/release-$MSVC_DEPS_REPO_RELEASE/strawberry-msvc-x86_64-debug.tar.xz
"@

    $Additional = if ($FromScratch) { $FromScratchTargets } else { $PrecompiledDepsTargets }
    $ResultTargets = $BaseTargets, $Additional -join "`n"
    [string[]]$FILE_TARGETS = $ResultTargets -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^\s*#' }

    #endregion
    #region Repositories to Clone

    $REPO_TARGETS = @{
        'https://github.com/Pro/tinysvcmdns'                  = $TINYSVCMDNS_BRANCH
        'https://github.com/strawberrymusicplayer/strawberry' = $STRAWBERRY_REPO_BRANCH, $STRAWBERRY_REPO_COMMIT
        'https://github.com/ShiftMediaProject/gmp'            = $GMP_BRANCH, $GMP_VERSION
        'https://github.com/ShiftMediaProject/nettle'         = $NETTLE_BRANCH, "nettle_$NETTLE_VERSION"
        'https://github.com/ShiftMediaProject/gnutls'         = $GNUTLS_BRANCH, $GNUTLS_VERSION
    }
    if ($FromScratch) {
        $REPO_TARGETS['https://github.com/pffang/libiconv-for-Windows'] = $LIBICONV_BRANCH
        $REPO_TARGETS['https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi'] = $LIBFFI_BRANCH
        $REPO_TARGETS['https://gitlab.freedesktop.org/gstreamer/meson-ports/ffmpeg'] = "meson-$FFMPEG_VERSION"
        # $REPO_TARGETS['https://github.com/frida/proxy-libintl'] = $LIBINTL_BRANCH
        $REPO_TARGETS['https://github.com/ludvikjerabek/getopt-win'] = $GETOPT_BRANCH
        $REPO_TARGETS['https://github.com/Tencent/rapidjson'] = $RAPIDJSON_BRANCH
        $REPO_TARGETS['https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs'] = $GSTSPOTIFY_BRANCH, $GSTREAMER_GST_PLUGINS_RS_VERSION
        $REPO_TARGETS['https://github.com/strawberrymusicplayer/qtsparkle'] = $QTSPARKLE_BRANCH
        $REPO_TARGETS['https://github.com/gsauthof/pe-util'] = $PEUTIL_BRANCH
        if ($QTDevMode) {
            $REPO_TARGETS['https://github.com/qt/qtbase.git'] = $QT_DEV_BRANCH
            $REPO_TARGETS['https://github.com/qt/qttools.git'] = $QT_DEV_BRANCH
            $REPO_TARGETS['https://github.com/qt/qtgrpc.git'] = $QT_DEV_BRANCH
            $REPO_TARGETS['https://github.com/qt/qtimageformats.git'] = $QT_DEV_BRANCH
        }
        if ($GStreamerDevMode) {
            $REPO_TARGETS['https://gitlab.freedesktop.org/gstreamer/gstreamer'] = $GSTREAMER_BRANCH
        }
    }

    #endregion
    #region Web parameters

    $WebParams = @{
        UserAgent          = 'curl/8.9.1'
        MaximumRedirection = 8
    }

    if ($PSVersionTable.PSVersion -ge '6.0') {
        $WebParams.RetryIntervalSec = 10
        $WebParams.MaximumRetryCount = 6
    } else {
        $WebParams.UseBasicParsing = $true
    }
    if ($PSVersionTable.PSVersion -ge '7.4') {
        $WebParams.AllowInsecureRedirect = $true
        $WebParams.ConnectionTimeoutSeconds = 20
        $WebParams.OperationTimeoutSeconds = 30
    } else {
        $WebParams.TimeoutSec = 20
    }

    #endregion
    #region Convenience Functions

    function CheckGit {
        [CmdletBinding()]
        param ([int]$Try = 0, [int]$MaxTries = 5)

        if ($Try -ge $MaxTries) { return $false }

        $GitPaths = @(
            "$env:ProgramFiles\Git\bin\git.exe"
            "${env:ProgramFiles(x86)}\Git\bin\git.exe"
        )

        foreach ($Bin in $GitPaths) {
            $Dir = Split-Path $Bin -Parent
            if (Test-Path $Bin) {
                if ($env:Path -notlike "*$Dir*") {
                    $env:Path = "$env:Path$([Path]::PathSeparator)$Dir"
                }
                return $true
            }
        }

        $GitInstall = Join-Path $DownloadPath "Git-${GIT_VERSION}-64-bit.exe"

        if (-not (Test-Path $GitInstall)) {
            Invoke-WebRequest "https://github.com/git-for-windows/git/releases/download/v${GIT_VERSION}.windows.1/Git-${GIT_VERSION}-64-bit.exe" -OutFile $GitInstall @WebParams
            if (-not $?) { return $(CheckGit ($Try + 1)) }
        }

        if (-not (Test-Path $GitInstall)) { return $(CheckGit ($Try + 1)) }

        & $GitInstall /silent /norestart

        if ($LASTEXITCODE -ne 0) { return (CheckGit ($Try + 1)) }

        return $(CheckGit ($Try + 1))
    }
}

#endregion
#region Main

process {

    if (-not (Test-Path $DownloadPath -PathType Container)) {
        $null = mkdir $DownloadPath
        if (-not $?) { return }
    }

    Push-Location $DownloadPath

    $Tries = @{}
    $MaxTries = 1
    :MainLoop for ($i = 0; $i -lt $FILE_TARGETS.Count; $i++) {
        $Url = $FILE_TARGETS[$i]
        $Filename = $Url -replace '^.+/'

        if (-not $Tries.Contains($Url)) { $Tries[$Url] = 1 }
        if ($Tries[$Url] -gt $MaxTries) {
            $Err = [ErrorRecord]::new([FileNotFoundException]::new("Failed to find or download file '$Filename'.", $Filename), 'FileNotFound', 'ObjectNotFound', $Filename)
            $PSCmdlet.WriteError($Err)
            continue MainLoop
        }

        if (-not (Test-Path -LiteralPath $Filename)) {
            Write-Host -fo Cyan "Downloading file '$Filename' from '$Url'. (Try $($Tries[$Url])/$MaxTries)..."
            if (-not [string]::IsNullOrWhiteSpace($CurlCmd)) {
                if ($VerbosePreference -notin 'SilentlyContinue', 'Ignore') {
                    & $CurlCmd -v -k -L -A $WebParams.UserAgent --create-dirs --max-redirs $WebParams.MaximumRedirection --connect-timeout 20 --retry-max-time 90 --retry-delay 10 --retry 8 -o $Filename $Url
                } else {
                    & $CurlCmd -s -k -L -A $WebParams.UserAgent --create-dirs --max-redirs $WebParams.MaximumRedirection --connect-timeout 20 --retry-max-time 90 --retry-delay 10 --retry 8 -o $Filename $Url
                }
            } else {
                Invoke-WebRequest -Uri $Url -OutFile $Filename -ErrorAction SilentlyContinue @WebParams
            }
        }

        if (-not (Test-Path $Filename) -or ((Get-Item $Filename).Length -lt 10kb -and $Filename -notlike '*.patch')) {
            $PSCmdlet.WriteWarning("Failed to download file '$Filename'. Trying again.")
            $i--
            $Tries[$Url]++
            Start-Sleep -Seconds 10
            continue MainLoop
        }
        $HashOrSig = $false
        if ($FILE_HASHES.Contains($Filename)) {
            Write-Host -fo DarkCyan ('{0,-110}' -f "Checking integrity of file '$Filename'...  ") -NoNewline
            $Expected = $FILE_HASHES[$Filename]
            $Actual = (Get-FileHash -LiteralPath $Filename -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($Expected -ine $Actual) {
                Write-Host -fo Red 'MISMATCH'
                $PSCmdlet.WriteWarning("FILE HASH MISMATCH: '$Filename' should have hash '$Expected' but hash is '$Actual'. Redownloading.")
                Remove-Item -LiteralPath $Filename -Force
                $i--
                $Tries[$Url]++
                Start-Sleep -Seconds 10
                continue MainLoop
            }
            Write-Host -fo Green 'GOOD'
            $PSCmdlet.WriteVerbose("File '$Filename' passed integrity check.")
            $HashOrSig = $true
        }

        foreach ($Pattern in $SIGNED_FILES) {
            if ($Filename -notlike $Pattern) { continue }
            Write-Host -fo DarkCyan ('{0,-110}' -f "Checking signature of file '$Filename'...  ") -NoNewline
            $Result = Get-AuthenticodeSignature $Filename
            if ($Result.Status -ne 'Valid') {
                Write-Host -fo Red 'FAIL'
                $PSCmdlet.WriteWarning("FILE HASH MISMATCH: '$Filename' failed certificate verification, status: $($Result.StatusMessage). Redownloading.")
                Remove-Item -LiteralPath $Filename -Force
                $i--
                $Tries[$Url]++
                Start-Sleep -Seconds 10
                continue MainLoop
            }
            Write-Host -fo Green 'GOOD'
            $PSCmdlet.WriteVerbose("File '$Filename' passed certificate verifcation. Thumbprint: $($Result.SignerCertificate.Thumbprint)")
            $HashOrSig = $true
            break
        }

        if ($WarnNotVerified -and -not $HashOrSig) {
            $PSCmdlet.WriteWarning("File '$Filename' is not signed and is not in the hash list. The integrity of the file is unknown." +
                "`n$Filename = $((Get-FileHash -LiteralPath $Filename -Algorithm SHA256).Hash.ToLowerInvariant())")
        }
    }

    if (-not (CheckGit)) {
        $Err = [ErrorRecord]::new([FileNotFoundException]::new('Git installation not found and unable to be installed.', 'git.exe'), 'GitNotFound', 'ObjectNotFound', 'git.exe')
        $PSCmdlet.WriteError($Err)
        return
    }

    foreach ($Url in $REPO_TARGETS.Keys) {
        $DirName = $Url -replace '/$' -replace '\.git$' -replace '^.+/'
        $Targets = $REPO_TARGETS[$Url]
        if ($Targets.Count -gt 1) {
            $Branch = $Targets[0]
            $Commit = $Targets[1]
        } else {
            $Branch = $Targets
            $Commit = ''
        }
        $PSCmdlet.WriteVerbose("Repo: '$Url', Dir: '$DirName', Branch: '$Branch', Commit: '$Commit'")
        if (Test-Path -LiteralPath $DirName -PathType Container) {
            Write-Host -fo DarkCyan ('{0,-110}' -f "Updating Git repo '$DirName'...  ") -NoNewline
            $Res = git -C $DirName fetch *>&1
            if ($LASTEXITCODE -ne 0) { Write-Host -fo Red "FAILED FETCH: $LASTEXITCODE"; $Res; continue }
            if ([string]::IsNullOrWhiteSpace($Commit)) {
                $null = git switch - *>&1
                $Res = git -C $DirName checkout $Branch *>&1
                if ($LASTEXITCODE -eq 0) { $Res = git -C $DirName pull --autostash *>&1 }
            } else {
                $null = git switch - *>&1
                $Res = git -C $DirName checkout $Commit *>&1
            }
            if ($LASTEXITCODE -ne 0) { Write-Host -fo Red "FAILED CHECKOUT: $LASTEXITCODE"; $Res } else { Write-Host -fo Green 'GOOD' }
        } else {
            if ([string]::IsNullOrWhiteSpace($Commit)) {
                Write-Host -fo Cyan ('{0,-110}' -f "Cloning Git repo '$Url' branch '$Branch' into '$DirName'...  ") -NoNewline
                $Res = git clone --recurse-submodules -b $Branch $Url *>&1
            } else {
                Write-Host -fo Cyan ('{0,-110}' -f "Cloning Git repo '$Url' into '$DirName'...  ") -NoNewline
                $Res = git clone --recurse-submodules $Url *>&1
            }
            if ($LASTEXITCODE -ne 0) { Write-Host -fo Red "FAILED: $LASTEXITCODE"; $Res; continue } else { Write-Host -fo Green 'GOOD' }
            if (-not [string]::IsNullOrWhiteSpace($Commit)) {
                Write-Host -fo Cyan ('{0,-110}' -f "Checkout commit '$Commit' on repo '$DirName'...  ") -NoNewline
                $Res = git -C $DirName checkout $Commit *>&1
                if ($LASTEXITCODE -ne 0) { Write-Host -fo Red "FAILED: $LASTEXITCODE"; $Res } else { Write-Host -fo Green 'GOOD' }
            }
        }
    }

    if ($Cleanup) {
        $FileList = [List[string]]::new()
        foreach ($Url in $FILE_TARGETS) {
            $FileList.Add(($Url -replace '.+/'))
        }
        Get-ChildItem $DownloadPath -File | ForEach-Object {
            if ($_.Name -notin $FileList) {
                Write-Host -fo Cyan ('{0,-110}' -f "Removing unused file '$($_.Name)'...  ") -NoNewline
                Remove-Item $_ -Force
                if ($?) {
                    Write-Host -fo Green 'GOOD'
                } else {
                    Write-Host -fo Red 'FAILED'
                }
            }
        }
    }

}

end {
    Pop-Location
    $InformationPreference = $OldInfoPref
}

#endregion

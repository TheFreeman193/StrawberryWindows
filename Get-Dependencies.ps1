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
    $SQLITE_YEAR = '2025'
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
7z2409-x64.exe                         = bdd1a33de78618d16ee4ce148b849932c05d0015491c34887846d431d29f308e
7z2501-x64.exe                         = 78afa2a1c773caf3cf7edf62f857d2a8a5da55fb0fff5da416074c0d28b2b55f
abseil-cpp-20240722.0.tar.gz           = f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3
boost_1_88_0.tar.gz                    = 3621533e820dcab1e8012afd583c0c73cf0f77694952b81352bf38c1488f9cb4
boost_1_89_0.tar.gz                    = 9de758db755e8330a01d995b0a24d09798048400ac25c03fc5ea9be364b13c93
boost_1_90_0.tar.gz                    = 5e93d582aff26868d581a52ae78c7d8edf3f3064742c6e77901a1f18a437eea9
brotli-1.1.0.tar.gz                    = e720a6ca29428b803f4ad165371771f5398faba397edf6778837a18599ea13ff
brotli-1.2.0.tar.gz                    = 816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec
bzip2-1.0.8.tar.gz                     = ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269
cairo-1.18.0.tar.xz                    = 243a0736b978a33dee29f9cca7521733b78a65b5418206fef7bd1c3d4cf10b64
ccache-4.11.3.tar.gz                   = 28a407314f03a7bd7a008038dbaffa83448bc670e2fc119609b1d99fb33bb600
chromaprint-1.5.1.tar.gz               = a1aad8fa3b8b18b78d3755b3767faff9abb67242e01b478ec9a64e190f335e1c
chromaprint-1.6.0.tar.gz               = 9d33482e56a1389a37a0d6742c376139fa43e3b8a63d29003222b93db2cb40da
cmake-4.0.1-windows-x86_64.msi         = b2cd97898ba97ee6d08ee2b7e99def5eb13c2c24eae8d5f2c3cd983923c2db49
cmake-4.1.0-windows-x86_64.msi         = 10664a3a59daa9ee47bc04d183b16cafe91235310e728ee3d0c9ba418f0a7bd7
curl-8.11.0.tar.gz                     = 264537d90e58d2b09dddc50944baf3c38e7089151c8986715e2aaeaaf2b8118f
dlfcn-win32-1.4.2.tar.gz               = f61a874bc9163ab488accb364fd681d109870c86e8071f4710cbcdcbaf9f2565
expat-2.7.1.tar.bz2                    = 45c98ae1e9b5127325d25186cf8c511fa814078e9efeae7987a574b482b79b3d
expat-2.7.3.tar.bz2                    = 59c31441fec9a66205307749eccfee551055f2d792f329f18d97099e919a3b2f
faac-1.31.1.tar.gz                     = 3191bf1b131f1213221ed86f65c2dfabf22d41f6b3771e7e65b6d29478433527
faad2-2.11.2.tar.gz                    = 5ecf60648c26df34308d40e7f78e70fc6ca0e4d7c24815d99da87ca82bbec6f4
fdk-aac-2.0.3.tar.gz                   = 829b6b89eef382409cda6857fd82af84fabb63417b08ede9ea7a553f811cb79e
fftw-3.3.10-x64-debug.zip              = 05fc35930da3b375733685e50ec40c1cfc4c188df0bbd022a85e4f6fc9f8ab60
fftw-3.3.10-x64-release.zip            = d8af9c26d0fcb0f81c0b8ea848c411969788114650a43ec07f47b350cedaed5f
fftw-3.3.10-x86-debug.zip              = cacfc427049637c52c84f8b1da92dc98ac8a6e2b7f269d3fcd508ff51227e4d8
fftw-3.3.10-x86-release.zip            = a5f1f5c3493c33737c118eb8e6ee21d03d27cc3dee4a4ead59d070aa4cefd04b
flac-1.5.0.tar.xz                      = f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920
freetype-2.13.3.tar.gz                 = 5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747
freetype-2.14.1.tar.gz                 = 174d9e53402e1bf9ec7277e22ec199ba3e55a6be2c0740cb18c0ee9850fc8c34
gettext0.25-iconv1.17-static-32.zip    = 0a4841dfb0b6545f5eacf1bfe1637bd0eaca93da811c73884ed0fe7704883ded
gettext0.25-iconv1.17-static-64.zip    = 96b945382422038108a05ae7362497da82b44d8f14ed6c1a7134fe6a8052a3cd
gettext0.25.1-iconv1.17-static-32.zip  = f02e414a3cdfd260523ad908aa5ddf19006bf39878232b0933108d5e12216991
gettext0.25.1-iconv1.17-static-64.zip  = 50ed96f0d804473fcd6809715bb890fe9063f3a0fa3f3e3fbafbb901e7b51b61
gettext0.26-iconv1.17-static-32.zip    = c1f03ee4bebbfcd4dee8fe39a75ccca3f3c0160584baaea40aa8aea4675c1f3a
gettext0.26-iconv1.17-static-64.zip    = 13090adabc3146951cd6bde80a9ea5435b16317577063fa8f2bb747fd1e9988f
Git-2.49.0-64-bit.exe                  = 726056328967f242fe6e9afbfe7823903a928aff577dcf6f517f2fb6da6ce83c
Git-2.50.1-64-bit.exe                  = 47fe1d46dbb7111f6693b04a8bd95fc869ce2062df7b4822b52849548fb457e4
glew-2.1.0.tgz                         = 04de91e7e6763039bc11940095cd9c7f880baba82196a7765f727ac05a993c95
glib-2.85.0.tar.xz                     = 97cfb0466ae41fca4fa2a57a15440bee15b54ae76a12fb3cbff11df947240e48
glib-2.85.1.tar.xz                     = d3f57bcd4202d93aa547ffa1d2a5dbd380a05dbaac04cc291bd7dfce93b4a8e5
glib-2.85.3.tar.xz                     = af229e1de191d66aebcdb03c7493c724fd4d0a6628b1ca4ea1f35739259b311d
glib-2.86.1.tar.xz                     = 119d1708ca022556d6d2989ee90ad1b82bd9c0d1667e066944a6d0020e2d5e57
glib-2.87.0.tar.xz                     = 926cf73d8eb90ea341cc2d6fc7b258901e1a086a3808b166b4476d69a98b2401
glib-networking-2.80.1.tar.xz          = b80e2874157cd55071f1b6710fa0b911d5ac5de106a9ee2a4c9c7bee61782f8e
gst-libav-1.26.1.tar.xz                = 350a20b45b6655b6e10265430bdfbb3c436a96e9611b79caabef8f10abe570ea
gst-libav-1.26.2.tar.xz                = 2eceba9cae4c495bb4ea134c27f010356036f1fa1972db5f54833f5f6c9f8db0
gst-libav-1.26.3.tar.xz                = 3ada7e50a3b9b8ba3e405b14c4021e25fbb10379f77d2ce490aa16523ed2724d
gst-libav-1.26.5.tar.xz                = d6de05884ef42376dd8cde89940f7b50ced96f4f6f52888e764cd8233e74f052
gst-libav-1.26.7.tar.xz                = 91d4a7a14527d97fe0ce7ccedb3554e8f692b216429ef2b1850944bbf5435c09
gst-libav-1.26.8.tar.xz                = d8610d88026cc4927eb013e46ecf505f73ee946ec8b8fd5aee5b3ae4614a5d59
gst-libav-1.26.9.tar.xz                = 08a8e944fc61ef26df515784a089c8ac41765304a5d55b98199835b28a98dbdf
gst-plugins-bad-1.26.1.tar.xz          = 9b8415b1bb3726a499578fb39907952981716643f660215fe68628fbd8629197
gst-plugins-bad-1.26.2.tar.xz          = cb116bfc3722c2de53838899006cafdb3c7c0bc69cd769b33c992a8421a9d844
gst-plugins-bad-1.26.3.tar.xz          = 95c48dacaf14276f4e595f4cbca94b3cfebfc22285e765e2aa56d0a7275d7561
gst-plugins-bad-1.26.5.tar.xz          = 9890f262f3b2a9564dcb629e9eb697d77b93d1f71897eda1a8170b7dcfe73294
gst-plugins-bad-1.26.7.tar.xz          = a0ab17dddd4c029ecd7a423c30badd5a3c7599ea42707016d1d57545f5723ccf
gst-plugins-bad-1.26.8.tar.xz          = 25c05be5eb0694bde3ecd3317516f5d0d6e4ad21125a5ebcf6fb644a4c92439f
gst-plugins-bad-1.26.9.tar.xz          = a96bfb68c53a7c9ab1ae279eac7c101f4204fb5c0e4729683b2be64261707446
gst-plugins-base-1.26.1.tar.xz         = 659553636f84dcf388cad5cf6530e02b0b2d3dc450e76199287ba9db6a6c5226
gst-plugins-base-1.26.2.tar.xz         = f4b9fc0be852fe5f65401d18ae6218e4aea3ff7a3c9f8d265939b9c4704915f7
gst-plugins-base-1.26.3.tar.xz         = 4ef9f9ef09025308ce220e2dd22a89e4c992d8ca71b968e3c70af0634ec27933
gst-plugins-base-1.26.5.tar.xz         = f0c0e26cbedaa57732cb6a578e8cc13a1164bf18d737d55c333061c52f0c48d7
gst-plugins-base-1.26.7.tar.xz         = 969e3cbf05dfab92cf37e94840fbe398517d7ba3275331d1c216a2e30a7208d0
gst-plugins-base-1.26.8.tar.xz         = 513cace4b02cb183ee47665d64bb2a25088abb6678c4cc57bb100b841add746b
gst-plugins-base-1.26.9.tar.xz         = 11db4ec9ae5be2194ff8ccf2b5fecdc069252fe4416921b083a921ef71dd000a
gst-plugins-good-1.26.1.tar.xz         = fcdcb2f77620a599557b2843d1c6c55c2b660f5fc28222b542847d11d9ca982f
gst-plugins-good-1.26.2.tar.xz         = d864b9aec28c3a80895468c909dd303e5f22f92d6e2b1137f80e2a1454584339
gst-plugins-good-1.26.3.tar.xz         = fe4ec9670edfe6bb1e5f27169ae145b5ac2dd218ac98bd8251c8fba41ad33c53
gst-plugins-good-1.26.5.tar.xz         = eb0862e93404b073e98ec50350ece7e6685ea2936cab8118c2b8e938e2cbea8b
gst-plugins-good-1.26.7.tar.xz         = 82af18a1f3e4a060db61d2630fbb975269b80b55bb2fdcfddfab5c6440d30781
gst-plugins-good-1.26.8.tar.xz         = 061e84efae31dfb4d96e4517659aca82bad9d5625b8f64d3290604385edd1d14
gst-plugins-good-1.26.9.tar.xz         = f38566fb53ae56b7019a039475311756a28eb978a781154d67813dcb551ff5fe
gst-plugins-ugly-1.26.1.tar.xz         = 34d9bcec8e88b008839d8de33fb043ae75eb04e466df74066fd66ee487a8ec4f
gst-plugins-ugly-1.26.2.tar.xz         = ec2d7556c6b8c2694f9b918ab9c4c6c998fb908c6b6a6ad57441702dad14ce73
gst-plugins-ugly-1.26.3.tar.xz         = 417f5ee895f734ac0341b3719c175fff16b4c8eae8806e29e170b3bcb3d9dba5
gst-plugins-ugly-1.26.5.tar.xz         = 3dfc43435be97e110816bac6d602b0f206a038546279683d9d25372ff127db52
gst-plugins-ugly-1.26.7.tar.xz         = 11f2e4f34bb2e841dc60edc95581572bc47be0c11e577d12bed98bb1f80a661b
gst-plugins-ugly-1.26.8.tar.xz         = ed3c687290dd4d0cc1681f6fb3f59c57c8cfc765fa22eba16a7d09566cc5c7e1
gst-plugins-ugly-1.26.9.tar.xz         = 184e4c6e765bc463ed806b2263cb9b2aaa3a65415df0a3c22fd520d5d1bacb4d
gstreamer-1.26.1.tar.xz                = 30a4c4a5e48345583eb596aa265d0f53c0feb93011d93a6aaa70dd6e3c519dc4
gstreamer-1.26.2.tar.xz                = f75334a3dff497c240844304a60015145792ecc3b6b213ac19841ccbd6fdf0ad
gstreamer-1.26.3.tar.xz                = dc661603221293dccc740862425eb54fbbed60fb29d08c801d440a6a3ff82680
gstreamer-1.26.5.tar.xz                = 0a7edb0e7b42dbe6b575fce61a4808a3f6b20e085a1eaecbc025d0ec21f1e774
gstreamer-1.26.7.tar.xz                = 18a5e214114dc501407697dd458514bba62cadd5414c60f793cf70141a4d0bb3
gstreamer-1.26.8.tar.xz                = 2348e837464c3cb7423b79fc1cc8c4c994c74603443bd97d14edc6cd5ca7db13
gstreamer-1.26.9.tar.xz                = 8ee8772e468102ebe86d414d8c4c7440dd91d9f3e9396952ff23aecde80670c8
harfbuzz-11.2.1.tar.xz                 = 093714c8548a285094685f0bdc999e202d666b59eeb3df2ff921ab68b8336a49
harfbuzz-11.3.3.tar.xz                 = e1fbca6b32a91ae91ecd9eb2ca8d47a5bfe2b1cb2e54855ab7a0b464919ef358
harfbuzz-12.1.0.tar.xz                 = e5c81b7f6e0b102dfb000cfa424538b8e896ab78a2f4b8a5ec8cae62ab43369e
harfbuzz-12.2.0.tar.xz                 = ecb603aa426a8b24665718667bda64a84c1504db7454ee4cadbd362eea64e545
icu4c-77_1-src.zip                     = d5cf533cf70cd49044d89eda3e74880328eb9426e6fd2b3cc8f9a963d2ad480e
icu4c-78.1-sources.zip                 = fe027bcd7e52ab3f3bbbb2d5e9ff9c674e94bbe671bb6a8f58719f27485864da
InetC.zip                              = b01077e56ebb19c005b45d40f837958ca6a92f51a5a937dc1bb497c7c7f2aa93
kdsingleapplication-1.1.0.tar.gz       = 31029fffa4873e2769c555668e8edaa6bd5721edbc445bff5e66cc6af3b9ed78
kdsingleapplication-1.2.0.tar.gz       = ff4ae6a4620beed1cdb3e6a9b78a17d7d1dae7139c3d4746d4856b7547d42c38
lame-3.100.tar.gz                      = ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
libbs2b-3.1.0.tar.bz2                  = 4799974becdeeedf0db00115bc63f60ea3fe4b25f1dfdb6903505839a720e46f
libebur128-1.2.6.tar.gz                = baa7fc293a3d4651e244d8022ad03ab797ca3c2ad8442c43199afe8059faa613
libgme-0.6.4-src.tar.gz                = 6f94eac735d86bca998a7ce1170d007995191ef6d4388345a0dc5ffa1de0bafa
libgnutls_3.8.7_msvc17.zip             = 6d42dc3984e229806fc8810ef4c78b21ec47be00f1998c746592aeb16a4f8cf9
libgnutls_3.8.8_msvc17.zip             = 73abaa5d049e106c2a613d752df228f16588eead3a4e4fd47aa9135f67e562b0
libjpeg-turbo-3.1.0.tar.gz             = 9564c72b1dfd1d6fe6274c5f95a8d989b59854575d4bbee44ade7bc17aa9bc93
libjpeg-turbo-3.1.1.tar.gz             = aadc97ea91f6ef078b0ae3a62bba69e008d9a7db19b34e4ac973b19b71b4217c
libjpeg-turbo-3.1.2.tar.gz             = 8f0012234b464ce50890c490f18194f913a7b1f4e6a03d6644179fa0f867d0cf
libjpeg-turbo-3.1.3.tar.gz             = 075920b826834ac4ddf97661cc73491047855859affd671d52079c6867c1c6c0
libogg-1.3.5.tar.gz                    = 0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664
libogg-1.3.6.tar.gz                    = 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638
libopenmpt-0.7.13+release.msvc.zip     = 50db46162b2bb7a3c4047e67fd2074ce9791a26b454a27391eb87b9cc7713258
libopenmpt-0.8.1+release.msvc.zip      = 9203bd07e09373d836a5ae03523416054c1ceecfe228ff4dec47029a3790b184
libopenmpt-0.8.2+release.msvc.zip      = 1bac5f88ec10152dd1a56dd9d4262730572085077603521a0541c847245b02b8
libopenmpt-0.8.3+release.msvc.zip      = face7bab41d2c6236ae8ddba1aca5fd9f600180abded3ffd43104d75f9cd421a
libopenmpt-0.8.4+release.msvc.zip      = c9204e2cf490b73633b274c6bfa72f09c347e699d3cf9ba959ae1a25b8229bf7
libpng-1.6.48.tar.gz                   = 68f3d83a79d81dfcb0a439d62b411aa257bb4973d7c67cd1ff8bdf8d011538cd
libpng-1.6.49.tar.gz                   = d173dada6181ef1638bcdb9526dd46a0f5eee08e3be9615e628ae54f888f17f9
libpng-1.6.50.tar.gz                   = 708f4398f996325819936d447f982e0db90b6b8212b7507e7672ea232210949a
libpng-1.6.51.tar.gz                   = ac25cafc2054cda3f6f0fe22ee9fc587024b99e01d03bd72b765824e48f39021
libpng-1.6.53.tar.gz                   = da0b045cbb1d06a8fc9696f9441359f70645f280ff24ae453ccb7c722353654f
libprojectm-4.1.1.tar.gz               = 481c4bd18fd92e0046f0ce1a663a33df92822fb95c0a9aac8eab8317ddf46f11
libproxy-0.5.9.tar.gz                  = a1976c3ac4affedc17e6d40cf78c9d8eca6751520ea3cbbec1a8850f7ded1565
libpsl-0.21.5.tar.gz                   = 1dcc9ceae8b128f3c0b3f654decd0e1e891afc6ff81098f227ef260449dae208
libsoup-3.6.5.tar.xz                   = 6891765aac3e949017945c3eaebd8cc8216df772456dc9f460976fbdb7ada234
libvorbis-1.3.7.tar.gz                 = 0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab
libxml2-v2.13.8.tar.bz2                = 55369e84948c6920c2a82dedd3b03bbd4bf721121271d7954ffe6dc82f9bb3f9
libxml2-v2.14.5.tar.bz2                = f5eb7a794759770debada3a1e3feba130af1a5735615974509224b5b97289c1a
libxml2-v2.15.1.tar.bz2                = d0e8dfcc349eb967496f601a881d5b5ee2dcc9202f4748fa381cf926ebee4f92
LockedList.3.1.0.0.zip                 = 2ad420f6481248b5de71ccde8dd2b6d1f51534ba7abc30c1d477d5cca8a5fc30
mimalloc-2.1.2.tar.gz                  = 2b1bff6f717f9725c70bf8d79e4786da13de8a270059e4ba0bdd262ae7be46eb
mpg123-1.32.10.tar.bz2                 = 87b2c17fe0c979d3ef38eeceff6362b35b28ac8589fbf1854b5be75c9ab6557c
mpg123-1.33.0.tar.bz2                  = 2290e3aede6f4d163e1a17452165af33caad4b5f0948f99429cfa2d8385faa9d
mpg123-1.33.2.tar.bz2                  = 2c54fabbfa696dce8f9b137c8ef7a429a061f8fe633cd7d0a511809855f2c219
mpg123-1.33.3.tar.bz2                  = 6a0c6472dd156e213c2068f40115ebbb73978c2d873e66bae2a250e2d2198d26
musepack_src_r475.tar.gz               = a4b1742f997f83e1056142d556a8c20845ba764b70365ff9ccf2e3f81c427b2b
nasm-2.16.03-installer-x64.exe         = 657e1252676cfb26a008835c20a760f731c8e0414469a4ed0f83f0fb059cdd35
nasm-3.01-installer-x64.exe            = 7881e9febc8b6558581041019b7890f109bef0694d93ed82c9589794c7b5a600
nghttp2-1.65.0.tar.bz2                 = 0bdbb78dc21870484fd54449067657b60e3b1b7226e1174cf564016c6d3307f5
nghttp2-1.66.0.tar.bz2                 = 1d484ad37354df9fcab970814e93a5dca91a53256e83f4f58dd73119c6321017
nghttp2-1.68.0.tar.bz2                 = 8d80cb4e45adca546a2005b86251ba5a7b63f5ea322228ae28e9969743f99707
nsis-3.10-setup.exe                    = 4313d352e0dafd1f22b6517126a655cae3b444fa758d2845eddfbe72f24f7bdd
openssl-3.5.0.tar.gz                   = 344d0a79f1a9b08029b0744e2cc401a43f9c90acd1044d09a530b4885a8e9fc0
openssl-3.5.1.tar.gz                   = 529043b15cffa5f36077a4d0af83f3de399807181d607441d734196d889b641f
openssl-3.5.2.tar.gz                   = c53a47e5e441c930c3928cf7bf6fb00e5d129b630e0aa873b08258656e7345ec
openssl-3.6.0.tar.gz                   = b6a5f44b7eb69e3fa35dbf15524405b44837a481d43d81daddde3ff21fcbb8e9
opus-1.5.2.tar.gz                      = 65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
opusfile-0.12.tar.gz                   = 118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b
orc-0.4.41.tar.xz                      = cb1bfd4f655289cd39bc04642d597be9de5427623f0861c1fc19c08d98467fa2
pcre2-10.45.tar.bz2                    = 21547f3516120c75597e5b30a992e27a592a31950b5140e7b8bfde3f192033c4
pcre2-10.47.tar.bz2                    = 47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7
pe-parse-2.1.1.tar.gz                  = 74c4012274e6e15128a8cf4453f63bb11155bcc14ad56ca7594a259ae8ae0202
pixman-0.46.0.tar.gz                   = 02d9ff7b8458ef61731c3d355f854bbf461fd0a4d3563c51f1c1c7b00638050d
pixman-0.46.2.tar.gz                   = 3e0de5ba6e356916946a3d958192f15505dcab85134771bfeab4ce4e29bbd733
pixman-0.46.4.tar.gz                   = d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c
pkg-config-0.29.2.tar.gz               = 6fc69c01688c9458a57eb9a1664c9aba372ccda420a02bf4429fe610e7e7d591
pkgconf-2.4.3.tar.gz                   = cea5b0ed69806b69c1900ce2f6f223a33f15230ad797243634df9fd56e64b156
pkgconf-2.5.1.tar.gz                   = 79721badcad1987dead9c3609eb4877ab9b58821c06bdacb824f2c8897c11f2a
protobuf-29.1.tar.gz                   = 3d32940e975c4ad9b8ba69640e78f5527075bae33ca2890275bf26b853c0962c
python-3.13.3-amd64.exe                = 698f2df46e1a3dd92f393458eea77bd94ef5ff21f0d5bf5cf676f3d28a9b4b6c
qtbase-everywhere-src-6.9.0.tar.xz     = c1800c2ea835801af04a05d4a32321d79a93954ee3ae2172bbeacf13d1f0598c
qtbase-everywhere-src-6.9.1.tar.xz     = 40caedbf83cc9a1959610830563565889878bc95f115868bbf545d1914acf28e
qtbase-everywhere-src-6.9.2.tar.xz     = 44be9c9ecfe04129c4dea0a7e1b36ad476c9cc07c292016ac98e7b41514f2440
qtbase-everywhere-src-6.10.0.tar.xz    = ead4623bcb54a32257c5b3e3a5aec6d16ec96f4cda58d2e003f5a0c16f72046d
qtbase-everywhere-src-6.10.1.tar.xz    = 5a6226f7e23db51fdc3223121eba53f3f5447cf0cc4d6cb82a3a2df7a65d265d
qtgrpc-everywhere-src-6.9.0.tar.xz     = 3957e076181ac0d9a8f9fca93ec49e1e5e143e39eee1ec3feee10ca13f64b137
qtgrpc-everywhere-src-6.9.1.tar.xz     = c34c869e203289b0fd695a1e5391840bc51b919a8b55e1ed1ff36b4cb923a750
qtgrpc-everywhere-src-6.9.2.tar.xz     = a43d3c8823fe11b71d0c362527150914134239fa285feaff86fd692617353f64
qtgrpc-everywhere-src-6.10.0.tar.xz    = fb722289066101ae08865378e7fb29a22b416a71f6b1c19ae5a957f53a91a445
qtgrpc-everywhere-src-6.10.1.tar.xz    = 98138fb8633c4922ef7ef49b8301f7cbfb7beb7897d44d72e639120a29f4577f
qttools-everywhere-src-6.9.0.tar.xz    = fa645589cc3f939022401a926825972a44277dead8ec8607d9f2662e6529c9a4
qttools-everywhere-src-6.9.1.tar.xz    = 90c4a562f4ccfd043fd99f34c600853e0b5ba9babc6ec616c0f306f2ce3f4b4c
qttools-everywhere-src-6.9.2.tar.xz    = d8b7f7e8e970cc0b975205fd6d5832ea917ef3e751df69b97439c1cddd67a489
qttools-everywhere-src-6.10.0.tar.xz   = d86d5098cf3e3e599f37e18df477e65908fc8f036e10ea731b3469ec4fdbd02a
qttools-everywhere-src-6.10.1.tar.xz   = 8148408380ffea03101a26305c812b612ea30dbc07121e58707601522404d49b
rapidjson-1.1.0.tar.gz                 = bf7ced29704a1e696fbccf2a2b4ea068e7774fa37f6d7dd4039d0787f8bed98e
Registry.zip                           = 791451f1be34ea1ed6f2ad6d205cf8e54bb0562af11b0160a6bfa5f499624094
rustup-init.exe                        = 88d8258dcf6ae4f7a80c7d1088e1f36fa7025a1cfd1343731b4ee6f385121fc0
sed.exe                                = 4aa7a40b3a0e38e1c56f066d722f8a0c0dd99e6e2842a5d0c57c4f336d80589d
sparsehash-2.0.4.tar.gz                = 8cd1a95827dfd8270927894eb77f62b4087735cbede953884647f16c521c7e58
speex-Speex-1.2.1.tar.gz               = beaf2642e81a822eaade4d9ebf92e1678f301abfc74a29159c4e721ee70fdce0
sqlite-autoconf-3490200.tar.gz         = 5c6d8697e8a32a1512a9be5ad2b2e7a891241c334f56f8b0fb4fc6051e1652e8
sqlite-autoconf-3500100.tar.gz         = 00a65114d697cfaa8fe0630281d76fd1b77afcd95cd5e40ec6a02cbbadbfea71
sqlite-autoconf-3500200.tar.gz         = 84a616ffd31738e4590b65babb3a9e1ef9370f3638e36db220ee0e73f8ad2156
sqlite-autoconf-3500400.tar.gz         = a3db587a1b92ee5ddac2f66b3edb41b26f9c867275782d46c3a088977d6a5b18
sqlite-autoconf-3510000.tar.gz         = 42e26dfdd96aa2e6b1b1be5c88b0887f9959093f650d693cb02eb9c36d146ca5
sqlite-autoconf-3510100.tar.gz         = 4f2445cd70479724d32ad015ec7fd37fbb6f6130013bd4bfbc80c32beb42b7e0
strawberry-perl-5.40.0.1-64bit.msi     = 29f72c3403d316b5ec48204546a7aad6b5567ff9a346cacd94af81fe0ffdc83e
strawberry-perl-5.40.2.1-64bit.msi     = fdb810474472a769d6a1327a36d0f0a4843d5b1eac3a503428d4d86a1836e222
taglib-2.0.2.tar.gz                    = 0de288d7fe34ba133199fd8512f19cc1100196826eafcb67a33b224ec3a59737
taglib-2.1.1.tar.gz                    = 3716d31f7c83cbf17b67c8cf44dd82b2a2f17e6780472287a16823e70305ddba
taglib-2.1.tar.gz                      = 95b788b39eaebab41f7e6d1c1d05ceee01a5d1225e4b6d11ed8976e96ba90b0c
twolame-0.4.0.tar.gz                   = cc35424f6019a88c6f52570b63e1baf50f62963a3eac52a03a800bb070d7c87d
utfcpp-4.0.6.tar.gz                    = 6920a6a5d6a04b9a89b2a89af7132f8acefd46e0c2a7b190350539e9213816c0
utfcpp-4.0.8.tar.gz                    = f808b26d8c3a59def27fea207182ece77a8930bd121a69f80d328ecf3cfef925
VSYASM.zip                             = ec99229ba3ea6f0a0db3c15647266588db3c605301ff3b78bbf427d6657277d5
wavpack-5.8.0.tar.bz2                  = d2079e339582d43a0ee58626d9ed5e2d46c6886e788700093faf3753db68e6cd
wavpack-5.8.1.tar.bz2                  = 7bd540ed92d2d1bf412213858a9e4f1dfaf6d9a614f189b0622060a432e77bbf
win_flex_bison-2.5.25.zip              = 8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135
xz-5.8.1.tar.gz                        = 507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543
xz-5.8.2.tar.gz                        = ce09c50a5962786b83e5da389c90dd2c15ecd0980a258dd01f70f9e7ce58a8f1
yasm-1.3.0.tar.gz                      = 3dce6601b495f5b3d45b59f7d2492a340ee7e84b5beca17e48f862502bd5603f
zlib-1.3.1.tar.gz                      = 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
bzip2-cmake.patch                      = c6089dcebc75789dd84c2edd6b36fe9cb40fbfcf9c4fd35d1a61204b00e3da8c
faac-msvc.patch                        = 96f53f6411ac621768669d7eb3cd8d94767be4eba4d1b6f209f20f6fb919e9a5
fftw-fixes.patch                       = 4ebdcd7ce363759cc108ec3674da6ae39f7e542f0b14e5f4f329edb8a6877810
gst-plugins-bad-meson-dependency.patch = dcb4641d6e214a6844572332219f56d977e27e17a750058d5e3f0929d4e7d496
gst-plugins-bad-wasapi2.patch          = a43d1c266334adbfeebe769c83e1b28525f626cbab178ff42c2f5ae0c0bb26e4
libbs2b-clipping.patch                 = 6e059e81766449469de2e58f9d46fb1a01e2a7917af24e4bb25167b13bc73f93
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
strawberry-msvc-x86-release.tar.xz     = 669191f80c27328685fb509166736cf296e9a4b197cffb8b0deb4f5b8c51b39c
strawberry-msvc-x86-debug.tar.xz       = d7e5c69d40121f8b30d18e972e1f62a82e2ca298f07d944871735971b757c121
strawberry-msvc-x86_64-release.tar.xz  = 27691a31130d85e165777d14507aca8129bebe09c938a4be29d585630a44b1df
strawberry-msvc-x86_64-debug.tar.xz    = 60dccd66025bb778ea07e4f62b5f891ef1ae5695501e0afbf92dd4cd94579f19
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
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/gst-plugins-bad-meson-dependency.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/libbs2b-msvc.patch
https://raw.githubusercontent.com/strawberrymusicplayer/strawberry-msvc-dependencies/${MSVC_DEPS_REPO_COMMIT}/patches/libbs2b-clipping.patch
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
https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_TURBO_VERSION}/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz
https://github.com/PhilipHazel/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.bz2
https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz
https://downloads.sourceforge.net/project/lzmautils/xz-${XZ_VERSION}.tar.gz
https://github.com/google/brotli/archive/refs/tags/v${BROTLI_VERSION}/brotli-${BROTLI_VERSION}.tar.gz
https://www.cairographics.org/releases/pixman-${PIXMAN_VERSION}.tar.gz
https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${LIBXML2_VERSION}/libxml2-v${LIBXML2_VERSION}.tar.bz2
https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.bz2
https://sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE3_VERSION}.tar.gz
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
# https://download.qt.io/official_releases/qt/$($QT_VERSION -replace '\.\d+$')/${QT_VERSION}/submodules/qtgrpc-everywhere-src-${QT_VERSION}.tar.xz
https://github.com/libgme/game-music-emu/releases/download/${LIBGME_VERSION}/libgme-${LIBGME_VERSION}-src.tar.gz
https://downloads.sourceforge.net/twolame/twolame-${TWOLAME_VERSION}.tar.gz
https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-${SPARSEHASH_VERSION}.tar.gz
https://github.com/Tencent/rapidjson/archive/refs/tags/v${RAPIDJSON_VERSION}/rapidjson-${RAPIDJSON_VERSION}.tar.gz
# https://github.com/abseil/abseil-cpp/archive/refs/tags/${ABSEIL_VERSION}/abseil-cpp-${ABSEIL_VERSION}.tar.gz
https://github.com/KDAB/KDSingleApplication/releases/download/v${KDSINGLEAPPLICATION_VERSION}/kdsingleapplication-${KDSINGLEAPPLICATION_VERSION}.tar.gz
# https://github.com/curl/curl/releases/download/curl-${CURL_VERSION_UNDERSCORE}/curl-${CURL_VERSION}.tar.gz
https://github.com/mlocati/gettext-iconv-windows/releases/download/v${GETTEXT_VERSION}-v${ICONV_VERSION}/gettext${GETTEXT_VERSION}-iconv${ICONV_VERSION}-static-64.zip
https://github.com/mlocati/gettext-iconv-windows/releases/download/v${GETTEXT_VERSION}-v${ICONV_VERSION}/gettext${GETTEXT_VERSION}-iconv${ICONV_VERSION}-static-32.zip
https://github.com/trailofbits/pe-parse/archive/refs/tags/v${PE_PARSE_VERSION}/pe-parse-${PE_PARSE_VERSION}.tar.gz
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
        $REPO_TARGETS['https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs'] = $GSTSPOTIFY_BRANCH, $GSTREAMER_PLUGINS_RS_VERSION
        $REPO_TARGETS['https://github.com/strawberrymusicplayer/qtsparkle'] = $QTSPARKLE_BRANCH
        $REPO_TARGETS['https://github.com/gsauthof/pe-util'] = $PEUTIL_BRANCH
        if ($QTDevMode) {
            $REPO_TARGETS['https://code.qt.io/qt/qtbase.git'] = $QT_DEV_BRANCH
            $REPO_TARGETS['https://code.qt.io/qt/qttools.git'] = $QT_DEV_BRANCH
            # $REPO_TARGETS['https://code.qt.io/qt/qtgrpc.git'] = $QT_DEV_BRANCH
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

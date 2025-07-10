param(
    [string]$TargetDir = "$env:ProgramFiles\Strawberry Music Player Debug",
    [ValidateSet('x64', 'x86', 'arm64', 'arm')]
    [string]$Arch = $($env:PROCESSOR_ARCHITECTURE -replace 'amd64|ia64|em64t', 'x64' -replace 'ia32|i[3-6]86', 'x86')
)

$VCDR = Get-Item "$env:ProgramFiles\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\debug_nonredist\$Arch\Microsoft.VC*.DebugCRT" | Select-Object -Last 1 -ExpandProperty FullName
if (-not $?) { return }
$WDSDK = Get-Item "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows Kits\10\ExtensionSDKs\Microsoft.UniversalCRT.Debug\*\Redist\Debug\$Arch" | Select-Object -Last 1 -ExpandProperty FullName
if (-not $?) { return }

Copy-Item "$VCDR\*.dll" $TargetDir -Force
if (-not $?) { return }
Copy-Item "$WDSDK\*.dll" $TargetDir -Force

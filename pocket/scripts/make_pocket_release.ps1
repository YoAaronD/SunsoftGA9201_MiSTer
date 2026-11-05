# Make the Analogue Pocket package of the SunsoftGA9201 core (Windows PowerShell 5.1 or PowerShell 7).
#
#   powershell -ExecutionPolicy Bypass -File pocket\scripts\make_pocket_release.ps1 [-Date YYYYMMDD] [-SdCard E:]
#
# Run after a successful Quartus build of pocket\src\fpga\ap_core.qpf. It:
#   1. bit-reverses pocket\src\fpga\output_files\ap_core.rbf into bitstream.rbf_r
#      (the Pocket loads its bitstreams bit-reversed);
#   2. writes pocket\output\SunsoftGA9201_Pocket_<Date>.zip, laid out like the Pocket's SD card:
#        Cores/AjaxHC.SunsoftGA9201/   core definition files + bitstream.rbf_r
#        Platforms/ga9201.json
#        Assets/ga9201/AjaxHC.SunsoftGA9201/   one .json per game
#        Assets/ga9201/common/         (put the .rom files here)
#      Users copy its folders onto the SD card root. ROMs are never included.
#   3. with -SdCard (the card's drive, e.g. E:), also unpacks the zip onto the
#      card's root, replacing the core's files there (the .rom files in
#      Assets/ga9201/common/ are left alone).
param([string]$Date = (Get-Date -Format 'yyyyMMdd'), [string]$SdCard = '')

$ErrorActionPreference = 'Stop'
if ($Date -notmatch '^\d{8}$') { throw "Date must be YYYYMMDD, got '$Date'" }

$pocket = Split-Path -Parent $PSScriptRoot
$built  = Join-Path $pocket 'src\fpga\output_files\ap_core.rbf'
$dist   = Join-Path $pocket 'dist'
$outDir = Join-Path $pocket 'output'
$zipPath = Join-Path $outDir "SunsoftGA9201_Pocket_$Date.zip"

if (-not (Test-Path -LiteralPath $built)) { throw "No build: $built. Compile pocket\src\fpga\ap_core.qpf first." }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# 1. bit reversal
$table = New-Object byte[] 256
for ($i = 0; $i -lt 256; $i++) {
    $r = 0
    for ($b = 0; $b -lt 8; $b++) { if ($i -band (1 -shl $b)) { $r = $r -bor (1 -shl (7 - $b)) } }
    $table[$i] = [byte]$r
}
$data = [System.IO.File]::ReadAllBytes($built)
for ($i = 0; $i -lt $data.Length; $i++) { $data[$i] = $table[$data[$i]] }
$rbfr = Join-Path $outDir 'bitstream.rbf_r'
[System.IO.File]::WriteAllBytes($rbfr, $data)
Write-Host "Bit-reversed $($data.Length) bytes into pocket\output\bitstream.rbf_r"

# 2. zip (forward-slash entry names)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath }
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $distFull = (Resolve-Path -LiteralPath $dist).Path
    foreach ($f in (Get-ChildItem -LiteralPath $dist -Recurse -File)) {
        $rel = $f.FullName.Substring($distFull.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel)
        Write-Host "  $rel"
    }
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $rbfr, 'Cores/AjaxHC.SunsoftGA9201/bitstream.rbf_r')
    Write-Host "  Cores/AjaxHC.SunsoftGA9201/bitstream.rbf_r"
} finally {
    $zip.Dispose()
}
Write-Host "Wrote pocket\output\SunsoftGA9201_Pocket_$Date.zip"

# 3. optional: straight onto the SD card
if ($SdCard -ne '') {
    $root = $SdCard.TrimEnd('\') + '\'
    if (-not (Test-Path -LiteralPath $root)) { throw "SD card not found: $root" }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'Cores'))) {
        throw "$root has no Cores folder - is this the Pocket's SD card? (boot the Pocket with it once first)"
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $root -Force
    Write-Host "Unpacked onto $root - eject the card before taking it out."
}

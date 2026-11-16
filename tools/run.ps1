[CmdletBinding()]
param(
    [ValidateRange(1, 8)]
    [int]$Scale = 1,

    [switch]$Headless,

    [ValidateRange(1, 10000000)]
    [int]$Frames = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Game = Join-Path $Root "port\macross-recomp.exe"

if (-not (Test-Path -LiteralPath $Game)) {
    throw "The port has not been built. Run tools\setup.ps1 -Image <path-to-iso>."
}
if (-not $Headless -and -not (Test-Path -LiteralPath "$env:WINDIR\System32\vulkan-1.dll")) {
    throw "Vulkan loader not found. Install a Vulkan 1.3-capable graphics driver."
}

$env:MACROSS_SW = "0"
$env:MACROSS_SCALE = [string]$Scale
if ($Headless) {
    $env:MACROSS_HEADLESS = "1"
    $env:MACROSS_COMPAT = "1"
    $env:MACROSS_FRAMES = [string]$Frames
}

Push-Location (Join-Path $Root "port")
try {
    & $Game
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}

[CmdletBinding()]
param(
    [ValidateSet("Vulkan", "Software")]
    [string]$Renderer = "Vulkan",

    [ValidateRange(1, 8)]
    [int]$Scale = 1,

    [ValidateSet("Linear", "FSR1")]
    [string]$Upscaler = "Linear",

    [switch]$Launcher,

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
if ($Renderer -eq "Vulkan" -and -not $Headless -and -not (Test-Path -LiteralPath "$env:WINDIR\System32\vulkan-1.dll")) {
    throw "Vulkan loader not found. Install a Vulkan 1.3-capable graphics driver."
}

if ($Renderer -eq "Software") {
    $env:MACROSS_SW = "1"
}
else {
    $env:MACROSS_SW = "0"
}
$env:MACROSS_SCALE = [string]$Scale
$env:MACROSS_UPSCALER = $Upscaler.ToLowerInvariant()
if ($Headless) {
    $env:MACROSS_HEADLESS = "1"
    $env:MACROSS_COMPAT = "1"
    $env:MACROSS_FRAMES = [string]$Frames
}

Push-Location (Join-Path $Root "port")
try {
    $GameArgument = "--play"
    if ($Launcher) {
        $GameArgument = "--launcher"
    }
    & $Game $GameArgument
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}

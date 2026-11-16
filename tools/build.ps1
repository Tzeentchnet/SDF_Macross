[CmdletBinding()]
param(
    # Build without optimisation for a faster edit/compile loop.
    [switch]$Fast
)

# Rebuilds port\macross-recomp.exe from the existing generated source in
# port\src\rec. Run tools\setup.ps1 first (once per disc image, framework, or
# patch-series change); this script only relinks after port source edits.
# Older generated trees without provenance remain usable with a warning.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Lock = Get-Content -LiteralPath (Join-Path $Root "recomp.lock.json") -Raw |
    ConvertFrom-Json
$FrameworkPath = Join-Path $Root ".deps\ps-recomp"
$Odin = Join-Path $Root ".tools\$($Lock.odin.tag)\dist\odin.exe"
$Generated = Join-Path $Root "port\src\rec\all.odin"

if (-not (Test-Path -LiteralPath $Odin)) {
    throw "Odin is not installed. Run tools\setup.ps1 -Image <path-to-iso> first."
}
if (-not (Test-Path -LiteralPath $Generated)) {
    throw "No generated source in port\src\rec. Run tools\setup.ps1 -Image <path-to-iso> first."
}

. (Join-Path $PSScriptRoot "framework-patches.ps1")
$FrameworkPatchFingerprint = Get-FrameworkPatchFingerprint -Root $Root
Assert-FrameworkGenerationProvenance -Root $Root -Lock $Lock `
    -PatchFingerprint $FrameworkPatchFingerprint
Invoke-FrameworkPatches -Root $Root -FrameworkPath $FrameworkPath -Lock $Lock
if ((Get-FrameworkPatchFingerprint -Root $Root) -cne $FrameworkPatchFingerprint) {
    throw "Framework patches changed during build; retry."
}

$Game = Join-Path $Root "port\macross-recomp.exe"
$Arguments = @(
    "build",
    (Join-Path $Root "port\src"),
    "-collection:ps=$FrameworkPath",
    "-define:COMMIT=$($Lock.framework.commit)",
    "-define:ENV_PREFIX=MACROSS_",
    "-use-separate-modules",
    "-out:$Game"
)
if ($Fast) {
    $Arguments += @("-o:minimal", "-debug")
}
else {
    $Arguments += "-o:speed"
}
# A GUI-subsystem build would hide the console the runtime logs to; keep the
# console so problems remain visible.
try {
    $ErrorActionPreference = "Continue"
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = $null
    & $Odin @Arguments
    $OdinExitCode = $global:LASTEXITCODE
}
finally {
    $ErrorActionPreference = "Stop"
}
if ($null -eq $OdinExitCode) {
    throw "odin could not be started"
}
if ($OdinExitCode -ne 0) {
    throw "odin build failed with exit code $OdinExitCode"
}

$Sdl = Join-Path (Split-Path -Parent $Odin) "vendor\sdl2\SDL2.dll"
Copy-Item -LiteralPath $Sdl -Destination (Join-Path $Root "port\SDL2.dll") -Force
Write-Host "Built $Game"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Image,

    [Parameter(Mandatory = $true)]
    [string]$TranslationTools,

    [ValidateSet("Verify", "Baseline", "Full")]
    [string]$Mode = "Verify",

    [string]$Output,

    [switch]$Subtitles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Source = (Resolve-Path -LiteralPath $Image).Path
$Tools = (Resolve-Path -LiteralPath $TranslationTools).Path
$Python = (Get-Command python -ErrorAction Stop).Source
$Verify = Join-Path $Tools "tools\verify.py"
$Builder = Join-Path $Tools "tools\build.py"

if (-not (Test-Path -LiteralPath $Verify)) {
    throw "Translation checkout is missing tools\verify.py: $Tools"
}
& $Python $Verify $Source
if ($LASTEXITCODE -ne 0) {
    throw "The translation project rejected this image."
}
if ($Mode -eq "Verify") {
    exit 0
}
if (-not (Test-Path -LiteralPath $Builder)) {
    throw "Translation checkout is missing tools\build.py: $Tools"
}
if (-not $Output) {
    $Output = Join-Path $Root ".local\Macross-$($Mode.ToLowerInvariant()).iso"
}
$Destination = [System.IO.Path]::GetFullPath($Output)
if ($Destination -eq $Source) {
    throw "Translation output must not overwrite the source image."
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) |
    Out-Null
$Arguments = @($Builder, $Source, $Destination)
if ($Mode -eq "Full") {
    $Arguments += "--mtl"
}
if ($Subtitles) {
    $Arguments += "--subtitles"
}
& $Python @Arguments
if ($LASTEXITCODE -ne 0) {
    throw "Translation build failed with exit code $LASTEXITCODE"
}
& $Python (Join-Path $PSScriptRoot "inspect_game.py") $Destination --allow-patched
if ($LASTEXITCODE -ne 0) {
    throw "Translated image failed recomp project verification."
}
Write-Host "Translated image: $Destination"
Write-Host "Build it with: tools\setup.ps1 -Image `"$Destination`" -AllowPatchedImage"

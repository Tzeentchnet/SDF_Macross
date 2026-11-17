[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Image,

    [switch]$RecompileOnly,

    [switch]$ExactDisc,

    [switch]$AllowPatchedImage,

    [string]$Vu1Capture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Lock = Get-Content -LiteralPath (Join-Path $Root "recomp.lock.json") -Raw |
    ConvertFrom-Json
$ImagePath = (Resolve-Path -LiteralPath $Image).Path
$Vu1CapturePath = $null
if ($Vu1Capture) {
    $Vu1CapturePath = (Resolve-Path -LiteralPath $Vu1Capture).Path
    if (-not (Test-Path -LiteralPath $Vu1CapturePath -PathType Leaf)) {
        throw "VU1 capture is not a file: $Vu1CapturePath"
    }
    if ($Vu1CapturePath.IndexOfAny([char[]]"`t`r`n") -ge 0) {
        throw "VU1 capture path contains a tab or newline."
    }
}
$FrameworkPath = Join-Path $Root ".deps\ps-recomp"
$ToolRoot = Join-Path $Root ".tools"
$BuildRoot = Join-Path $Root ".build"
$LocalRoot = Join-Path $Root ".local"

. (Join-Path $PSScriptRoot "framework-patches.ps1")
. (Join-Path $PSScriptRoot "setup-verification.ps1")

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [string]$WorkingDirectory = $Root
    )

    Push-Location $WorkingDirectory
    try {
        # Native tools may write progress or warnings to stderr even when they
        # succeed. Check the exit code ourselves on both PowerShell versions.
        $ErrorActionPreference = "Continue"
        $PSNativeCommandUseErrorActionPreference = $false
        $global:LASTEXITCODE = $null
        & $FilePath @ArgumentList
        if ($null -eq $global:LASTEXITCODE) {
            throw "$FilePath could not be started"
        }
        if ($global:LASTEXITCODE -ne 0) {
            throw "$FilePath failed with exit code $global:LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-CheckedGit {
    param([Parameter(Mandatory = $true)] [string[]]$ArgumentList)

    $result = Invoke-FrameworkGit -Arguments $ArgumentList
    if ($result.ExitCode -ne 0) {
        throw "git failed with exit code $($result.ExitCode)$(Get-FrameworkGitError $result)"
    }
    if ($result.StdOut.Trim()) { Write-Host $result.StdOut.Trim() }
    if ($result.StdErr.Trim()) { Write-Host $result.StdErr.Trim() }
}

function Get-Odin {
    $archive = Join-Path $ToolRoot $Lock.odin.asset
    $install = Join-Path $ToolRoot $Lock.odin.tag
    $executable = Join-Path $install "dist\odin.exe"
    if (-not (Test-Path -LiteralPath $executable)) {
        New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
        if (-not (Test-Path -LiteralPath $archive)) {
            Write-Host "Downloading Odin $($Lock.odin.tag)..."
            Invoke-WebRequest -Uri $Lock.odin.url -OutFile $archive
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($actual -ne $Lock.odin.sha256) {
            throw "Odin archive SHA-256 mismatch: found $actual"
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $install -Force
    }
    if (-not (Test-Path -LiteralPath $executable)) {
        throw "Odin executable was not found after extraction: $executable"
    }
    return $executable
}

function Get-Framework {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $FrameworkPath) |
        Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $FrameworkPath ".git"))) {
        Invoke-CheckedGit @(
            "clone",
            "--filter=blob:none",
            "--no-checkout",
            $Lock.framework.repository,
            $FrameworkPath
        )
        Invoke-CheckedGit @(
            "-C",
            $FrameworkPath,
            "fetch",
            "--depth",
            "1",
            "origin",
            $Lock.framework.commit
        )
        Invoke-CheckedGit @(
            "-C",
            $FrameworkPath,
            "checkout",
            "--detach",
            $Lock.framework.commit
        )
    }
}

$Python = (Get-Command python -ErrorAction Stop).Source
$VerifyArguments = Get-SetupVerificationArguments `
    -InspectorPath (Join-Path $PSScriptRoot "inspect_game.py") `
    -ImagePath $ImagePath -ExactDisc:$ExactDisc `
    -AllowPatchedImage:$AllowPatchedImage
Invoke-Checked $Python $VerifyArguments

Get-Framework
$FrameworkPatchFingerprint = Get-FrameworkPatchFingerprint -Root $Root
Invoke-FrameworkPatches -Root $Root -FrameworkPath $FrameworkPath -Lock $Lock
if ((Get-FrameworkPatchFingerprint -Root $Root) -cne $FrameworkPatchFingerprint) {
    throw "Framework patches changed during setup; retry."
}
$Odin = Get-Odin
New-Item -ItemType Directory -Force -Path $BuildRoot, $LocalRoot | Out-Null

$Recompiler = Join-Path $BuildRoot "recomp.exe"
Invoke-Checked $Odin @(
    "build",
    (Join-Path $FrameworkPath "recomp"),
    "-collection:ps=$FrameworkPath",
    "-o:speed",
    "-out:$Recompiler"
)

$Generated = Join-Path $Root "port\src\rec"
if (Test-Path -LiteralPath $Generated) {
    Remove-Item -LiteralPath $Generated -Recurse -Force
}
$RecompConfig = Join-Path $BuildRoot "recomp.tsv"
$Template = Join-Path $PSScriptRoot "recomp.tsv"
$TemplateFingerprint = (Get-FileHash -LiteralPath $Template -Algorithm SHA256).Hash
$ConfigText = Get-Content -LiteralPath $Template -Raw
if ((Get-FileHash -LiteralPath $Template -Algorithm SHA256).Hash -ne $TemplateFingerprint) {
    throw "Recompiler configuration changed during setup; retry."
}
if ($null -ne $Vu1CapturePath) {
    $ConfigText += "vu1_capture`t$Vu1CapturePath`n"
}
$ConfigText += "disc`t$ImagePath`n"
[System.IO.File]::WriteAllText($RecompConfig, $ConfigText)
$ConfigFingerprint = (Get-FileHash -LiteralPath $RecompConfig -Algorithm SHA256).Hash
Invoke-Checked $Recompiler @($RecompConfig)
Write-FrameworkGenerationProvenance -Root $Root -Lock $Lock `
    -ExpectedPatchFingerprint $FrameworkPatchFingerprint `
    -ExpectedTemplateFingerprint $TemplateFingerprint `
    -ExpectedConfigFingerprint $ConfigFingerprint

$RuntimeData = Join-Path $LocalRoot "runtime"
New-Item -ItemType Directory -Force -Path $RuntimeData | Out-Null
$LocalText = "key`tvalue`nimage`t$ImagePath`ndata`t$RuntimeData`n" +
    "id`tSLPM-65405`nsystem`tps2`ncommit`t$($Lock.framework.commit)`n"
[System.IO.File]::WriteAllText((Join-Path $Root "local.tsv"), $LocalText)

if ($RecompileOnly) {
    $size = (
        Get-ChildItem -LiteralPath $Generated -Recurse -File |
            Measure-Object -Property Length -Sum
    ).Sum
    Write-Host ("Generated {0:N1} MiB in {1}" -f ($size / 1MB), $Generated)
    exit 0
}

$Game = Join-Path $Root "port\macross-recomp.exe"
Invoke-Checked $Odin @(
    "build",
    (Join-Path $Root "port\src"),
    "-collection:ps=$FrameworkPath",
    "-define:COMMIT=$($Lock.framework.commit)",
    "-define:ENV_PREFIX=MACROSS_",
    "-use-separate-modules",
    "-o:speed",
    "-out:$Game"
)

$OdinRoot = Split-Path -Parent $Odin
$Sdl = Join-Path $OdinRoot "vendor\sdl2\SDL2.dll"
if (-not (Test-Path -LiteralPath $Sdl)) {
    throw "The Odin distribution does not contain SDL2.dll: $Sdl"
}
Copy-Item -LiteralPath $Sdl -Destination (Join-Path $Root "port\SDL2.dll") -Force
Write-Host "Built $Game"

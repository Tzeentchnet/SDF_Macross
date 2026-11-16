[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Image,

    [switch]$RecompileOnly,

    [switch]$ExactDisc,

    [switch]$AllowPatchedImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Lock = Get-Content -LiteralPath (Join-Path $Root "recomp.lock.json") -Raw |
    ConvertFrom-Json
$ImagePath = (Resolve-Path -LiteralPath $Image).Path
$FrameworkPath = Join-Path $Root ".deps\ps-recomp"
$ToolRoot = Join-Path $Root ".tools"
$BuildRoot = Join-Path $Root ".build"
$LocalRoot = Join-Path $Root ".local"

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
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
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
        Invoke-Checked "git" @(
            "clone",
            "--filter=blob:none",
            "--no-checkout",
            $Lock.framework.repository,
            $FrameworkPath
        )
    }
    Invoke-Checked "git" @(
        "-C",
        $FrameworkPath,
        "fetch",
        "--depth",
        "1",
        "origin",
        $Lock.framework.commit
    )
    Invoke-Checked "git" @(
        "-C",
        $FrameworkPath,
        "checkout",
        "--detach",
        $Lock.framework.commit
    )
    $actual = (& git -C $FrameworkPath rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $Lock.framework.commit) {
        throw "Framework checkout mismatch: found $actual"
    }
}

$Python = (Get-Command python -ErrorAction Stop).Source
$VerifyArguments = @(
    (Join-Path $PSScriptRoot "inspect_game.py"),
    $ImagePath
)
if ($ExactDisc) {
    $VerifyArguments += "--exact"
}
if ($AllowPatchedImage) {
    $VerifyArguments += "--allow-patched"
}
Invoke-Checked $Python $VerifyArguments

Get-Framework
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
$ConfigText = Get-Content -LiteralPath (Join-Path $PSScriptRoot "recomp.tsv") -Raw
$ConfigText += "disc`t$ImagePath`n"
[System.IO.File]::WriteAllText($RecompConfig, $ConfigText)
Invoke-Checked $Recompiler @($RecompConfig)

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

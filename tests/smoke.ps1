[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Image,

    [ValidateRange(600, 10000000)]
    [int]$Frames = 600,

    [ValidateRange(1, 86400)]
    [int]$SetupTimeoutSeconds = 1800,

    [ValidateRange(1, 86400)]
    [int]$RunTimeoutSeconds = 600,

    [Parameter(DontShow = $true)]
    [ValidateSet("Setup", "Run")]
    [string]$ChildStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

if ($ChildStage) {
    if ([Console]::In.ReadLine() -cne "MACROSS_SMOKE_START") {
        throw "The smoke child was not started by its process supervisor."
    }
    $global:LASTEXITCODE = $null
    if ($ChildStage -ceq "Setup") {
        & (Join-Path $Root "tools\setup.ps1") -Image $Image -ExactDisc
    }
    else {
        & (Join-Path $Root "tools\run.ps1") -Headless -Scale 1 -Frames $Frames
    }
    if ($null -eq $global:LASTEXITCODE) {
        throw "The smoke stage returned without an exit code."
    }
    exit $global:LASTEXITCODE
}

if ($env:OS -cne "Windows_NT" -or [IntPtr]::Size -ne 8) {
    throw "Missing prerequisite: 64-bit Windows PowerShell."
}
try {
    if (-not (Test-Path -LiteralPath $Image -PathType Leaf)) {
        throw "Image not found."
    }
    $ImagePath = (Resolve-Path -LiteralPath $Image -ErrorAction Stop).Path
}
catch {
    throw "Missing prerequisite: the original disc image must be an existing file."
}

foreach ($file in @(
    "recomp.lock.json", "tools\setup.ps1", "tools\run.ps1",
    "tools\setup-verification.ps1", "tools\smoke-process.ps1",
    "tests\_smoke_assertions.ps1"
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $file) -PathType Leaf)) {
        throw "Missing prerequisite: repository file $file."
    }
}
foreach ($command in @("python", "git")) {
    if (-not (Get-Command $command -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "Missing prerequisite: $command must be available on PATH."
    }
}
if (-not $env:WINDIR -or -not (Test-Path -LiteralPath (
    Join-Path $env:WINDIR "System32\vulkan-1.dll"
) -PathType Leaf)) {
    throw "Missing prerequisite: the Windows Vulkan loader and a Vulkan-capable driver."
}

$LockPath = Join-Path $Root "recomp.lock.json"
try {
    $Lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $Commit = $Lock.framework.commit
    if ($Commit -isnot [string] -or $Commit -cnotmatch '^[0-9a-f]{40}$') {
        throw "Invalid commit."
    }
}
catch {
    throw "Missing or invalid prerequisite: the pinned framework commit in recomp.lock.json."
}
$PowerShell = if ($PSVersionTable.PSEdition -ceq "Desktop") {
    Join-Path $PSHOME "powershell.exe"
}
else {
    Join-Path $PSHOME "pwsh.exe"
}
if (-not (Test-Path -LiteralPath $PowerShell -PathType Leaf)) {
    throw "Missing prerequisite: the current PowerShell executable."
}

. (Join-Path $Root "tools\smoke-process.ps1")
. (Join-Path $PSScriptRoot "_smoke_assertions.ps1")

$CommonArguments = @(
    "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-File", $PSCommandPath, "-Image", $ImagePath, "-Frames", [string]$Frames
)

Write-Host "Running pinned setup with exact-disc verification and the full build..."
$setup = Invoke-SmokeChild -PowerShell $PowerShell -WorkingDirectory $Root `
    -Arguments ($CommonArguments + @("-ChildStage", "Setup")) `
    -TimeoutSeconds $SetupTimeoutSeconds
if ($setup.TimedOut) {
    throw "Pinned setup timed out after $SetupTimeoutSeconds seconds; its process tree was stopped."
}
if ($setup.ExitCode -ne 0) {
    throw (("Pinned setup failed with exit code {0}. Run tools\setup.ps1 directly for diagnostics; " +
        "captured setup output is withheld because it can contain the image path.") -f $setup.ExitCode)
}

Write-Host "Running headless Vulkan at scale 1 for at least $Frames frames..."
$run = Invoke-SmokeChild -PowerShell $PowerShell -WorkingDirectory $Root `
    -Arguments ($CommonArguments + @("-ChildStage", "Run")) `
    -TimeoutSeconds $RunTimeoutSeconds
if ($run.TimedOut) {
    throw "Headless run timed out after $RunTimeoutSeconds seconds; its process tree was stopped."
}
$result = Assert-SmokeLog -StdOut $run.StdOut -StdErr $run.StdErr -ExitCode $run.ExitCode `
    -ExpectedBuild $Commit -RequestedFrames $Frames

try {
    $FinalLock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($FinalLock.framework.commit -cne $Commit) { throw "Commit changed." }
}
catch {
    throw "recomp.lock.json changed or became invalid during the smoke test."
}

Write-Host "Vulkan device: $($result.VulkanDevice)"
Write-Host "Renderer: $($result.Renderer), scale $($result.Scale)"
Write-Host ("compat: system={0} result={1} build={2} frames={3} shown={4} fallback=false fatal=<empty>" -f `
    $result.System, $result.Result, $result.Build, $result.Frames, $result.Shown)
Write-Host "Frame limit: $($result.Frames) reached"
Write-Host "SMOKE PASS"

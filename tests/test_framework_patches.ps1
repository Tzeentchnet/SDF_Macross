[CmdletBinding()]
param()

# Run with PowerShell 5.1 or 7; all Git fixtures live under patches\ps-recomp,
# never the real .deps checkout. Setup/build integration runs when Odin exists.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepositoryRoot "tools\framework-patches.ps1")
$TestRoot = Join-Path $RepositoryRoot (
    "patches\ps-recomp\.framework-tests-" + [guid]::NewGuid().ToString("N")
)
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Passed = 0
$Failures = @()

function Write-TestText {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Invoke-TestGit {
    param([string]$Repository, [string[]]$Arguments)
    $result = Invoke-FrameworkGit -Arguments (@("-C", $Repository) + $Arguments)
    if ($result.ExitCode -ne 0) {
        throw "Test Git command failed: $($Arguments -join ' ')$(Get-FrameworkGitError $result)"
    }
    return $result.StdOut
}

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Operation, [string]$Pattern)
    $message = $null
    try {
        & $Operation
    }
    catch {
        $message = $_.Exception.Message
    }
    if (-not $message) {
        throw "Expected an error matching '$Pattern'."
    }
    if ($message -notmatch $Pattern) {
        throw "Expected error matching '$Pattern'; received: $message"
    }
}

function New-Fixture {
    param(
        [string]$Name,
        [switch]$Dependent,
        [switch]$UnicodeName,
        [switch]$ZeroContext
    )

    $root = Join-Path $TestRoot $Name
    $framework = Join-Path $root "framework checkout"
    $patchDir = Join-Path $root "patches\ps-recomp"
    $generated = Join-Path $root "port\src\rec"
    [void](New-Item -ItemType Directory -Force -Path $framework, $patchDir,
        (Join-Path $generated "p00"), (Join-Path $root "tools"), (Join-Path $root ".build"))
    [void](Invoke-TestGit $framework @("init", "--quiet"))
    [void](Invoke-TestGit $framework @("config", "user.name", "Patch Test"))
    [void](Invoke-TestGit $framework @("config", "user.email", "patch-test@example.invalid"))
    [void](Invoke-TestGit $framework @("config", "core.autocrlf", "false"))
    [void](Invoke-TestGit $framework @("config", "commit.gpgsign", "false"))
    $alphaName = if ($UnicodeName) { "alpha [literal] $([char]0x00E9).txt" } else { "alpha.txt" }
    $alpha = Join-Path $framework $alphaName
    $beta = Join-Path $framework "beta.txt"
    Write-TestText $alpha "header`nalpha-base`ntail`n"
    Write-TestText $beta "header`nbeta-base`ntail`n"
    [void](Invoke-TestGit $framework @("add", "--all"))
    [void](Invoke-TestGit $framework @("-c", "core.hooksPath=", "commit", "--quiet", "-m", "base"))
    $commit = (Invoke-TestGit $framework @("rev-parse", "HEAD")).Trim()

    $patch1 = Join-Path $patchDir "0001-first.patch"
    $patch2 = Join-Path $patchDir "0002-second.patch"
    $diffArguments = @("diff", "--binary", "--full-index")
    if ($ZeroContext) { $diffArguments += "--unified=0" }
    $diffArguments += "--"
    Write-TestText (Join-Path $patchDir "series") "0001-first.patch`n0002-second.patch`n"
    Write-TestText $alpha "header`nalpha-first`ntail`n"
    Write-TestText $patch1 (Invoke-TestGit $framework $diffArguments)
    [void](Invoke-TestGit $framework @("add", "--all"))
    $expectedAlpha = "header`nalpha-first`ntail`n"
    if ($Dependent) {
        $expectedAlpha = "header`nalpha-second`ntail`n"
        Write-TestText $alpha $expectedAlpha
    }
    Write-TestText $beta "header`nbeta-second`ntail`n"
    Write-TestText $patch2 (Invoke-TestGit $framework $diffArguments)
    [void](Invoke-TestGit $framework @("reset", "--hard", "--quiet", "HEAD"))

    Write-TestText (Join-Path $root "tools\recomp.tsv") "key`tvalue`nbackend`tr5900`n"
    Write-TestText (Join-Path $root ".build\recomp.tsv") "key`tvalue`nbackend`tr5900`ndisc`tfixture.iso`n"
    Write-TestText (Join-Path $root "local.tsv") "key`tvalue`ncommit`t$commit`n"
    Write-TestText (Join-Path $generated "all.odin") "// Generated`npackage rec`n"
    Write-TestText (Join-Path $generated "p00\part.odin") "package p00`n"

    return [pscustomobject]@{
        Root = $root
        Framework = $framework
        PatchDirectory = $patchDir
        Patch1 = $patch1
        Patch2 = $patch2
        Alpha = $alpha
        Beta = $beta
        ExpectedAlpha = $expectedAlpha
        Lock = [pscustomobject]@{ framework = [pscustomobject]@{ commit = $commit } }
    }
}

function Get-FixtureSnapshot {
    param($Fixture)
    $entries = @(
        (Invoke-TestGit $Fixture.Framework @("rev-parse", "HEAD")).Trim()
        (Invoke-TestGit $Fixture.Framework @("status", "--porcelain=v1", "--untracked-files=all"))
        (Get-FileHash -LiteralPath (Join-Path $Fixture.Framework ".git\index") -Algorithm SHA256).Hash
    )
    foreach ($path in @(
        $Fixture.Alpha, $Fixture.Beta, (Join-Path $Fixture.Framework "unexpected.txt")
    )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $entries += (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
        else {
            $entries += "<missing>"
        }
    }
    return $entries -join "`n"
}

function Assert-FixtureUnchanged {
    param($Fixture, [scriptblock]$Operation, [string]$Pattern)
    $before = Get-FixtureSnapshot $Fixture
    Assert-Throws $Operation $Pattern
    $after = Get-FixtureSnapshot $Fixture
    Assert-Test ($before -ceq $after) "Rejected patching changed the framework checkout or index."
}

function Assert-FixtureApplied {
    param($Fixture)
    $alpha = [System.IO.File]::ReadAllText($Fixture.Alpha).Replace("`r`n", "`n")
    $beta = [System.IO.File]::ReadAllText($Fixture.Beta).Replace("`r`n", "`n")
    Assert-Test ($alpha -ceq $Fixture.ExpectedAlpha) "First or dependent patch was not applied."
    Assert-Test ($beta -ceq "header`nbeta-second`ntail`n") "Second patch was not applied."
    $index = Invoke-TestGit $Fixture.Framework @("diff", "--cached", "--quiet", "HEAD", "--")
    Assert-Test ([string]::IsNullOrWhiteSpace($index)) "Patching changed the real Git index."
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures += "${Name}: $($_.Exception.Message)"
        Write-Host "FAIL ${Name}: $($_.Exception.Message)"
    }
}

try {
    [void](New-Item -ItemType Directory -Path $TestRoot)

    Invoke-Case "repository patch payload whitespace" {
        foreach ($patch in @(Get-FrameworkPatchSet -Root $RepositoryRoot)) {
            $bytes = [System.IO.File]::ReadAllBytes($patch.FullName)
            if ([System.Array]::IndexOf($bytes, [byte]13) -ge 0) {
                throw "Patch $($patch.Name) must use LF line endings."
            }
            # --no-index checks these files even when they are still untracked.
            $result = Invoke-FrameworkGit -Arguments @(
                "-c", "core.autocrlf=false", "diff", "--no-index", "--check", "--", "NUL", $patch.FullName
            )
            if ($result.ExitCode -ne 1 -or $result.StdOut.Trim() -or
                $result.StdErr -match '(?im)^(fatal|error):') {
                throw "Patch $($patch.Name) fails git diff --check$(Get-FrameworkGitError $result)"
            }
        }
    }

    Invoke-Case "patch payloads stay LF on Windows checkout" {
        $repo = Join-Path $TestRoot "patch-checkout"
        $patchDir = Join-Path $repo "patches\ps-recomp"
        [void](New-Item -ItemType Directory -Force -Path $patchDir)
        [void](Invoke-TestGit $repo @("init", "--quiet"))
        [void](Invoke-TestGit $repo @("config", "user.name", "Patch Test"))
        [void](Invoke-TestGit $repo @("config", "user.email", "patch-test@example.invalid"))
        [void](Invoke-TestGit $repo @("config", "core.autocrlf", "true"))
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot "patches\ps-recomp\.gitattributes") -Destination $patchDir
        foreach ($patch in @(Get-FrameworkPatchSet -Root $RepositoryRoot)) {
            Copy-Item -LiteralPath $patch.FullName -Destination $patchDir
        }
        [void](Invoke-TestGit $repo @("add", "--all"))
        [void](Invoke-TestGit $repo @("-c", "core.hooksPath=", "-c", "commit.gpgsign=false",
            "commit", "--quiet", "-m", "patch checkout fixture"))
        Get-ChildItem -LiteralPath $patchDir -File -Filter "*.patch" | Remove-Item -Force
        [void](Invoke-TestGit $repo @("checkout", "--force", "HEAD", "--", "patches\ps-recomp"))
        foreach ($patch in @(Get-ChildItem -LiteralPath $patchDir -File -Filter "*.patch")) {
            $bytes = [System.IO.File]::ReadAllBytes($patch.FullName)
            Assert-Test ([System.Array]::IndexOf($bytes, [byte]13) -lt 0) `
                "Git converted $($patch.Name) to CRLF."
        }
    }

    Invoke-Case "clean and already applied" {
        $f = New-Fixture "clean"
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-FixtureApplied $f
        $before = Get-FixtureSnapshot $f
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-Test ($before -ceq (Get-FixtureSnapshot $f)) "A second invocation was not idempotent."
    }

    Invoke-Case "dependent patches and Unicode paths" {
        $f = New-Fixture "dependent" -Dependent -UnicodeName
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-FixtureApplied $f
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
    }

    Invoke-Case "zero-context patches" {
        $f = New-Fixture "zero-context" -Dependent -ZeroContext
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-FixtureApplied $f
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
    }

    Invoke-Case "ordered prefix" {
        $f = New-Fixture "prefix" -Dependent
        [void](Invoke-TestGit $f.Framework @("apply", "--", $f.Patch1))
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-FixtureApplied $f
    }

    Invoke-Case "missing directory" {
        $f = New-Fixture "missing-directory"
        Remove-Item -LiteralPath $f.PatchDirectory -Recurse -Force
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "patch directory is missing"
    }

    Invoke-Case "missing manifest" {
        $f = New-Fixture "missing-manifest"
        Remove-Item -LiteralPath (Join-Path $f.PatchDirectory "series")
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "manifest is missing"
    }

    Invoke-Case "empty manifest" {
        $f = New-Fixture "empty-manifest"
        Write-TestText (Join-Path $f.PatchDirectory "series") "`n # no patches`n"
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "series is empty"
    }

    Invoke-Case "empty patch" {
        $f = New-Fixture "empty-patch"
        Write-TestText $f.Patch1 ""
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "patch is empty"
    }

    Invoke-Case "missing listed patch" {
        $f = New-Fixture "missing-patch"
        Remove-Item -LiteralPath $f.Patch2
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "patch listed in series is missing"
    }

    Invoke-Case "unlisted patch" {
        $f = New-Fixture "extra-patch"
        Write-TestText (Join-Path $f.PatchDirectory "0003-extra.patch") "unexpected`n"
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "not listed"
    }

    Invoke-Case "reordered manifest" {
        $f = New-Fixture "reordered-manifest"
        Write-TestText (Join-Path $f.PatchDirectory "series") "0002-second.patch`n0001-first.patch`n"
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "numbered consecutively in order"
    }

    Invoke-Case "numbering gap" {
        $f = New-Fixture "numbering-gap"
        Move-Item -LiteralPath $f.Patch2 -Destination (Join-Path $f.PatchDirectory "0003-second.patch")
        Write-TestText (Join-Path $f.PatchDirectory "series") "0001-first.patch`n0003-second.patch`n"
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "numbered consecutively in order"
    }

    Invoke-Case "later patch conflict preflight is atomic" {
        $f = New-Fixture "bad-later-patch"
        $text = [System.IO.File]::ReadAllText($f.Patch2).Replace("-beta-base", "-not-the-base")
        Write-TestText $f.Patch2 $text
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "patch 0002-second.patch conflicts"
    }

    Invoke-Case "conflicting working tree" {
        $f = New-Fixture "conflict"
        Write-TestText $f.Alpha "not the pinned file`n"
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "unrecognized changes"
    }

    Invoke-Case "out-of-order applied patch" {
        $f = New-Fixture "out-of-order"
        [void](Invoke-TestGit $f.Framework @("apply", "--", $f.Patch2))
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "out-of-order"
    }

    Invoke-Case "unrelated edit after applied patches" {
        $f = New-Fixture "extra-edit"
        [void](Invoke-TestGit $f.Framework @("apply", "--", $f.Patch1))
        [void](Invoke-TestGit $f.Framework @("apply", "--", $f.Patch2))
        [System.IO.File]::AppendAllText($f.Alpha, "unrelated edit`n", $Utf8)
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "unrecognized changes"
    }

    Invoke-Case "untracked file" {
        $f = New-Fixture "untracked"
        Write-TestText (Join-Path $f.Framework "unexpected.txt") "unexpected`n"
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "unrecognized changes"
    }

    Invoke-Case "staged change" {
        $f = New-Fixture "staged"
        [void](Invoke-TestGit $f.Framework @("apply", "--", $f.Patch1))
        [void](Invoke-TestGit $f.Framework @("add", "--", "alpha.txt"))
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "staged changes"
    }

    Invoke-Case "wrong pinned HEAD" {
        $f = New-Fixture "wrong-head"
        [void](Invoke-TestGit $f.Framework @("-c", "core.hooksPath=", "commit", "--quiet", "--allow-empty", "-m", "other"))
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "expected"
    }

    Invoke-Case "CRLF checkout" {
        $f = New-Fixture "crlf"
        [void](Invoke-TestGit $f.Framework @("config", "core.autocrlf", "true"))
        foreach ($path in @($f.Alpha, $f.Beta)) {
            $content = [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n").Replace("`n", "`r`n")
            Write-TestText $path $content
        }
        Assert-Test ([System.IO.File]::ReadAllText($f.Alpha).Contains("`r`n")) "Fixture is not CRLF."
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-FixtureApplied $f
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
    }

    Invoke-Case "rollback after an unexpected partial write" {
        $f = New-Fixture "rollback"
        $realGit = (Get-Command Invoke-FrameworkGit -CommandType Function).ScriptBlock
        function Invoke-FrameworkGit {
            param([string[]]$Arguments, [hashtable]$Environment = @{}, [string]$OutputPath)
            if ($Arguments -contains "apply" -and $Arguments -notcontains "--check" -and
                $Arguments -notcontains "--cached" -and $Arguments[-1] -like "*combined.patch") {
                $partial = & $realGit -Arguments @("-C", $f.Framework, "apply", "--", $f.Patch1)
                if ($partial.ExitCode -ne 0) { throw "Could not simulate a partial write." }
                return [pscustomobject]@{ ExitCode = 1; StdOut = ""; StdErr = "simulated write failure" }
            }
            return (& $realGit @PSBoundParameters)
        }
        Assert-FixtureUnchanged $f {
            Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        } "simulated write failure"
    }

    Invoke-Case "new file is a recognized patched state" {
        $f = New-Fixture "new-file"
        $newFile = Join-Path $f.Framework "new $([char]0x00E9).txt"
        Write-TestText $newFile "new file`n"
        [void](Invoke-TestGit $f.Framework @("add", "--intent-to-add", "--", (Split-Path -Leaf $newFile)))
        Write-TestText $f.Patch2 (Invoke-TestGit $f.Framework @("diff", "--binary", "--full-index", "--"))
        [void](Invoke-TestGit $f.Framework @("reset", "--hard", "--quiet", "HEAD"))
        if (Test-Path -LiteralPath $newFile) { Remove-Item -LiteralPath $newFile -Force }
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-Test (Test-Path -LiteralPath $newFile -PathType Leaf) "New patch file was not created."
        $before = Get-FixtureSnapshot $f
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-Test ($before -ceq (Get-FixtureSnapshot $f)) "New-file patch was not idempotent."
    }

    Invoke-Case "ignored patch-added file" {
        $f = New-Fixture "ignored-added-file"
        Write-TestText (Join-Path $f.Framework ".gitignore") "ignored/`n"
        [void](Invoke-TestGit $f.Framework @("add", "--", ".gitignore"))
        [void](Invoke-TestGit $f.Framework @("-c", "core.hooksPath=", "commit", "--quiet", "-m", "ignore fixture"))
        $f.Lock.framework.commit = (Invoke-TestGit $f.Framework @("rev-parse", "HEAD")).Trim()
        $ignoredDir = Join-Path $f.Framework "ignored"
        [void](New-Item -ItemType Directory -Path $ignoredDir)
        $newFile = Join-Path $ignoredDir "added.txt"
        Write-TestText $newFile "patch-owned file`n"
        [void](Invoke-TestGit $f.Framework @("add", "--force", "--intent-to-add", "--", "ignored\added.txt"))
        Write-TestText $f.Patch2 (Invoke-TestGit $f.Framework @("diff", "--binary", "--full-index", "--"))
        [void](Invoke-TestGit $f.Framework @("reset", "--hard", "--quiet", "HEAD"))
        if (Test-Path -LiteralPath $newFile) { Remove-Item -LiteralPath $newFile -Force }
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-Test (Test-Path -LiteralPath $newFile -PathType Leaf) "Ignored patch file was not created."
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
    }

    Invoke-Case "binary patch" {
        $f = New-Fixture "binary"
        $binary = Join-Path $f.Framework "data.bin"
        [System.IO.File]::WriteAllBytes($binary, [byte[]]@(0, 1, 2, 3, 4))
        [void](Invoke-TestGit $f.Framework @("add", "--", "data.bin"))
        [void](Invoke-TestGit $f.Framework @("-c", "core.hooksPath=", "commit", "--quiet", "-m", "binary fixture"))
        $f.Lock.framework.commit = (Invoke-TestGit $f.Framework @("rev-parse", "HEAD")).Trim()
        [System.IO.File]::WriteAllBytes($binary, [byte[]]@(0, 9, 8, 7, 6, 5))
        Write-TestText $f.Patch2 (Invoke-TestGit $f.Framework @("diff", "--binary", "--full-index", "--"))
        [void](Invoke-TestGit $f.Framework @("reset", "--hard", "--quiet", "HEAD"))
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
        Assert-Test (([System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($binary))) -ceq "00-09-08-07-06-05") `
            "Binary patch bytes do not match."
        Invoke-FrameworkPatches -Root $f.Root -FrameworkPath $f.Framework -Lock $f.Lock
    }

    Invoke-Case "provenance and stale inputs" {
        $f = New-Fixture "provenance"
        $fingerprint = Get-FrameworkPatchFingerprint -Root $f.Root
        Write-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock -ExpectedPatchFingerprint $fingerprint
        Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock

        $source = Join-Path $f.Root "port\src\rec\p00\part.odin"
        Write-TestText $source "package changed`n"
        Assert-Throws { Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock } "missing or has changed"
        Write-TestText $source "package p00`n"

        $template = Join-Path $f.Root "tools\recomp.tsv"
        $expectedTemplate = (Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash
        Write-TestText $template "changed`n"
        Assert-Throws { Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock } "recompiler configuration"
        Assert-Throws {
            Write-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock -ExpectedTemplateFingerprint $expectedTemplate
        } "configuration changed during source generation"
        Write-TestText $template "key`tvalue`nbackend`tr5900`n"

        $config = Join-Path $f.Root ".build\recomp.tsv"
        $expectedConfig = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
        Write-TestText $config "different disc`n"
        Assert-Throws { Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock } "does not match"
        Assert-Throws {
            Write-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock -ExpectedConfigFingerprint $expectedConfig
        } "configuration changed during source generation"
        Write-TestText $config "key`tvalue`nbackend`tr5900`ndisc`tfixture.iso`n"

        [System.IO.File]::AppendAllText($f.Patch2, "`n", $Utf8)
        Assert-Throws { Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock } "patch series"
        Assert-Throws {
            Write-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock -ExpectedPatchFingerprint $fingerprint
        } "patches changed during source generation"
    }

    Invoke-Case "legacy provenance is compatible but diagnosed" {
        $f = New-Fixture "legacy"
        $warnings = @(Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock 3>&1)
        Assert-Test (($warnings | Out-String) -match "provenance is missing") "Missing provenance was not diagnosed."
        Write-TestText (Join-Path $f.Root "local.tsv") "key`tvalue`ncommit`t$(([string]'0') * 40)`n"
        Assert-Throws { Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock } "records framework"
        Remove-Item -LiteralPath (Join-Path $f.Root "local.tsv")
        $warnings = @(Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock 3>&1)
        Assert-Test (($warnings | Out-String) -match "provenance is missing") "Missing legacy metadata was not diagnosed."
    }

    Invoke-Case "missing generated config remains compatible" {
        $f = New-Fixture "missing-generated-config"
        Write-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock
        Remove-Item -LiteralPath (Join-Path $f.Root ".build\recomp.tsv")
        $warnings = @(Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock 3>&1)
        Assert-Test (($warnings | Out-String) -match "configuration.*missing") "Missing config was not diagnosed."
    }

    Invoke-Case "corrupt provenance is rejected" {
        $f = New-Fixture "bad-provenance"
        Write-TestText (Join-Path $f.Root "port\src\rec\.framework-provenance.json") "{"
        Assert-Throws { Assert-FrameworkGenerationProvenance -Root $f.Root -Lock $f.Lock } "provenance is unreadable"
    }

    $actualLock = Get-Content -LiteralPath (Join-Path $RepositoryRoot "recomp.lock.json") -Raw | ConvertFrom-Json
    $odinDist = Join-Path $RepositoryRoot ".tools\$($actualLock.odin.tag)\dist"
    if ((Test-Path -LiteralPath (Join-Path $odinDist "odin.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $odinDist "vendor\sdl2\SDL2.dll") -PathType Leaf)) {
        Invoke-Case "fresh setup and repeated incremental builds" {
            $f = New-Fixture "setup-build"
            $recompiler = Join-Path $f.Framework "recomp"
            [void](New-Item -ItemType Directory -Path $recompiler)
            $markerSource = Join-Path $recompiler "flags.odin"
            Write-TestText $markerSource "package main`n"
            Write-TestText (Join-Path $recompiler "main.odin") @'
package main
import "core:os"
main :: proc() {
    patch_marker()
    if err := os.make_directory_all("port\\src\\rec"); err != nil && err != .Exist {os.exit(1)}
    if os.write_entire_file("port\\src\\rec\\all.odin", string("package rec\n")) != nil {os.exit(1)}
}
'@
            [void](Invoke-TestGit $f.Framework @("add", "--", "recomp"))
            [void](Invoke-TestGit $f.Framework @("-c", "core.hooksPath=", "commit", "--quiet", "-m", "recompiler fixture"))
            $f.Lock.framework.commit = (Invoke-TestGit $f.Framework @("rev-parse", "HEAD")).Trim()

            Write-TestText $f.Alpha $f.ExpectedAlpha
            Write-TestText $markerSource "package main`npatch_marker :: proc() {}`n"
            Write-TestText $f.Patch1 (Invoke-TestGit $f.Framework @("diff", "--binary", "--full-index", "--"))
            [void](Invoke-TestGit $f.Framework @("add", "--all"))
            Write-TestText $f.Beta "header`nbeta-second`ntail`n"
            Write-TestText $f.Patch2 (Invoke-TestGit $f.Framework @("diff", "--binary", "--full-index", "--"))
            [void](Invoke-TestGit $f.Framework @("reset", "--hard", "--quiet", "HEAD"))

            foreach ($script in @(
                "setup.ps1",
                "setup-verification.ps1",
                "build.ps1",
                "framework-patches.ps1"
            )) {
                Copy-Item -LiteralPath (Join-Path $RepositoryRoot "tools\$script") `
                    -Destination (Join-Path $f.Root "tools\$script")
            }
            Write-TestText (Join-Path $f.Root "tools\inspect_game.py") "print('fixture image verified')`n"
            Write-TestText (Join-Path $f.Root "port\src\main.odin") "package main`nmain :: proc() {}`n"
            $image = Join-Path $f.Root "fixture.iso"
            $capture = Join-Path $f.Root "VU1 capture.bin"
            Write-TestText $image "synthetic fixture`n"
            Write-TestText $capture "synthetic VU1 capture`n"
            $fixtureLock = [ordered]@{
                framework = @{ repository = $f.Framework; commit = $f.Lock.framework.commit }
                odin = @{ tag = "fixture"; asset = "unused.zip"; url = "unused"; sha256 = "unused" }
            }
            Write-TestText (Join-Path $f.Root "recomp.lock.json") ($fixtureLock | ConvertTo-Json -Depth 4)

            $toolParent = Join-Path $f.Root ".tools\fixture"
            $junction = Join-Path $toolParent "dist"
            $scratch = Join-Path $f.Root "work"
            [void](New-Item -ItemType Directory -Force -Path $toolParent, $scratch)
            $oldTemp, $oldTmp, $oldNoBytecode = $env:TEMP, $env:TMP, $env:PYTHONDONTWRITEBYTECODE
            try {
                [void](New-Item -ItemType Junction -Path $junction -Target $odinDist)
                $env:TEMP, $env:TMP, $env:PYTHONDONTWRITEBYTECODE = $scratch, $scratch, "1"
                & (Join-Path $f.Root "tools\setup.ps1") -Image $image -Vu1Capture $capture 2>&1 |
                    ForEach-Object { Write-Host $_ }
                Assert-Test (Test-Path -LiteralPath (Join-Path $f.Root "port\src\rec\.framework-provenance.json")) `
                    "Fresh setup did not record generated-source provenance."
                Assert-Test (Test-Path -LiteralPath (Join-Path $f.Root "port\macross-recomp.exe")) `
                    "Fresh setup did not build the fixture port."
                $config = [System.IO.File]::ReadAllText((Join-Path $f.Root ".build\recomp.tsv"))
                Assert-Test ($config.Contains("vu1_capture`t$([System.IO.Path]::GetFullPath($capture))`n")) `
                    "Setup did not add the resolved VU1 capture to the generated configuration."
                $checkout = Join-Path $f.Root ".deps\ps-recomp"
                Assert-Test ([System.IO.File]::ReadAllText((Join-Path $checkout "recomp\flags.odin")) -match "patch_marker") `
                    "Setup built before applying the framework patches."
                $indexBefore = (Get-FileHash -LiteralPath (Join-Path $checkout ".git\index") -Algorithm SHA256).Hash
                & (Join-Path $f.Root "tools\build.ps1") -Fast 2>&1 |
                    ForEach-Object { Write-Host $_ }
                & (Join-Path $f.Root "tools\build.ps1") -Fast 2>&1 |
                    ForEach-Object { Write-Host $_ }
                $indexAfter = (Get-FileHash -LiteralPath (Join-Path $checkout ".git\index") -Algorithm SHA256).Hash
                Assert-Test ($indexBefore -ceq $indexAfter) "Incremental builds changed the framework index."

                Write-TestText (Join-Path $f.Root "tools\inspect_game.py") "import sys`nsys.exit(17)`n"
                Assert-Throws {
                    & (Join-Path $f.Root "tools\setup.ps1") -Image $image 2>&1 |
                        ForEach-Object { Write-Host $_ }
                } "failed with exit code 17"
                Write-TestText (Join-Path $f.Root "port\src\main.odin") "not valid Odin`n"
                Assert-Throws {
                    & (Join-Path $f.Root "tools\build.ps1") -Fast 2>&1 |
                        ForEach-Object { Write-Host $_ }
                } "odin build failed with exit code"
            }
            finally {
                $env:TEMP, $env:TMP, $env:PYTHONDONTWRITEBYTECODE = $oldTemp, $oldTmp, $oldNoBytecode
                if (Test-Path -LiteralPath $junction) {
                    [System.IO.Directory]::Delete($junction)
                }
            }
        }
    }
    else {
        Write-Host "SKIP fresh setup and repeated incremental builds (local Odin is not installed)"
    }

    Write-Host "$Passed passed; $($Failures.Count) failed."
    if ($Failures.Count -gt 0) {
        throw ($Failures -join "`n")
    }
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}

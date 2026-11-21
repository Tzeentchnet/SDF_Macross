# patches\ps-recomp\series is the complete, consecutively numbered patch list.
# Validate it against the pinned commit in a separate Git index/object store.
# Only an exact, ordered prefix is acceptable; unrelated tracked or untracked
# changes conflict. Ignored build artifacts remain untouched.

function ConvertTo-FrameworkNativeArgument {
    param([AllowEmptyString()] [string]$Argument)

    # ProcessStartInfo.Arguments uses Windows command-line quoting, including
    # doubled backslashes before quotes and at the end of a quoted argument.
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-FrameworkGit {
    param(
        [Parameter(Mandatory = $true)] [string[]]$Arguments,
        [hashtable]$Environment = @{},
        [string]$OutputPath
    )

    # Process rather than PowerShell's native-command pipeline keeps Git's
    # expected stderr diagnostics non-terminating in both PowerShell 5.1 and 7.
    $git = (Get-Command git -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $git
    $quoted = @("--no-pager") + $Arguments | ForEach-Object {
        ConvertTo-FrameworkNativeArgument $_
    }
    $start.Arguments = $quoted -join " "
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    # Do not let a caller's Git environment silently select another checkout,
    # object store, or index. The isolated preflight opts in below.
    foreach ($name in @(
        "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_PREFIX", "GIT_NAMESPACE", "GIT_QUARANTINE_PATH"
    )) {
        [void]$start.EnvironmentVariables.Remove($name)
    }
    $start.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0"
    $start.EnvironmentVariables["GIT_OPTIONAL_LOCKS"] = "0"
    foreach ($entry in $Environment.GetEnumerator()) {
        $start.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $outputStream = $null
    try {
        [void]$process.Start()
        if ($OutputPath) {
            $outputStream = [System.IO.File]::Open(
                $OutputPath, [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None
            )
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($outputStream)
        }
        else {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdoutTask.Wait()
        $stderrTask.Wait()
        $stdout = ""
        if (-not $OutputPath) {
            $stdout = $stdoutTask.Result
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderrTask.Result
        }
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        $process.Dispose()
    }
}

function Get-FrameworkGitError {
    param($Result)

    $details = ($Result.StdErr + "`n" + $Result.StdOut).Trim()
    if ($details) {
        return ": $details"
    }
    return ""
}

function Get-FrameworkPatchSet {
    param([Parameter(Mandatory = $true)] [string]$Root)

    $patchDir = Join-Path $Root "patches\ps-recomp"
    $series = Join-Path $patchDir "series"
    if (-not (Test-Path -LiteralPath $patchDir -PathType Container)) {
        throw "Framework patch directory is missing: $patchDir"
    }
    if (-not (Test-Path -LiteralPath $series -PathType Leaf)) {
        throw "Framework patch series manifest is missing: $series"
    }

    $names = @(
        Get-Content -LiteralPath $series -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#")) { $line }
        }
    )
    if ($names.Count -eq 0) {
        throw "Framework patch series is empty: $series"
    }
    $files = @(Get-ChildItem -LiteralPath $patchDir -File -Force -Filter "*.patch")
    $patches = @()
    for ($i = 0; $i -lt $names.Count; $i++) {
        $name = $names[$i]
        $match = [regex]::Match($name, '^(?<number>[0-9]{4})-[A-Za-z0-9][A-Za-z0-9._-]*\.patch$')
        $expectedNumber = "{0:D4}" -f ($i + 1)
        if (-not $match.Success -or $match.Groups["number"].Value -cne $expectedNumber) {
            throw "Framework patch series must be numbered consecutively in order; invalid entry: $name"
        }
        $matching = @($files | Where-Object { $_.Name -ceq $name })
        if ($matching.Count -ne 1) {
            throw "Framework patch listed in series is missing: $name"
        }
        if ($matching[0].Length -eq 0) {
            throw "Framework patch is empty: $name"
        }
        $patches += $matching[0]
    }
    foreach ($file in $files) {
        if ($names -cnotcontains $file.Name) {
            throw "Framework patch is not listed in the ordered series: $($file.Name)"
        }
    }
    return $patches
}

function Get-FrameworkTextHash {
    param([Parameter(Mandatory = $true)] [string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FrameworkPatchFingerprint {
    param([Parameter(Mandatory = $true)] [string]$Root)

    $entries = foreach ($patch in @(Get-FrameworkPatchSet -Root $Root)) {
        $hash = (Get-FileHash -LiteralPath $patch.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$($patch.Name)`t$hash`n"
    }
    return Get-FrameworkTextHash -Text ($entries -join "")
}

function Get-FrameworkWorktreeTree {
    param(
        [string]$FrameworkPath,
        [string]$Commit,
        [string]$ObjectDirectory,
        [string]$IndexPath,
        [string[]]$PatchPaths = @()
    )

    $environment = @{
        GIT_OBJECT_DIRECTORY = $ObjectDirectory
        GIT_INDEX_FILE = $IndexPath
    }
    $result = Invoke-FrameworkGit -Arguments @(
        "-C", $FrameworkPath, "read-tree", "--reset", $Commit
    ) -Environment $environment
    if ($result.ExitCode -ne 0) {
        throw "Could not initialize the framework verification index$(Get-FrameworkGitError $result)"
    }
    $result = Invoke-FrameworkGit -Arguments @(
        "-C", $FrameworkPath, "-c", "core.safecrlf=false", "add", "--all", "--", "."
    ) -Environment $environment
    if ($result.ExitCode -ne 0) {
        throw "Could not inspect the framework working tree$(Get-FrameworkGitError $result)"
    }
    # A patch can add a path ignored by .gitignore. Include such paths when
    # recognizing a series state without admitting unrelated ignored files.
    $presentPaths = @(
        foreach ($path in $PatchPaths) {
            $localPath = Join-Path $FrameworkPath $path.Replace('/', '\')
            if (Test-Path -LiteralPath $localPath -PathType Leaf) { $path }
        }
    )
    if ($presentPaths.Count -gt 0) {
        $result = Invoke-FrameworkGit -Arguments (@(
            "-C", $FrameworkPath, "--literal-pathspecs", "-c", "core.safecrlf=false", "add", "--force", "--"
        ) + $presentPaths) -Environment $environment
        if ($result.ExitCode -ne 0) {
            throw "Could not inspect framework patch paths$(Get-FrameworkGitError $result)"
        }
    }
    $result = Invoke-FrameworkGit -Arguments @(
        "-C", $FrameworkPath, "write-tree"
    ) -Environment $environment
    if ($result.ExitCode -ne 0) {
        throw "Could not fingerprint the framework working tree$(Get-FrameworkGitError $result)"
    }
    return $result.StdOut.Trim()
}

function Backup-FrameworkPatchFiles {
    param(
        [string]$FrameworkPath,
        [string]$BackupDirectory,
        [string[]]$Paths
    )

    [void](New-Item -ItemType Directory -Path $BackupDirectory -Force)
    $root = [System.IO.Path]::GetFullPath($FrameworkPath).TrimEnd('\') + '\'
    $backups = @()
    for ($i = 0; $i -lt $Paths.Count; $i++) {
        $relative = $Paths[$i].Replace('/', '\')
        $path = [System.IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Framework patch refers to a path outside the checkout: $relative"
        }
        $exists = Test-Path -LiteralPath $path
        $backup = Join-Path $BackupDirectory ("{0:D6}" -f $i)
        $attributes = $null
        $lastWrite = $null
        if ($exists) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                throw "Cannot safely patch a directory or link: $path"
            }
            $attributes = $item.Attributes
            $lastWrite = $item.LastWriteTimeUtc
            [System.IO.File]::Copy($path, $backup)
        }
        $backups += [pscustomobject]@{
            Path = $path
            Backup = $backup
            Existed = $exists
            Attributes = $attributes
            LastWriteTimeUtc = $lastWrite
        }
    }
    return $backups
}

function Restore-FrameworkPatchFiles {
    param([object[]]$Backups)

    $errors = @()
    foreach ($entry in $Backups) {
        try {
            if ($entry.Existed) {
                [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $entry.Path))
                if ([System.IO.File]::Exists($entry.Path)) {
                    [System.IO.File]::SetAttributes($entry.Path, [System.IO.FileAttributes]::Normal)
                }
                [System.IO.File]::Copy($entry.Backup, $entry.Path, $true)
                [System.IO.File]::SetLastWriteTimeUtc($entry.Path, $entry.LastWriteTimeUtc)
                [System.IO.File]::SetAttributes($entry.Path, $entry.Attributes)
            }
            elseif ([System.IO.File]::Exists($entry.Path)) {
                [System.IO.File]::SetAttributes($entry.Path, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($entry.Path)
            }
        }
        catch {
            $errors += "$($entry.Path): $($_.Exception.Message)"
        }
    }
    return $errors
}

function Invoke-FrameworkPatches {
    param(
        [Parameter(Mandatory = $true)] [string]$Root,
        [Parameter(Mandatory = $true)] [string]$FrameworkPath,
        [Parameter(Mandatory = $true)] $Lock
    )

    $patches = @(Get-FrameworkPatchSet -Root $Root)
    $patchFingerprint = Get-FrameworkPatchFingerprint -Root $Root
    $commit = [string]$Lock.framework.commit
    if ($commit -notmatch '^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        throw "Framework lock must contain a full Git commit ID."
    }
    if (-not (Test-Path -LiteralPath $FrameworkPath -PathType Container)) {
        throw "Framework checkout is missing: $FrameworkPath"
    }
    $FrameworkPath = (Resolve-Path -LiteralPath $FrameworkPath).Path
    $result = Invoke-FrameworkGit -Arguments @("-C", $FrameworkPath, "rev-parse", "--show-toplevel")
    if ($result.ExitCode -ne 0) {
        throw "Framework checkout is not a Git worktree$(Get-FrameworkGitError $result)"
    }
    $top = [System.IO.Path]::GetFullPath($result.StdOut.Trim().Replace('/', '\')).TrimEnd('\')
    if (-not [string]::Equals($top, $FrameworkPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Framework path is not the root of its Git worktree: $FrameworkPath"
    }
    $result = Invoke-FrameworkGit -Arguments @("-C", $FrameworkPath, "rev-parse", "--verify", "HEAD^{commit}")
    $actualCommit = $result.StdOut.Trim()
    if ($result.ExitCode -ne 0 -or $actualCommit -ne $commit) {
        throw "Framework checkout is at $actualCommit, expected $commit$(Get-FrameworkGitError $result)"
    }
    $result = Invoke-FrameworkGit -Arguments @(
        "-C", $FrameworkPath, "diff", "--cached", "--quiet", "--no-ext-diff", $commit, "--"
    )
    if ($result.ExitCode -eq 1) {
        throw "Framework checkout has staged changes; only the ordered patch series may be present."
    }
    if ($result.ExitCode -ne 0) {
        throw "Could not inspect the framework index$(Get-FrameworkGitError $result)"
    }
    $result = Invoke-FrameworkGit -Arguments @("-C", $FrameworkPath, "rev-parse", "--git-path", "objects")
    if ($result.ExitCode -ne 0) {
        throw "Could not locate framework Git objects$(Get-FrameworkGitError $result)"
    }
    $originalObjects = $result.StdOut.Trim().Replace('/', '\')
    if (-not [System.IO.Path]::IsPathRooted($originalObjects)) {
        $originalObjects = Join-Path $FrameworkPath $originalObjects
    }
    $originalObjects = [System.IO.Path]::GetFullPath($originalObjects)
    if (-not (Test-Path -LiteralPath $originalObjects -PathType Container)) {
        throw "Framework Git object directory is missing: $originalObjects"
    }

    $patchDir = Join-Path $Root "patches\ps-recomp"
    $work = Join-Path $patchDir (".framework-check-" + [guid]::NewGuid().ToString("N"))
    $objects = Join-Path $work "objects"
    try {
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $objects "info"), (Join-Path $objects "pack"))
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $objects "info\alternates"), $originalObjects + "`n", $utf8)
        $seriesEnvironment = @{
            GIT_OBJECT_DIRECTORY = $objects
            GIT_INDEX_FILE = (Join-Path $work "series.index")
        }
        $result = Invoke-FrameworkGit -Arguments @(
            "-C", $FrameworkPath, "read-tree", $commit
        ) -Environment $seriesEnvironment
        if ($result.ExitCode -ne 0) {
            throw "Could not initialize framework patch preflight$(Get-FrameworkGitError $result)"
        }
        $result = Invoke-FrameworkGit -Arguments @(
            "-C", $FrameworkPath, "write-tree"
        ) -Environment $seriesEnvironment
        if ($result.ExitCode -ne 0) {
            throw "Could not read the pinned framework tree$(Get-FrameworkGitError $result)"
        }
        $states = @($result.StdOut.Trim())
        foreach ($patch in $patches) {
            $result = Invoke-FrameworkGit -Arguments @(
                "-C", $FrameworkPath, "apply", "--cached", "--check", "--unidiff-zero",
                "--ignore-whitespace", "--", $patch.FullName
            ) -Environment $seriesEnvironment
            if ($result.ExitCode -ne 0) {
                throw "Framework patch $($patch.Name) conflicts with the ordered series at $commit$(Get-FrameworkGitError $result)"
            }
            $result = Invoke-FrameworkGit -Arguments @(
                "-C", $FrameworkPath, "apply", "--cached", "--unidiff-zero",
                "--ignore-whitespace", "--", $patch.FullName
            ) -Environment $seriesEnvironment
            if ($result.ExitCode -ne 0) {
                throw "Could not preflight framework patch $($patch.Name)$(Get-FrameworkGitError $result)"
            }
            $result = Invoke-FrameworkGit -Arguments @(
                "-C", $FrameworkPath, "write-tree"
            ) -Environment $seriesEnvironment
            if ($result.ExitCode -ne 0) {
                throw "Could not fingerprint framework patch $($patch.Name)$(Get-FrameworkGitError $result)"
            }
            $tree = $result.StdOut.Trim()
            if ($states -ccontains $tree) {
                throw "Framework patch $($patch.Name) produces an empty or ambiguous series state."
            }
            $states += $tree
        }
        if ((Get-FrameworkPatchFingerprint -Root $Root) -cne $patchFingerprint) {
            throw "Framework patch series changed during preflight; retry the build."
        }

        $knownPaths = @{}
        for ($i = 1; $i -lt $states.Count; $i++) {
            $result = Invoke-FrameworkGit -Arguments @(
                "-C", $FrameworkPath, "diff", "--name-only", "--no-renames", "-z",
                $states[$i - 1], $states[$i], "--"
            ) -Environment $seriesEnvironment
            if ($result.ExitCode -ne 0) {
                throw "Could not enumerate framework patch paths$(Get-FrameworkGitError $result)"
            }
            foreach ($path in $result.StdOut.Split([char]0)) {
                if ($path.Length -gt 0) { $knownPaths[$path] = $true }
            }
        }
        $patchPaths = @($knownPaths.Keys)
        $actualTree = Get-FrameworkWorktreeTree -FrameworkPath $FrameworkPath -Commit $commit `
            -ObjectDirectory $objects -IndexPath (Join-Path $work "actual.index") -PatchPaths $patchPaths
        $prefix = -1
        for ($i = 0; $i -lt $states.Count; $i++) {
            if ($states[$i] -ceq $actualTree) {
                $prefix = $i
                break
            }
        }
        if ($prefix -lt 0) {
            $status = Invoke-FrameworkGit -Arguments @(
                "-C", $FrameworkPath, "status", "--short", "--untracked-files=all"
            )
            $details = if ($status.ExitCode -eq 0) { $status.StdOut.Trim() } else { "" }
            throw "Framework checkout has unrecognized changes or out-of-order patches; expected the pinned tree or an exact ordered patch prefix.`n$details"
        }

        for ($i = 0; $i -lt $prefix; $i++) {
            Write-Host "Already applied framework patch $($patches[$i].Name)"
        }
        if ($prefix -eq $patches.Count) {
            return
        }

        # A single net patch supports dependent patches touching the same file.
        # Git's default all-or-nothing apply checks it before writing anything.
        $targetTree = $states[$states.Count - 1]
        $combined = Join-Path $work "combined.patch"
        $result = Invoke-FrameworkGit -Arguments @(
            "-C", $FrameworkPath, "diff", "--binary", "--full-index",
            "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color",
            "--src-prefix=a/", "--dst-prefix=b/", $actualTree, $targetTree, "--"
        ) -Environment $seriesEnvironment -OutputPath $combined
        if ($result.ExitCode -ne 0 -or (Get-Item -LiteralPath $combined).Length -eq 0) {
            throw "Could not construct the complete framework patch$(Get-FrameworkGitError $result)"
        }
        $result = Invoke-FrameworkGit -Arguments @(
            "-C", $FrameworkPath, "apply", "--check", "--unidiff-zero",
            "--ignore-whitespace", "--", $combined
        )
        if ($result.ExitCode -ne 0) {
            throw "Framework patch series conflicts with the working tree$(Get-FrameworkGitError $result)"
        }
        $result = Invoke-FrameworkGit -Arguments @(
            "-C", $FrameworkPath, "diff", "--name-only", "--no-renames", "-z", $actualTree, $targetTree, "--"
        ) -Environment $seriesEnvironment
        if ($result.ExitCode -ne 0) {
            throw "Could not enumerate framework patch files$(Get-FrameworkGitError $result)"
        }
        $paths = @($result.StdOut.Split([char]0) | Where-Object { $_.Length -gt 0 })
        $backups = @(Backup-FrameworkPatchFiles -FrameworkPath $FrameworkPath `
            -BackupDirectory (Join-Path $work "backups") -Paths $paths)
        if ((Get-FrameworkPatchFingerprint -Root $Root) -cne $patchFingerprint) {
            throw "Framework patch series changed during preflight; retry the build."
        }
        $rechecked = Get-FrameworkWorktreeTree -FrameworkPath $FrameworkPath -Commit $commit `
            -ObjectDirectory $objects -IndexPath (Join-Path $work "rechecked.index") -PatchPaths $patchPaths
        if ($rechecked -cne $actualTree) {
            throw "Framework checkout changed during preflight; retry the build."
        }

        try {
            $result = Invoke-FrameworkGit -Arguments @(
                "-C", $FrameworkPath, "apply", "--unidiff-zero",
                "--ignore-whitespace", "--", $combined
            )
            if ($result.ExitCode -ne 0) {
                throw "Could not apply the complete framework patch series$(Get-FrameworkGitError $result)"
            }
            $after = Get-FrameworkWorktreeTree -FrameworkPath $FrameworkPath -Commit $commit `
                -ObjectDirectory $objects -IndexPath (Join-Path $work "after.index") -PatchPaths $patchPaths
            if ($after -cne $targetTree -or
                (Get-FrameworkPatchFingerprint -Root $Root) -cne $patchFingerprint) {
                throw "Framework checkout or patch series changed during application."
            }
        }
        catch {
            $failure = $_
            $restoreErrors = @(Restore-FrameworkPatchFiles -Backups $backups)
            try {
                $restored = Get-FrameworkWorktreeTree -FrameworkPath $FrameworkPath -Commit $commit `
                    -ObjectDirectory $objects -IndexPath (Join-Path $work "restored.index") -PatchPaths $patchPaths
                if ($restored -cne $actualTree) {
                    $restoreErrors += "The checkout does not match its pre-application state."
                }
            }
            catch {
                $restoreErrors += $_.Exception.Message
            }
            if ($restoreErrors.Count -gt 0) {
                throw "$($failure.Exception.Message) Rollback failed: $($restoreErrors -join '; ')"
            }
            throw $failure
        }
        for ($i = $prefix; $i -lt $patches.Count; $i++) {
            Write-Host "Applied framework patch $($patches[$i].Name)"
        }
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force
        }
    }
}

function Get-GeneratedSourceFingerprint {
    param([Parameter(Mandatory = $true)] [string]$Root)

    $generated = Join-Path $Root "port\src\rec"
    if (-not (Test-Path -LiteralPath (Join-Path $generated "all.odin") -PathType Leaf)) {
        throw "No generated source in port\src\rec. Run tools\setup.ps1 -Image <path-to-iso> first."
    }
    $base = [System.IO.Path]::GetFullPath($generated).TrimEnd('\') + '\'
    $names = [string[]]@(
        Get-ChildItem -LiteralPath $generated -Recurse -File -Filter "*.odin" |
            ForEach-Object { $_.FullName.Substring($base.Length) }
    )
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    $entries = foreach ($name in $names) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $base $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$name`t$hash`n"
    }
    return Get-FrameworkTextHash -Text ($entries -join "")
}

function Write-FrameworkGenerationProvenance {
    param(
        [Parameter(Mandatory = $true)] [string]$Root,
        [Parameter(Mandatory = $true)] $Lock,
        [string]$ExpectedPatchFingerprint,
        [string]$ExpectedTemplateFingerprint,
        [string]$ExpectedConfigFingerprint
    )

    $patchFingerprint = Get-FrameworkPatchFingerprint -Root $Root
    if ($ExpectedPatchFingerprint -and $patchFingerprint -cne $ExpectedPatchFingerprint) {
        throw "Framework patches changed during source generation; rerun tools\setup.ps1."
    }
    $templateFingerprint = (Get-FileHash -LiteralPath (Join-Path $Root "tools\recomp.tsv") -Algorithm SHA256).Hash.ToLowerInvariant()
    $configFingerprint = (Get-FileHash -LiteralPath (Join-Path $Root ".build\recomp.tsv") -Algorithm SHA256).Hash.ToLowerInvariant()
    if (($ExpectedTemplateFingerprint -and $templateFingerprint -ne $ExpectedTemplateFingerprint) -or
        ($ExpectedConfigFingerprint -and $configFingerprint -ne $ExpectedConfigFingerprint)) {
        throw "Recompiler configuration changed during source generation; rerun tools\setup.ps1."
    }
    $state = [ordered]@{
        schemaVersion = 1
        frameworkCommit = ([string]$Lock.framework.commit).ToLowerInvariant()
        patchesSha256 = $patchFingerprint
        templateSha256 = $templateFingerprint
        recompConfigSha256 = $configFingerprint
        sourceSha256 = Get-GeneratedSourceFingerprint -Root $Root
    }
    $path = Join-Path $Root "port\src\rec\.framework-provenance.json"
    $temporary = $path + "." + [guid]::NewGuid().ToString("N")
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json), $utf8)
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Assert-FrameworkGenerationProvenance {
    param(
        [Parameter(Mandatory = $true)] [string]$Root,
        [Parameter(Mandatory = $true)] $Lock,
        [string]$PatchFingerprint
    )

    $generated = Join-Path $Root "port\src\rec\all.odin"
    if (-not (Test-Path -LiteralPath $generated -PathType Leaf)) {
        throw "No generated source in port\src\rec. Run tools\setup.ps1 -Image <path-to-iso> first."
    }
    $path = Join-Path $Root "port\src\rec\.framework-provenance.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $legacyCommit = $null
        $legacy = Join-Path $Root "local.tsv"
        if (Test-Path -LiteralPath $legacy -PathType Leaf) {
            try {
                foreach ($row in @(Import-Csv -LiteralPath $legacy -Delimiter "`t" -Encoding UTF8)) {
                    $key = $row.PSObject.Properties["key"]
                    $value = $row.PSObject.Properties["value"]
                    if ($null -ne $key -and $null -ne $value -and $key.Value -eq "commit") {
                        $legacyCommit = [string]$value.Value
                    }
                }
            }
            catch {
                Write-Warning "Could not read legacy local.tsv provenance: $($_.Exception.Message)"
            }
        }
        if ($legacyCommit -and $legacyCommit -ne [string]$Lock.framework.commit) {
            throw "Generated source records framework $legacyCommit, not $($Lock.framework.commit). Run tools\setup.ps1 to regenerate."
        }
        Write-Warning "Generated-source provenance is missing; using the existing legacy output. Run tools\setup.ps1 to record provenance."
        return
    }

    try {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Generated-source provenance is unreadable. Run tools\setup.ps1 to regenerate: $($_.Exception.Message)"
    }
    foreach ($property in @(
        "schemaVersion", "frameworkCommit", "patchesSha256", "templateSha256",
        "recompConfigSha256", "sourceSha256"
    )) {
        if ($null -eq $state -or $null -eq $state.PSObject.Properties[$property]) {
            throw "Generated-source provenance is incomplete. Run tools\setup.ps1 to regenerate."
        }
    }
    if ($state.schemaVersion -ne 1 -or $state.frameworkCommit -ne [string]$Lock.framework.commit) {
        throw "Generated source was produced for a different framework or provenance version. Run tools\setup.ps1 to regenerate."
    }
    if (-not $PatchFingerprint) {
        $PatchFingerprint = Get-FrameworkPatchFingerprint -Root $Root
    }
    if ($state.patchesSha256 -ne $PatchFingerprint) {
        throw "Generated source predates the current framework patch series. Run tools\setup.ps1 to regenerate."
    }
    $template = (Get-FileHash -LiteralPath (Join-Path $Root "tools\recomp.tsv") -Algorithm SHA256).Hash
    if ($state.templateSha256 -ne $template) {
        throw "Generated source predates the current recompiler configuration. Run tools\setup.ps1 to regenerate."
    }
    $config = Join-Path $Root ".build\recomp.tsv"
    if (Test-Path -LiteralPath $config -PathType Leaf) {
        $configHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
        if ($state.recompConfigSha256 -ne $configHash) {
            throw "Generated source does not match .build\recomp.tsv. Run tools\setup.ps1 to regenerate."
        }
    }
    else {
        Write-Warning "Cannot verify the generated recompiler configuration because .build\recomp.tsv is missing."
    }
    if ($state.sourceSha256 -ne (Get-GeneratedSourceFingerprint -Root $Root)) {
        throw "Generated source is missing or has changed since setup. Run tools\setup.ps1 to regenerate."
    }
}

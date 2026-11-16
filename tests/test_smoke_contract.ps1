[CmdletBinding()]
param(
    [string]$ProcessProbe,
    [AllowEmptyString()] [string]$ProbeValue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($ProcessProbe) {
    if ($ProcessProbe -in @("stage-setup", "stage-run")) {
        $smokePath = Join-Path $PSScriptRoot "smoke.ps1"
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $smokePath, [ref]$tokens, [ref]$errors
        )
        if ($errors.Count -ne 0) { throw "smoke.ps1 does not parse." }
        $stage = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -ceq '$ChildStage'
        }, $true)
        if ($null -eq $stage) { throw "Smoke child stage was not found." }
        $block = $stage.Clauses[0].Item2.Extent.Text
        $body = $block.Substring(1, $block.Length - 2).
            Replace('(Join-Path $Root "tools\setup.ps1")', '"Invoke-SmokeStageProbe"').
            Replace('(Join-Path $Root "tools\run.ps1")', '"Invoke-SmokeStageProbe"')
        if ($body -match 'tools\\(?:setup|run)\.ps1') {
            throw "Could not replace the child stage's external script."
        }
        $script:ChildStage = if ($ProcessProbe -ceq "stage-setup") { "Setup" } else { "Run" }
        $script:Image = "synthetic image"
        $script:Frames = 600
        $script:ProbeExit = [int]$ProbeValue
        function Invoke-SmokeStageProbe {
            param([string]$Image, [switch]$ExactDisc, [switch]$Headless, [int]$Scale, [int]$Frames)
            if ($script:ChildStage -ceq "Setup") {
                if (-not $ExactDisc -or $Image -cne $script:Image) {
                    throw "Setup did not receive the exact image and switch."
                }
            }
            elseif (-not $Headless -or $Scale -ne 1 -or $Frames -ne $script:Frames) {
                throw "Runtime did not receive the headless scale and frame arguments."
            }
            $global:LASTEXITCODE = $script:ProbeExit
        }
        & ([scriptblock]::Create($body))
        exit 127
    }
    if ([Console]::In.ReadLine() -cne "MACROSS_SMOKE_START") { exit 125 }
    switch ($ProcessProbe) {
        "flood" {
            $block = "x" * 4096
            for ($i = 0; $i -lt 256; $i++) {
                [Console]::Out.Write($block)
                [Console]::Error.Write($block)
            }
        }
        "arguments" {
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ProbeValue))
            [Console]::Out.WriteLine($encoded)
            $overrides = @([Environment]::GetEnvironmentVariables().Keys |
                Where-Object { $_ -like "MACROSS_*" })
            [Console]::Out.WriteLine("overrides=$($overrides.Count)")
        }
        { $_ -in @("timeout", "orphan", "orphan-fanout") } {
            $exe = if ($PSVersionTable.PSEdition -ceq "Desktop") {
                Join-Path $PSHOME "powershell.exe"
            }
            else {
                Join-Path $PSHOME "pwsh.exe"
            }
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = $exe
            $start.Arguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 90"'
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $count = if ($ProcessProbe -ceq "orphan-fanout") { 5 } else { 1 }
            $children = @()
            for ($i = 0; $i -lt $count; $i++) {
                $child = [System.Diagnostics.Process]::Start($start)
                $children += $child
                [Console]::Out.WriteLine("child=$($child.Id):$($child.StartTime.ToUniversalTime().Ticks)")
            }
            [Console]::Out.Flush()
            foreach ($child in $children) {
                if ($child.HasExited) { throw "A probe child exited before the stage." }
            }
            if ($ProcessProbe -ceq "timeout") { Start-Sleep -Seconds 90 }
        }
        default { throw "Unknown process probe." }
    }
    exit 0
}

$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "_smoke_assertions.ps1")
. (Join-Path $Root "tools\smoke-process.ps1")
$Self = $PSCommandPath
$Shell = if ($PSVersionTable.PSEdition -ceq "Desktop") {
    Join-Path $PSHOME "powershell.exe"
}
else {
    Join-Path $PSHOME "pwsh.exe"
}

$Passed = 0
$Failures = @()
$Build = "0123456789abcdef0123456789abcdef01234567"
$ValidJson = '{"system":"ps2","result":"frames","build":"BUILD_COMMIT","frames":600,"shown":599,"fallback":false,"fatal":"","details":[{"nested":[null,true,{"x":"text\""}]}]}'.Replace(
    "BUILD_COMMIT", $Build
)
$ValidStdOut = "other output`nframes: 600 reached`n"
$ValidStdErr = "vulkan: Example Vulkan GPU`ngs: GPU renderer, scale 1`ncompat: $ValidJson`n"

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

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param([hashtable]$Changes, [string]$Pattern)
    $arguments = @{
        StdOut = $ValidStdOut
        StdErr = $ValidStdErr
        ExitCode = 0
        ExpectedBuild = $Build
        RequestedFrames = 600
    }
    foreach ($entry in $Changes.GetEnumerator()) { $arguments[$entry.Key] = $entry.Value }
    $message = $null
    try {
        [void](Assert-SmokeLog @arguments)
    }
    catch {
        $message = $_.Exception.Message
    }
    if (-not $message) { throw "Expected the smoke contract to reject the fixture." }
    if ($Pattern -and $message -notmatch $Pattern) {
        throw "Expected '$Pattern', received '$message'."
    }
}

function Get-FixtureErrorLog {
    param([string]$Json)
    return "vulkan: Example Vulkan GPU`ngs: GPU renderer, scale 1`ncompat: $Json`n"
}

function Invoke-ProcessProbe {
    param([string]$Probe, [int]$TimeoutSeconds = 15, [AllowEmptyString()] [string]$Value = "")
    $arguments = @(
        "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $Self, "-ProcessProbe", $Probe
    )
    if ($Probe -ceq "arguments" -or $Probe -like "stage-*") {
        $arguments += @("-ProbeValue", $Value)
    }
    return Invoke-SmokeChild -PowerShell $Shell -Arguments $arguments `
        -WorkingDirectory $Root -TimeoutSeconds $TimeoutSeconds
}

function Invoke-SmokePreflight {
    param([string]$Image, [int]$Frames = 600)
    $arguments = @(
        "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "smoke.ps1"), "-Image", $Image, "-Frames", [string]$Frames
    )
    return Invoke-SmokeChild -PowerShell $Shell -Arguments $arguments `
        -WorkingDirectory $Root -TimeoutSeconds 15
}

function Assert-ProbeChildStopped {
    param([string]$Output)
    $match = [regex]::Match($Output, '(?m)^child=([0-9]+):([0-9]+)\r?$')
    if (-not $match.Success) { throw "Probe did not report its launched child." }
    $id = [int]$match.Groups[1].Value
    $ticks = [long]$match.Groups[2].Value
    $child = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($null -eq $child) { return }
    try {
        if ($child.HasExited) { return }
        try {
            $startTime = $child.StartTime
        }
        catch {
            if ($child.HasExited) { return }
            throw
        }
        if ($null -eq $startTime) {
            if ($child.HasExited) { return }
            throw "Could not verify the smoke child process identity."
        }
        if ($startTime.ToUniversalTime().Ticks -eq $ticks -and -not $child.HasExited) {
            throw "The smoke child process tree was not stopped."
        }
    }
    finally {
        $child.Dispose()
    }
}

Invoke-Case "valid record and return fields" {
    $result = Assert-SmokeLog -StdOut $ValidStdOut -StdErr $ValidStdErr -ExitCode 0 `
        -ExpectedBuild $Build -RequestedFrames 600
    Assert-Test ($result.VulkanDevice -ceq "Example Vulkan GPU") "Wrong device."
    Assert-Test ($result.Renderer -ceq "GPU" -and $result.Scale -eq 1) "Wrong renderer."
    Assert-Test ($result.System -ceq "ps2" -and $result.Result -ceq "frames") "Wrong status."
    Assert-Test ($result.Build -ceq $Build -and $result.Frames -eq 600 -and
        $result.Shown -eq 599 -and $result.Fallback -is [bool] -and
        -not $result.Fallback -and $result.Fatal -ceq "") "Wrong compat fields."
}

Invoke-Case "streams and line endings are interchangeable" {
    $stdout = "vulkan: Example Vulkan GPU`r`ngs: GPU renderer, scale 1`r`ncompat: $ValidJson"
    $stderr = "frames: 600 reached`r`n"
    $result = Assert-SmokeLog -StdOut $stdout -StdErr $stderr -ExitCode 0 `
        -ExpectedBuild $Build -RequestedFrames 600
    Assert-Test ($result.Frames -eq 600) "Split streams were not parsed."
}

Invoke-Case "more frames and boundary shown counts are accepted" {
    foreach ($shown in @(1, 601)) {
        $json = $ValidJson.Replace('"frames":600', '"frames":601').Replace(
            '"shown":599', ('"shown":' + $shown)
        )
        $result = Assert-SmokeLog -StdOut "frames: 601 reached" -StdErr (Get-FixtureErrorLog $json) `
            -ExitCode 0 -ExpectedBuild $Build -RequestedFrames 600
        Assert-Test ($result.Frames -eq 601 -and $result.Shown -eq $shown) "Boundary rejected."
    }
}

Invoke-Case "escaped JSON keys are decoded" {
    $json = $ValidJson.Replace('"system"', '"\u0073ystem"')
    $result = Assert-SmokeLog -StdOut $ValidStdOut -StdErr (Get-FixtureErrorLog $json) `
        -ExitCode 0 -ExpectedBuild $Build -RequestedFrames 600
    Assert-Test ($result.System -ceq "ps2") "Escaped key was not decoded."
}

Invoke-Case "missing compat record" {
    Assert-Rejected @{ StdErr = "vulkan: Example Vulkan GPU`ngs: GPU renderer, scale 1" } "exactly one compat"
}

Invoke-Case "duplicate compat records across streams" {
    Assert-Rejected @{ StdOut = $ValidStdOut + "compat: $ValidJson`n" } "exactly one compat"
}

Invoke-Case "a malformed extra compat record is not ignored" {
    Assert-Rejected @{ StdErr = $ValidStdErr + "compat: {`n" } "exactly one compat"
}

Invoke-Case "malformed and non-object compat JSON" {
    foreach ($json in @("{", "not-json", "[]", "null", '{"system":}')) {
        Assert-Rejected @{ StdErr = (Get-FixtureErrorLog $json) } "JSON"
    }
}

Invoke-Case "strict JSON syntax and duplicate object keys" {
    $bad = @(
        '{"x":01}', '{"x":NaN}', '{"x":true,}', "{'x':1}", '{x:1}',
        '{"x":/* comment */true}', '{"x":[1,]}', '{"x":1,"x":2}',
        '{"x":1,"\u0078":2}', '{"x":{"a":1,"A":2}}', '{"x":"\q"}'
    )
    foreach ($json in $bad) {
        $rejected = $false
        try { Assert-SmokeStrictJson -Json $json }
        catch { $rejected = $true }
        if (-not $rejected) { throw "Invalid JSON was accepted: $json" }
    }
}

Invoke-Case "wrong or missing system" {
    foreach ($json in @(
        $ValidJson.Replace('"system":"ps2"', '"system":"ps1"'),
        $ValidJson.Replace('"system":"ps2",', '')
    )) { Assert-Rejected @{ StdErr = (Get-FixtureErrorLog $json) } "system" }
}

Invoke-Case "wrong result" {
    Assert-Rejected @{ StdErr = (Get-FixtureErrorLog $ValidJson.Replace('"result":"frames"', '"result":"exit"')) } "result"
}

Invoke-Case "wrong or modified build" {
    foreach ($actual in @($Build.ToUpperInvariant(), ($Build + "+mods.1234567890abcdef"), "wrong")) {
        Assert-Rejected @{ StdErr = (Get-FixtureErrorLog $ValidJson.Replace($Build, $actual)) } "build"
    }
}

Invoke-Case "missing or failed Vulkan device" {
    foreach ($device in @("", "vulkan: ", "vulkan: no Vulkan 1.3 device", "vulkan: loader not found")) {
        $stderr = $ValidStdErr.Replace("vulkan: Example Vulkan GPU", $device)
        Assert-Rejected @{ StdErr = $stderr } "Vulkan device"
    }
}

Invoke-Case "wrong renderer or scale" {
    foreach ($renderer in @("gs: software renderer", "gs: GPU renderer, scale 2", "gs: GPU renderer, scale 10", "")) {
        Assert-Rejected @{ StdErr = $ValidStdErr.Replace("gs: GPU renderer, scale 1", $renderer) } "renderer"
    }
}

Invoke-Case "contradictory renderer lines" {
    Assert-Rejected @{ StdErr = $ValidStdErr + "gs: software renderer`n" } "renderer"
}

Invoke-Case "missing, duplicate, malformed and inconsistent frame lines" {
    foreach ($line in @("", "frames: 599 reached", "frames: 600", "frames: 600 reached`nframes: 600 reached")) {
        Assert-Rejected @{ StdOut = $line } "frame-limit|Frame-limit"
    }
}

Invoke-Case "insufficient or invalid frames" {
    foreach ($value in @("599", '"600"', "600.0", "true", "-1", "null")) {
        $json = $ValidJson.Replace('"frames":600', ('"frames":' + $value))
        Assert-Rejected @{ StdErr = (Get-FixtureErrorLog $json) } "frames"
    }
}

Invoke-Case "shown must be an integer within bounds" {
    foreach ($value in @("0", "601", "-1", '"599"', "1.0", "true", "null")) {
        $json = $ValidJson.Replace('"shown":599', ('"shown":' + $value))
        Assert-Rejected @{ StdErr = (Get-FixtureErrorLog $json) } "shown"
    }
}

Invoke-Case "fallback must be boolean false" {
    foreach ($value in @("true", '"false"', "0", "null")) {
        $json = $ValidJson.Replace('"fallback":false', ('"fallback":' + $value))
        Assert-Rejected @{ StdErr = (Get-FixtureErrorLog $json) } "fallback"
    }
}

Invoke-Case "fatal must be an empty string" {
    foreach ($value in @('"failure"', '" "', "null", "false")) {
        $json = $ValidJson.Replace('"fatal":""', ('"fatal":' + $value))
        Assert-Rejected @{ StdErr = (Get-FixtureErrorLog $json) } "fatal"
    }
}

Invoke-Case "nonzero exit overrides an otherwise valid log" {
    Assert-Rejected @{ ExitCode = 1 } "exited"
}

Invoke-Case "an unavailable Vulkan device is diagnosed explicitly" {
    foreach ($line in @(
        "vulkan: no Vulkan 1.3 device with a graphics and compute queue",
        "vulkan: vulkan-1.dll not found",
        "vulkan: vulkan-1.dll lacks vkGetInstanceProcAddr"
    )) {
        Assert-Rejected @{ ExitCode = 1; StdErr = $line } "missing Vulkan"
    }
}

Invoke-Case "a vanished start time is accepted only for an exited process" {
    $fakeExited = $true
    function Get-Process {
        [CmdletBinding()]
        param([int]$Id)
        $fake = [pscustomobject]@{ StartTime = $null; HasExited = $fakeExited }
        $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        return $fake
    }

    Assert-ProbeChildStopped "child=123:456"
    $fakeExited = $false
    $message = $null
    try { Assert-ProbeChildStopped "child=123:456" }
    catch { $message = $_.Exception.Message }
    Assert-Test ($message -match "identity|not stopped") `
        "An unidentifiable live process was accepted."
}

Invoke-Case "the process assertion rejects a live matching PID but permits PID reuse" {
    $current = Get-Process -Id $PID
    try { $ticks = $current.StartTime.ToUniversalTime().Ticks }
    finally { $current.Dispose() }
    $message = $null
    try { Assert-ProbeChildStopped ("child={0}:{1}" -f $PID, $ticks) }
    catch { $message = $_.Exception.Message }
    Assert-Test ($message -match "not stopped") "A live probe process was accepted."
    Assert-ProbeChildStopped ("child={0}:{1}" -f $PID, ($ticks + 1))
}

Invoke-Case "both redirected streams drain without deadlock" {
    $result = Invoke-ProcessProbe -Probe "flood"
    Assert-Test (-not $result.TimedOut -and $result.ExitCode -eq 0) "Flood probe failed."
    Assert-Test ($result.StdOut.Length -eq 1048576 -and $result.StdErr.Length -eq 1048576) `
        "Redirected output was incomplete."
}

Invoke-Case "child arguments are exact and MACROSS overrides are removed" {
    $name = "MACROSS_SMOKE_SENTINEL"
    $previous = [Environment]::GetEnvironmentVariable($name, "Process")
    try {
        [Environment]::SetEnvironmentVariable($name, "poison", "Process")
        $value = 'F:\space [literal] & "quoted" O''Brien\' + [char]0x00E9 + '\'
        $result = Invoke-ProcessProbe -Probe "arguments" -Value $value
        $expected = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
        $lines = @($result.StdOut.Trim() -split "\r?\n")
        Assert-Test (-not $result.TimedOut -and $result.ExitCode -eq 0) "Argument probe failed."
        Assert-Test ($lines.Count -eq 2 -and $lines[0] -ceq $expected) "Argument changed in transit."
        Assert-Test ($lines[1] -ceq "overrides=0") "Inherited MACROSS override reached child."
        Assert-Test ([Environment]::GetEnvironmentVariable($name, "Process") -ceq "poison") `
            "The parent's environment was changed."
    }
    finally {
        [Environment]::SetEnvironmentVariable($name, $previous, "Process")
    }
}

Invoke-Case "setup and runtime child stages forward arguments and exit codes" {
    foreach ($probe in @("stage-setup", "stage-run")) {
        foreach ($code in @(0, 17)) {
            $result = Invoke-ProcessProbe -Probe $probe -Value ([string]$code)
            Assert-Test (-not $result.TimedOut -and $result.ExitCode -eq $code) `
                "$probe did not forward exit code $code."
        }
    }
}

Invoke-Case "timeout stops only the launched process tree" {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Shell
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 90"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $unrelated = [System.Diagnostics.Process]::Start($start)
    try {
        $result = Invoke-ProcessProbe -Probe "timeout" -TimeoutSeconds 5
        Assert-Test $result.TimedOut "The long-running probe did not time out."
        Assert-ProbeChildStopped $result.StdOut
        Assert-Test (-not $unrelated.HasExited) "Cleanup stopped an unrelated process."
    }
    finally {
        try {
            if (-not $unrelated.HasExited) { $unrelated.Kill() }
            if (-not $unrelated.WaitForExit(5000)) { throw "Could not stop the probe sentinel." }
        }
        finally {
            $unrelated.Dispose()
        }
    }
}

Invoke-Case "orphan descendants are stopped when the stage exits" {
    $result = Invoke-ProcessProbe -Probe "orphan"
    Assert-Test (-not $result.TimedOut -and $result.ExitCode -eq 0) "Orphan probe failed."
    Assert-ProbeChildStopped $result.StdOut
}

Invoke-Case "all orphan descendants are stopped even without inherited output pipes" {
    $result = Invoke-ProcessProbe -Probe "orphan-fanout"
    Assert-Test (-not $result.TimedOut -and $result.ExitCode -eq 0) "Orphan fanout probe failed."
    $children = [regex]::Matches($result.StdOut, '(?m)^child=[0-9]+:[0-9]+\r?$')
    Assert-Test ($children.Count -eq 5) "The probe did not report all launched children."
    foreach ($child in $children) { Assert-ProbeChildStopped $child.Value }
}

Invoke-Case "missing image fails explicitly without a pass" {
    $missing = Join-Path $Root ("missing-smoke-image-" + [guid]::NewGuid().ToString("N") + ".iso")
    $result = Invoke-SmokePreflight -Image $missing
    Assert-Test (-not $result.TimedOut -and $result.ExitCode -ne 0) "Missing image did not fail."
    Assert-Test ($result.StdErr -match "Missing prerequisite.*original disc image") `
        "Missing image was not diagnosed."
    Assert-Test ($result.StdOut -notmatch "SMOKE PASS") "A failed preflight reported success."
}

Invoke-Case "missing Python fails explicitly without a pass" {
    $previousPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
    try {
        [Environment]::SetEnvironmentVariable("PATH", (Join-Path $Root "no-smoke-tools"), "Process")
        $result = Invoke-SmokePreflight -Image $Self
        Assert-Test (-not $result.TimedOut -and $result.ExitCode -ne 0) "Missing Python did not fail."
        Assert-Test ($result.StdErr -match "Missing prerequisite.*python") "Missing Python was not diagnosed."
        Assert-Test ($result.StdOut -notmatch "SMOKE PASS") "A failed preflight reported success."
    }
    finally {
        [Environment]::SetEnvironmentVariable("PATH", $previousPath, "Process")
    }
}

Invoke-Case "fewer than 600 frames is rejected" {
    $result = Invoke-SmokePreflight -Image $Self -Frames 599
    Assert-Test (-not $result.TimedOut -and $result.ExitCode -ne 0) "An insufficient frame limit was accepted."
    Assert-Test (($result.StdOut + $result.StdErr) -notmatch "SMOKE PASS") "An invalid run reported success."
}

if ($Failures.Count -ne 0) {
    throw "$($Failures.Count) smoke contract test(s) failed."
}
Write-Host "Smoke contract tests passed: $Passed"

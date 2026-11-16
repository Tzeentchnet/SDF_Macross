function Assert-SmokeStrictJson {
    param([Parameter(Mandatory = $true)] [string]$Json)

    # ConvertFrom-Json accepts several non-JSON extensions on at least one of
    # the supported PowerShell versions, so check the JSON grammar first.
    $pattern = '\G[ \t\r\n]*(?<token>"(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\],:])'
    $lexer = New-Object System.Text.RegularExpressions.Regex($pattern)
    $stack = New-Object 'System.Collections.Generic.List[object]'
    $stack.Add([pscustomobject]@{ Kind = "root"; State = "value"; Keys = $null })
    $position = 0

    while ($position -lt $Json.Length) {
        $match = $lexer.Match($Json, $position)
        if (-not $match.Success) {
            if ($Json.Substring($position) -cmatch '^[ \t\r\n]*$') { break }
            throw "compat JSON is malformed."
        }
        $position += $match.Length
        $token = $match.Groups["token"].Value
        $frame = $stack[$stack.Count - 1]
        $needsValue = $false

        if ($frame.Kind -ceq "object") {
            if ($frame.State -ceq "keyOrEnd" -and $token -ceq "}") {
                $stack.RemoveAt($stack.Count - 1)
                continue
            }
            if ($frame.State -ceq "keyOrEnd" -or $frame.State -ceq "key") {
                if (-not $token.StartsWith('"')) { throw "compat JSON is malformed." }
                # The prefix prevents PowerShell from interpreting a key that
                # resembles a date as a DateTime while decoding its escapes.
                $quotedKey = '"__' + $token.Substring(1, $token.Length - 2) + '__"'
                $decoded = (ConvertFrom-Json -InputObject ('{"k":' + $quotedKey + '}') `
                    -ErrorAction Stop).k
                $key = $decoded.Substring(2, $decoded.Length - 4)
                if (-not $frame.Keys.Add($key)) {
                    throw "compat JSON contains duplicate object keys."
                }
                $frame.State = "colon"
                continue
            }
            if ($frame.State -ceq "colon") {
                if ($token -cne ":") { throw "compat JSON is malformed." }
                $frame.State = "value"
                continue
            }
            if ($frame.State -ceq "commaOrEnd") {
                if ($token -ceq "}") {
                    $stack.RemoveAt($stack.Count - 1)
                }
                elseif ($token -ceq ",") {
                    $frame.State = "key"
                }
                else {
                    throw "compat JSON is malformed."
                }
                continue
            }
            $needsValue = $frame.State -ceq "value"
        }
        elseif ($frame.Kind -ceq "array") {
            if ($frame.State -ceq "valueOrEnd" -and $token -ceq "]") {
                $stack.RemoveAt($stack.Count - 1)
                continue
            }
            if ($frame.State -ceq "commaOrEnd") {
                if ($token -ceq "]") {
                    $stack.RemoveAt($stack.Count - 1)
                }
                elseif ($token -ceq ",") {
                    $frame.State = "value"
                }
                else {
                    throw "compat JSON is malformed."
                }
                continue
            }
            $needsValue = $frame.State -ceq "valueOrEnd" -or $frame.State -ceq "value"
        }
        else {
            $needsValue = $frame.State -ceq "value"
        }

        if (-not $needsValue) { throw "compat JSON is malformed." }
        $frame.State = if ($frame.Kind -ceq "root") { "done" } else { "commaOrEnd" }
        if ($token -ceq "{") {
            $keys = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $stack.Add([pscustomobject]@{ Kind = "object"; State = "keyOrEnd"; Keys = $keys })
        }
        elseif ($token -ceq "[") {
            $stack.Add([pscustomobject]@{ Kind = "array"; State = "valueOrEnd"; Keys = $null })
        }
        elseif (-not ($token.StartsWith('"') -or
            $token -cmatch '^(?:true|false|null|-?[0-9])')) {
            throw "compat JSON is malformed."
        }
    }

    if ($stack.Count -ne 1 -or $stack[0].State -cne "done") {
        throw "compat JSON is malformed."
    }
}

function Assert-SmokeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$StdOut,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$StdErr,
        [Parameter(Mandatory = $true)] [int]$ExitCode,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ExpectedBuild,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 10000000)] [int]$RequestedFrames
    )

    $log = $StdOut + "`n" + $StdErr
    if ($ExitCode -ne 0) {
        if ($log -match '(?m)^vulkan:[ \t]*(?:no Vulkan 1\.3 device|[^\r\n]*(?:not found|lacks vkGetInstanceProcAddr))') {
            throw "Runtime exited with code ${ExitCode}: missing Vulkan 1.3 device or loader."
        }
        throw "Runtime exited with code $ExitCode."
    }
    $lines = @($log -split "\r?\n")

    $devices = @(
        foreach ($line in $lines) {
            $match = [regex]::Match($line, '^vulkan:[ \t]*(.+?)[ \t]*$')
            if ($match.Success) {
                $device = $match.Groups[1].Value.Trim()
                if ($device -and $device -cnotmatch '^(?i:no\b|error\b|warning\b)' -and
                    $device -cnotmatch '(?i:\bfailed:|\bnot found\b|\blacks\b)') {
                    $device
                }
            }
        }
    )
    if ($devices.Count -eq 0) { throw "Vulkan device line is missing." }

    $renderers = @($lines | Where-Object { $_ -cmatch '^gs:[ \t].*\brenderer\b' })
    if ($renderers.Count -ne 1 -or $renderers[0] -cnotmatch '^gs:[ \t]+GPU renderer, scale 1[ \t]*$') {
        throw "Expected exactly one GPU renderer line at scale 1."
    }

    $compatLines = @($lines | Where-Object { $_ -cmatch '^compat:' })
    if ($compatLines.Count -ne 1) {
        throw "Expected exactly one compat JSON record; found $($compatLines.Count)."
    }
    $json = $compatLines[0].Substring(7).Trim()
    if (-not $json) { throw "compat JSON is malformed." }
    try {
        Assert-SmokeStrictJson -Json $json
        $record = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch {
        throw "compat JSON is malformed: $($_.Exception.Message)"
    }
    if ($record -isnot [pscustomobject]) { throw "compat JSON must be an object." }

    $names = @($record.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in @("system", "result", "build", "frames", "shown", "fallback", "fatal")) {
        if ($names -cnotcontains $name) { throw "compat JSON is missing '$name'." }
    }
    if ($record.system -isnot [string] -or $record.system -cne "ps2") {
        throw "compat system must be ps2."
    }
    if ($record.result -isnot [string] -or $record.result -cne "frames") {
        throw "compat result must be frames."
    }
    if ($record.build -isnot [string] -or $record.build -cne $ExpectedBuild) {
        throw "compat build does not match the pinned framework commit."
    }
    foreach ($name in @("frames", "shown")) {
        $value = $record.PSObject.Properties[$name].Value
        if ($value -isnot [int] -and $value -isnot [long]) {
            throw "compat $name must be an integer."
        }
    }
    $frames = [long]$record.frames
    $shown = [long]$record.shown
    if ($frames -lt $RequestedFrames) { throw "compat frames are below the requested limit." }
    if ($shown -le 0 -or $shown -gt $frames) {
        throw "compat shown must be greater than zero and at most frames."
    }
    if ($record.fallback -isnot [bool] -or $record.fallback) {
        throw "compat fallback must be the boolean false."
    }
    if ($record.fatal -isnot [string] -or $record.fatal -cne "") {
        throw "compat fatal must be an empty string."
    }

    $frameLines = @($lines | Where-Object { $_ -cmatch '^frames:' })
    if ($frameLines.Count -ne 1) { throw "Expected exactly one frame-limit line." }
    $frameMatch = [regex]::Match($frameLines[0], '^frames:[ \t]+([0-9]+)[ \t]+reached[ \t]*$')
    $lineFrames = [long]0
    if (-not $frameMatch.Success -or -not [long]::TryParse(
        $frameMatch.Groups[1].Value, [ref]$lineFrames
    ) -or $lineFrames -ne $frames) {
        throw "Frame-limit line does not match compat frames."
    }

    return [pscustomobject]@{
        VulkanDevice = $devices[0]
        Renderer = "GPU"
        Scale = 1
        System = $record.system
        Result = $record.result
        Build = $record.build
        Frames = $frames
        Shown = $shown
        Fallback = $record.fallback
        Fatal = $record.fatal
    }
}

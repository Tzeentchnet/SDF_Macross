$script:SmokeNativeType = $null

function Initialize-SmokeNativeApi {
    if ($null -ne $script:SmokeNativeType) { return }
    if ($env:OS -cne "Windows_NT" -or [IntPtr]::Size -ne 8) {
        throw "The smoke test requires 64-bit Windows PowerShell."
    }

    # Emit only P/Invoke declarations in memory; no compiler or temporary
    # files are needed on either Windows PowerShell 5.1 or PowerShell 7.
    $name = New-Object System.Reflection.AssemblyName("MacrossSmokeNative")
    $access = [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    $signature = [type[]]@(
        [System.Reflection.AssemblyName], [System.Reflection.Emit.AssemblyBuilderAccess]
    )
    if ([System.AppDomain]::CurrentDomain.GetType().GetMethod("DefineDynamicAssembly", $signature)) {
        $assembly = [System.AppDomain]::CurrentDomain.DefineDynamicAssembly($name, $access)
    }
    else {
        $assembly = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, $access)
    }
    $module = $assembly.DefineDynamicModule("MacrossSmokeNative")
    $type = $module.DefineType(
        "MacrossSmoke.Native", [System.Reflection.TypeAttributes]"Public, Abstract, Sealed"
    )
    $attributes = [System.Reflection.MethodAttributes]"Public, Static, PinvokeImpl"
    $calling = [System.Reflection.CallingConventions]::Standard
    $nativeCalling = [System.Runtime.InteropServices.CallingConvention]::Winapi
    $charset = [System.Runtime.InteropServices.CharSet]::Unicode
    $methods = @(
        @{ Name = "CreateJobObject"; Return = [IntPtr]; Args = [type[]]@([IntPtr], [string]) }
        @{ Name = "SetInformationJobObject"; Return = [bool]; Args = [type[]]@([IntPtr], [int], [IntPtr], [uint32]) }
        @{ Name = "AssignProcessToJobObject"; Return = [bool]; Args = [type[]]@([IntPtr], [IntPtr]) }
        @{ Name = "TerminateJobObject"; Return = [bool]; Args = [type[]]@([IntPtr], [uint32]) }
        @{ Name = "QueryInformationJobObject"; Return = [bool]; Args = [type[]]@([IntPtr], [int], [IntPtr], [uint32], [IntPtr]) }
        @{ Name = "CloseHandle"; Return = [bool]; Args = [type[]]@([IntPtr]) }
    )
    foreach ($spec in $methods) {
        $method = $type.DefinePInvokeMethod(
            $spec.Name, "kernel32.dll", $attributes, $calling, $spec.Return,
            $spec.Args, $nativeCalling, $charset
        )
        $method.SetImplementationFlags(
            $method.GetMethodImplementationFlags() -bor
                [System.Reflection.MethodImplAttributes]::PreserveSig
        )
    }
    $script:SmokeNativeType = $type.CreateType()
}

function New-SmokeJob {
    Initialize-SmokeNativeApi
    $api = $script:SmokeNativeType
    $job = $api::CreateJobObject([IntPtr]::Zero, $null)
    if ($job -eq [IntPtr]::Zero) { throw "Could not create a Windows smoke process job." }

    # JOBOBJECT_EXTENDED_LIMIT_INFORMATION on 64-bit Windows; the flags are
    # at byte 16 and KILL_ON_JOB_CLOSE confines cleanup to this job's tree.
    $size = 144
    $info = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        $zero = New-Object byte[] $size
        [System.Runtime.InteropServices.Marshal]::Copy($zero, 0, $info, $size)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($info, 16, 0x2000)
        if (-not $api::SetInformationJobObject($job, 9, $info, [uint32]$size)) {
            throw "Could not configure safe smoke process cleanup."
        }
    }
    catch {
        [void]$api::CloseHandle($job)
        throw
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info)
    }
    return $job
}

function Stop-SmokeJob {
    param([Parameter(Mandatory = $true)] [IntPtr]$Job)

    $api = $script:SmokeNativeType
    if (-not $api::TerminateJobObject($Job, [uint32]1)) {
        throw "Could not terminate the smoke process job."
    }

    # Job accounting still includes descendants after their parent exits.
    # Wait for ActiveProcesses at byte 40 to reach zero before returning.
    $info = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(48)
    try {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if (-not $api::QueryInformationJobObject($Job, 1, $info, 48, [IntPtr]::Zero)) {
                throw "Could not query the smoke process job."
            }
            if ([System.Runtime.InteropServices.Marshal]::ReadInt32($info, 40) -eq 0) {
                return
            }
            if ($timer.ElapsedMilliseconds -ge 5000) {
                throw "Could not stop the smoke process tree."
            }
            Start-Sleep -Milliseconds 10
        }
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info)
    }
}

function ConvertTo-SmokeWindowsArgument {
    param([AllowEmptyString()] [string]$Argument)

    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-SmokeChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PowerShell,
        [Parameter(Mandatory = $true)] [string[]]$Arguments,
        [Parameter(Mandatory = $true)] [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 86400)] [int]$TimeoutSeconds
    )

    $job = New-SmokeJob
    $api = $script:SmokeNativeType
    $process = New-Object System.Diagnostics.Process
    $started = $false
    $assigned = $false
    $stdoutTask = $null
    $stderrTask = $null
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $PowerShell
        $start.Arguments = (@($Arguments | ForEach-Object {
            ConvertTo-SmokeWindowsArgument $_
        }) -join " ")
        $start.WorkingDirectory = $WorkingDirectory
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        foreach ($name in @($start.EnvironmentVariables.Keys)) {
            if ($name.StartsWith("MACROSS_", [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$start.EnvironmentVariables.Remove($name)
            }
        }
        $start.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0"
        $process.StartInfo = $start
        $started = $process.Start()
        if (-not $started) { throw "Could not start the smoke PowerShell child." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # The child waits for this handshake before starting setup or the game.
        if (-not $api::AssignProcessToJobObject($job, $process.Handle)) {
            throw "Could not isolate the smoke PowerShell child in a Windows job."
        }
        $assigned = $true
        $process.StandardInput.WriteLine("MACROSS_SMOKE_START")
        $process.StandardInput.Close()

        $timeoutMilliseconds = $TimeoutSeconds * 1000
        $remaining = [Math]::Max(0, $timeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
        $timedOut = -not $process.WaitForExit($remaining)

        # Stop and wait for the whole job, including orphans that no longer
        # have a discoverable live parent, before closing its handle.
        Stop-SmokeJob -Job $job
        if (-not $api::CloseHandle($job)) { throw "Could not close the smoke process job." }
        $job = [IntPtr]::Zero
        if (-not $process.WaitForExit(5000)) { throw "Could not stop the smoke process tree." }

        $remaining = if ($timedOut) {
            5000
        }
        else {
            [Math]::Max(0, $timeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
        }
        if (-not $stdoutTask.Wait($remaining)) {
            throw "Timed out collecting smoke child stdout."
        }
        $remaining = if ($timedOut) {
            5000
        }
        else {
            [Math]::Max(0, $timeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
        }
        if (-not $stderrTask.Wait($remaining)) {
            throw "Timed out collecting smoke child stderr."
        }
        return [pscustomobject]@{
            TimedOut = $timedOut
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.Result
            StdErr = $stderrTask.Result
        }
    }
    finally {
        if ($job -ne [IntPtr]::Zero) { [void]$api::CloseHandle($job) }
        if ($started -and -not $assigned) {
            try {
                if (-not $process.HasExited) { $process.Kill() }
                [void]$process.WaitForExit(5000)
            }
            catch {
                # The gated child cannot have launched setup or the game.
            }
        }
        $process.Dispose()
    }
}

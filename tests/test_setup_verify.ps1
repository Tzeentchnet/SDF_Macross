[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root "tools\setup-verification.ps1")

$Passed = 0
$Failures = @()

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

function Assert-Arguments {
    param([string[]]$Actual, [string[]]$Expected)
    if ($Actual.Count -ne $Expected.Count) {
        throw "Expected $($Expected.Count) arguments, received $($Actual.Count)."
    }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($Actual[$i] -cne $Expected[$i]) {
            throw "Argument $i was not forwarded exactly."
        }
    }
}

$Inspector = 'F:\project path\inspect_game.py'
$Image = 'F:\images [literal]\O''Brien & "disc".iso'

Invoke-Case "default verification arguments" {
    $actual = @(Get-SetupVerificationArguments -InspectorPath $Inspector -ImagePath $Image)
    Assert-Arguments $actual @($Inspector, $Image)
}

Invoke-Case "exact disc forwarding" {
    $actual = @(Get-SetupVerificationArguments -InspectorPath $Inspector -ImagePath $Image -ExactDisc)
    Assert-Arguments $actual @($Inspector, $Image, "--exact")
}

Invoke-Case "allow patched forwarding" {
    $actual = @(Get-SetupVerificationArguments -InspectorPath $Inspector -ImagePath $Image -AllowPatchedImage)
    Assert-Arguments $actual @($Inspector, $Image, "--allow-patched")
}

Invoke-Case "both verification switches forward independently" {
    $actual = @(Get-SetupVerificationArguments -InspectorPath $Inspector -ImagePath $Image `
        -ExactDisc -AllowPatchedImage)
    Assert-Arguments $actual @($Inspector, $Image, "--exact", "--allow-patched")
}

Invoke-Case "explicit false switches do not forward" {
    $actual = @(Get-SetupVerificationArguments -InspectorPath $Inspector -ImagePath $Image `
        -ExactDisc:$false -AllowPatchedImage:$false)
    Assert-Arguments $actual @($Inspector, $Image)
}

Invoke-Case "setup passes its switches to the helper" {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $Root "tools\setup.ps1"), [ref]$tokens, [ref]$errors
    )
    if ($errors.Count -ne 0) { throw "setup.ps1 does not parse." }
    $calls = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq "Get-SetupVerificationArguments"
    }, $true))
    if ($calls.Count -ne 1) { throw "Expected one setup verification helper call." }
    $parameters = @{}
    foreach ($element in $calls[0].CommandElements) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $parameters[$element.ParameterName] = if ($null -ne $element.Argument) {
                $element.Argument.Extent.Text
            }
            else {
                ""
            }
        }
    }
    if ($parameters["ExactDisc"] -cne '$ExactDisc' -or
        $parameters["AllowPatchedImage"] -cne '$AllowPatchedImage') {
        throw "Setup does not forward both switch values to the helper."
    }
}

if ($Failures.Count -ne 0) {
    throw "$($Failures.Count) setup verification test(s) failed."
}
Write-Host "Setup verification tests passed: $Passed"

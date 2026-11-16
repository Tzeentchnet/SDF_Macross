function Get-SetupVerificationArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$InspectorPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ImagePath,

        [switch]$ExactDisc,

        [switch]$AllowPatchedImage
    )

    $arguments = @($InspectorPath, $ImagePath)
    if ($ExactDisc) {
        $arguments += "--exact"
    }
    if ($AllowPatchedImage) {
        $arguments += "--allow-patched"
    }
    return $arguments
}

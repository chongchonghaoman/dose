param([Parameter(Mandatory=$true)][int]$WindowHandle,[Parameter(Mandatory=$true)][string]$HelperPath)
$ErrorActionPreference='Stop'
# The generic helper uses GetWindowRect + CopyFromScreen. Use physical pixels
# consistently on Windows displays configured above 100% scale.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DoseScreenshotDpi {
    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
}
'@
[DoseScreenshotDpi]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
& $HelperPath -Mode temp -WindowHandle $WindowHandle

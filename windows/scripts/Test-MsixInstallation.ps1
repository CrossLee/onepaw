[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,

    [switch]$UseSetup,

    [ValidateRange(15, 240)]
    [int]$InstallerTimeoutSeconds = 120,

    [ValidateRange(5, 60)]
    [int]$LaunchTimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    [Environment]::OSVersion.Version.Build -lt 22000) {
    throw "Packaged Crosio acceptance requires Windows 11 build 22000 or later."
}
if ((Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1) {
    throw "Packaged Crosio product acceptance requires Windows 11, not Windows Server."
}
$osArchitecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432")
if ([string]::IsNullOrEmpty($osArchitecture)) {
    $osArchitecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
}
if ($osArchitecture -ne "ARM64") {
    throw "This installation acceptance test requires an ARM64 Windows 11 host; found $osArchitecture."
}

$windowAcceptancePath = Join-Path $PSScriptRoot "WindowAcceptance.ps1"
if (-not (Test-Path -LiteralPath $windowAcceptancePath -PathType Leaf)) {
    throw "The shared window acceptance helper was not found: $windowAcceptancePath"
}
. $windowAcceptancePath

$releaseDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
$brandName = -join @([char]0x4E00, [char]0x722A)
$setupAssetBrand = "OnePaw"
$expectedHomeName = -join @([char]0x9996, [char]0x9875)
$installerPath = Join-Path $releaseDirectory ((-join @([char]0x5B89, [char]0x88C5)) + "$brandName.ps1")
$buildInfoPath = Join-Path $releaseDirectory "build-info.json"
if (-not (Test-Path -LiteralPath $buildInfoPath -PathType Leaf)) {
    throw "Missing installation test input: $buildInfoPath"
}
$bundles = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter "*.msixbundle" -File)
if ($bundles.Count -ne 1) {
    throw "Expected exactly one MSIX bundle in $releaseDirectory; found $($bundles.Count)."
}
$buildInfo = Get-Content -Encoding UTF8 -LiteralPath $buildInfoPath -Raw | ConvertFrom-Json
$expectedVersion = [version]$buildInfo.version
if ($buildInfo.product -ne "Crosio" -or @($buildInfo.architectures) -notcontains "ARM64") {
    throw "The build information does not identify an ARM64 Crosio release."
}
$setupPath = Join-Path $releaseDirectory "$setupAssetBrand-Windows-$($buildInfo.version)-Setup.exe"
$selectedInstallerPath = if ($UseSetup) { $setupPath } else { $installerPath }
if (-not (Test-Path -LiteralPath $selectedInstallerPath -PathType Leaf)) {
    throw "Missing installation test input: $selectedInstallerPath"
}

# Read the bundle identity without extracting or running anything from it.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$bundleArchive = [System.IO.Compression.ZipFile]::OpenRead($bundles[0].FullName)
try {
    $entry = $bundleArchive.GetEntry("AppxMetadata/AppxBundleManifest.xml")
    if ($null -eq $entry) { throw "The bundle has no AppxBundleManifest.xml." }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try { $bundleManifest = [xml]$reader.ReadToEnd() }
    finally { $reader.Dispose() }
}
finally { $bundleArchive.Dispose() }
$bundleIdentity = $bundleManifest.DocumentElement.SelectSingleNode("*[local-name()='Identity']")
$armPackages = @($bundleManifest.DocumentElement.SelectNodes("*[local-name()='Packages']/*[local-name()='Package'][@Architecture='arm64' and @Type='application']"))
if ($null -eq $bundleIdentity -or $bundleIdentity.GetAttribute("Name") -ne "Crosio.Windows" -or
    [version]$bundleIdentity.GetAttribute("Version") -ne $expectedVersion -or $armPackages.Count -ne 1 -or
    [version]$armPackages[0].GetAttribute("Version") -ne $expectedVersion) {
    throw "The bundle identity or ARM64 payload does not match build-info.json."
}
$expectedPublisher = $bundleIdentity.GetAttribute("Publisher")

# Do not replace or remove an app that existed before this isolated CI test.
$existingPackages = @(Get-AppxPackage -AllUsers -Name "Crosio.Windows" -ErrorAction Stop)
if ($existingPackages.Count -ne 0) {
    throw "Crosio is already installed or staged for a user. Refusing to modify it."
}
if (@(Get-Process -Name "Crosio" -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "A Crosio process is already running. Refusing to redirect or terminate it."
}

if ($UseSetup) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
}

function ConvertFrom-UnicodeCodePoints {
    param(
        [Parameter(Mandatory)]
        [int[]]$CodePoints
    )

    return (-join @($CodePoints | ForEach-Object { [char]$_ }))
}

# Windows PowerShell 5.1 treats UTF-8 files without a BOM as ANSI. Keep this
# script ASCII-only and construct the installer's localized UI contract from
# Unicode code points so matching is stable on every runner code page.
$script:SetupWindowTitle = $brandName + " " + (ConvertFrom-UnicodeCodePoints @(0x5B89, 0x88C5))
$script:SetupInstallButtonPrefix = ConvertFrom-UnicodeCodePoints @(0x5B89, 0x88C5)
$script:SetupFinishButtonPrefix = ConvertFrom-UnicodeCodePoints @(0x5B8C, 0x6210)
$script:SetupFailureText = ConvertFrom-UnicodeCodePoints @(0x5B89, 0x88C5, 0x5931, 0x8D25)
$script:SetupIncompleteText = ConvertFrom-UnicodeCodePoints @(0x5B89, 0x88C5, 0x672A, 0x5B8C, 0x6210)
$script:SetupSystemInstallerText = ConvertFrom-UnicodeCodePoints @(0x7CFB, 0x7EDF, 0x5B89, 0x88C5, 0x670D, 0x52A1)
$script:SetupRunOptionPrefix = (ConvertFrom-UnicodeCodePoints @(0x7ACB, 0x5373, 0x6253, 0x5F00)) + " $brandName"
$script:SetupCompletionText = (ConvertFrom-UnicodeCodePoints @(
    0x8BF7, 0x5728, 0x5F00, 0x59CB, 0x83DC, 0x5355, 0x4E2D, 0x641C, 0x7D22)) + " $brandName"

function Format-SetupDiagnosticText {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "<none>"
    }

    $singleLine = ($Text -replace "\s+", " ").Trim()
    if ($singleLine.Length -gt 1000) {
        return $singleLine.Substring(0, 1000) + "..."
    }

    return $singleLine
}

function Format-SetupControlText {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $displayText = Format-SetupDiagnosticText -Text $Text
    $codePoints = if ($null -eq $Text) {
        "<null>"
    }
    else {
        (@($Text.ToCharArray() | ForEach-Object { "U+{0:X4}" -f [int]$_ }) -join ",")
    }
    return "$displayText [$codePoints]"
}

function Add-OwnedInstallerProcessHandle {
    param(
        [Parameter(Mandatory)]
        [hashtable]$StartTimes,

        [Parameter(Mandatory)]
        [hashtable]$Handles,

        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    if ($Handles.ContainsKey($ProcessId) -or -not $StartTimes.ContainsKey($ProcessId)) {
        return
    }

    try {
        $candidateProcess = Get-Process -Id $ProcessId -ErrorAction Stop
        $actualStart = $candidateProcess.StartTime.ToUniversalTime()
        $expectedStart = [DateTime]$StartTimes[$ProcessId]
        if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
            $candidateProcess.Dispose()
            return
        }

        # Opening the handle binds this Process object to the exact process,
        # rather than a PID that could later be reused during cleanup.
        $null = $candidateProcess.Handle
        $Handles[$ProcessId] = $candidateProcess
    }
    catch {
        # A short-lived helper can disappear before its handle is retained. It
        # cannot own a UI element by the time the next UI Automation query runs.
    }
}

function Update-OwnedInstallerProcesses {
    param(
        [Parameter(Mandatory)]
        [hashtable]$StartTimes,

        [Parameter(Mandatory)]
        [hashtable]$Handles,

        [Parameter(Mandatory)]
        [DateTime]$NotBeforeUtc
    )

    $snapshot = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    do {
        $added = $false
        foreach ($candidate in $snapshot) {
            $candidateProcessId = [int]$candidate.ProcessId
            $parentProcessId = [int]$candidate.ParentProcessId
            if ($StartTimes.ContainsKey($candidateProcessId) -or
                -not $StartTimes.ContainsKey($parentProcessId) -or
                -not $Handles.ContainsKey($parentProcessId)) {
                continue
            }

            $createdUtc = ([DateTime]$candidate.CreationDate).ToUniversalTime()
            if ($createdUtc -lt $NotBeforeUtc) {
                continue
            }

            # ParentProcessId is only a numeric snapshot and can be reused.
            # Trust it only while the retained handle proves that the exact
            # owned parent was alive when this candidate was created.
            try {
                $ownedParent = $Handles[$parentProcessId]
                $ownedParent.Refresh()
                if ($ownedParent.HasExited -and
                    $createdUtc -gt $ownedParent.ExitTime.ToUniversalTime()) {
                    continue
                }
            }
            catch {
                continue
            }

            $StartTimes[$candidateProcessId] = $createdUtc
            Add-OwnedInstallerProcessHandle -StartTimes $StartTimes -Handles $Handles -ProcessId $candidateProcessId
            if (-not $Handles.ContainsKey($candidateProcessId)) {
                [void]$StartTimes.Remove($candidateProcessId)
                continue
            }
            $added = $true
        }
    }
    while ($added)
}

function Test-OwnedInstallerProcessAlive {
    param(
        [Parameter(Mandatory)]
        [hashtable]$StartTimes,

        [Parameter(Mandatory)]
        [hashtable]$Handles
    )

    foreach ($processIdValue in @($StartTimes.Keys)) {
        Add-OwnedInstallerProcessHandle -StartTimes $StartTimes -Handles $Handles -ProcessId ([int]$processIdValue)
        if (-not $Handles.ContainsKey($processIdValue)) {
            continue
        }

        try {
            $ownedProcess = $Handles[$processIdValue]
            $ownedProcess.Refresh()
            if (-not $ownedProcess.HasExited) {
                return $true
            }
        }
        catch {
            # A retained process handle can disappear between Refresh and
            # HasExited; the next retained descendant still keeps the tree live.
        }
    }

    return $false
}

function Get-OwnedVisibleWindows {
    param(
        [Parameter(Mandatory)]
        [hashtable]$StartTimes,

        [Parameter(Mandatory)]
        [hashtable]$Handles
    )

    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $windows = $desktop.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($window in $windows) {
        try {
            $windowProcessId = [int]$window.Current.ProcessId
            if (-not $StartTimes.ContainsKey($windowProcessId)) {
                continue
            }

            Add-OwnedInstallerProcessHandle -StartTimes $StartTimes -Handles $Handles -ProcessId $windowProcessId
            if ($Handles.ContainsKey($windowProcessId)) {
                $ownedWindowProcess = $Handles[$windowProcessId]
                $ownedWindowProcess.Refresh()
                if (-not $ownedWindowProcess.HasExited -and
                    $window.Current.NativeWindowHandle -ne 0 -and
                    -not $window.Current.IsOffscreen) {
                    Write-Output $window
                }
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
            # The window closed while the desktop snapshot was being inspected.
        }
    }
}

function Assert-NoVisibleInstallerConsole {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Windows,

        [Parameter(Mandatory)]
        [hashtable]$Handles
    )

    foreach ($window in $Windows) {
        try {
            $windowProcessId = [int]$window.Current.ProcessId
            if (-not $Handles.ContainsKey($windowProcessId)) {
                continue
            }

            $processName = $Handles[$windowProcessId].ProcessName
            if ($processName -in @("powershell", "pwsh", "conhost", "OpenConsole", "cmd")) {
                throw "The GUI installer exposed a visible PowerShell or console window (PID=$windowProcessId)."
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
            # A disappearing window cannot remain visibly exposed.
        }
    }
}

function Get-AutomationElementText {
    param(
        [Parameter(Mandatory)]
        $Window
    )

    $elements = $Window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $names = foreach ($element in $elements) {
        try {
            $name = [string]$element.Current.Name
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $name
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }
    }

    return ($names -join "`n")
}

function Find-EnabledSetupButton {
    param(
        [Parameter(Mandatory)]
        $Window,

        [Parameter(Mandatory)]
        [string[]]$NamePrefixes
    )

    $candidateDiagnostics = [System.Collections.Generic.List[string]]::new()
    $elements = $Window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($element in $elements) {
        try {
            $elementName = [string]$element.Current.Name
            $elementType = $element.Current.ControlType.ProgrammaticName
            $elementEnabled = $element.Current.IsEnabled
            $elementAutomationId = [string]$element.Current.AutomationId
            $nameMatches = $false
            foreach ($prefix in $NamePrefixes) {
                if ($elementName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $nameMatches = $true
                    break
                }
            }

            if ($nameMatches -or
                $elementType -eq "ControlType.Button" -or
                $elementAutomationId -eq "1") {
                $elementText = Format-SetupControlText -Text $elementName
                [void]$candidateDiagnostics.Add(
                    "UIA Name=$elementText; Type=$elementType; Enabled=$elementEnabled; AutomationId=$elementAutomationId; HWND=$($element.Current.NativeWindowHandle)")
            }
            if (-not $nameMatches -or -not $elementEnabled) {
                continue
            }

            try {
                $null = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                $script:LastSetupButtonDiagnostics = Format-SetupDiagnosticText -Text ($candidateDiagnostics -join " || ")
                return [pscustomobject]@{
                    Element = $element
                    NativeHandle = [IntPtr]::Zero
                }
            }
            catch [System.InvalidOperationException] {
                # Some native NSIS controls expose their caption through UIA
                # without an InvokePattern. The exact dialog-item fallback
                # below still validates its class, caption, and enabled state.
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }
    }

    $dialogHandleValue = [int]$Window.Current.NativeWindowHandle
    $nativeButton = [Crosio.MsixAcceptance.Native]::GetDialogButton($dialogHandleValue, 1)
    if ($nativeButton -ne [IntPtr]::Zero) {
        $nativeName = [Crosio.MsixAcceptance.Native]::GetNativeWindowText($nativeButton)
        $nativeClass = [Crosio.MsixAcceptance.Native]::GetNativeWindowClass($nativeButton)
        $nativeEnabled = [Crosio.MsixAcceptance.Native]::GetNativeWindowEnabled($nativeButton)
        $nativeText = Format-SetupControlText -Text $nativeName
        [void]$candidateDiagnostics.Add(
            "Win32 ID=1; Name=$nativeText; Class=$nativeClass; Enabled=$nativeEnabled; HWND=$nativeButton")
        $nativeNameMatches = $false
        foreach ($prefix in $NamePrefixes) {
            if ($nativeName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $nativeNameMatches = $true
                break
            }
        }

        if ($nativeNameMatches -and $nativeEnabled -and $nativeClass -eq "Button") {
            $nativeElement = $null
            try {
                $nativeElement = [System.Windows.Automation.AutomationElement]::FromHandle($nativeButton)
            }
            catch [System.Windows.Automation.ElementNotAvailableException] {
                # The bounded native click below does not require a UIA proxy.
            }
            $script:LastSetupButtonDiagnostics = Format-SetupDiagnosticText -Text ($candidateDiagnostics -join " || ")
            return [pscustomobject]@{
                Element = $nativeElement
                NativeHandle = $nativeButton
            }
        }
    }

    $script:LastSetupButtonDiagnostics = Format-SetupDiagnosticText -Text ($candidateDiagnostics -join " || ")
    return $null
}

function Wait-ForSetupAction {
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [string[]]$ButtonPrefixes,

        [Parameter(Mandatory)]
        [DateTime]$DeadlineUtc,

        [Parameter(Mandatory)]
        [DateTime]$NotBeforeUtc,

        [Parameter(Mandatory)]
        [hashtable]$StartTimes,

        [Parameter(Mandatory)]
        [hashtable]$Handles,

        [int]$ExpectedWindowHandle = 0
    )

    $noProcessSince = $null
    $lastOwnedInstallerText = $null
    $lastButtonDiagnostics = "<none>"
    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        Update-OwnedInstallerProcesses -StartTimes $StartTimes -Handles $Handles -NotBeforeUtc $NotBeforeUtc
        $visibleWindows = @(Get-OwnedVisibleWindows -StartTimes $StartTimes -Handles $Handles)
        Assert-NoVisibleInstallerConsole -Windows $visibleWindows -Handles $Handles

        foreach ($window in $visibleWindows) {
            try {
                $windowTitle = [string]$window.Current.Name
                $windowHandle = [int]$window.Current.NativeWindowHandle
                if ($ExpectedWindowHandle -ne 0 -and $windowHandle -ne $ExpectedWindowHandle) {
                    continue
                }
                if ($ExpectedWindowHandle -eq 0 -and
                    -not $windowTitle.Trim().StartsWith(
                        $script:SetupWindowTitle,
                        [StringComparison]::Ordinal)) {
                    continue
                }

                $pageText = Get-AutomationElementText -Window $window
                $titleDiagnostic = Format-SetupControlText -Text $windowTitle
                $lastOwnedInstallerText = Format-SetupDiagnosticText -Text (
                    "Title=" + $titleDiagnostic + "; HWND=" + $windowHandle + " | " + $pageText)
                if ($pageText.Contains($script:SetupFailureText) -or
                    $pageText.Contains($script:SetupIncompleteText) -or
                    $pageText.Contains($script:SetupSystemInstallerText) -or
                    $pageText -match "Installation failed|Setup failed|installation was not completed") {
                    throw "The Crosio GUI installer displayed an error during $Stage. Installer UI: $lastOwnedInstallerText"
                }

                $button = Find-EnabledSetupButton -Window $window -NamePrefixes $ButtonPrefixes
                $lastButtonDiagnostics = $script:LastSetupButtonDiagnostics
                if ($null -ne $button) {
                    return [pscustomobject]@{
                        Window = $window
                        WindowHandle = $windowHandle
                        Button = $button
                        ProcessId = [int]$window.Current.ProcessId
                        PageText = $pageText
                    }
                }
            }
            catch [System.Windows.Automation.ElementNotAvailableException] {
            }
        }

        if (Test-OwnedInstallerProcessAlive -StartTimes $StartTimes -Handles $Handles) {
            $noProcessSince = $null
        }
        elseif ($null -eq $noProcessSince) {
            $noProcessSince = [DateTime]::UtcNow
        }
        elseif (([DateTime]::UtcNow - $noProcessSince).TotalSeconds -ge 1) {
            $diagnosticText = Format-SetupDiagnosticText -Text $lastOwnedInstallerText
            throw "The Crosio GUI installer exited before the $Stage action became available. Last installer UI: $diagnosticText. Button candidates: $lastButtonDiagnostics"
        }

        Start-Sleep -Milliseconds 100
    }

    $diagnosticText = Format-SetupDiagnosticText -Text $lastOwnedInstallerText
    throw "The Crosio GUI installer did not expose the $Stage action within $InstallerTimeoutSeconds seconds. Last installer UI: $diagnosticText. Button candidates: $lastButtonDiagnostics"
}

function Invoke-SetupAction {
    param(
        [Parameter(Mandatory)]
        $Button,

        [Parameter(Mandatory)]
        [string]$Stage
    )

    try {
        if ($null -ne $Button.Element) {
            try {
            $invokePattern = $Button.Element.GetCurrentPattern(
                [System.Windows.Automation.InvokePattern]::Pattern)
            [void]$invokePattern.Invoke()
            return
            }
            catch {
                if ($Button.NativeHandle -eq [IntPtr]::Zero) {
                    throw
                }
            }
        }

        # BM_CLICK is bounded by SendMessageTimeout and is used only after the
        # owned dialog's ID 1 child was verified as an enabled Button whose
        # caption exactly matches the expected stage.
        [Crosio.MsixAcceptance.Native]::ClickDialogButton($Button.NativeHandle, 2000)
    }
    catch {
        throw "The Crosio GUI installer's $Stage button could not be invoked through UI Automation: $($_.Exception.Message)"
    }
}

function Assert-SetupRunOptionUnchecked {
    param(
        [Parameter(Mandatory)]
        $Window
    )

    $elements = $Window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $runCheckBox = $null
    foreach ($element in $elements) {
        try {
            $elementName = [string]$element.Current.Name
            if ($elementName.StartsWith($script:SetupRunOptionPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $elementName.StartsWith("Run $brandName", [StringComparison]::OrdinalIgnoreCase)) {
                try {
                    $null = $element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                    $runCheckBox = $element
                }
                catch [System.InvalidOperationException] {
                }
                break
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }
    }

    if ($null -ne $runCheckBox) {
        $togglePattern = $runCheckBox.GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        if ($togglePattern.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
            throw "The Crosio GUI installer selected its run-Crosio option by default."
        }
        return
    }

    $dialogHandleValue = [int]$Window.Current.NativeWindowHandle
    $nativeCheckBox = [Crosio.MsixAcceptance.Native]::FindCheckBox(
        $dialogHandleValue,
        $script:SetupRunOptionPrefix)
    if ($nativeCheckBox -eq [IntPtr]::Zero) {
        throw "The Crosio GUI installer's Finish page has no uniquely identifiable optional run-Crosio checkbox."
    }
    if (-not [Crosio.MsixAcceptance.Native]::GetNativeWindowEnabled($nativeCheckBox)) {
        throw "The Crosio GUI installer's optional run-Crosio checkbox is disabled."
    }
    if ([Crosio.MsixAcceptance.Native]::GetCheckState($nativeCheckBox, 2000) -ne 0) {
        throw "The Crosio GUI installer selected its run-Crosio option by default."
    }
}

function Wait-ForOwnedInstallerExit {
    param(
        [Parameter(Mandatory)]
        [DateTime]$DeadlineUtc,

        [Parameter(Mandatory)]
        [DateTime]$NotBeforeUtc,

        [Parameter(Mandatory)]
        [hashtable]$StartTimes,

        [Parameter(Mandatory)]
        [hashtable]$Handles
    )

    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        Update-OwnedInstallerProcesses -StartTimes $StartTimes -Handles $Handles -NotBeforeUtc $NotBeforeUtc
        $visibleWindows = @(Get-OwnedVisibleWindows -StartTimes $StartTimes -Handles $Handles)
        Assert-NoVisibleInstallerConsole -Windows $visibleWindows -Handles $Handles
        if (-not (Test-OwnedInstallerProcessAlive -StartTimes $StartTimes -Handles $Handles)) {
            return
        }

        Start-Sleep -Milliseconds 100
    }

    throw "The Crosio GUI installer did not exit within $InstallerTimeoutSeconds seconds."
}

function Stop-OwnedInstallerProcesses {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Handles,

        [Parameter(Mandatory)]
        [int]$RootProcessId
    )

    # Stop retained descendants before their retained root. Every Process
    # object already owns a kernel handle opened while ancestry was verified.
    $orderedProcessIds = @($Handles.Keys | Sort-Object { if ([int]$_ -eq $RootProcessId) { 1 } else { 0 } })
    foreach ($processIdValue in $orderedProcessIds) {
        $ownedProcess = $Handles[$processIdValue]
        try {
            $ownedProcess.Refresh()
            if (-not $ownedProcess.HasExited) {
                $ownedProcess.Kill()
                if (-not $ownedProcess.WaitForExit(3000)) {
                    throw "PID $processIdValue did not stop."
                }
            }
        }
        catch {
            throw "Owned installer process cleanup failed for PID ${processIdValue}: $($_.Exception.Message)"
        }
    }
}

if ($null -eq ("Crosio.MsixAcceptance.Native" -as [type])) {
    # Interface signatures and GUIDs are from Microsoft's shobjidl_core.h.
    # CLSCTX_LOCAL_SERVER keeps activation arguments alive in the COM surrogate.
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Crosio.MsixAcceptance
{
    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager
    {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
        [PreserveSig] int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string appId,
            IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
        [PreserveSig] int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)] string appId,
            IntPtr items, out uint processId);
    }

    public sealed class ActivationOperation
    {
        private readonly object gate = new object();
        private readonly ManualResetEventSlim done = new ManualResetEventSlim(false);
        private readonly int acceptedExistingProcessId;
        private bool stopRequested;
        private Process process;
        private Exception error;
        private int returnedProcessId;

        internal ActivationOperation(string appId, string packageName)
            : this(appId, packageName, -1)
        {
        }

        internal ActivationOperation(string appId, string packageName, int acceptedExistingProcessId)
        {
            this.acceptedExistingProcessId = acceptedExistingProcessId;
            var thread = new Thread(() => Run(appId, packageName));
            thread.IsBackground = true;
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        public bool Wait(int milliseconds) { return done.Wait(milliseconds); }
        public Exception Error { get { return error; } }
        public Process Process { get { lock (gate) { return process; } } }
        public int ReturnedProcessId { get { return returnedProcessId; } }

        private void Run(string appId, string packageName)
        {
            IApplicationActivationManager manager = null;
            bool initialized = false;
            Process candidate = null;
            try
            {
                int result = Native.CoInitializeEx(IntPtr.Zero, 2);
                Marshal.ThrowExceptionForHR(result);
                initialized = true;
                var clsid = new Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c");
                var iid = typeof(IApplicationActivationManager).GUID;
                result = Native.CoCreateInstance(ref clsid, IntPtr.Zero, 4, ref iid, out manager);
                Marshal.ThrowExceptionForHR(result);
                DateTime activationStart = DateTime.UtcNow;
                uint processId;
                result = manager.ActivateApplication(appId, null, 2, out processId);
                Marshal.ThrowExceptionForHR(result);
                if (processId == 0) { throw new InvalidOperationException("Activation returned no process ID."); }
                returnedProcessId = checked((int)processId);
                if (returnedProcessId == acceptedExistingProcessId)
                {
                    return;
                }
                try
                {
                    candidate = System.Diagnostics.Process.GetProcessById(checked((int)processId));
                }
                catch (ArgumentException)
                {
                    // A redirect-only secondary can finish before its Process
                    // object is acquired. The original verified process must
                    // still restore its window before the test can pass.
                    if (acceptedExistingProcessId >= 0) { return; }
                    throw;
                }

                IntPtr handle;
                DateTime candidateStart;
                string candidatePackage;
                try
                {
                    handle = candidate.Handle; // Retain exactly this process, protecting against PID reuse.
                    candidateStart = candidate.StartTime.ToUniversalTime();
                    candidatePackage = Native.PackageFullName(handle);
                }
                catch
                {
                    bool candidateExited = false;
                    try
                    {
                        candidate.Refresh();
                        candidateExited = candidate.HasExited;
                    }
                    catch { candidateExited = true; }

                    if (acceptedExistingProcessId >= 0 && candidateExited)
                    {
                        candidate.Dispose();
                        candidate = null;
                        return;
                    }
                    throw;
                }

                if (candidateStart < activationStart.AddSeconds(-1) ||
                    !String.Equals(candidatePackage, packageName, StringComparison.Ordinal))
                {
                    candidate.Dispose();
                    candidate = null;
                    throw new InvalidOperationException("Activation did not create a new process with the expected package identity.");
                }
                lock (gate)
                {
                    if (stopRequested) { StopProcess(candidate); }
                    else { process = candidate; }
                    candidate = null;
                }
            }
            catch (Exception failure) { error = failure; }
            finally
            {
                // An unverified candidate is never terminated.
                if (candidate != null) { candidate.Dispose(); }
                try
                {
                    if (manager != null) { Marshal.FinalReleaseComObject(manager); }
                }
                catch (Exception releaseFailure) { if (error == null) { error = releaseFailure; } }
                finally
                {
                    if (initialized) { Native.CoUninitialize(); }
                    done.Set();
                }
            }
        }

        private static void StopProcess(Process ownedProcess)
        {
            try
            {
                if (!ownedProcess.HasExited)
                {
                    ownedProcess.Kill();
                    if (!ownedProcess.WaitForExit(3000))
                    {
                        throw new InvalidOperationException("The activated test process did not stop.");
                    }
                }
            }
            finally { ownedProcess.Dispose(); }
        }

        public void Stop()
        {
            lock (gate)
            {
                stopRequested = true;
                if (process != null)
                {
                    Process ownedProcess = process;
                    process = null;
                    StopProcess(ownedProcess);
                }
            }
        }
    }

    public static class Native
    {
        internal static ActivationOperation StartCore(string appId, string packageName)
        { return new ActivationOperation(appId, packageName); }
        public static ActivationOperation Start(string appId, string packageName)
        { return StartCore(appId, packageName); }
        public static ActivationOperation StartRedirect(string appId, string packageName, int existingProcessId)
        { return new ActivationOperation(appId, packageName, existingProcessId); }

        [DllImport("ole32.dll")] internal static extern int CoInitializeEx(IntPtr reserved, uint flags);
        [DllImport("ole32.dll")] internal static extern void CoUninitialize();
        [DllImport("ole32.dll")] internal static extern int CoCreateInstance(ref Guid clsid,
            IntPtr outer, uint context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IApplicationActivationManager manager);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern int GetPackageFullName(
            IntPtr process, ref uint length, StringBuilder name);
        private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);
        private delegate bool EnumChildWindowsCallback(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int GetWindowTextW(IntPtr window, StringBuilder title, int capacity);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int GetClassNameW(IntPtr window, StringBuilder className, int capacity);
        [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr dialog, int itemId);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowEnabled(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, UIntPtr wParam,
            IntPtr lParam, uint flags, uint timeoutMilliseconds, out UIntPtr result);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumChildWindows(
            IntPtr parent, EnumChildWindowsCallback callback, IntPtr parameter);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);

        public static IntPtr GetDialogButton(int automationDialogHandle, int itemId)
        {
            var dialog = new IntPtr(unchecked((long)(uint)automationDialogHandle));
            return GetDlgItem(dialog, itemId);
        }

        public static string GetNativeWindowText(IntPtr window)
        {
            var text = new StringBuilder(512);
            GetWindowTextW(window, text, text.Capacity);
            return text.ToString();
        }

        public static string GetNativeWindowClass(IntPtr window)
        {
            var className = new StringBuilder(128);
            GetClassNameW(window, className, className.Capacity);
            return className.ToString();
        }

        public static bool GetNativeWindowEnabled(IntPtr window) { return IsWindowEnabled(window); }

        public static IntPtr FindCheckBox(int automationDialogHandle, string captionPrefix)
        {
            var dialog = new IntPtr(unchecked((long)(uint)automationDialogHandle));
            IntPtr found = IntPtr.Zero;
            bool ambiguous = false;
            bool succeeded = EnumChildWindows(dialog, (window, parameter) =>
            {
                long buttonType = GetWindowLongPtrW(window, -16).ToInt64() & 0x0f;
                bool checkBoxStyle = buttonType == 2 || buttonType == 3 || buttonType == 5 || buttonType == 6;
                if (checkBoxStyle &&
                    String.Equals(GetNativeWindowClass(window), "Button", StringComparison.Ordinal) &&
                    GetNativeWindowText(window).StartsWith(captionPrefix, StringComparison.OrdinalIgnoreCase))
                {
                    if (found == IntPtr.Zero) { found = window; }
                    else if (found != window) { ambiguous = true; }
                }
                return true;
            }, IntPtr.Zero);
            if (!succeeded) { throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumChildWindows failed."); }
            return ambiguous ? IntPtr.Zero : found;
        }

        public static uint GetCheckState(IntPtr checkBox, uint timeoutMilliseconds)
        {
            UIntPtr result;
            IntPtr sent = SendMessageTimeoutW(checkBox, 0x00F0, UIntPtr.Zero, IntPtr.Zero,
                0x0001 | 0x0002, timeoutMilliseconds, out result);
            if (sent == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Reading the native installer checkbox timed out or failed.");
            }
            return checked((uint)result.ToUInt64());
        }

        public static void ClickDialogButton(IntPtr button, uint timeoutMilliseconds)
        {
            if (button == IntPtr.Zero || !IsWindowEnabled(button) ||
                !String.Equals(GetNativeWindowClass(button), "Button", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The validated native installer button is no longer actionable.");
            }

            UIntPtr result;
            IntPtr sent = SendMessageTimeoutW(button, 0x00F5, UIntPtr.Zero, IntPtr.Zero,
                0x0001 | 0x0002, timeoutMilliseconds, out result);
            if (sent == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "The native installer button click timed out or failed.");
            }
        }

        internal static string PackageFullName(IntPtr handle)
        {
            uint length = 0;
            int result = GetPackageFullName(handle, ref length, null);
            if (result != 122) { throw new Win32Exception(result, "Activated process has no readable package identity."); }
            var name = new StringBuilder(checked((int)length));
            result = GetPackageFullName(handle, ref length, name);
            if (result != 0) { throw new Win32Exception(result); }
            return name.ToString();
        }

        public static IntPtr FindMainWindow(int processId)
        {
            IntPtr found = IntPtr.Zero;
            bool succeeded = EnumWindows((window, parameter) =>
            {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner == (uint)processId && IsWindowVisible(window))
                {
                    var title = new StringBuilder(256);
                    GetWindowTextW(window, title, title.Capacity);
                    if (String.Equals(title.ToString(), "\u4e00\u722a", StringComparison.Ordinal)) { found = window; }
                }
                return true;
            }, IntPtr.Zero);
            if (!succeeded) { throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed."); }
            return found;
        }
    }
}
"@
}

$installationAttempted = $false
$installedPackageFullName = $null
$activation = $null
$reactivation = $null
$failure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$activatedProcessId = $null
$reactivationProcessId = $null
$mainWindow = [IntPtr]::Zero
$mainWindowAssessment = $null
$lastMainWindowAssessment = $null
$setupAttempts = [System.Collections.Generic.List[object]]::new()
try {
    $installationAttempted = $true
    if ($UseSetup) {
        foreach ($setupAttemptNumber in 1..2) {
            # Each run gets an isolated ownership graph. Exited processes from
            # attempt one must never satisfy or terminate attempt two, even if
            # Windows reuses a PID between the two launches.
            $setupNotBeforeUtc = [DateTime]::UtcNow.AddSeconds(-1)
            $setupDeadlineUtc = [DateTime]::UtcNow.AddSeconds($InstallerTimeoutSeconds)
            $setupUiProcessIds = [System.Collections.Generic.HashSet[int]]::new()
            $setupOwnedStartTimes = @{}
            $setupOwnedHandles = @{}
            $setupRootProcess = Start-Process `
                -FilePath $setupPath `
                -WorkingDirectory $releaseDirectory `
                -PassThru
            $setupRootProcessId = $setupRootProcess.Id
            $null = $setupRootProcess.Handle
            $setupRootStartUtc = $setupRootProcess.StartTime.ToUniversalTime()
            $setupOwnedStartTimes[$setupRootProcessId] = $setupRootStartUtc
            $setupOwnedHandles[$setupRootProcessId] = $setupRootProcess
            $setupAttemptState = [pscustomobject]@{
                Number = $setupAttemptNumber
                RootProcessId = $setupRootProcessId
                NotBeforeUtc = $setupNotBeforeUtc
                StartTimes = $setupOwnedStartTimes
                Handles = $setupOwnedHandles
                Completed = $false
            }
            [void]$setupAttempts.Add($setupAttemptState)

            $installAction = Wait-ForSetupAction `
                -Stage "Install (attempt $setupAttemptNumber)" `
                -ButtonPrefixes @($script:SetupInstallButtonPrefix, "Install") `
                -DeadlineUtc $setupDeadlineUtc `
                -NotBeforeUtc $setupNotBeforeUtc `
                -StartTimes $setupOwnedStartTimes `
                -Handles $setupOwnedHandles
            [void]$setupUiProcessIds.Add($installAction.ProcessId)
            Invoke-SetupAction -Button $installAction.Button -Stage "Install (attempt $setupAttemptNumber)"

            $finishAction = Wait-ForSetupAction `
                -Stage "Finish (attempt $setupAttemptNumber)" `
                -ButtonPrefixes @($script:SetupFinishButtonPrefix, "Finish") `
                -DeadlineUtc $setupDeadlineUtc `
                -NotBeforeUtc $setupNotBeforeUtc `
                -StartTimes $setupOwnedStartTimes `
                -Handles $setupOwnedHandles `
                -ExpectedWindowHandle $installAction.WindowHandle
            [void]$setupUiProcessIds.Add($finishAction.ProcessId)
            if (-not $finishAction.PageText.Contains($script:SetupCompletionText)) {
                throw "The Crosio GUI installer did not reach its expected successful Finish page on attempt $setupAttemptNumber."
            }
            Assert-SetupRunOptionUnchecked -Window $finishAction.Window
            Invoke-SetupAction -Button $finishAction.Button -Stage "Finish (attempt $setupAttemptNumber)"

            Wait-ForOwnedInstallerExit `
                -DeadlineUtc $setupDeadlineUtc `
                -NotBeforeUtc $setupNotBeforeUtc `
                -StartTimes $setupOwnedStartTimes `
                -Handles $setupOwnedHandles

            $exitProcessIds = @($setupRootProcessId) + @($setupUiProcessIds)
            foreach ($exitProcessId in @($exitProcessIds | Select-Object -Unique)) {
                if (-not $setupOwnedHandles.ContainsKey([int]$exitProcessId)) {
                    throw "GUI installer attempt $setupAttemptNumber did not retain an exact handle for UI process $exitProcessId."
                }

                $exitProcess = $setupOwnedHandles[[int]$exitProcessId]
                $exitProcess.Refresh()
                if (-not $exitProcess.HasExited) {
                    throw "GUI installer attempt $setupAttemptNumber process $exitProcessId remained active after Finish."
                }
                if ($exitProcess.ExitCode -ne 0) {
                    throw "GUI installer attempt $setupAttemptNumber process $exitProcessId returned exit code $($exitProcess.ExitCode)."
                }
            }

            if (@(Get-Process -Name "Crosio" -ErrorAction SilentlyContinue).Count -ne 0) {
                throw "GUI installer attempt $setupAttemptNumber launched Crosio even though its optional launch checkbox was clear."
            }
            $setupAttemptState.Completed = $true
            foreach ($completedHandle in @($setupOwnedHandles.Values)) {
                $completedHandle.Dispose()
            }
            $setupOwnedHandles.Clear()
            Write-Host "Crosio Setup.exe GUI attempt $setupAttemptNumber of 2 completed through UI Automation."
        }
    }
    else {
        & $installerPath -PackagePath $bundles[0].FullName
    }

    $packages = @(Get-AppxPackage -Name "Crosio.Windows" -ErrorAction Stop)
    if ($packages.Count -ne 1) { throw "Installation did not register exactly one Crosio package." }
    $package = $packages[0]
    if ($package.Publisher -ne $expectedPublisher -or [version]$package.Version -ne $expectedVersion) {
        throw "Installed Crosio identity does not match the supplied bundle."
    }
    $installedPackageFullName = $package.PackageFullName
    if ($package.Architecture.ToString() -ne "Arm64") {
        throw "The ARM64 host installed $($package.Architecture) instead of ARM64."
    }
    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName -ErrorAction Stop
    $ns = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
    $ns.AddNamespace("f", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $ns.AddNamespace("desktop5", "http://schemas.microsoft.com/appx/manifest/desktop/windows10/5")
    $ns.AddNamespace("desktop", "http://schemas.microsoft.com/appx/manifest/desktop/windows10")
    $ns.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
    if ($manifest.SelectSingleNode("/f:Package/f:Properties/f:DisplayName", $ns).InnerText -ne $brandName -or
        $manifest.SelectSingleNode("//uap:VisualElements", $ns).GetAttribute("DisplayName") -ne $brandName) {
        throw "The installed package does not use the current display name."
    }
    $verbs = @($manifest.SelectNodes("//desktop5:Verb", $ns))
    $itemTypes = @($manifest.SelectNodes("//desktop5:ItemType", $ns) | ForEach-Object { $_.GetAttribute("Type") })
    if ($verbs.Count -ne 2 -or $itemTypes -notcontains "*" -or $itemTypes -notcontains "Directory" -or
        @($verbs | Where-Object { $_.GetAttribute("Clsid") -ne "6EA97827-5B42-4E82-8ABC-4FC22D3BE129" }).Count -ne 0) {
        throw "Installed package is missing its file/folder Copy Path registrations."
    }
    $startup = $manifest.SelectSingleNode("//desktop:StartupTask[@TaskId='CrosioStartupTask']", $ns)
    if ($null -eq $startup -or $startup.GetAttribute("Enabled") -ne "false" -or
        $startup.GetAttribute("DisplayName") -ne $brandName) {
        throw "Installed package is missing its opt-in startup task."
    }
    $actualTypes = @($manifest.SelectNodes("//uap:FileTypeAssociation[@Name='crosio.images']/uap:SupportedFileTypes/uap:FileType", $ns) | ForEach-Object { $_.InnerText })
    $expectedTypes = @(".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".heic", ".heif", ".tif", ".tiff")
    $actualTypesKey = ($actualTypes | Sort-Object) -join "|"
    $expectedTypesKey = ($expectedTypes | Sort-Object) -join "|"
    if ($actualTypesKey -ne $expectedTypesKey) {
        throw "Installed package does not register the expected nine image types."
    }
    $application = $manifest.SelectSingleNode("/f:Package/f:Applications/f:Application[@Id='App']", $ns)
    if ($null -eq $application) { throw "Installed package has no App activation entry." }
    $aumid = "$($package.PackageFamilyName)!$($application.GetAttribute('Id'))"
    Write-Host "Installed $installedPackageFullName. Activating registered AUMID $aumid."

    $launchWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $activation = [Crosio.MsixAcceptance.Native]::Start($aumid, $installedPackageFullName)
    if (-not $activation.Wait($LaunchTimeoutSeconds * 1000)) {
        throw "Registered package activation exceeded $LaunchTimeoutSeconds seconds."
    }
    if ($null -ne $activation.Error) { throw $activation.Error }
    $startedProcess = $activation.Process
    if ($null -eq $startedProcess) { throw "Registered activation yielded no owned process." }
    $activatedProcessId = $startedProcess.Id
    $visibleSince = $null
    $visibleHandle = [IntPtr]::Zero
    while ($launchWatch.Elapsed.TotalSeconds -lt $LaunchTimeoutSeconds) {
        $startedProcess.Refresh()
        if ($startedProcess.HasExited) { throw "Installed Crosio exited during startup. ExitCode=$($startedProcess.ExitCode)" }
        $candidate = [Crosio.MsixAcceptance.Native]::FindMainWindow($activatedProcessId)
        if ($candidate -ne [IntPtr]::Zero) {
            $candidateAssessment = Get-OnePawInteractiveWindowAssessment `
                -WindowHandle $candidate `
                -ExpectedHomeName $expectedHomeName
            $lastMainWindowAssessment = $candidateAssessment
            if ($candidateAssessment.Accepted) {
                if ($null -eq $visibleSince -or $visibleHandle -ne $candidate) {
                    $visibleSince = $launchWatch.Elapsed
                    $visibleHandle = $candidate
                }
                if (($launchWatch.Elapsed - $visibleSince).TotalSeconds -ge 1) {
                    $mainWindow = $candidate
                    $mainWindowAssessment = $candidateAssessment
                    break
                }
            }
            else {
                $visibleSince = $null
                $visibleHandle = [IntPtr]::Zero
            }
        }
        else {
            $visibleSince = $null
            $visibleHandle = [IntPtr]::Zero
        }
        Start-Sleep -Milliseconds 150
    }
    if ($mainWindow -eq [IntPtr]::Zero) {
        $assessmentDiagnostic = if ($null -eq $lastMainWindowAssessment) {
            "<no titled visible window was inspected>"
        }
        else {
            $lastMainWindowAssessment.Summary
        }
        throw (
            "Installed Crosio did not show a stable, onscreen, restored and UIA-ready main window " +
            "within $LaunchTimeoutSeconds seconds. LastAssessment=$assessmentDiagnostic"
        )
    }

    # Reproduce the resident-app path that a user's second Start-menu launch
    # takes. Hide the exact verified primary window, activate the same AUMID
    # again, and require the original process to restore a usable main window.
    if (-not [Crosio.WindowAcceptance.NativeWindow]::HideWindow($mainWindow)) {
        throw "ShowWindow(SW_HIDE) reported that the verified main window was not previously visible."
    }
    $hideDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $hiddenState = [Crosio.WindowAcceptance.NativeWindow]::Inspect($mainWindow)
        if (-not $hiddenState.Visible) { break }
        Start-Sleep -Milliseconds 100
    }
    while ([DateTime]::UtcNow -lt $hideDeadline)
    if ($hiddenState.Visible) {
        throw "The verified main window did not become hidden before redirected activation."
    }

    $startedProcess.Refresh()
    if ($startedProcess.HasExited) {
        throw "Installed Crosio exited while its main window was hidden. ExitCode=$($startedProcess.ExitCode)"
    }

    Write-Host "Main window hidden. Reactivating registered AUMID while PID $activatedProcessId remains resident."
    $reactivation = [Crosio.MsixAcceptance.Native]::StartRedirect(
        $aumid,
        $installedPackageFullName,
        $activatedProcessId)
    if (-not $reactivation.Wait($LaunchTimeoutSeconds * 1000)) {
        throw "Redirected package activation exceeded $LaunchTimeoutSeconds seconds."
    }
    if ($null -ne $reactivation.Error) { throw $reactivation.Error }
    $reactivationProcessId = $reactivation.ReturnedProcessId
    $reactivationWatch = [System.Diagnostics.Stopwatch]::StartNew()

    $restoredWindow = [IntPtr]::Zero
    $restoredAssessment = $null
    $restoredSince = $null
    $restoredHandle = [IntPtr]::Zero
    $lastRestoredAssessment = $null
    while ($reactivationWatch.Elapsed.TotalSeconds -lt $LaunchTimeoutSeconds) {
        $startedProcess.Refresh()
        if ($startedProcess.HasExited) {
            throw "The original installed Crosio process exited during redirected activation. ExitCode=$($startedProcess.ExitCode)"
        }

        $candidate = [Crosio.MsixAcceptance.Native]::FindMainWindow($activatedProcessId)
        if ($candidate -ne [IntPtr]::Zero) {
            $candidateAssessment = Get-OnePawInteractiveWindowAssessment `
                -WindowHandle $candidate `
                -ExpectedHomeName $expectedHomeName
            $lastRestoredAssessment = $candidateAssessment
            if ($candidateAssessment.Accepted) {
                if ($null -eq $restoredSince -or $restoredHandle -ne $candidate) {
                    $restoredSince = $reactivationWatch.Elapsed
                    $restoredHandle = $candidate
                }
                if (($reactivationWatch.Elapsed - $restoredSince).TotalSeconds -ge 1) {
                    $restoredWindow = $candidate
                    $restoredAssessment = $candidateAssessment
                    break
                }
            }
            else {
                $restoredSince = $null
                $restoredHandle = [IntPtr]::Zero
            }
        }
        else {
            $restoredSince = $null
            $restoredHandle = [IntPtr]::Zero
        }
        Start-Sleep -Milliseconds 150
    }

    if ($restoredWindow -eq [IntPtr]::Zero) {
        $assessmentDiagnostic = if ($null -eq $lastRestoredAssessment) {
            "<the original process exposed no titled visible window>"
        }
        else {
            $lastRestoredAssessment.Summary
        }
        throw (
            "Redirected activation did not restore an onscreen, UIA-ready main window in the original process " +
            "within $LaunchTimeoutSeconds seconds. ReturnedPID=$reactivationProcessId; " +
            "LastAssessment=$assessmentDiagnostic"
        )
    }

    $redirectProcess = $reactivation.Process
    if ($null -ne $redirectProcess) {
        if (-not $redirectProcess.WaitForExit(5000)) {
            throw "The redirect-only activation process remained active after restoring the primary window. PID=$($redirectProcess.Id)"
        }
        if ($redirectProcess.ExitCode -ne 0) {
            throw "The redirect-only activation process exited with code $($redirectProcess.ExitCode). PID=$($redirectProcess.Id)"
        }
    }

    $mainWindow = $restoredWindow
    $mainWindowAssessment = $restoredAssessment
    Write-Host (
        "Resident-process reactivation restored the main window. " +
        "PrimaryPID=$activatedProcessId; ActivationPID=$reactivationProcessId; HWND=$mainWindow; " +
        $mainWindowAssessment.Summary
    )
}
catch { $failure = $_.Exception }
finally {
    if ($null -ne $reactivation) {
        try { $reactivation.Stop() }
        catch { $cleanupFailures.Add("Redirect activation process cleanup: $($_.Exception.Message)") }
    }
    if ($null -ne $activation) {
        try { $activation.Stop() }
        catch { $cleanupFailures.Add("Process cleanup: $($_.Exception.Message)") }
    }
    foreach ($setupAttemptState in @($setupAttempts)) {
        if (-not $setupAttemptState.Completed) {
            try {
                Update-OwnedInstallerProcesses `
                    -StartTimes $setupAttemptState.StartTimes `
                    -Handles $setupAttemptState.Handles `
                    -NotBeforeUtc $setupAttemptState.NotBeforeUtc
            }
            catch {
                $cleanupFailures.Add("Installer attempt $($setupAttemptState.Number) process discovery cleanup: $($_.Exception.Message)")
            }
            try {
                Stop-OwnedInstallerProcesses `
                    -Handles $setupAttemptState.Handles `
                    -RootProcessId $setupAttemptState.RootProcessId
            }
            catch {
                $cleanupFailures.Add("Installer attempt $($setupAttemptState.Number) process cleanup: $($_.Exception.Message)")
            }
        }
    }
    if ($installationAttempted) {
        try {
            # Also recover a registration created before the installer threw.
            # Preflight proved no existing Crosio package; match this bundle's identity.
            $installedByTest = @(Get-AppxPackage -Name "Crosio.Windows" -ErrorAction Stop |
                Where-Object { $_.Publisher -eq $expectedPublisher -and [version]$_.Version -eq $expectedVersion })
            foreach ($testPackage in $installedByTest) {
                Remove-AppxPackage -Package $testPackage.PackageFullName -ErrorAction Stop
            }
            if (@(Get-AppxPackage -Name "Crosio.Windows" -ErrorAction Stop |
                Where-Object { $_.Publisher -eq $expectedPublisher -and [version]$_.Version -eq $expectedVersion }).Count -ne 0) {
                throw "The package installed by this acceptance test remains registered."
            }
        }
        catch { $cleanupFailures.Add("Package cleanup: $($_.Exception.Message)") }
    }
    foreach ($setupAttemptState in @($setupAttempts)) {
        foreach ($ownedInstallerHandle in @($setupAttemptState.Handles.Values)) {
            try { $ownedInstallerHandle.Dispose() }
            catch {
                $cleanupFailures.Add("Installer attempt $($setupAttemptState.Number) handle cleanup: $($_.Exception.Message)")
            }
        }
    }
}

if ($null -ne $failure -or $cleanupFailures.Count -gt 0) {
    $messages = @()
    if ($null -ne $failure) { $messages += $failure.Message }
    $messages += @($cleanupFailures)
    throw "Windows 11 ARM64 MSIX acceptance failed: $($messages -join ' | ')"
}
$installerMode = if ($UseSetup) { "Setup.exe GUI" } else { "direct MSIX" }
Write-Host (
    "Windows 11 ARM64 $installerMode acceptance passed: Version=$expectedVersion; " +
    "Package=$installedPackageFullName; PID=$activatedProcessId; ReactivationPID=$reactivationProcessId; " +
    "HWND=$mainWindow; $($mainWindowAssessment.Summary). Test processes stopped and test package removed."
)

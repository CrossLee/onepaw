[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [string]$PackageDirectory,

    [switch]$AllowUnsignedTestPackage,

    [switch]$RequirePreparedNsis
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Packaging.Common.ps1")
Assert-CrosioMsixVersion -Version $Version
if ($env:OS -ne "Windows_NT") {
    throw "The release Setup.exe must be built on Windows with pinned NSIS 3.12."
}

$windowsRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    $PackageDirectory = Join-Path $windowsRoot "artifacts/release"
}
$releaseDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
$installerSource = Join-Path $windowsRoot "installer"
$buildInfoPath = Join-Path $releaseDirectory "build-info.json"
$checksumsPath = Join-Path $releaseDirectory "SHA256SUMS.txt"
$buildInfo = Get-Content -Encoding UTF8 -LiteralPath $buildInfoPath -Raw | ConvertFrom-Json
if ($buildInfo.product -ne "Crosio" -or $buildInfo.version -ne $Version -or
    @($buildInfo.architectures).Count -ne 2 -or @($buildInfo.architectures) -notcontains "x64" -or
    @($buildInfo.architectures) -notcontains "ARM64" -or $buildInfo.signed -isnot [bool]) {
    throw "build-info.json does not identify the expected universal Crosio release."
}
$flavor = if ($buildInfo.signed) { "signed" } else { "unsigned-test" }
if ($buildInfo.artifactKind -ne $flavor -or (-not $buildInfo.signed -and -not $AllowUnsignedTestPackage)) {
    throw "Unsigned preview input requires explicit -AllowUnsignedTestPackage; signed metadata must match the bundle."
}
$bundlePath = Join-Path $releaseDirectory "一爪-Windows-$Version-$flavor.msixbundle"
$bundles = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter "*.msixbundle" -File)
if ($bundles.Count -ne 1 -or $bundles[0].FullName -ne $bundlePath) {
    throw "Expected exactly the same-run $Version universal MSIX bundle."
}

# Verify the original manifest before adding our seventh checksum. Reject
# arbitrary paths, duplicates, or stale payloads rather than wrapping them.
$setupName = "OnePaw-Windows-$Version-Setup.exe"
$checksums = @(Get-Content -Encoding UTF8 -LiteralPath $checksumsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$originalChecksums = @()
$seenNames = @{}
$bundleHash = $null
$expectedSourceNames = @(
    "一爪-Windows-$Version-x64-$flavor.msix",
    "一爪-Windows-$Version-arm64-$flavor.msix",
    "一爪-Windows-$Version-$flavor.msixbundle",
    "THIRD_PARTY_NOTICES.md", "安装一爪.ps1", "TESTING.md"
)
foreach ($line in $checksums) {
    if ($line -notmatch '^([0-9a-fA-F]{64})  ([^\\/]+)$') { throw "Invalid SHA256SUMS line: $line" }
    $hash = $Matches[1]
    $name = $Matches[2]
    if ($name -eq $setupName) { continue }
    if ($name -notin $expectedSourceNames -or $seenNames.ContainsKey($name)) { throw "Unexpected or duplicate checksum file: $name" }
    $seenNames[$name] = $true
    $filePath = Join-Path $releaseDirectory $name
    if ((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash -ne $hash) { throw "Release checksum mismatch: $name" }
    if ($filePath -eq $bundlePath) { $bundleHash = $hash.ToLowerInvariant() }
    $originalChecksums += $line
}
if ($originalChecksums.Count -ne 6 -or [string]::IsNullOrWhiteSpace($bundleHash)) {
    throw "Expected all six original release checksums, including the universal bundle."
}
$signature = Get-AuthenticodeSignature -FilePath $bundlePath
if ($buildInfo.signed) {
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "The signed input bundle does not have a trusted valid signature: $($signature.Status)."
    }
}
elseif ($signature.Status -ne [System.Management.Automation.SignatureStatus]::NotSigned) {
    throw "The preview bundle has an invalid or unexpected signature: $($signature.Status)."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($bundlePath)
try {
    $entry = $archive.GetEntry("AppxMetadata/AppxBundleManifest.xml")
    if ($null -eq $entry) { throw "The MSIX bundle manifest is missing." }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try { $manifest = [xml]$reader.ReadToEnd() }
    finally { $reader.Dispose() }
}
finally { $archive.Dispose() }
$identity = $manifest.DocumentElement.SelectSingleNode("*[local-name()='Identity']")
if ($null -eq $identity -or $identity.GetAttribute("Name") -ne "Crosio.Windows" -or
    [version]$identity.GetAttribute("Version") -ne [version]$Version) {
    throw "The bundle identity/version does not match this Setup.exe."
}
foreach ($architecture in @("x64", "arm64")) {
    $packages = @($manifest.DocumentElement.SelectNodes("*[local-name()='Packages']/*[local-name()='Package'][@Type='application' and @Architecture='$architecture']"))
    if ($packages.Count -ne 1 -or [version]$packages[0].GetAttribute("Version") -ne [version]$Version) {
        throw "The bundle does not contain exactly one matching $architecture application."
    }
}

# Pin both the release and the installer digest. The official download URL and
# SHA256 are independently published by Microsoft's winget-pkgs manifest:
# https://github.com/microsoft/winget-pkgs/blob/master/manifests/n/NSIS/NSIS/3.12/NSIS.NSIS.installer.yaml
$nsisVersion = "3.12"
$nsisSetupHash = "3BC2B06253A7E4957111BE152AC6A536E0C7478A706E19DA814038DB5D706495"
$nsisSetupSize = 1566914
$toolsDirectory = Join-Path $windowsRoot "artifacts/tools"
New-Item -ItemType Directory -Path $toolsDirectory -Force | Out-Null
$nsisDownload = Join-Path $toolsDirectory "nsis-$nsisVersion-setup.exe"

function Test-NsisDownload {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $length = (Get-Item -LiteralPath $Path).Length
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $stream = [System.IO.File]::OpenRead($Path)
    try { $isPe = $stream.ReadByte() -eq 0x4d -and $stream.ReadByte() -eq 0x5a }
    finally { $stream.Dispose() }
    if ($length -eq $nsisSetupSize -and $isPe -and $hash -eq $nsisSetupHash) { return $true }
    Write-Warning "Rejected NSIS download: bytes=$length; SHA256=$hash; MZ=$isPe. Expected bytes=$nsisSetupSize; SHA256=$nsisSetupHash. No downloaded code was executed."
    return $false
}

# /projects/.../download can return an HTML interstitial with HTTP 200 on CI.
# These are SourceForge's official direct-file endpoints and download mirror.
# Every attempt, including cached files, must match the unchanged winget pin.
if (-not (Test-NsisDownload -Path $nsisDownload)) {
    if ($RequirePreparedNsis) {
        throw "The prepared NSIS 3.12 artifact is missing or invalid at $nsisDownload. CI requires the verified same-run tool artifact; Windows network fallback is disabled."
    }
    # This fallback is for local Windows builds only. CI prepares and verifies
    # the tool on Ubuntu before the expensive Windows build starts. Use the
    # system curl client rather than Invoke-WebRequest, which SourceForge can
    # serve an HTML interstitial even from its nominal direct-file endpoints.
    $curlPath = Join-Path $env:WINDIR "System32/curl.exe"
    if (-not (Test-Path -LiteralPath $curlPath -PathType Leaf)) {
        throw "The Windows system curl client is missing. Supply the pinned prepared NSIS tool artifact."
    }
    $downloadUrls = @(
        "https://sourceforge.net/projects/nsis/files/NSIS%203/3.12/nsis-3.12-setup.exe/download",
        "https://downloads.sourceforge.net/project/nsis/NSIS%203/3.12/nsis-3.12-setup.exe",
        "https://prdownloads.sourceforge.net/nsis/nsis-3.12-setup.exe?download",
        "https://pilotfiber.dl.sourceforge.net/project/nsis/NSIS%203/3.12/nsis-3.12-setup.exe"
    )
    $downloadVerified = $false
    foreach ($downloadUrl in $downloadUrls) {
        $attemptPath = Join-Path $toolsDirectory ("nsis-3.12-" + [Guid]::NewGuid().ToString("N") + ".download")
        try {
            Write-Host "Downloading pinned NSIS 3.12 from $downloadUrl"
            Invoke-CrosioChecked -Command $curlPath -Arguments @(
                "--fail", "--location", "--silent", "--show-error",
                "--proto", "=https", "--proto-redir", "=https",
                "--connect-timeout", "15", "--max-time", "60",
                "--output", $attemptPath, $downloadUrl
            )
            if (Test-NsisDownload -Path $attemptPath) {
                Move-Item -LiteralPath $attemptPath -Destination $nsisDownload -Force
                $downloadVerified = $true
                break
            }
        }
        catch {
            Write-Warning "NSIS download attempt failed: $($_.Exception.Message)"
        }
        finally {
            # Delete only this attempt's generated partial/untrusted download.
            if (Test-Path -LiteralPath $attemptPath -PathType Leaf) { Remove-Item -LiteralPath $attemptPath -Force }
        }
    }
    if (-not $downloadVerified) {
        throw "No official NSIS download matched the pinned SHA256 after $($downloadUrls.Count) bounded attempts. No downloaded code was executed."
    }
}
if (-not (Test-NsisDownload -Path $nsisDownload)) {
    throw "The verified NSIS cache changed before extraction. No downloaded code was executed."
}

$stagingRoot = Join-Path $windowsRoot "artifacts/installer-staging"
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
$stagingDirectory = Join-Path $stagingRoot ([Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
$setupPath = Join-Path $releaseDirectory $setupName
try {
    # Extract the verified NSIS installer instead of installing build tools into
    # the system. GitHub's Windows image includes 7-Zip; no end-user dependency.
    $sevenZip = Join-Path $env:ProgramFiles "7-Zip/7z.exe"
    if (-not (Test-Path -LiteralPath $sevenZip -PathType Leaf)) {
        $sevenZipCommand = Get-Command "7z.exe" -ErrorAction SilentlyContinue
        if ($null -eq $sevenZipCommand) { throw "7-Zip is required to extract the verified NSIS build tool." }
        $sevenZip = $sevenZipCommand.Source
    }
    $nsisDirectory = Join-Path $stagingDirectory "nsis"
    Invoke-CrosioChecked -Command $sevenZip -Arguments @("x", "-y", "-o$nsisDirectory", $nsisDownload)
    $makeNsis = Join-Path $nsisDirectory "makensis.exe"
    if (-not (Test-Path -LiteralPath $makeNsis -PathType Leaf)) { throw "The verified NSIS archive did not contain makensis.exe." }
    $actualNsisVersion = (& $makeNsis "/VERSION" | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualNsisVersion -ne "v3.12") { throw "Expected NSIS v3.12; found $actualNsisVersion." }

    $payloadPath = Join-Path $stagingDirectory "payload.json"
    # Windows PowerShell 5.1 otherwise treats UTF-8 without BOM as the system
    # ANSI code page, corrupting Chinese strings on non-Chinese Windows.
    $enginePath = Join-Path $stagingDirectory "Install-Payload.ps1"
    [System.IO.File]::WriteAllText($enginePath,
        [System.IO.File]::ReadAllText((Join-Path $installerSource "Install-Payload.ps1")),
        [System.Text.UTF8Encoding]::new($true))
    $metadata = [ordered]@{
        product = "Crosio"
        packageName = "Crosio.Windows"
        version = $Version
        publisher = $identity.GetAttribute("Publisher")
        sha256 = $bundleHash
        allowUnsignedTestPackage = (-not $buildInfo.signed -and [bool]$AllowUnsignedTestPackage)
    }
    [System.IO.File]::WriteAllText($payloadPath, ($metadata | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

    function ConvertTo-NsisLiteral {
        param([string]$Value)
        if ($Value -match '[\r\n]') { throw "A generated NSIS value contains a newline." }
        return $Value.Replace('$', '$$').Replace('"', '$\"')
    }
    $defines = [ordered]@{
        CROSIO_OUTPUT = $setupPath
        CROSIO_VERSION = $Version
        CROSIO_FLAVOR_TEXT = $(if ($buildInfo.signed) { "" } else { "（未签名测试版）" })
        CROSIO_BUNDLE = $bundlePath
        CROSIO_PAYLOAD_METADATA = $payloadPath
        CROSIO_ENGINE = $enginePath
        CROSIO_NSIS_LICENSE = (Join-Path $installerSource "LICENSE.NSIS.txt")
        CROSIO_ICON = (Join-Path $windowsRoot "src/Crosio.Windows.App/Assets/OnePaw.ico")
    }
    $configPath = Join-Path $stagingDirectory "setup-config.nsh"
    $configLines = foreach ($key in $defines.Keys) { '!define ' + $key + ' "' + (ConvertTo-NsisLiteral $defines[$key]) + '"' }
    [System.IO.File]::WriteAllLines($configPath, $configLines, [System.Text.UTF8Encoding]::new($true))
    Invoke-CrosioChecked -Command $makeNsis -Arguments @("/NOCONFIG", "/INPUTCHARSET", "UTF8", "/V3", "/WX", "/DCROSIO_CONFIG=$configPath", (Join-Path $installerSource "CrosioSetup.nsi"))
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf) -or (Get-Item -LiteralPath $setupPath).Length -lt 65536) {
        throw "NSIS did not create the expected Setup.exe."
    }
    $setupBytes = [System.IO.File]::ReadAllBytes($setupPath)
    $peOffset = [BitConverter]::ToInt32($setupBytes, 60)
    if ($peOffset -lt 64 -or $peOffset + 6 -ge $setupBytes.Length -or
        [BitConverter]::ToUInt16($setupBytes, $peOffset + 4) -ne 0x14c) {
        throw "Setup.exe is not the expected universal x86 bootstrapper."
    }
    $setupHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllLines($checksumsPath,
        ($originalChecksums + @("$setupHash  $setupName")), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Graphical installer created: $setupPath"
    Write-Output $setupPath
}
finally {
    # Only our fresh GUID staging directory is removed, never release/user data.
    if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}

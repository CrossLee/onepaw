[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$windowsRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot

function Read-Source([string]$RelativePath) {
    return [System.IO.File]::ReadAllText((Join-Path $repositoryRoot $RelativePath))
}
function Assert-Brand([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$manifest = [xml](Read-Source "windows/src/Crosio.Windows.App/Package.appxmanifest")
$ns = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
$ns.AddNamespace("f", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
$ns.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
$ns.AddNamespace("desktop", "http://schemas.microsoft.com/appx/manifest/desktop/windows10")
$identity = $manifest.SelectSingleNode("/f:Package/f:Identity", $ns)
Assert-Brand ($identity.Name -eq "Crosio.Windows") "Renaming must not change the package identity."
Assert-Brand ($identity.Publisher -eq "CN=Crosio, OID.2.25.311729368913984317654407730594956997722=1") "Renaming must not change the unsigned publisher/PFN."
Assert-Brand ($manifest.Package.Properties.DisplayName -eq "一爪") "Package display name is stale."
Assert-Brand ($manifest.Package.Properties.PublisherDisplayName -eq "一爪") "Publisher display name is stale."
Assert-Brand ($manifest.SelectSingleNode("//uap:VisualElements", $ns).DisplayName -eq "一爪") "App list display name is stale."
Assert-Brand ($manifest.SelectSingleNode("//uap:Protocol[@Name='crosio']/uap:DisplayName", $ns).InnerText -eq "一爪") "Protocol display name or compatible protocol changed."
Assert-Brand ($manifest.SelectSingleNode("//uap:FileTypeAssociation[@Name='crosio.images']/uap:DisplayName", $ns).InnerText -eq "使用一爪自动压缩") "Image association display name or identity is incorrect."
Assert-Brand ($manifest.SelectSingleNode("//desktop:StartupTask[@TaskId='CrosioStartupTask']", $ns).DisplayName -eq "一爪") "Startup display name or identity is incorrect."
Assert-Brand ($manifest.SelectSingleNode("/f:Package/f:Applications/f:Application", $ns).Id -eq "App") "Renaming must not change the AUMID application ID."

$requiredSourceText = @{
    "windows/src/Crosio.Windows.App/Crosio.Windows.App.csproj" = @('<AssemblyName>Crosio</AssemblyName>', '<Product>一爪</Product>', '<AssemblyTitle>一爪</AssemblyTitle>')
    "windows/src/Crosio.Windows.App/MainWindow.xaml.cs" = @('Title = "一爪";')
    "windows/src/Crosio.Windows.App/MainWindow.xaml" = @('Title="一爪"')
    "windows/src/Crosio.Windows.App/SingleInstanceCoordinator.cs" = @('MainInstanceKey = "Crosio.Main"')
    "windows/src/Crosio.Windows.Platform/Startup/StartupRegistrationService.cs" = @('RegistryValueName = "Crosio"', 'DefaultTaskId = "CrosioStartupTask"')
    "windows/src/Crosio.Windows.Core/Settings/JsonSettingsStore.cs" = @('Path.Combine(localData, "Crosio", "settings.json")')
    "windows/src/Crosio.Windows.App/FeatureServices.cs" = @('Path.Combine(localData, "Crosio", "Inbox")', 'Path.Combine(localData, "Crosio", "TranslationModels")', 'Path.Combine(localData, "Crosio", "translation-history.json")', 'Path.Combine(videos, "Crosio")')
    "windows/src/Crosio.Windows.Capture/Editor/ScreenshotEditorWindow.cs" = @('Text = "截图 — 一爪"', 'AccessibleName = "一爪截图编辑器"', 'FileName = $"一爪-')
    "windows/src/Crosio.Windows.Capture/Pinning/PinnedScreenshotWindow.cs" = @('Text = "固定截图 — 一爪"')
    "windows/src/Crosio.Windows.Platform/Tray/TrayIconHost.cs" = @('tooltip = "一爪"', '"打开一爪"')
    "windows/src/Crosio.Windows.Platform/Images/ImageCompressionPathPolicy.cs" = @('sequence == 1 ? "-一爪" : $"-一爪-{sequence}"')
    "windows/installer/CrosioSetup.nsi" = @('Name "一爪"', 'Caption "一爪 安装"', '"ProductName" "一爪"', '"FileDescription" "一爪 图形化安装器"', '搜索 一爪')
    "windows/scripts/build-msixbundle.ps1" = @('"一爪-Windows-$Version-$packageFlavor.msixbundle"', '"安装一爪.ps1"', '[System.Text.UTF8Encoding]::new($true)')
    "windows/scripts/build-setup.ps1" = @('"OnePaw-Windows-$Version-Setup.exe"', '"安装一爪.ps1"', 'Get-Content -Encoding UTF8 -LiteralPath $checksumsPath')
    "windows/scripts/Test-MsixInstallation.ps1" = @('$brandName = -join @([char]0x4E00, [char]0x722A)', '$setupAssetBrand = "OnePaw"', '"\u4e00\u722a"')
    ".github/workflows/windows-ci.yml" = @('setup_name="OnePaw-Windows-${version}-Setup.exe"', '"安装一爪.ps1"', 'diff -u "$preview_root/expected-source-hashes.txt" "$preview_root/actual-source-hashes.txt"', 'sha256sum --check --strict')
}
foreach ($entry in $requiredSourceText.GetEnumerator()) {
    $text = Read-Source $entry.Key
    foreach ($required in $entry.Value) {
        Assert-Brand ($text.Contains($required)) "Branding or compatibility contract missing in $($entry.Key): $required"
    }
}
$html = Read-Source "Sources/CrossToolApp/Resources/Web/index.html"
Assert-Brand ($html.Contains('<title>一爪 · 课堂共享区</title>') -and -not $html.Contains('Crosio')) "Embedded web client still exposes the old brand."

# PowerShell 5.1 reads BOM-less UTF-8 as ANSI. The GUI smoke script remains
# ASCII-only; localized build/installer source must have an explicit UTF-8 BOM.
foreach ($relativePath in @('scripts/build-msix.ps1', 'scripts/build-msixbundle.ps1', 'scripts/build-setup.ps1', 'scripts/Install-Crosio.ps1', 'scripts/Test-PackageLayout.ps1', 'installer/Install-Payload.ps1')) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $windowsRoot $relativePath))
    Assert-Brand ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "Localized PowerShell source must be UTF-8 with BOM: $relativePath"
}
$smokeBytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "Test-MsixInstallation.ps1"))
Assert-Brand (@($smokeBytes | Where-Object { $_ -gt 127 }).Count -eq 0) "The GUI smoke script must remain code-page-independent ASCII."
Write-Host "OnePaw display branding, Unicode packaging, and stable upgrade identities are consistent."

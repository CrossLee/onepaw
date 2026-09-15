#if CROSIO_STATIC_COMPILE
using Microsoft.UI.Xaml.Controls;

namespace Crosio.Windows.App;

public partial class App
{
    private void InitializeComponent()
    {
    }
}

public sealed partial class MainWindow
{
    private readonly NavigationView Navigation = new();
    private readonly TextBlock GreetingText = new();
    private readonly InfoBar StatusBar = new();
    private readonly Button PrimaryActionButton = new();
    private readonly StackPanel RecordingPanel = new();
    private readonly ToggleSwitch RecordingSystemAudioToggle = new();
    private readonly ToggleSwitch RecordingCursorToggle = new();
    private readonly TextBlock RecordingStatusText = new();
    private readonly TextBlock RecentRecordingText = new();
    private readonly StackPanel RecordingRecentActions = new();
    private readonly Button AddRecordingToSharingButton = new();
    private readonly StackPanel TranslationPanel = new();
    private readonly TextBox TranslationInputBox = new();
    private readonly TextBlock TranslationDirectionLabel = new();
    private readonly TextBlock TranslationModelStatus = new();
    private readonly TextBlock TranslationDownloadStatus = new();
    private readonly ProgressBar TranslationModelProgress = new();
    private readonly TextBox TranslationOutputBox = new();
    private readonly Button DownloadTranslationModelsButton = new();
    private readonly Button CancelTranslationModelDownloadButton = new();
    private readonly Button InstallLocalTranslationModelButton = new();
    private readonly Button TranslateButton = new();
    private readonly Button CopyTranslationButton = new();
    private readonly StackPanel CompressionPanel = new();
    private readonly StackPanel SharingPanel = new();
    private readonly TextBox SharingAccessCodeBox = new();
    private readonly TextBlock SharingAccessCodeStatusText = new();
    private readonly TextBox SharedTextInput = new();
    private readonly TextBlock SharingSummary = new();
    private readonly StackPanel SettingsPanel = new();
    private readonly ToggleSwitch StartWithWindowsToggle = new();
    private readonly TextBlock StartupStatusText = new();
    private readonly TextBox SettingsShareAccessCodeBox = new();
    private readonly TextBlock SettingsShareAccessCodeStatusText = new();
    private readonly ListView HotkeyList = new();
    private readonly TextBlock ShortcutStatusText = new();
    private readonly Button RestoreDefaultHotkeysButton = new();
    private readonly Button ApplyHotkeysButton = new();

    private void InitializeComponent()
    {
    }
}
#endif

using Crosio.Windows.App.ViewModels;
using Crosio.Windows.Core.Activation;
using Crosio.Windows.Core.Features;
using Crosio.Windows.Core.Presentation;
using Crosio.Windows.Core.Settings;
using Crosio.Windows.Intelligence.Translation;
using Crosio.Windows.Media;
using Crosio.Windows.Platform.Images;
using Crosio.Windows.Platform.Startup;
using Crosio.Windows.Sharing;
using Crosio.Windows.Translation;
using Microsoft.UI.Windowing;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;

namespace Crosio.Windows.App;

public sealed class FeatureActionRequestedEventArgs : EventArgs
{
    public FeatureActionRequestedEventArgs(FeatureId feature)
    {
        Feature = feature;
    }

    public FeatureId Feature { get; }
}

public sealed partial class MainWindow : Window
{
    private const int DefaultWindowWidth = 1120;
    private const int DefaultWindowHeight = 720;
    private readonly ActivationRouter _router = new();
    private readonly FeatureServices _services;
    private readonly ObservableCollection<HotkeyRowViewModel> _hotkeyRows = new(
        HotkeyCommandCatalog.All.Select(definition => new HotkeyRowViewModel(definition)));
    private IReadOnlyDictionary<string, HotkeyBinding> _appliedHotkeys =
        AppSettings.DefaultHotkeys;
    private readonly CancellationTokenSource _windowLifetimeCancellation = new();
    private FeatureId _selectedFeature = FeatureId.Home;
    private bool _loadingStartupState;
    private bool _hotkeysLoaded;
    private bool _hotkeysSuspendedForRecording;
    private CancellationTokenSource? _translationModelDownloadCancellation;
    private WindowTranslationRequest? _translationUiRequest;
    private long _translationUiGeneration;
    private string? _latestRecordingPath;
    private bool _windowClosed;

    internal MainWindow(FeatureServices services)
    {
        _services = services ?? throw new ArgumentNullException(nameof(services));
        InitializeComponent();
        AppWindow.SetIcon(ApplicationBranding.IconPath);
        HotkeyList.ItemsSource = _hotkeyRows;
        Title = "一爪";
        GreetingText.Text = TimeOfDayGreeting.ForHour(DateTime.Now.Hour);
        var translationDownloadBytes =
            OfficialTranslationModelInstaller.GetModelInfo(TranslationDirection.ChineseToEnglish).DownloadBytes +
            OfficialTranslationModelInstaller.GetModelInfo(TranslationDirection.EnglishToChinese).DownloadBytes;
        DownloadTranslationModelsButton.Content =
            $"下载官方中英双向模型（约 {Math.Ceiling(translationDownloadBytes / (1024d * 1024d)):0} MB）";
        ApplyRecordingSnapshot(_services.Recording.Snapshot);
        _services.SharedContent.Changed += OnSharedContentChanged;
        Activated += OnWindowActivated;
        Closed += OnWindowClosed;
    }

    public event EventHandler<FeatureActionRequestedEventArgs>? FeatureActionRequested;

    public MainWindowViewModel ViewModel { get; } = new();

    public bool IsRecordingHotkey { get; private set; }

    public bool CaptureSystemAudio => RecordingSystemAudioToggle.IsOn;

    public bool ShowRecordingCursor => RecordingCursorToggle.IsOn;

    public void ApplyRoute(ActivationRoute route)
    {
        GreetingText.Text = TimeOfDayGreeting.ForHour(DateTime.Now.Hour);
        ViewModel.Apply(route);
        _selectedFeature = route.Feature;
        SelectNavigationItem(FeatureCatalog.Get(route.Feature).Route);
        UpdateFeaturePanels(route.Feature);
        ShowFeatureStatus(ViewModel.Status, isError: route.Issue != ActivationIssue.None);

        if (route.Feature == FeatureId.TextTranslation && route.Inputs.FirstOrDefault() is { } sourceText)
        {
            TranslationInputBox.Text = sourceText;
            UpdateTranslationDirection(sourceText);
            ShowFeatureStatus("已读取选中文字，正在使用本机模型翻译…", isError: false);
            _ = TranslateCurrentAsync(automatic: true);
        }
    }

    public void ShowFeatureStatus(string message, bool isError)
    {
        StatusBar.Severity = isError ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
        StatusBar.Message = message;
        StatusBar.IsOpen = !string.IsNullOrWhiteSpace(message);
    }

    internal async Task HideForBackgroundActionAsync()
    {
        AppWindow.Hide();

        var compositionFlushed = TryFlushDesktopComposition();
        if (!AppWindow.IsVisible && compositionFlushed)
        {
            return;
        }

        const int maximumVisibilityChecks = 4;
        for (var attempt = 0; attempt < maximumVisibilityChecks; attempt++)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(16));
            compositionFlushed = TryFlushDesktopComposition();
            if (!AppWindow.IsVisible && compositionFlushed)
            {
                return;
            }
        }

        if (AppWindow.IsVisible)
        {
            Debug.WriteLine("Crosio main window remained visible after the bounded hide barrier.");
        }
    }

    internal void ShowAndActivate()
    {
        var presenter = AppWindow.Presenter as OverlappedPresenter;
        if (presenter?.State == OverlappedPresenterState.Minimized)
        {
            presenter.Restore(activateWindow: false);
        }

        EnsureMainWindowOnScreen(presenter);
        AppWindow.Show(activateWindow: true);
        Activate();
    }

    internal void BeginShutdown()
    {
        if (_windowClosed)
        {
            return;
        }

        _windowClosed = true;
        Interlocked.Increment(ref _translationUiGeneration);
        Interlocked.Exchange(ref _translationUiRequest, null)?.Cancel();
        _windowLifetimeCancellation.Cancel();
        _translationModelDownloadCancellation?.Cancel();
    }

    private void Navigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer?.Tag is not string route)
        {
            return;
        }

        var activation = _router.Route(ActivationEnvelope.CommandLine(["--feature", route]));
        ApplyRoute(activation);
    }

    private void SelectNavigationItem(string route)
    {
        var items = Navigation.MenuItems
            .Concat(Navigation.FooterMenuItems)
            .OfType<NavigationViewItem>();
        var selected = items.FirstOrDefault(
            item => string.Equals(item.Tag as string, route, StringComparison.OrdinalIgnoreCase));

        if (selected is not null && !ReferenceEquals(Navigation.SelectedItem, selected))
        {
            Navigation.SelectedItem = selected;
        }
    }

    private void UpdateFeaturePanels(FeatureId feature)
    {
        RecordingPanel.Visibility = Visibility.Collapsed;
        TranslationPanel.Visibility = Visibility.Collapsed;
        CompressionPanel.Visibility = Visibility.Collapsed;
        SharingPanel.Visibility = Visibility.Collapsed;
        SettingsPanel.Visibility = Visibility.Collapsed;
        PrimaryActionButton.Visibility = Visibility.Collapsed;
        PrimaryActionButton.IsEnabled = true;

        switch (feature)
        {
            case FeatureId.RegionScreenshot:
                ShowPrimaryAction("开始区域截图");
                break;
            case FeatureId.WindowScreenshot:
                ShowPrimaryAction("选择窗口截图");
                break;
            case FeatureId.ScreenScreenshot:
                ShowPrimaryAction("截取鼠标所在屏幕");
                break;
            case FeatureId.DelayedScreenshot:
                ShowPrimaryAction("5 秒后截图");
                break;
            case FeatureId.FramedScreenshot:
                ShowPrimaryAction("3 秒倒计时后生成带壳截图");
                break;
            case FeatureId.MultiWindowScreenshot:
                ShowPrimaryAction("选择多个可见窗口并合成");
                break;
            case FeatureId.ScreenRecording:
            case FeatureId.RegionRecording:
            case FeatureId.WindowRecording:
                RecordingPanel.Visibility = Visibility.Visible;
                UpdateRecordingControls(_services.Recording.Snapshot);
                break;
            case FeatureId.LongScreenshot:
                ShowPrimaryAction("框选滚动区域并开始长截图");
                break;
            case FeatureId.ColorPicker:
                ShowPrimaryAction("隐藏窗口并复制鼠标处颜色");
                break;
            case FeatureId.TextTranslation:
                TranslationPanel.Visibility = Visibility.Visible;
                UpdateTranslationDirection(TranslationInputBox.Text);
                _ = RefreshTranslationModelStatusAsync();
                break;
            case FeatureId.ImageCompression:
                CompressionPanel.Visibility = Visibility.Visible;
                break;
            case FeatureId.ShareFiles:
            case FeatureId.ShareText:
                SharingPanel.Visibility = Visibility.Visible;
                UpdateSharingSummary();
                _ = RefreshSharingAccessCodeAsync();
                break;
            case FeatureId.Settings:
                SettingsPanel.Visibility = Visibility.Visible;
                _ = RefreshStartupStateAsync();
                _ = RefreshHotkeyStateAsync();
                _ = RefreshSharingAccessCodeAsync();
                break;
        }
    }

    private void ShowPrimaryAction(string text, bool isEnabled = true)
    {
        PrimaryActionButton.Content = text;
        PrimaryActionButton.Visibility = Visibility.Visible;
        PrimaryActionButton.IsEnabled = isEnabled;
    }

    private void PrimaryAction_Click(object sender, RoutedEventArgs args)
    {
        FeatureActionRequested?.Invoke(this, new FeatureActionRequestedEventArgs(_selectedFeature));
    }

    public void ApplyRecordingSnapshot(RecordingSessionSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (snapshot.OutputPath is { Length: > 0 } outputPath)
        {
            _latestRecordingPath = outputPath;
        }

        RecordingStatusText.Text = snapshot.Phase switch
        {
            RecordingSessionPhase.Idle => "尚未开始录屏。",
            RecordingSessionPhase.CheckingCapabilities => "正在检查 Windows 录屏能力…",
            RecordingSessionPhase.Starting => "正在启动录屏…",
            RecordingSessionPhase.Recording => $"正在录制{RecordingKindName(snapshot.TargetKind)}。再次按相同快捷键或点击按钮即可停止。",
            RecordingSessionPhase.Stopping => "正在停止并安全封装 MP4，请稍候…",
            RecordingSessionPhase.Completed => "录屏已保存。",
            RecordingSessionPhase.Cancelled => "录屏已取消。",
            RecordingSessionPhase.Failed => snapshot.Message ?? "录屏失败。",
            _ => snapshot.Message ?? "正在处理录屏…",
        };

        RecordingSystemAudioToggle.IsEnabled = !IsRecordingBusy(snapshot.Phase);
        RecordingCursorToggle.IsEnabled = !IsRecordingBusy(snapshot.Phase);
        UpdateRecentRecordingActions();

        if (!IsRecordingFeature(_selectedFeature))
        {
            return;
        }

        switch (snapshot.Phase)
        {
            case RecordingSessionPhase.CheckingCapabilities:
            case RecordingSessionPhase.Starting:
                ShowPrimaryAction("取消启动录屏");
                break;
            case RecordingSessionPhase.Recording:
                if (snapshot.TargetKind == RecordingKindFor(_selectedFeature))
                {
                    ShowPrimaryAction("停止并保存录屏");
                }
                else
                {
                    ShowPrimaryAction($"正在录制{RecordingKindName(snapshot.TargetKind)}", isEnabled: false);
                }
                break;
            case RecordingSessionPhase.Stopping:
                ShowPrimaryAction("正在保存 MP4…", isEnabled: false);
                break;
            default:
                ShowPrimaryAction(StartRecordingLabel(_selectedFeature));
                break;
        }
    }

    private void UpdateRecordingControls(RecordingSessionSnapshot snapshot) =>
        ApplyRecordingSnapshot(snapshot);

    private void UpdateRecentRecordingActions()
    {
        var exists = _latestRecordingPath is { Length: > 0 } path && File.Exists(path);
        RecordingRecentActions.Visibility = exists ? Visibility.Visible : Visibility.Collapsed;
        RecentRecordingText.Text = exists
            ? $"最近录屏：{Path.GetFileName(_latestRecordingPath)}"
            : "完成录屏后可在这里播放、定位或加入共享区。";

        if (!exists)
        {
            AddRecordingToSharingButton.IsEnabled = false;
            return;
        }

        try
        {
            AddRecordingToSharingButton.IsEnabled =
                new FileInfo(_latestRecordingPath!).Length <= SharedContentStore.MaximumUploadBytes;
        }
        catch
        {
            AddRecordingToSharingButton.IsEnabled = false;
        }
    }

    private void OpenRecordingsFolder_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            Directory.CreateDirectory(_services.RecordingsDirectory);
            OpenWithShell(_services.RecordingsDirectory);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"无法打开录屏目录：{error.Message}", isError: true);
        }
    }

    private void PlayRecentRecording_Click(object sender, RoutedEventArgs args)
    {
        if (!TryGetRecentRecording(out var path))
        {
            return;
        }

        try
        {
            OpenWithShell(path);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"无法播放录屏：{error.Message}", isError: true);
        }
    }

    private void RevealRecentRecording_Click(object sender, RoutedEventArgs args)
    {
        if (!TryGetRecentRecording(out var path))
        {
            return;
        }

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "explorer.exe",
                UseShellExecute = false,
            };
            startInfo.ArgumentList.Add($"/select,{path}");
            _ = Process.Start(startInfo);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"无法在资源管理器中定位录屏：{error.Message}", isError: true);
        }
    }

    private void AddRecordingToSharing_Click(object sender, RoutedEventArgs args)
    {
        if (!TryGetRecentRecording(out var path))
        {
            return;
        }

        try
        {
            if (new FileInfo(path).Length > SharedContentStore.MaximumUploadBytes)
            {
                ShowFeatureStatus("录屏超过当前版本 256 MB 的局域网共享限制。", isError: true);
                return;
            }

            _services.SharedContent.AddSharedFile(path);
            ShowFeatureStatus("最近录屏已加入共享区。", isError: false);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"无法加入共享区：{error.Message}", isError: true);
        }
    }

    private bool TryGetRecentRecording(out string path)
    {
        path = _latestRecordingPath ?? string.Empty;
        if (path.Length > 0 && File.Exists(path))
        {
            return true;
        }

        UpdateRecentRecordingActions();
        ShowFeatureStatus("最近的录屏文件已不存在。", isError: true);
        return false;
    }

    private static void OpenWithShell(string path)
    {
        _ = Process.Start(new ProcessStartInfo
        {
            FileName = path,
            UseShellExecute = true,
        });
    }

    private static bool IsRecordingBusy(RecordingSessionPhase phase) => phase is
        RecordingSessionPhase.CheckingCapabilities or
        RecordingSessionPhase.Starting or
        RecordingSessionPhase.Recording or
        RecordingSessionPhase.Stopping;

    private static bool IsRecordingFeature(FeatureId feature) => feature is
        FeatureId.ScreenRecording or FeatureId.RegionRecording or FeatureId.WindowRecording;

    private static RecordingTargetKind RecordingKindFor(FeatureId feature) => feature switch
    {
        FeatureId.ScreenRecording => RecordingTargetKind.Display,
        FeatureId.RegionRecording => RecordingTargetKind.Region,
        FeatureId.WindowRecording => RecordingTargetKind.Window,
        _ => throw new ArgumentOutOfRangeException(nameof(feature)),
    };

    private static string StartRecordingLabel(FeatureId feature) => feature switch
    {
        FeatureId.ScreenRecording => "开始录制鼠标所在屏幕",
        FeatureId.RegionRecording => "框选区域并开始录制",
        FeatureId.WindowRecording => "选择窗口并开始录制",
        _ => "开始录屏",
    };

    private static string RecordingKindName(RecordingTargetKind? kind) => kind switch
    {
        RecordingTargetKind.Display => "屏幕",
        RecordingTargetKind.Region => "区域",
        RecordingTargetKind.Window => "窗口",
        _ => "画面",
    };

    private void TranslationInputBox_TextChanged(object sender, TextChangedEventArgs args)
    {
        UpdateTranslationDirection(TranslationInputBox.Text);
    }

    private void UpdateTranslationDirection(string? text)
    {
        var input = TranslationDirectionDetector.Analyze(text);
        TranslationDirectionLabel.Text = input.Issue switch
        {
            TranslationInputIssue.Empty => "输入中文或英文后自动判断方向",
            TranslationInputIssue.Unsupported => "当前内容无法判断为中文或英文",
            _ when input.Direction == TranslationDirection.ChineseToEnglish => "已检测：中文 → 英文",
            _ => "已检测：英文 → 简体中文",
        };
    }

    private async void InstallTranslationModel_Click(object sender, RoutedEventArgs args)
    {
        if (_translationModelDownloadCancellation is not null)
        {
            ShowFeatureStatus("官方模型正在下载，请等待完成或先取消。", isError: true);
            return;
        }

        InstallLocalTranslationModelButton.IsEnabled = false;
        var windowCancellation = _windowLifetimeCancellation.Token;
        try
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add(".zip");
            InitializePicker(picker);
            var file = await picker.PickSingleFileAsync();
            if (file is null)
            {
                return;
            }
            windowCancellation.ThrowIfCancellationRequested();

            TranslationModelStatus.Text = "正在校验并安装…";
            ShowFeatureStatus("正在校验离线模型包，失败时不会替换现有模型。", isError: false);
            var installed = await _services.TranslationModelInstaller.InstallLocalArchiveAsync(
                file.Path,
                cancellationToken: windowCancellation);
            windowCancellation.ThrowIfCancellationRequested();
            TranslationModelStatus.Text = installed.Manifest.Direction == TranslationDirection.ChineseToEnglish
                ? "中译英模型已就绪"
                : "英译中模型已就绪";
            ShowFeatureStatus(
                $"离线模型已安装：{installed.Manifest.License.Attribution}",
                isError: false);
        }
        catch (OperationCanceledException) when (windowCancellation.IsCancellationRequested)
        {
            // The window no longer owns this operation. The installer itself
            // drains its worker before releasing any shared resources.
        }
        catch (TranslationModelInvalidException error)
        {
            if (!_windowClosed)
            {
                ShowFeatureStatus($"模型包无效：{error.Message}", isError: true);
                await RefreshTranslationModelStatusAsync();
            }
        }
        catch (Exception error)
        {
            if (!_windowClosed)
            {
                ShowFeatureStatus($"安装离线模型失败：{error.Message}", isError: true);
                await RefreshTranslationModelStatusAsync();
            }
        }
        finally
        {
            if (!_windowClosed)
            {
                InstallLocalTranslationModelButton.IsEnabled = true;
            }
        }
    }

    private async void DownloadOfficialTranslationModels_Click(object sender, RoutedEventArgs args)
    {
        if (_translationModelDownloadCancellation is not null)
        {
            return;
        }

        var directions = new[]
        {
            TranslationDirection.ChineseToEnglish,
            TranslationDirection.EnglishToChinese,
        };
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
            _windowLifetimeCancellation.Token);
        var downloadCancellation = cancellation.Token;
        _translationModelDownloadCancellation = cancellation;
        DownloadTranslationModelsButton.IsEnabled = false;
        InstallLocalTranslationModelButton.IsEnabled = false;
        CancelTranslationModelDownloadButton.IsEnabled = true;
        CancelTranslationModelDownloadButton.Visibility = Visibility.Visible;
        TranslationModelProgress.Visibility = Visibility.Visible;
        TranslationModelProgress.Value = 0;

        try
        {
            var statuses = await Task.WhenAll(directions.Select(direction =>
                _services.TranslationModels.GetStatusAsync(
                    direction,
                    verifyArtifactHashes: true,
                    downloadCancellation)));
            downloadCancellation.ThrowIfCancellationRequested();
            var pending = directions
                .Where((_, index) => statuses[index].State != OfflineModelState.Ready)
                .Select(OfficialTranslationModelInstaller.GetModelInfo)
                .ToArray();
            if (pending.Length == 0)
            {
                TranslationModelProgress.Value = 100;
                TranslationDownloadStatus.Text = "中英双向模型已经安装。";
                ShowFeatureStatus("中英双向离线模型已经安装，无需重复下载。", isError: false);
                return;
            }

            var totalBytes = pending.Sum(model => model.DownloadBytes);
            var completedBeforeCurrent = 0L;
            foreach (var model in pending)
            {
                downloadCancellation.ThrowIfCancellationRequested();
                var prefix = model.Direction == TranslationDirection.ChineseToEnglish
                    ? "中译英"
                    : "英译中";
                var completedBase = completedBeforeCurrent;
                var progress = new Progress<ModelInstallProgress>(value =>
                {
                    if (_windowClosed || downloadCancellation.IsCancellationRequested)
                    {
                        return;
                    }
                    var completed = Math.Min(
                        totalBytes,
                        completedBase + Math.Min(value.CompletedBytes, model.DownloadBytes));
                    TranslationModelProgress.Value = totalBytes == 0
                        ? 0
                        : completed * 100d / totalBytes;
                    TranslationDownloadStatus.Text = $"{prefix}：{value.Message}";
                });

                TranslationDownloadStatus.Text =
                    $"正在下载{prefix}模型（{FormatMegabytes(model.DownloadBytes)}）…";
                _ = await _services.OfficialTranslationModels.DownloadAndInstallAsync(
                    model.Direction,
                    progress,
                    downloadCancellation);
                downloadCancellation.ThrowIfCancellationRequested();
                completedBeforeCurrent = checked(completedBeforeCurrent + model.DownloadBytes);
                TranslationModelProgress.Value = completedBeforeCurrent * 100d / totalBytes;
            }

            TranslationDownloadStatus.Text = "官方模型已校验并安装；后续翻译不需要联网。";
            ShowFeatureStatus("中英双向离线模型已安装，可以直接翻译。", isError: false);
            await RefreshTranslationModelStatusAsync();
        }
        catch (OperationCanceledException)
        {
            if (!_windowClosed)
            {
                TranslationDownloadStatus.Text = "下载已取消，未完成的临时文件已清理。";
                ShowFeatureStatus("离线模型下载已取消。", isError: false);
                await RefreshTranslationModelStatusAsync();
            }
        }
        catch (TranslationModelInvalidException error)
        {
            if (!_windowClosed)
            {
                TranslationDownloadStatus.Text = "官方模型校验失败。";
                ShowFeatureStatus($"官方模型安装失败：{error.Message}", isError: true);
                await RefreshTranslationModelStatusAsync();
            }
        }
        catch (Exception error)
        {
            if (!_windowClosed)
            {
                TranslationDownloadStatus.Text = "官方模型下载失败，可稍后重试。";
                ShowFeatureStatus($"官方模型下载失败：{error.Message}", isError: true);
                await RefreshTranslationModelStatusAsync();
            }
        }
        finally
        {
            if (ReferenceEquals(_translationModelDownloadCancellation, cancellation))
            {
                _translationModelDownloadCancellation = null;
            }
            cancellation.Dispose();
            if (!_windowClosed)
            {
                DownloadTranslationModelsButton.IsEnabled = true;
                InstallLocalTranslationModelButton.IsEnabled = true;
                CancelTranslationModelDownloadButton.Visibility = Visibility.Collapsed;
            }
        }
    }

    private void CancelTranslationModelDownload_Click(object sender, RoutedEventArgs args)
    {
        CancelTranslationModelDownloadButton.IsEnabled = false;
        TranslationDownloadStatus.Text = "正在取消并清理临时文件…";
        _translationModelDownloadCancellation?.Cancel();
    }

    private static string FormatMegabytes(long bytes) =>
        $"{bytes / (1024d * 1024d):0.#} MB";

    private async Task RefreshTranslationModelStatusAsync()
    {
        var windowCancellation = _windowLifetimeCancellation.Token;
        try
        {
            var statuses = await Task.WhenAll(
                _services.TranslationModels.GetStatusAsync(
                    TranslationDirection.ChineseToEnglish,
                    verifyArtifactHashes: true,
                    windowCancellation),
                _services.TranslationModels.GetStatusAsync(
                    TranslationDirection.EnglishToChinese,
                    verifyArtifactHashes: true,
                    windowCancellation));
            windowCancellation.ThrowIfCancellationRequested();
            var invalidCount = statuses.Count(status => status.State == OfflineModelState.Invalid);
            TranslationModelStatus.Text = invalidCount switch
            {
                2 => "中英双向模型损坏，可点下载自动修复",
                1 when statuses[0].State == OfflineModelState.Invalid => "中译英模型损坏，可点下载自动修复",
                1 => "英译中模型损坏，可点下载自动修复",
                _ => statuses.Count(status => status.State == OfflineModelState.Ready) switch
                {
                    2 => "中英双向模型已就绪",
                    1 when statuses[0].State == OfflineModelState.Ready => "中译英模型已就绪",
                    1 => "英译中模型已就绪",
                    _ => "尚未安装离线模型",
                },
            };
        }
        catch (OperationCanceledException) when (windowCancellation.IsCancellationRequested)
        {
        }
        catch (Exception error)
        {
            if (!_windowClosed)
            {
                TranslationModelStatus.Text = $"无法读取模型状态：{error.Message}";
            }
        }
    }

    private void Translate_Click(object sender, RoutedEventArgs args) =>
        _ = TranslateCurrentAsync(automatic: false);

    private async Task TranslateCurrentAsync(bool automatic)
    {
        var generation = Interlocked.Increment(ref _translationUiGeneration);
        var request = new WindowTranslationRequest(_windowLifetimeCancellation.Token);
        Interlocked.Exchange(ref _translationUiRequest, request)?.Cancel();
        try
        {
            var input = TranslationDirectionDetector.Analyze(TranslationInputBox.Text);
            if (!input.CanTranslate)
            {
                if (IsCurrentTranslationUiRequest(request, generation))
                {
                    ShowFeatureStatus(
                        input.Issue == TranslationInputIssue.Empty
                            ? "请先输入或选中要翻译的文字。"
                            : "当前内容无法判断为中文或英文。",
                        isError: true);
                }
                return;
            }

            TranslateButton.IsEnabled = false;
            CopyTranslationButton.IsEnabled = false;
            TranslationOutputBox.Text = string.Empty;
            ShowFeatureStatus(
                automatic ? "已读取选中文字，正在本机翻译…" : "正在本机翻译…",
                isError: false);
            var result = await _services.Translation.TranslateLatestAsync(input.Text, request.Token);
            if (!IsCurrentTranslationUiRequest(request, generation))
            {
                return;
            }
            TranslationOutputBox.Text = result.TranslatedText;
            CopyTranslationButton.IsEnabled = true;
            await _services.TranslationHistory.AddAsync(result, request.Token);
            if (!IsCurrentTranslationUiRequest(request, generation))
            {
                return;
            }
            ShowFeatureStatus("翻译完成，文字未上传到网络。", isError: false);
        }
        catch (OperationCanceledException)
        {
            // A newer edit or shortcut activation superseded this request.
        }
        catch (TranslationModelMissingException error)
        {
            if (IsCurrentTranslationUiRequest(request, generation))
            {
                ShowFeatureStatus($"{error.Message}。请先安装对应的一爪离线模型包。", isError: true);
            }
        }
        catch (TranslationException error)
        {
            if (IsCurrentTranslationUiRequest(request, generation))
            {
                ShowFeatureStatus($"翻译失败：{error.Message}", isError: true);
            }
        }
        catch (Exception error)
        {
            if (IsCurrentTranslationUiRequest(request, generation))
            {
                ShowFeatureStatus($"本机翻译失败：{error.Message}", isError: true);
            }
        }
        finally
        {
            var ownedUi = ReferenceEquals(
                Interlocked.CompareExchange(ref _translationUiRequest, null, request),
                request);
            if (ownedUi && !_windowClosed)
            {
                TranslateButton.IsEnabled = true;
                CopyTranslationButton.IsEnabled = !string.IsNullOrWhiteSpace(TranslationOutputBox.Text);
            }
            request.Dispose();
        }
    }

    private bool IsCurrentTranslationUiRequest(WindowTranslationRequest request, long generation) =>
        !_windowClosed &&
        Volatile.Read(ref _translationUiGeneration) == generation &&
        ReferenceEquals(Volatile.Read(ref _translationUiRequest), request) &&
        !request.Token.IsCancellationRequested;

    private void CopyTranslation_Click(object sender, RoutedEventArgs args)
    {
        if (string.IsNullOrWhiteSpace(TranslationOutputBox.Text))
        {
            ShowFeatureStatus("当前没有可复制的译文。", isError: true);
            return;
        }

        CopyTextToClipboard(TranslationOutputBox.Text);
        ShowFeatureStatus("译文已复制。", isError: false);
    }

    private async void ChooseImagesToCompress_Click(object sender, RoutedEventArgs args)
    {
        var windowCancellation = _windowLifetimeCancellation.Token;
        try
        {
            var picker = new FileOpenPicker();
            foreach (var extension in new[] { ".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".heic", ".heif", ".tif", ".tiff" })
            {
                picker.FileTypeFilter.Add(extension);
            }
            InitializePicker(picker);
            var files = await picker.PickMultipleFilesAsync();
            if (files.Count == 0)
            {
                return;
            }
            windowCancellation.ThrowIfCancellationRequested();

            ShowFeatureStatus($"正在压缩 {files.Count} 张图片…", isError: false);
            var compression = await _services.ImageFileActivation.HandleAsync(
                files.Select(file => file.Path),
                new ImageCompressionSettings(),
                windowCancellation);
            windowCancellation.ThrowIfCancellationRequested();
            var succeeded = compression.Items.Count(item => item.Succeeded);
            var failed = compression.Items.Count - succeeded;
            ShowFeatureStatus(
                failed == 0
                    ? $"已处理 {succeeded} 张图片，并在资源管理器中定位结果。"
                    : $"完成 {succeeded} 张，失败 {failed} 张。",
                isError: failed > 0);
        }
        catch (OperationCanceledException) when (windowCancellation.IsCancellationRequested)
        {
            // Closing the window or exiting the app cancels queued/active work
            // without reopening or updating the main window.
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"图片压缩失败：{error.Message}", isError: true);
        }
    }

    private async void AddSharedFiles_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add("*");
            InitializePicker(picker);
            var files = await picker.PickMultipleFilesAsync();
            foreach (var file in files)
            {
                _services.SharedContent.AddSharedFile(file.Path);
            }
            if (files.Count > 0)
            {
                ShowFeatureStatus($"已将 {files.Count} 个文件加入共享区。", isError: false);
            }
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"加入共享文件失败：{error.Message}", isError: true);
        }
    }

    private void AddSharedText_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            _services.SharedContent.AddSharedText(SharedTextInput.Text);
            SharedTextInput.Text = string.Empty;
            ShowFeatureStatus("文字已加入共享区。", isError: false);
        }
        catch (Exception error)
        {
            ShowFeatureStatus(error.Message, isError: true);
        }
    }

    private async void StartSharing_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            ApplySharingAccessCodeState(await _services.SharingAccessCodes.InitializeAsync());
            await _services.SharingServer.StartAsync();
            UpdateSharingSummary();
            ShowFeatureStatus("局域网共享已开始。", isError: false);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"无法开始共享：{error.Message}", isError: true);
        }
    }

    private async void CopySharingLink_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            ApplySharingAccessCodeState(await _services.SharingAccessCodes.InitializeAsync());
            await _services.SharingServer.StartAsync();
            var uri = _services.SharingServer.SharingUris.FirstOrDefault();
            if (uri is null)
            {
                ShowFeatureStatus("没有找到可用于局域网共享的 IPv4 地址。", isError: true);
                return;
            }

            CopyTextToClipboard(uri.AbsoluteUri);
            UpdateSharingSummary();
            ShowFeatureStatus("共享链接已复制。", isError: false);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"复制共享链接失败：{error.Message}", isError: true);
        }
    }

    private async void StopSharing_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            await _services.SharingServer.StopAsync();
            UpdateSharingSummary();
            ShowFeatureStatus("共享已停止，旧链接已经失效。", isError: false);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"停止共享失败：{error.Message}", isError: true);
        }
    }

    private async void SaveSharingAccessCode_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            var previousCode = _services.SharingServer.SessionToken;
            var value = sender is Button { Tag: string tag }
                && string.Equals(tag, "settings", StringComparison.Ordinal)
                ? SettingsShareAccessCodeBox.Text
                : SharingAccessCodeBox.Text;
            var state = await _services.SharingAccessCodes.SaveCustomAsync(value);
            ApplySharingAccessCodeState(state);
            UpdateSharingSummary();
            ShowFeatureStatus(
                string.Equals(state.AccessCode, previousCode, StringComparison.Ordinal)
                    ? "共享访问码已保存。"
                    : "共享访问码已更新，旧链接已经失效。",
                isError: false);
        }
        catch (ArgumentException error)
        {
            ShowFeatureStatus(error.Message, isError: true);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"保存共享访问码失败：{error.Message}", isError: true);
        }
    }

    private async void ResetSharingAccessCode_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            var state = await _services.SharingAccessCodes.ResetToRandomAsync();
            ApplySharingAccessCodeState(state);
            UpdateSharingSummary();
            ShowFeatureStatus("已换用新的随机访问码，旧链接已经失效。", isError: false);
        }
        catch (Exception error)
        {
            ShowFeatureStatus($"更新随机访问码失败：{error.Message}", isError: true);
        }
    }

    private async Task RefreshSharingAccessCodeAsync()
    {
        try
        {
            var state = await _services.SharingAccessCodes.InitializeAsync(
                cancellationToken: _windowLifetimeCancellation.Token);
            ApplySharingAccessCodeState(state);
            UpdateSharingSummary();
        }
        catch (OperationCanceledException) when (_windowLifetimeCancellation.IsCancellationRequested)
        {
        }
        catch (Exception error)
        {
            SharingAccessCodeStatusText.Text = $"无法读取共享访问码：{error.Message}";
            SettingsShareAccessCodeStatusText.Text = SharingAccessCodeStatusText.Text;
        }
    }

    private void ApplySharingAccessCodeState(SharingAccessCodeState state)
    {
        SharingAccessCodeBox.Text = state.AccessCode;
        SettingsShareAccessCodeBox.Text = state.AccessCode;
        var message = state.IsCustom
            ? "当前使用自定义访问码；区分大小写。访问码会明文出现在链接中，请勿复用重要密码。"
            : "当前使用 10 位随机访问码；可直接改成自己的访问码。访问码会明文出现在链接中。";
        SharingAccessCodeStatusText.Text = message;
        SettingsShareAccessCodeStatusText.Text = message;
    }

    private async void StartWithWindowsToggle_Toggled(object sender, RoutedEventArgs args)
    {
        if (_loadingStartupState)
        {
            return;
        }

        _loadingStartupState = true;
        try
        {
            var requested = StartWithWindowsToggle.IsOn;
            var result = await _services.StartupRegistration.SetEnabledAsync(requested);
            StartupStatusText.Text = result.Message;
            StartWithWindowsToggle.IsOn = result.Status == StartupRegistrationStatus.Enabled;

            var current = await LoadSettingsOrDefaultAsync();
            await _services.Settings.SaveAsync(new AppSettings
            {
                SchemaVersion = current.SchemaVersion,
                StartWithWindows = result.Status == StartupRegistrationStatus.Enabled,
                RunInBackground = current.RunInBackground,
                PreferredSharingPort = current.PreferredSharingPort,
                CustomShareAccessCode = current.CustomShareAccessCode,
                Hotkeys = current.Hotkeys,
            });

            if (result.Status == StartupRegistrationStatus.RequiresUserAction)
            {
                ShowFeatureStatus("Windows 设置中曾禁用一爪，请在“启动应用”里重新开启。", isError: true);
            }
        }
        catch (Exception error)
        {
            StartupStatusText.Text = error.Message;
            ShowFeatureStatus($"更新开机启动失败：{error.Message}", isError: true);
        }
        finally
        {
            _loadingStartupState = false;
        }
    }

    private async Task RefreshStartupStateAsync()
    {
        if (_loadingStartupState)
        {
            return;
        }

        _loadingStartupState = true;
        try
        {
            var status = await _services.StartupRegistration.GetStatusAsync();
            StartWithWindowsToggle.IsOn = status.Status == StartupRegistrationStatus.Enabled;
            StartupStatusText.Text = status.Message;
        }
        catch (Exception error)
        {
            StartupStatusText.Text = error.Message;
        }
        finally
        {
            _loadingStartupState = false;
        }
    }

    private async Task<AppSettings> LoadSettingsOrDefaultAsync()
    {
        try
        {
            return await _services.Settings.LoadAsync();
        }
        catch
        {
            return AppSettings.Default;
        }
    }

    private async Task RefreshHotkeyStateAsync()
    {
        if (_hotkeysLoaded)
        {
            UpdateHotkeyButtons();
            return;
        }

        try
        {
            var settings = await LoadSettingsOrDefaultAsync();
            _appliedHotkeys = settings.Hotkeys.ToDictionary(
                pair => pair.Key,
                pair => pair.Value,
                StringComparer.OrdinalIgnoreCase);
            SetHotkeyRows(_appliedHotkeys);
            _hotkeysLoaded = true;
            ShortcutStatusText.Text = "当前快捷键已启用。默认只设置前三项截图快捷键。";
            UpdateHotkeyButtons();
        }
        catch (Exception error)
        {
            ShortcutStatusText.Text = $"读取快捷键失败：{error.Message}";
            ShowFeatureStatus(ShortcutStatusText.Text, isError: true);
        }
    }

    private void ShortcutEditor_GotFocus(object sender, RoutedEventArgs args)
    {
        if (sender is not TextBox { Tag: string route }
            || !HotkeyCommandCatalog.TryGet(route, out var command))
        {
            return;
        }

        if (!_hotkeysSuspendedForRecording)
        {
            Crosio.Windows.Hotkeys.GlobalHotkeyUpdateResult suspension;
            try
            {
                suspension = _services.GlobalHotkeys.SuspendForRecording();
            }
            catch (Exception error)
            {
                ShortcutStatusText.Text = $"无法开始录入：{error.Message}";
                ShowFeatureStatus(ShortcutStatusText.Text, isError: true);
                IsRecordingHotkey = false;
                return;
            }
            if (!suspension.Succeeded)
            {
                ShortcutStatusText.Text = $"无法开始录入：{suspension.Failure?.Message}";
                ShowFeatureStatus(ShortcutStatusText.Text, isError: true);
                IsRecordingHotkey = false;
                return;
            }

            _hotkeysSuspendedForRecording = true;
        }
        IsRecordingHotkey = true;
        ShortcutStatusText.Text = command.IsRequired
            ? $"正在录入“{command.Title}”：请按含 Ctrl 的组合键。此项不能清除，Esc 取消。"
            : $"正在录入“{command.Title}”：请按含 Ctrl 的组合键；按 Delete 清除，Esc 取消。";
    }

    private void ShortcutEditor_LostFocus(object sender, RoutedEventArgs args)
    {
        EndHotkeyRecording();
    }

    private void ShortcutEditor_KeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (sender is not TextBox { Tag: string route }
            || _hotkeyRows.FirstOrDefault(candidate =>
                string.Equals(candidate.Route, route, StringComparison.OrdinalIgnoreCase)) is not { } row)
        {
            return;
        }

        args.Handled = true;
        if (args.Key == VirtualKey.Escape)
        {
            row.Feedback = string.Empty;
            ShortcutStatusText.Text = "已取消本次录入，待应用配置未改变。";
            ApplyHotkeysButton.Focus(FocusState.Programmatic);
            return;
        }

        var modifiers = CurrentHotkeyModifiers();
        if ((args.Key == VirtualKey.Delete || args.Key == VirtualKey.Back)
            && modifiers == HotkeyModifiers.None)
        {
            if (row.IsRequired)
            {
                row.Feedback = "区域、窗口和全屏截图必须保留快捷键。";
                ShortcutStatusText.Text = row.Feedback;
                return;
            }

            row.Binding = null;
            row.Feedback = string.Empty;
            ShortcutStatusText.Text = $"已清除“{row.Title}”，点击“应用更改”后生效。";
            UpdateHotkeyButtons();
            ApplyHotkeysButton.Focus(FocusState.Programmatic);
            return;
        }

        if (IsModifierKey(args.Key))
        {
            row.Feedback = string.Empty;
            ShortcutStatusText.Text = "请保持修饰键按下，再按 A–Z、0–9 或 F1–F24。";
            return;
        }

        if (!TryMapTriggerKey(args.Key, out var key))
        {
            row.Feedback = "主键仅支持 A–Z、0–9 或 F1–F24，请继续录入。";
            ShortcutStatusText.Text = row.Feedback;
            return;
        }

        var candidate = new HotkeyBinding(modifiers, key);
        if (!candidate.TryNormalize(out var normalized))
        {
            row.Feedback = "组合键必须包含 Ctrl；请保持 Ctrl 按下并重新按主键。";
            ShortcutStatusText.Text = row.Feedback;
            return;
        }

        var conflict = _hotkeyRows.FirstOrDefault(other =>
            !ReferenceEquals(other, row)
            && other.Binding is not null
            && other.Binding.TryNormalize(out var otherBinding)
            && otherBinding == normalized);
        if (conflict is not null)
        {
            row.Feedback = $"与“{conflict.Title}”的 {normalized} 冲突，请继续录入。";
            ShortcutStatusText.Text = row.Feedback;
            return;
        }

        row.Binding = normalized;
        row.Feedback = string.Empty;
        ShortcutStatusText.Text = $"已录入“{row.Title}” {normalized}，点击“应用更改”后生效。";
        UpdateHotkeyButtons();
        ApplyHotkeysButton.Focus(FocusState.Programmatic);
    }

    private void RestoreDefaultHotkeys_Click(object sender, RoutedEventArgs args)
    {
        SetHotkeyRows(AppSettings.DefaultHotkeys);
        ShortcutStatusText.Text = "已恢复默认待应用值；点击“应用更改”后才会注册并保存。";
        UpdateHotkeyButtons();
    }

    private async void ApplyHotkeys_Click(object sender, RoutedEventArgs args)
    {
        EndHotkeyRecording();
        ApplyHotkeysButton.IsEnabled = false;
        RestoreDefaultHotkeysButton.IsEnabled = false;
        try
        {
            var requested = BuildStagedHotkeys();
            var result = await _services.HotkeySettings.ApplyAsync(requested);
            ShortcutStatusText.Text = result.Message;
            if (result.Succeeded)
            {
                _hotkeysSuspendedForRecording = false;
                _appliedHotkeys = result.ActiveBindings.ToDictionary(
                    pair => pair.Key,
                    pair => pair.Value,
                    StringComparer.OrdinalIgnoreCase);
                SetHotkeyRows(_appliedHotkeys);
                ShowFeatureStatus("全局快捷键已应用。", isError: false);
            }
            else
            {
                ShowFeatureStatus(
                    $"快捷键未应用，原配置仍然有效：{result.Message}",
                    isError: true);
            }
        }
        catch (Exception error)
        {
            ShortcutStatusText.Text = $"快捷键未应用：{error.Message}";
            ShowFeatureStatus(ShortcutStatusText.Text, isError: true);
        }
        finally
        {
            UpdateHotkeyButtons();
        }
    }

    private void SetHotkeyRows(IReadOnlyDictionary<string, HotkeyBinding> bindings)
    {
        foreach (var row in _hotkeyRows)
        {
            row.Binding = bindings.TryGetValue(row.Route, out var binding)
                ? binding
                : null;
            row.Feedback = string.Empty;
        }
    }

    private IReadOnlyDictionary<string, HotkeyBinding> BuildStagedHotkeys() =>
        _hotkeyRows
            .Where(row => row.Binding is not null)
            .ToDictionary(
                row => row.Route,
                row => row.Binding!,
                StringComparer.OrdinalIgnoreCase);

    private void UpdateHotkeyButtons()
    {
        var staged = BuildStagedHotkeys();
        var hasChanges = staged.Count != _appliedHotkeys.Count
            || staged.Any(pair =>
                !_appliedHotkeys.TryGetValue(pair.Key, out var current)
                || current != pair.Value);
        ApplyHotkeysButton.IsEnabled = hasChanges;
        RestoreDefaultHotkeysButton.IsEnabled =
            !AreEqual(staged, AppSettings.DefaultHotkeys);
    }

    private static bool AreEqual(
        IReadOnlyDictionary<string, HotkeyBinding> first,
        IReadOnlyDictionary<string, HotkeyBinding> second) =>
        first.Count == second.Count
        && first.All(pair =>
            second.TryGetValue(pair.Key, out var other)
            && other == pair.Value);

    private static HotkeyModifiers CurrentHotkeyModifiers()
    {
        var modifiers = HotkeyModifiers.None;
        if (IsKeyDown(VirtualKey.Control)) modifiers |= HotkeyModifiers.Control;
        if (IsKeyDown(VirtualKey.Shift)) modifiers |= HotkeyModifiers.Shift;
        if (IsKeyDown(VirtualKey.Menu)) modifiers |= HotkeyModifiers.Alt;
        if (IsKeyDown(VirtualKey.LeftWindows) || IsKeyDown(VirtualKey.RightWindows))
        {
            modifiers |= HotkeyModifiers.Windows;
        }
        return modifiers;
    }

    private static bool IsKeyDown(VirtualKey key) =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates.Down) != 0;

    private static bool IsModifierKey(VirtualKey key) => key is
        VirtualKey.Control or
        VirtualKey.Shift or
        VirtualKey.Menu or
        VirtualKey.LeftWindows or
        VirtualKey.RightWindows;

    private static bool TryMapTriggerKey(VirtualKey virtualKey, out string key)
    {
        var value = (int)virtualKey;
        if (value is >= 0x30 and <= 0x39 || value is >= 0x41 and <= 0x5A)
        {
            key = ((char)value).ToString();
            return true;
        }

        if (value is >= 0x70 and <= 0x87)
        {
            key = $"F{value - 0x70 + 1}";
            return true;
        }

        key = string.Empty;
        return false;
    }

    private void OnSharedContentChanged(object? sender, EventArgs args)
    {
        _ = DispatcherQueue.TryEnqueue(UpdateSharingSummary);
    }

    private void UpdateSharingSummary()
    {
        var itemCount = _services.SharedContent.PublicSnapshot().Count;
        var state = _services.SharingServer.State;
        var address = state.Status == SharingServerStatus.Running
            ? BaseSharingAddress(_services.SharingServer.SharingUris.FirstOrDefault())
            : "当前未共享";
        SharingSummary.Text =
            $"共享区 {itemCount} 项 · {address} · 访问码 {_services.SharingServer.SessionToken}";
    }

    private static string BaseSharingAddress(Uri? uri) => uri is null
        ? "正在等待局域网地址"
        : uri.GetLeftPart(UriPartial.Path).TrimEnd('/');

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        BeginShutdown();
        EndHotkeyRecording();
        _services.SharedContent.Changed -= OnSharedContentChanged;
        Activated -= OnWindowActivated;
        Closed -= OnWindowClosed;
    }

    private sealed class WindowTranslationRequest : IDisposable
    {
        private readonly object _gate = new();
        private readonly CancellationTokenSource _cancellation;
        private bool _disposed;

        public WindowTranslationRequest(CancellationToken windowCancellation)
        {
            _cancellation = CancellationTokenSource.CreateLinkedTokenSource(windowCancellation);
        }

        public CancellationToken Token => _cancellation.Token;

        public void Cancel()
        {
            lock (_gate)
            {
                if (!_disposed)
                {
                    try
                    {
                        _cancellation.Cancel();
                    }
                    catch (AggregateException)
                    {
                        // A UI cancellation callback must not prevent a newer
                        // request or window shutdown from taking ownership.
                    }
                }
            }
        }

        public void Dispose()
        {
            lock (_gate)
            {
                if (_disposed)
                {
                    return;
                }
                _disposed = true;
                _cancellation.Dispose();
            }
        }
    }

    private void OnWindowActivated(object sender, Microsoft.UI.Xaml.WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated)
        {
            EndHotkeyRecording();
        }
    }

    private void EnsureMainWindowOnScreen(OverlappedPresenter? presenter)
    {
        try
        {
            var displayAreas = DisplayArea.FindAll();
            var workAreas = displayAreas
                .Select(ToDesktopWorkArea)
                .ToArray();
            var originalWindowBounds = GetWindowBounds();
            var windowBounds = UseMainWindowFallbackSize(originalWindowBounds);

            if (windowBounds == originalWindowBounds &&
                WindowPlacementPolicy.IntersectsAnyWorkArea(windowBounds, workAreas))
            {
                return;
            }

            var wasMaximized = presenter?.State == OverlappedPresenterState.Maximized;
            try
            {
                if (wasMaximized)
                {
                    presenter!.Restore(activateWindow: false);
                    windowBounds = UseMainWindowFallbackSize(GetWindowBounds());
                }

                var targetDisplay = displayAreas.FirstOrDefault(display => display.IsPrimary) ??
                    DisplayArea.Primary;
                var targetWorkArea = targetDisplay.WorkArea;
                var targetBounds = WindowPlacementPolicy.CenterInWorkArea(
                    windowBounds,
                    new DesktopRectangle(
                        targetWorkArea.X,
                        targetWorkArea.Y,
                        targetWorkArea.Width,
                        targetWorkArea.Height));

                AppWindow.MoveAndResize(
                    new RectInt32(
                        targetBounds.X,
                        targetBounds.Y,
                        targetBounds.Width,
                        targetBounds.Height),
                    targetDisplay);
            }
            finally
            {
                if (wasMaximized && presenter!.State != OverlappedPresenterState.Maximized)
                {
                    presenter.Maximize();
                }
            }
        }
        catch (Exception error)
        {
            // Recovery is best-effort. Showing and activating the window must
            // still succeed if Windows cannot enumerate the current displays.
            Debug.WriteLine($"Crosio could not recover the main-window position: {error}");
        }
    }

    private static DesktopRectangle UseMainWindowFallbackSize(DesktopRectangle windowBounds) =>
        WindowPlacementPolicy.UseFallbackSize(
            windowBounds,
            DefaultWindowWidth,
            DefaultWindowHeight);

    private DesktopRectangle GetWindowBounds()
    {
        var position = AppWindow.Position;
        var size = AppWindow.Size;
        return new DesktopRectangle(
            position.X,
            position.Y,
            size.Width,
            size.Height);
    }

    private static DesktopRectangle ToDesktopWorkArea(DisplayArea displayArea)
    {
        var outerBounds = displayArea.OuterBounds;
        var workArea = displayArea.WorkArea;

        // WorkArea coordinates are relative to the containing DisplayArea;
        // AppWindow.Position uses desktop screen coordinates.
        return WindowPlacementPolicy.ToDesktopCoordinates(
            new DesktopRectangle(
                outerBounds.X,
                outerBounds.Y,
                outerBounds.Width,
                outerBounds.Height),
            new DesktopRectangle(
                workArea.X,
                workArea.Y,
                workArea.Width,
                workArea.Height));
    }

    private static bool TryFlushDesktopComposition()
    {
        try
        {
            return DwmFlush() >= 0;
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio could not flush desktop composition: {error}");
            return false;
        }
    }

    private void EndHotkeyRecording()
    {
        IsRecordingHotkey = false;
        if (!_hotkeysSuspendedForRecording)
        {
            return;
        }

        Crosio.Windows.Hotkeys.GlobalHotkeyUpdateResult resumed;
        try
        {
            resumed = _services.GlobalHotkeys.ResumeAfterRecording();
        }
        catch (Exception error)
        {
            ShortcutStatusText.Text = $"原快捷键暂时无法恢复：{error.Message}";
            ShowFeatureStatus(ShortcutStatusText.Text, isError: true);
            return;
        }
        if (resumed.Succeeded)
        {
            _hotkeysSuspendedForRecording = false;
            return;
        }

        ShortcutStatusText.Text = $"原快捷键暂时无法恢复：{resumed.Failure?.Message}";
        ShowFeatureStatus(ShortcutStatusText.Text, isError: true);
    }

    private void InitializePicker(object picker)
    {
        var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle);
    }

    private static void CopyTextToClipboard(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        Clipboard.Flush();
    }

    [DllImport("dwmapi.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern int DwmFlush();

}

internal sealed class HotkeyRowViewModel : INotifyPropertyChanged
{
    private HotkeyBinding? _binding;
    private string _feedback = string.Empty;

    public HotkeyRowViewModel(HotkeyCommandDefinition definition)
    {
        Definition = definition;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public HotkeyCommandDefinition Definition { get; }

    public string Route => Definition.Route;

    public string Title => Definition.IsRequired
        ? $"{Definition.Title}（必填）"
        : Definition.Title;

    public string Group => Definition.Group;

    public bool IsRequired => Definition.IsRequired;

    public HotkeyBinding? Binding
    {
        get => _binding;
        set
        {
            if (_binding == value)
            {
                return;
            }

            _binding = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Binding)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayText)));
        }
    }

    public string DisplayText => Binding?.ToString() ?? "未设置";

    public string Feedback
    {
        get => _feedback;
        set
        {
            if (_feedback == value)
            {
                return;
            }

            _feedback = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Feedback)));
        }
    }
}

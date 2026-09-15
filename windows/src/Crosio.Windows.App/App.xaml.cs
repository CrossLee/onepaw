using Crosio.Windows.Core.Activation;
using Crosio.Windows.Capture;
using Crosio.Windows.Core.Features;
using Crosio.Windows.Core.Presentation;
using Crosio.Windows.Core.Settings;
using Crosio.Windows.Media;
using Crosio.Windows.Platform.Images;
using Crosio.Windows.Platform.Shell;
using Crosio.Windows.Platform.Tray;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Crosio.Windows.App;

public partial class App : Application
{
    private readonly ActivationInbox _activationInbox = new();
    private readonly ActivationRouter _activationRouter = new();
    private readonly FeatureServices _featureServices;
    private readonly SingleInstanceCoordinator _singleInstance;
    private readonly SemaphoreSlim _featureGate = new(1, 1);
    private readonly CancellationTokenSource _shutdownCancellation = new();
    private IDisposable? _activationSubscription;
    private DispatcherQueue? _dispatcherQueue;
    private MainWindow? _mainWindow;
    private bool _residentServicesInitialized;
    private int _exitStarted;

    private bool IsExiting => Volatile.Read(ref _exitStarted) != 0;

    internal App(SingleInstanceCoordinator singleInstance)
    {
        _singleInstance = singleInstance;
        _featureServices = new FeatureServices();
        _featureServices.Recording.StateChanged += OnRecordingStateChanged;
        _singleInstance.Activated += OnRedirectedActivation;
        InitializeComponent();
    }

    public event EventHandler<ActivationRoute>? BackgroundActivationRequested;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();
        _activationSubscription = _activationInbox.Connect(HandleActivation);
        _ = InitializeResidentServicesAsync();
        Publish(_singleInstance.InitialActivation);
    }

    private void OnRedirectedActivation(object? sender, AppActivationArguments arguments)
    {
        if (IsExiting)
        {
            return;
        }

        var dispatcher = _dispatcherQueue;
        if (dispatcher is null)
        {
            Publish(arguments);
            return;
        }

        _ = dispatcher.TryEnqueue(() =>
        {
            if (!IsExiting)
            {
                Publish(arguments);
            }
        });
    }

    private void Publish(AppActivationArguments arguments)
    {
        if (IsExiting)
        {
            return;
        }

        var envelope = WindowsActivationAdapter.ToEnvelope(arguments);
        _activationInbox.Publish(_activationRouter.Route(envelope));
    }

    private async void HandleActivation(ActivationRoute route)
    {
        if (IsExiting)
        {
            return;
        }

        try
        {
            await HandleActivationAsync(route);
        }
        catch (OperationCanceledException) when (IsExiting)
        {
            // Shutdown closes every activation ingress before service teardown.
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio activation failed: {error}");
            if (!IsExiting)
            {
                ShowTrayInformation("操作失败", error.Message);
            }
        }
    }

    private async Task HandleActivationAsync(ActivationRoute route)
    {
        if (IsExiting)
        {
            return;
        }

        if (!route.ShouldShowMainWindow)
        {
            var request = route.Operation switch
            {
                ActivationOperation.CompressImages =>
                    FileActivationRequestParser.FromImageFileActivation(route.Inputs),
                ActivationOperation.CopyPaths => new FileActivationRequest(
                    FileActivationOperation.CopyPaths,
                    route.Inputs,
                    []),
                _ => new FileActivationRequest(
                    FileActivationOperation.BackgroundOnly,
                    [],
                    []),
            };

            try
            {
                _ = await _featureServices.SilentShellActivation.HandleAsync(
                    request,
                    new ImageCompressionSettings(),
                    _shutdownCancellation.Token);
            }
            catch (OperationCanceledException)
            {
                // Cancellation is an expected no-window outcome during app shutdown.
            }
            catch (Exception error)
            {
                Debug.WriteLine($"Crosio background activation failed: {error}");
            }

            if (!IsExiting)
            {
                BackgroundActivationRequested?.Invoke(this, route);
            }
            return;
        }

        if (route.Issue == ActivationIssue.None && IsDirectScreenshot(route.Feature))
        {
            await RunScreenshotAsync(route.Feature);
            return;
        }

        if (route.Issue == ActivationIssue.None && route.Feature == FeatureId.ColorPicker)
        {
            await RunColorSampleAsync();
            return;
        }

        if (route.Issue == ActivationIssue.None && IsRecordingFeature(route.Feature))
        {
            await RunRecordingAsync(route.Feature);
            return;
        }

        if (!TryAllowMainWindowDisplay())
        {
            return;
        }

        var preparedRoute = route;
        string? selectionMessage = null;
        if (route.Feature == FeatureId.TextTranslation && route.Inputs.Count == 0)
        {
            var selection = await _featureServices.SelectedTextReader.ReadAsync();
            if (IsExiting)
            {
                return;
            }
            if (selection.Text is not null)
            {
                preparedRoute = ActivationRoute.Navigate(FeatureId.TextTranslation, [selection.Text]);
            }
            else
            {
                selectionMessage = selection.Message;
            }
        }

        // Selected-text acquisition yields to the dispatcher. A capture or
        // recording may have started since the first visibility check, so the
        // visual operation gets the final say immediately before showing UI.
        if (!TryAllowMainWindowDisplay())
        {
            return;
        }

        var window = EnsureMainWindow();
        window.ApplyRoute(preparedRoute);
        if (selectionMessage is not null)
        {
            window.ShowFeatureStatus(selectionMessage, isError: true);
        }
        window.ShowAndActivate();
    }

    private async Task InitializeResidentServicesAsync()
    {
        if (_residentServicesInitialized || IsExiting)
        {
            return;
        }

        _residentServicesInitialized = true;
        try
        {
            AppSettings settings;
            try
            {
                settings = await _featureServices.Settings.LoadAsync();
            }
            catch (Exception error)
            {
                Debug.WriteLine($"Crosio settings could not be loaded; defaults will be used: {error}");
                settings = AppSettings.Default;
            }

            if (IsExiting)
            {
                return;
            }

            await _featureServices.SharingAccessCodes.InitializeAsync(
                settings,
                _shutdownCancellation.Token);

            if (IsExiting)
            {
                return;
            }

            var hotkeys = _featureServices.GlobalHotkeys;
            hotkeys.Pressed += OnGlobalHotkeyPressed;
            var hotkeyResult = hotkeys.ReplaceBindings(settings.Hotkeys);
            if (!hotkeyResult.Succeeded)
            {
                Debug.WriteLine($"Crosio hotkey registration failed: {hotkeyResult.Failure?.Message}");
            }

            var tray = _featureServices.TrayIcon;
            tray.OpenRequested += OnTrayOpenRequested;
            tray.RecordingCommandRequested += OnTrayRecordingCommandRequested;
            tray.ExitRequested += OnTrayExitRequested;
            tray.SetRecordingControlState(RecordingTrayStateFor(
                _featureServices.Recording.Snapshot.Phase));
            tray.Start();
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio resident services failed to start: {error}");
            _mainWindow?.ShowFeatureStatus("后台快捷键或托盘启动失败，请重新打开一爪。", isError: true);
        }
    }

    private MainWindow EnsureMainWindow()
    {
        if (_mainWindow is not null)
        {
            return _mainWindow;
        }

        var window = new MainWindow(_featureServices);
        window.FeatureActionRequested += OnFeatureActionRequested;
        window.Closed += OnMainWindowClosed;
        _mainWindow = window;
        return window;
    }

    private void OnMainWindowClosed(object sender, WindowEventArgs args)
    {
        if (_mainWindow is not { } window)
        {
            return;
        }

        window.FeatureActionRequested -= OnFeatureActionRequested;
        window.Closed -= OnMainWindowClosed;
        _mainWindow = null;
    }

    private async void OnFeatureActionRequested(object? sender, FeatureActionRequestedEventArgs args)
    {
        if (IsExiting)
        {
            return;
        }

        try
        {
            if (IsDirectScreenshot(args.Feature))
            {
                await RunScreenshotAsync(args.Feature);
            }
            else if (args.Feature == FeatureId.ColorPicker)
            {
                await RunColorSampleAsync();
            }
            else if (IsRecordingFeature(args.Feature))
            {
                await RunRecordingAsync(args.Feature);
            }
        }
        catch (OperationCanceledException) when (IsExiting)
        {
            // The action was superseded by app shutdown.
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio feature action failed: {error}");
            if (!IsExiting)
            {
                ShowTrayInformation("操作失败", error.Message);
            }
        }
    }

    private void OnGlobalHotkeyPressed(object? sender, Crosio.Windows.Hotkeys.GlobalHotkeyPressedEventArgs args)
    {
        if (IsExiting || _mainWindow?.IsRecordingHotkey == true)
        {
            return;
        }

        var route = _activationRouter.Route(
            ActivationEnvelope.CommandLine(["--feature", args.Route]));
        _activationInbox.Publish(route);
    }

    private void OnTrayOpenRequested(object? sender, EventArgs args)
    {
        if (IsExiting)
        {
            return;
        }

        if (!TryAllowMainWindowDisplay())
        {
            return;
        }

        var window = EnsureMainWindow();
        window.ApplyRoute(ActivationRoute.Navigate(FeatureId.Home));
        window.ShowAndActivate();
    }

    private async void OnTrayRecordingCommandRequested(
        object? sender,
        TrayRecordingCommandRequestedEventArgs args)
    {
        if (IsExiting)
        {
            return;
        }

        try
        {
            var controller = _featureServices.Recording;
            var phase = controller.Snapshot.Phase;
            switch (args.Command)
            {
                case TrayRecordingCommand.Cancel
                    when phase is RecordingSessionPhase.CheckingCapabilities or
                        RecordingSessionPhase.Starting:
                    await controller.CancelAsync();
                    break;

                case TrayRecordingCommand.StopAndSave
                    when phase == RecordingSessionPhase.Recording:
                    await controller.StopAsync();
                    break;

                // The menu can become stale between opening it and choosing an
                // item. A mismatched command must never affect the new state.
            }
        }
        catch (OperationCanceledException) when (IsExiting)
        {
            // Shutdown owns cancellation after every native callback returns.
        }
        catch (Exception error)
        {
            // This is an async-void native event handler, so every exception
            // must be contained here instead of reaching the message loop.
            Debug.WriteLine($"Crosio tray recording command failed: {error}");
            ShowTrayInformation("录屏操作失败", error.Message);
        }
    }

    private async void OnTrayExitRequested(object? sender, EventArgs args)
    {
        if (Interlocked.Exchange(ref _exitStarted, 1) != 0)
        {
            return;
        }

        _shutdownCancellation.Cancel();
        _mainWindow?.BeginShutdown();
        _singleInstance.Activated -= OnRedirectedActivation;
        Interlocked.Exchange(ref _activationSubscription, null)?.Dispose();
        if (_featureServices.IsGlobalHotkeyHostCreated)
        {
            _featureServices.GlobalHotkeys.Pressed -= OnGlobalHotkeyPressed;
        }
        if (_featureServices.IsTrayIconHostCreated)
        {
            _featureServices.TrayIcon.OpenRequested -= OnTrayOpenRequested;
            _featureServices.TrayIcon.RecordingCommandRequested -= OnTrayRecordingCommandRequested;
            _featureServices.TrayIcon.ExitRequested -= OnTrayExitRequested;
        }
        if (_mainWindow is { } window)
        {
            window.FeatureActionRequested -= OnFeatureActionRequested;
        }

        try
        {
            _featureServices.Recording.StateChanged -= OnRecordingStateChanged;
            await _featureServices.DisposeAsync();
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio shutdown cleanup failed: {error}");
        }
        finally
        {
            Exit();
        }
    }

    private async Task RunScreenshotAsync(FeatureId feature)
    {
        if (IsExiting)
        {
            return;
        }

        if (IsRecordingBusy(_featureServices.Recording.Snapshot.Phase))
        {
            ShowTrayInformation("截图暂停", "请先停止当前录屏，再开始截图。");
            return;
        }

        // Preserve the current annotation document. This check intentionally
        // happens before capture and clipboard delivery so a second shortcut
        // cannot put image B on the clipboard while the editor still shows A.
        if (await _featureServices.ActivateExistingScreenshotEditorAsync())
        {
            return;
        }

        if (IsExiting)
        {
            return;
        }

        if (!await _featureGate.WaitAsync(0))
        {
            return;
        }

        try
        {
            if (IsExiting)
            {
                return;
            }

            if (_mainWindow is { } mainWindow)
            {
                await mainWindow.HideForBackgroundActionAsync();
            }

            if (feature == FeatureId.LongScreenshot)
            {
                var result = await _featureServices.LongCapture.CaptureInteractiveAsync();
                if (result.WasCancelled || result.Image is null)
                {
                    return;
                }

                var longDelivery = await _featureServices.ScreenshotCapture.DeliverAndCopyAsync(
                    result.Image);
                await _featureServices.ScreenshotEditor.ShowAsync(
                    longDelivery.Image,
                    new Crosio.Windows.Capture.Editor.ScreenshotEditorOptions(
                        result.Warning ?? (longDelivery.WasCopiedToClipboard
                            ? "长截图已复制到剪贴板。"
                            : "长截图完成，但自动复制失败；可点击“复制图片”重试。")));
                return;
            }

            if (feature == FeatureId.FramedScreenshot)
            {
                await RunFramedScreenshotAsync();
                return;
            }

            if (feature == FeatureId.MultiWindowScreenshot)
            {
                await RunMultiWindowScreenshotAsync();
                return;
            }

            ScreenshotCaptureTarget? target = feature switch
            {
                FeatureId.RegionScreenshot =>
                    await _featureServices.CaptureTargetPicker.PickRegionAsync(),
                FeatureId.WindowScreenshot =>
                    await _featureServices.CaptureTargetPicker.PickWindowAsync(),
                FeatureId.ScreenScreenshot => DisplayUnderPointer(),
                FeatureId.DelayedScreenshot => await PrepareDelayedDisplayAsync(),
                _ => null,
            };
            if (target is null)
            {
                return;
            }

            var delivery = await _featureServices.ScreenshotCapture.CaptureAndCopyAsync(
                new ScreenshotCaptureRequest(target));
            await _featureServices.ScreenshotEditor.ShowAsync(delivery);
        }
        catch (OperationCanceledException)
        {
            // Cancelling a picker or countdown intentionally leaves the main window hidden.
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio screenshot failed: {error}");
            try
            {
                if (!IsExiting && _featureServices.TrayIcon.IsStarted)
                {
                    _featureServices.TrayIcon.ShowInformation("截图失败", error.Message);
                }
            }
            catch (Exception trayError)
            {
                Debug.WriteLine($"Crosio could not show the screenshot failure: {trayError}");
            }
        }
        finally
        {
            _featureGate.Release();
        }
    }

    private DisplayCaptureTarget? DisplayUnderPointer()
    {
        var pointer = System.Windows.Forms.Cursor.Position;
        var display = _featureServices.CaptureTargetCatalog.GetSnapshot(checked((uint)Environment.ProcessId))
            .Displays
            .FirstOrDefault(candidate =>
                pointer.X >= candidate.Bounds.Left &&
                pointer.X < candidate.Bounds.Right &&
                pointer.Y >= candidate.Bounds.Top &&
                pointer.Y < candidate.Bounds.Bottom);
        return display is null
            ? null
            : new DisplayCaptureTarget(display.DeviceName, display.Bounds);
    }

    private async Task<DisplayCaptureTarget?> PrepareDelayedDisplayAsync()
    {
        var display = DisplayUnderPointer();
        if (display is null)
        {
            return null;
        }

        await Task.Delay(TimeSpan.FromSeconds(5));
        return display;
    }

    private async Task RunFramedScreenshotAsync()
    {
        var display = DisplayUnderPointer()
            ?? throw new ScreenshotCaptureException("找不到鼠标所在的屏幕。");
        var completed = await _featureServices.ScreenshotCountdown.RunAsync(
            display.Bounds,
            seconds: 3);
        if (!completed)
        {
            return;
        }

        // Let DWM remove the countdown surface before reading display pixels.
        await Task.Delay(TimeSpan.FromMilliseconds(90));
        var delivery = await _featureServices.AdvancedScreenshots.CaptureFramedAndCopyAsync(display);
        await _featureServices.ScreenshotEditor.ShowAsync(delivery);
    }

    private async Task RunMultiWindowScreenshotAsync()
    {
        var selection = await _featureServices.MultiWindowCaptureTargetPicker.PickWindowsAsync();
        if (selection is null || selection.Count == 0)
        {
            return;
        }

        // The selection dialog is a real top-level window; ensure DWM has
        // removed it before capturing the explicitly checked windows.
        await Task.Delay(TimeSpan.FromMilliseconds(120));
        var delivery = await _featureServices.AdvancedScreenshots
            .CaptureSelectedWindowsAndCopyAsync(selection);
        if (delivery is null)
        {
            return;
        }
        await _featureServices.ScreenshotEditor.ShowAsync(delivery);
    }

    private async Task RunColorSampleAsync()
    {
        if (IsExiting)
        {
            return;
        }

        if (!await _featureGate.WaitAsync(0))
        {
            return;
        }

        try
        {
            if (IsExiting)
            {
                return;
            }

            if (_mainWindow is { } mainWindow)
            {
                await mainWindow.HideForBackgroundActionAsync();
            }
            await Task.Delay(TimeSpan.FromMilliseconds(700));
            var sample = await _featureServices.ScreenColorSampler.SampleCursorAsync();
            _featureServices.RecentColors.Confirm(sample.Color);
            await _featureServices.ColorClipboard.CopyAsync(sample.Color, ColorTextFormat.Hex);
            if (!IsExiting && _featureServices.TrayIcon.IsStarted)
            {
                _featureServices.TrayIcon.ShowInformation("颜色已复制", sample.Color.Hex);
            }
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio color sampling failed: {error}");
            try
            {
                if (!IsExiting && _featureServices.TrayIcon.IsStarted)
                {
                    _featureServices.TrayIcon.ShowInformation("取色失败", error.Message);
                }
            }
            catch (Exception trayError)
            {
                Debug.WriteLine($"Crosio could not show the color failure: {trayError}");
            }
        }
        finally
        {
            _featureGate.Release();
        }
    }

    private async Task RunRecordingAsync(FeatureId feature)
    {
        if (IsExiting)
        {
            return;
        }

        // Starting the native recorder can take a moment and holds the general
        // feature gate. A second press during that window is explicitly a
        // cancel request, so it must bypass that gate.
        var preGateSnapshot = _featureServices.Recording.Snapshot;
        if (preGateSnapshot.Phase is RecordingSessionPhase.CheckingCapabilities or
            RecordingSessionPhase.Starting)
        {
            await _featureServices.Recording.CancelAsync();
            return;
        }

        if (!await _featureGate.WaitAsync(0))
        {
            return;
        }

        try
        {
            if (IsExiting)
            {
                return;
            }

            var controller = _featureServices.Recording;
            var snapshot = controller.Snapshot;
            if (snapshot.Phase == RecordingSessionPhase.Recording)
            {
                var requestedKind = RecordingKindFor(feature);
                if (snapshot.TargetKind != requestedKind)
                {
                    ShowTrayInformation(
                        "正在录屏",
                        "请使用当前录制类型的快捷键停止，或从托盘菜单停止并保存。");
                    return;
                }

                await controller.StopAsync();
                return;
            }

            if (snapshot.Phase is RecordingSessionPhase.CheckingCapabilities or
                RecordingSessionPhase.Starting)
            {
                await controller.CancelAsync();
                return;
            }

            if (snapshot.Phase == RecordingSessionPhase.Stopping)
            {
                ShowTrayInformation("正在保存录屏", "MP4 封装完成前请稍候。");
                return;
            }

            if (snapshot.Phase != RecordingSessionPhase.Idle)
            {
                controller.Reset();
            }

            var includeSystemAudio = _mainWindow?.CaptureSystemAudio ?? true;
            var includeCursor = _mainWindow?.ShowRecordingCursor ?? true;
            if (_mainWindow is { } mainWindow)
            {
                await mainWindow.HideForBackgroundActionAsync();
            }

            var target = await PickRecordingTargetAsync(feature);
            if (target is null)
            {
                return;
            }

            var request = new RecordingRequest(
                target,
                includeSystemAudio,
                includeCursor,
                _featureServices.RecordingsDirectory,
                SuggestedRecordingName(feature));
            await controller.StartAsync(request);
            ShowTrayInformation(
                "录屏已开始",
                includeSystemAudio ? "正在录制画面和系统声音。" : "正在录制画面。");
        }
        catch (OperationCanceledException)
        {
            // Cancelling a native picker intentionally leaves the main window hidden.
        }
        catch (RecordingException error)
        {
            if (error.Code == RecordingFailureCode.StartCancelled)
            {
                return;
            }

            Debug.WriteLine($"Crosio recording failed: {error}");
            ShowTrayInformation("录屏失败", error.Message);
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio recording failed: {error}");
            ShowTrayInformation("录屏失败", error.Message);
        }
        finally
        {
            _featureGate.Release();
        }
    }

    private async Task<RecordingTarget?> PickRecordingTargetAsync(FeatureId feature)
    {
        var processId = checked((uint)Environment.ProcessId);
        switch (feature)
        {
            case FeatureId.ScreenRecording:
            {
                var display = DisplayUnderPointer();
                if (display is null)
                {
                    throw new RecordingException(
                        RecordingFailureCode.InvalidRequest,
                        "找不到鼠标所在的屏幕。");
                }
                return new DisplayRecordingTarget(
                    display.DeviceName,
                    MonitorFor(display.Bounds),
                    new PixelSize(display.Bounds.Width, display.Bounds.Height));
            }

            case FeatureId.RegionRecording:
            {
                var selected = await _featureServices.CaptureTargetPicker.PickRegionAsync();
                if (selected is null)
                {
                    return null;
                }

                var display = _featureServices.CaptureTargetCatalog
                    .GetSnapshot(processId)
                    .Displays
                    .FirstOrDefault(candidate => Contains(candidate.Bounds, selected.Bounds));
                if (display is null)
                {
                    throw new RecordingException(
                        RecordingFailureCode.InvalidRequest,
                        "录制区域必须完整位于同一块屏幕内，请重新框选。");
                }

                return new RegionRecordingTarget(
                    display.DeviceName,
                    MonitorFor(display.Bounds),
                    ToRecordingRectangle(display.Bounds),
                    ToRecordingRectangle(selected.Bounds));
            }

            case FeatureId.WindowRecording:
            {
                var selected = await _featureServices.CaptureTargetPicker.PickWindowAsync();
                if (selected is null)
                {
                    return null;
                }

                var window = _featureServices.CaptureTargetCatalog
                    .GetSnapshot(processId)
                    .Windows
                    .FirstOrDefault(candidate => candidate.WindowHandle == selected.WindowHandle);
                if (window is null)
                {
                    throw new RecordingException(
                        RecordingFailureCode.InvalidRequest,
                        "选中的窗口已经关闭或最小化。");
                }

                return new WindowRecordingTarget(
                    window.WindowHandle,
                    new PixelSize(window.Bounds.Width, window.Bounds.Height));
            }

            default:
                throw new ArgumentOutOfRangeException(nameof(feature));
        }
    }

    private void OnRecordingStateChanged(object? sender, RecordingSessionSnapshot snapshot)
    {
        if (IsExiting)
        {
            return;
        }

        var dispatcher = _dispatcherQueue;
        if (dispatcher is null)
        {
            return;
        }

        _ = dispatcher.TryEnqueue(() =>
        {
            if (IsExiting)
            {
                return;
            }

            _mainWindow?.ApplyRecordingSnapshot(snapshot);
            try
            {
                var tray = _featureServices.TrayIcon;
                tray.SetRecordingControlState(RecordingTrayStateFor(snapshot.Phase));
                if (tray.IsStarted)
                {
                    tray.UpdateTooltip(
                        snapshot.Phase == RecordingSessionPhase.Recording
                            ? "一爪 · 正在录屏"
                            : "一爪");
                    if (snapshot.Phase == RecordingSessionPhase.Completed && snapshot.OutputPath is { } outputPath)
                    {
                        tray.ShowInformation(
                            "录屏已保存",
                            Path.GetFileName(outputPath));
                    }
                    else if (snapshot.Phase == RecordingSessionPhase.Failed)
                    {
                        tray.ShowInformation(
                            "录屏失败",
                            snapshot.Message ?? "无法完成这次录屏。");
                    }
                }
            }
            catch (Exception error)
            {
                Debug.WriteLine($"Crosio could not update the recording tray state: {error}");
            }
        });
    }

    private void ShowTrayInformation(string title, string message)
    {
        if (IsExiting)
        {
            return;
        }

        try
        {
            if (_featureServices.TrayIcon.IsStarted)
            {
                _featureServices.TrayIcon.ShowInformation(title, message);
            }
            else
            {
                _mainWindow?.ShowFeatureStatus(message, isError: title.Contains("失败", StringComparison.Ordinal));
            }
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Crosio could not show a notification: {error}");
        }
    }

    private static bool Contains(PixelRect outer, PixelRect inner) =>
        inner.Left >= outer.Left &&
        inner.Top >= outer.Top &&
        inner.Right <= outer.Right &&
        inner.Bottom <= outer.Bottom;

    private static PixelRectangle ToRecordingRectangle(PixelRect rectangle) =>
        new(rectangle.Left, rectangle.Top, rectangle.Width, rectangle.Height);

    private static nint MonitorFor(PixelRect bounds)
    {
        var point = new NativePoint
        {
            X = checked(bounds.Left + bounds.Width / 2),
            Y = checked(bounds.Top + bounds.Height / 2),
        };
        var monitor = MonitorFromPoint(point, 2); // MONITOR_DEFAULTTONEAREST
        if (monitor == nint.Zero)
        {
            throw new RecordingException(
                RecordingFailureCode.InvalidRequest,
                "Windows 无法解析录屏目标的显示器。");
        }
        return monitor;
    }

    private static RecordingTargetKind RecordingKindFor(FeatureId feature) => feature switch
    {
        FeatureId.ScreenRecording => RecordingTargetKind.Display,
        FeatureId.RegionRecording => RecordingTargetKind.Region,
        FeatureId.WindowRecording => RecordingTargetKind.Window,
        _ => throw new ArgumentOutOfRangeException(nameof(feature)),
    };

    private static string SuggestedRecordingName(FeatureId feature) => feature switch
    {
        FeatureId.ScreenRecording => "一爪屏幕录制",
        FeatureId.RegionRecording => "一爪区域录制",
        FeatureId.WindowRecording => "一爪窗口录制",
        _ => "一爪录屏",
    };

    private static bool IsRecordingBusy(RecordingSessionPhase phase) => phase is
        RecordingSessionPhase.CheckingCapabilities or
        RecordingSessionPhase.Starting or
        RecordingSessionPhase.Recording or
        RecordingSessionPhase.Stopping;

    private static TrayRecordingControlState RecordingTrayStateFor(
        RecordingSessionPhase phase) => phase switch
    {
        RecordingSessionPhase.CheckingCapabilities or
            RecordingSessionPhase.Starting => TrayRecordingControlState.CanCancel,
        RecordingSessionPhase.Recording => TrayRecordingControlState.CanStopAndSave,
        RecordingSessionPhase.Stopping => TrayRecordingControlState.Saving,
        _ => TrayRecordingControlState.Hidden,
    };

    private bool TryAllowMainWindowDisplay()
    {
        var recordingInProgress = IsRecordingBusy(
            _featureServices.Recording.Snapshot.Phase);
        if (!MainWindowVisibilityPolicy.ShouldKeepHidden(
                visualOperationInProgress: _featureGate.CurrentCount == 0,
                recordingInProgress: recordingInProgress))
        {
            return true;
        }

        ShowTrayInformation(
            "操作进行中",
            recordingInProgress
                ? "录屏期间主界面保持隐藏。请从托盘菜单停止录屏，或再次按录屏快捷键停止。"
                : "完成当前截图或取色操作后再打开一爪。");
        return false;
    }

    private static bool IsRecordingFeature(FeatureId feature) => feature is
        FeatureId.ScreenRecording or
        FeatureId.RegionRecording or
        FeatureId.WindowRecording;

    private static bool IsDirectScreenshot(FeatureId feature) => feature is
        FeatureId.RegionScreenshot or
        FeatureId.WindowScreenshot or
        FeatureId.ScreenScreenshot or
        FeatureId.DelayedScreenshot or
        FeatureId.FramedScreenshot or
        FeatureId.MultiWindowScreenshot or
        FeatureId.LongScreenshot;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern nint MonitorFromPoint(NativePoint point, uint flags);
}

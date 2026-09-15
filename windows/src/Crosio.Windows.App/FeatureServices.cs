using Crosio.Windows.Accessibility;
using Crosio.Windows.Capture;
using Crosio.Windows.Capture.Clipboard;
using Crosio.Windows.Capture.Composition;
using Crosio.Windows.Capture.Editor;
using Crosio.Windows.Capture.Pinning;
using Crosio.Windows.Capture.Selection;
using Crosio.Windows.Core.Settings;
using Crosio.Windows.Hotkeys;
using Crosio.Windows.Intelligence.Ocr;
using Crosio.Windows.Intelligence.Translation;
using Crosio.Windows.LongCapture;
using Crosio.Windows.Media;
using Crosio.Windows.Ocr;
using Crosio.Windows.Platform.Images;
using Crosio.Windows.Platform.Shell;
using Crosio.Windows.Platform.Startup;
using Crosio.Windows.Platform.Tray;
using Crosio.Windows.Sharing;
using Crosio.Windows.Translation;

namespace Crosio.Windows.App;

/// <summary>
/// The composition root for native Windows services. Services that allocate a
/// window, message loop, listener, or user-data directory stay lazy until the
/// corresponding feature is invoked.
/// </summary>
internal sealed class FeatureServices : IAsyncDisposable
{
    private static readonly TimeSpan TranslationShutdownTimeout = TimeSpan.FromSeconds(5);

    private readonly WindowsImageClipboard _imageClipboard = new();
    private readonly Lazy<PinnedScreenshotManager> _pinnedScreenshots = new(
        () => new PinnedScreenshotManager(),
        LazyThreadSafetyMode.ExecutionAndPublication);
    private readonly Lazy<ScreenshotEditorController> _screenshotEditor;
    private readonly Lazy<WindowsGlobalHotkeyHost> _globalHotkeys = new(
        () => new WindowsGlobalHotkeyHost(),
        LazyThreadSafetyMode.None);
    private readonly Lazy<System.Drawing.Icon> _trayImage = new(
        () => new System.Drawing.Icon(ApplicationBranding.IconPath, 32, 32),
        LazyThreadSafetyMode.None);
    private readonly Lazy<TrayIconHost> _trayIcon;
    private readonly SharedContentStore _sharedContent;
    private readonly Lazy<LocalSharingServer> _sharingServer;
    private readonly MarianOnnxTranslationEngine _translationEngine;

    public FeatureServices()
    {
        _trayIcon = new Lazy<TrayIconHost>(
            () => new TrayIconHost(
                _trayImage.Value.Handle,
                new Guid("3F62CF92-8430-48F1-90C8-C25E93E8070B")),
            LazyThreadSafetyMode.None);
        ImageCompression = new ImageCompressionService();
        ImageFileActivation = new ImageFileActivationHandler(
            ImageCompression,
            new ExplorerRevealService());
        SilentShellActivation = new SilentShellActivationHandler(
            new ClipboardPathService(),
            ImageFileActivation);
        CaptureTargetCatalog = new WindowsCaptureTargetCatalog();
        ScreenshotCaptureService = new WindowsScreenshotCaptureService();
        SelectedWindowCaptureService = new WindowsSelectedWindowCaptureService();
        ScreenshotCapture = new ScreenshotCapturePipeline(
            ScreenshotCaptureService,
            _imageClipboard);
        CaptureTargetPicker = new WindowsCaptureTargetPicker(CaptureTargetCatalog);
        MultiWindowCaptureTargetPicker = new WindowsMultiWindowCaptureTargetPicker(
            CaptureTargetCatalog);
        ScreenshotCountdown = new WindowsScreenshotCountdown();
        ScreenshotComposer = new WindowsScreenshotComposer();
        AdvancedScreenshots = new AdvancedScreenshotCaptureCoordinator(
            ScreenshotCaptureService,
            SelectedWindowCaptureService,
            ScreenshotComposer,
            ScreenshotCapture);
        LongCapture = new WindowsLongCaptureController(
            CaptureTargetPicker,
            new WindowsScreenshotCaptureService());
        SelectedTextReader = new UiAutomationSelectedTextReader();
        ImageOcr = new WindowsOcrService();
        StartupRegistration = new StartupRegistrationService();
        ScreenColorSampler = new WindowsScreenColorSampler();
        ColorClipboard = new ColorClipboardService(new WindowsTextClipboardWriter());
        RecentColors = new RecentColorStore();
        Settings = JsonSettingsStore.CreateDefault();

        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        RecordingsDirectory = ResolveRecordingsDirectory(localData);
        Recording = new RecordingSessionController(
            new WindowsGraphicsCaptureRecordingBackend(),
            new RecordingFileStore(Path.Combine(localData, "Crosio", "Recordings", "Drafts")));
        _sharedContent = new SharedContentStore(Path.Combine(localData, "Crosio", "Inbox"));
        TranslationModels = new OfflineModelCatalog(
            Path.Combine(localData, "Crosio", "TranslationModels"));
        TranslationModelInstaller = new OfflineModelPackInstaller(TranslationModels);
        OfficialTranslationModels = new OfficialTranslationModelInstaller(TranslationModels);
        _translationEngine = new MarianOnnxTranslationEngine(TranslationModels);
        Translation = new TranslationCoordinator(_translationEngine);
        TranslationHistory = new TranslationHistoryStore(
            Path.Combine(localData, "Crosio", "translation-history.json"));
        _screenshotEditor = new Lazy<ScreenshotEditorController>(
            () => new ScreenshotEditorController(
                _imageClipboard,
                PinnedScreenshots,
                new ScreenshotEditorShareSink(
                    Path.Combine(localData, "Crosio", "Screenshots"),
                    _sharedContent),
                new ScreenshotEditorOcrService(ImageOcr)),
            LazyThreadSafetyMode.ExecutionAndPublication);
        _sharingServer = new Lazy<LocalSharingServer>(
            () => new LocalSharingServer(_sharedContent),
            LazyThreadSafetyMode.ExecutionAndPublication);
        SharingAccessCodes = new SharingAccessCodeSettingsService(
            Settings,
            () => _sharingServer.Value);
    }

    public IImageCompressionService ImageCompression { get; }

    public ImageFileActivationHandler ImageFileActivation { get; }

    public SilentShellActivationHandler SilentShellActivation { get; }

    public ScreenshotCapturePipeline ScreenshotCapture { get; }

    public IScreenshotCaptureService ScreenshotCaptureService { get; }

    public ISelectedWindowCaptureService SelectedWindowCaptureService { get; }

    public ICaptureTargetCatalog CaptureTargetCatalog { get; }

    public ICaptureTargetPicker CaptureTargetPicker { get; }

    public IMultiWindowCaptureTargetPicker MultiWindowCaptureTargetPicker { get; }

    public IScreenshotCountdown ScreenshotCountdown { get; }

    public WindowsScreenshotComposer ScreenshotComposer { get; }

    public AdvancedScreenshotCaptureCoordinator AdvancedScreenshots { get; }

    public WindowsLongCaptureController LongCapture { get; }

    public ISelectedTextReader SelectedTextReader { get; }

    public IImageOcrService ImageOcr { get; }

    public IStartupRegistrationService StartupRegistration { get; }

    public IScreenColorSampler ScreenColorSampler { get; }

    public ColorClipboardService ColorClipboard { get; }

    public RecentColorStore RecentColors { get; }

    public RecordingSessionController Recording { get; }

    public string RecordingsDirectory { get; }

    public ISettingsStore Settings { get; }

    public SharingAccessCodeSettingsService SharingAccessCodes { get; }

    public TranslationHistoryStore TranslationHistory { get; }

    public OfflineModelCatalog TranslationModels { get; }

    public OfflineModelPackInstaller TranslationModelInstaller { get; }

    public OfficialTranslationModelInstaller OfficialTranslationModels { get; }

    public TranslationCoordinator Translation { get; }

    public PinnedScreenshotManager PinnedScreenshots => _pinnedScreenshots.Value;

    public ScreenshotEditorController ScreenshotEditor => _screenshotEditor.Value;

    public Task<bool> ActivateExistingScreenshotEditorAsync(
        CancellationToken cancellationToken = default) =>
        _screenshotEditor.IsValueCreated
            ? _screenshotEditor.Value.ActivateExistingAsync(cancellationToken)
            : Task.FromResult(false);

    public WindowsGlobalHotkeyHost GlobalHotkeys => _globalHotkeys.Value;

    public bool IsGlobalHotkeyHostCreated => _globalHotkeys.IsValueCreated;

    public GlobalHotkeySettingsApplier HotkeySettings => new(GlobalHotkeys, Settings);

    public TrayIconHost TrayIcon => _trayIcon.Value;

    public bool IsTrayIconHostCreated => _trayIcon.IsValueCreated;

    public SharedContentStore SharedContent => _sharedContent;

    public LocalSharingServer SharingServer => _sharingServer.Value;

    public async ValueTask DisposeAsync()
    {
        // Close installers to new work and propagate cancellation immediately.
        // Their DisposeAsync tasks release HttpClient/semaphores only after the
        // active download/import scope has returned.
        var installerShutdown = Task.WhenAll(
            OfficialTranslationModels.DisposeAsync().AsTask(),
            TranslationModelInstaller.DisposeAsync().AsTask());

        // Recording disposal safely finalizes an active MP4. It must run before
        // capture windows, hotkeys, and the tray are torn down.
        // Preserve the WinUI dispatcher context: hotkey and tray hosts below
        // must be torn down on the same thread that created their HWNDs.
        await Recording.DisposeAsync();

        if (_screenshotEditor.IsValueCreated)
        {
            _screenshotEditor.Value.Dispose();
        }

        if (CaptureTargetPicker is IDisposable disposablePicker)
        {
            disposablePicker.Dispose();
        }

        LongCapture.Dispose();

        if (_globalHotkeys.IsValueCreated)
        {
            _globalHotkeys.Value.Dispose();
        }

        if (_trayIcon.IsValueCreated)
        {
            _trayIcon.Value.Dispose();
        }

        if (_trayImage.IsValueCreated)
        {
            _trayImage.Value.Dispose();
        }

        if (_pinnedScreenshots.IsValueCreated)
        {
            _pinnedScreenshots.Value.Dispose();
        }

        if (_sharingServer.IsValueCreated)
        {
            await _sharingServer.Value.DisposeAsync().ConfigureAwait(false);
        }

        var translationDrain = Translation.DisposeAsync().AsTask();
        if (await CompletesWithinAsync(translationDrain, TranslationShutdownTimeout).ConfigureAwait(false))
        {
            var engineDisposal = _translationEngine.DisposeAsync().AsTask();
            if (!await CompletesWithinAsync(engineDisposal, TranslationShutdownTimeout).ConfigureAwait(false))
            {
                System.Diagnostics.Debug.WriteLine(
                    "Crosio translation engine is still draining; native cleanup was deferred.");
                _ = ObserveDeferredCleanupAsync(engineDisposal);
            }
        }
        else
        {
            // Never dispose ONNX sessions while an inference call may still be
            // inside native code. Shutdown stays bounded; cleanup is resumed
            // only after every coordinator-owned request has actually exited.
            System.Diagnostics.Debug.WriteLine(
                "Crosio translation requests did not drain within the shutdown window; native cleanup was deferred.");
            _ = DisposeEngineAfterDrainAsync(translationDrain, _translationEngine);
        }
        if (!await CompletesWithinAsync(installerShutdown, TranslationShutdownTimeout).ConfigureAwait(false))
        {
            System.Diagnostics.Debug.WriteLine(
                "Crosio translation model installation is still draining; resource cleanup was deferred.");
            _ = ObserveDeferredCleanupAsync(installerShutdown);
        }
    }

    private static async Task<bool> CompletesWithinAsync(Task operation, TimeSpan timeout)
    {
        if (await Task.WhenAny(operation, Task.Delay(timeout)).ConfigureAwait(false) != operation)
        {
            return false;
        }
        await operation.ConfigureAwait(false);
        return true;
    }

    private static async Task DisposeEngineAfterDrainAsync(
        Task coordinatorDrain,
        MarianOnnxTranslationEngine engine)
    {
        try
        {
            await coordinatorDrain.ConfigureAwait(false);
            await engine.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Deferred Crosio translation cleanup failed: {error}");
        }
    }

    private static async Task ObserveDeferredCleanupAsync(Task cleanup)
    {
        try
        {
            await cleanup.ConfigureAwait(false);
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Deferred Crosio translation cleanup failed: {error}");
        }
    }

    private static string ResolveRecordingsDirectory(string localData)
    {
        var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
        return string.IsNullOrWhiteSpace(videos)
            ? Path.Combine(localData, "Crosio", "Recordings")
            : Path.Combine(videos, "Crosio");
    }
}

using Crosio.Windows.Core.Settings;
using Crosio.Windows.Sharing;

namespace Crosio.Windows.App;

internal sealed record SharingAccessCodeState(string AccessCode, bool IsCustom);

internal sealed class SharingAccessCodeSettingsService
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly ISettingsStore _settingsStore;
    private readonly Func<LocalSharingServer> _server;
    private bool _initialized;

    public SharingAccessCodeSettingsService(
        ISettingsStore settingsStore,
        Func<LocalSharingServer> server)
    {
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        _server = server ?? throw new ArgumentNullException(nameof(server));
    }

    public async Task<SharingAccessCodeState> InitializeAsync(
        AppSettings? loadedSettings = null,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!_initialized)
            {
                var settings = loadedSettings
                    ?? await _settingsStore.LoadAsync(cancellationToken).ConfigureAwait(false);
                if (settings.CustomShareAccessCode is { } customAccessCode)
                {
                    await _server()
                        .UpdateSessionTokenAsync(customAccessCode, cancellationToken)
                        .ConfigureAwait(false);
                }
                _initialized = true;
            }

            return CurrentState();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<SharingAccessCodeState> SaveCustomAsync(
        string accessCode,
        CancellationToken cancellationToken = default)
    {
        var normalized = ShareAccessCode.NormalizeCustom(accessCode);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureInitializedLockedAsync(cancellationToken).ConfigureAwait(false);
            var current = await _settingsStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            await _settingsStore
                .SaveAsync(CopyWithAccessCode(current, normalized), cancellationToken)
                .ConfigureAwait(false);
            await _server()
                .UpdateSessionTokenAsync(normalized, cancellationToken)
                .ConfigureAwait(false);
            return CurrentState();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<SharingAccessCodeState> ResetToRandomAsync(
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureInitializedLockedAsync(cancellationToken).ConfigureAwait(false);
            var current = await _settingsStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            await _settingsStore
                .SaveAsync(CopyWithAccessCode(current, customAccessCode: null), cancellationToken)
                .ConfigureAwait(false);
            await _server().ResetSessionTokenAsync(cancellationToken).ConfigureAwait(false);
            return CurrentState();
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task EnsureInitializedLockedAsync(CancellationToken cancellationToken)
    {
        if (_initialized)
        {
            return;
        }

        var settings = await _settingsStore.LoadAsync(cancellationToken).ConfigureAwait(false);
        if (settings.CustomShareAccessCode is { } customAccessCode)
        {
            await _server()
                .UpdateSessionTokenAsync(customAccessCode, cancellationToken)
                .ConfigureAwait(false);
        }
        _initialized = true;
    }

    private SharingAccessCodeState CurrentState()
    {
        var server = _server();
        return new SharingAccessCodeState(server.SessionToken, server.UsesCustomAccessCode);
    }

    private static AppSettings CopyWithAccessCode(AppSettings source, string? customAccessCode) =>
        new()
        {
            SchemaVersion = source.SchemaVersion,
            StartWithWindows = source.StartWithWindows,
            RunInBackground = source.RunInBackground,
            PreferredSharingPort = source.PreferredSharingPort,
            CustomShareAccessCode = customAccessCode,
            Hotkeys = source.Hotkeys,
        };
}

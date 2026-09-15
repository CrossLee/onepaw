using Crosio.Windows.App;
using Crosio.Windows.Core.Settings;
using Xunit;

namespace Crosio.Windows.Sharing.Tests;

public sealed class SharingAccessCodeSettingsServiceTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        $"onepaw-access-code-settings-{Guid.NewGuid():N}");

    [Fact]
    public async Task InitializesFromPersistsAndClearsCustomAccessCodeWithoutLosingSettings()
    {
        var initial = new AppSettings
        {
            StartWithWindows = true,
            PreferredSharingPort = 6123,
            CustomShareAccessCode = "Old-Code_8",
        };
        var store = new MemorySettingsStore(initial);
        await using var server = new LocalSharingServer(new SharedContentStore(_root));
        var service = new SharingAccessCodeSettingsService(store, () => server);

        var loaded = await service.InitializeAsync();
        var saved = await service.SaveCustomAsync("  New-Code_9  ");

        Assert.Equal("Old-Code_8", loaded.AccessCode);
        Assert.True(loaded.IsCustom);
        Assert.Equal("New-Code_9", saved.AccessCode);
        Assert.Equal("New-Code_9", store.Current.CustomShareAccessCode);
        Assert.True(store.Current.StartWithWindows);
        Assert.Equal(6123, store.Current.PreferredSharingPort);

        var random = await service.ResetToRandomAsync();

        Assert.False(random.IsCustom);
        Assert.Null(store.Current.CustomShareAccessCode);
        Assert.Equal(ShareAccessCode.DefaultRandomLength, random.AccessCode.Length);
        Assert.NotEqual("New-Code_9", random.AccessCode);
        Assert.True(store.Current.StartWithWindows);
        Assert.Equal(6123, store.Current.PreferredSharingPort);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    private sealed class MemorySettingsStore(AppSettings current) : ISettingsStore
    {
        public AppSettings Current { get; private set; } = current;

        public Task<AppSettings> LoadAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(Current);
        }

        public Task SaveAsync(AppSettings settings, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Current = settings;
            return Task.CompletedTask;
        }
    }
}

using Crosio.Windows.Core.Settings;

namespace Crosio.Windows.Core.Tests.Settings;

public sealed class JsonSettingsStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(
        Path.GetTempPath(),
        $"Crosio.Windows.Tests.{Guid.NewGuid():N}");

    [Fact]
    public async Task MissingFileReturnsFreshDefaults()
    {
        var store = new JsonSettingsStore(Path.Combine(_directory, "settings.json"));

        var first = await store.LoadAsync();
        var second = await store.LoadAsync();

        Assert.NotSame(first, second);
        Assert.Equal(5421, first.PreferredSharingPort);
    }

    [Fact]
    public async Task SavesAndLoadsSettingsWithoutBom()
    {
        var path = Path.Combine(_directory, "settings.json");
        var store = new JsonSettingsStore(path);
        var expected = new AppSettings
        {
            StartWithWindows = true,
            PreferredSharingPort = 6123,
            CustomShareAccessCode = "Class-2026_A",
        };

        await store.SaveAsync(expected);
        var actual = await store.LoadAsync();
        var bytes = await File.ReadAllBytesAsync(path);

        Assert.True(actual.StartWithWindows);
        Assert.Equal(6123, actual.PreferredSharingPort);
        Assert.Equal("Class-2026_A", actual.CustomShareAccessCode);
        Assert.False(bytes.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }));
    }

    [Fact]
    public async Task OlderSettingsWithoutAccessCodeRemainCompatible()
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, "settings.json");
        await File.WriteAllTextAsync(
            path,
            """
            {
              "schemaVersion": 1,
              "startWithWindows": false,
              "runInBackground": true,
              "preferredSharingPort": 5421,
              "hotkeys": {
                "capture-region": { "modifiers": "control, shift", "key": "1" },
                "capture-window": { "modifiers": "control, shift", "key": "2" },
                "capture-screen": { "modifiers": "control, shift", "key": "3" }
              }
            }
            """);
        var store = new JsonSettingsStore(path);

        var settings = await store.LoadAsync();

        Assert.Null(settings.CustomShareAccessCode);
        Assert.Empty(AppSettingsValidator.Validate(settings));
    }

    [Fact]
    public async Task CorruptFileIsReportedInsteadOfSilentlyOverwritten()
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, "settings.json");
        await File.WriteAllTextAsync(path, "{ definitely not json }");
        var store = new JsonSettingsStore(path);

        await Assert.ThrowsAsync<SettingsFileException>(() => store.LoadAsync());
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, true);
        }
    }
}

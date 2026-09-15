using Crosio.Windows.Core.Features;

namespace Crosio.Windows.Core.Settings;

public sealed class AppSettings
{
    public const int CurrentSchemaVersion = 1;

    public int SchemaVersion { get; init; } = CurrentSchemaVersion;

    public bool StartWithWindows { get; init; }

    public bool RunInBackground { get; init; } = true;

    public int PreferredSharingPort { get; init; } = 5421;

    public string? CustomShareAccessCode { get; init; }

    public IReadOnlyDictionary<string, HotkeyBinding> Hotkeys { get; init; } = CreateDefaultHotkeys();

    public static AppSettings Default => new();

    public static IReadOnlyDictionary<string, HotkeyBinding> DefaultHotkeys => CreateDefaultHotkeys();

    private static IReadOnlyDictionary<string, HotkeyBinding> CreateDefaultHotkeys() =>
        new Dictionary<string, HotkeyBinding>(StringComparer.OrdinalIgnoreCase)
        {
            [FeatureCatalog.Get(FeatureId.RegionScreenshot).Route] =
                new(HotkeyModifiers.Control | HotkeyModifiers.Shift, "1"),
            [FeatureCatalog.Get(FeatureId.WindowScreenshot).Route] =
                new(HotkeyModifiers.Control | HotkeyModifiers.Shift, "2"),
            [FeatureCatalog.Get(FeatureId.ScreenScreenshot).Route] =
                new(HotkeyModifiers.Control | HotkeyModifiers.Shift, "3"),
        };
}

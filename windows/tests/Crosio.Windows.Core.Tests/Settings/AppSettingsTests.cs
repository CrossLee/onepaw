using Crosio.Windows.Core.Settings;

namespace Crosio.Windows.Core.Tests.Settings;

public sealed class AppSettingsTests
{
    [Fact]
    public void DefaultsMatchExistingCrosioShortcuts()
    {
        var settings = AppSettings.Default;

        Assert.Equal("Ctrl+Shift+1", settings.Hotkeys["capture-region"].ToString());
        Assert.Equal("Ctrl+Shift+2", settings.Hotkeys["capture-window"].ToString());
        Assert.Equal("Ctrl+Shift+3", settings.Hotkeys["capture-screen"].ToString());
        Assert.Empty(AppSettingsValidator.Validate(settings));
    }

    [Fact]
    public void CatalogContainsAllTwelveCommandsAndOnlyThreeAreRequired()
    {
        Assert.Equal(12, HotkeyCommandCatalog.All.Count);
        Assert.Equal(
            ["capture-region", "capture-window", "capture-screen"],
            HotkeyCommandCatalog.All
                .Where(command => command.IsRequired)
                .Select(command => command.Route)
                .ToArray());
        Assert.Equal(3, AppSettings.Default.Hotkeys.Count);
        Assert.Equal("快捷翻译", HotkeyCommandCatalog.All[^1].Title);
    }

    [Fact]
    public void RequiredScreenshotBindingsCannotBeRemoved()
    {
        var settings = new AppSettings
        {
            Hotkeys = AppSettings.Default.Hotkeys
                .Where(pair => pair.Key != "capture-window")
                .ToDictionary(pair => pair.Key, pair => pair.Value),
        };

        var issues = AppSettingsValidator.Validate(settings);

        Assert.Contains(
            issues,
            issue => issue.Field == "hotkeys.capture-window"
                && issue.Code == "required-binding");
    }

    [Fact]
    public void DuplicateShortcutIsRejectedTransactionally()
    {
        var duplicate = new HotkeyBinding(HotkeyModifiers.Control | HotkeyModifiers.Shift, "1");
        var settings = new AppSettings
        {
            Hotkeys = new Dictionary<string, HotkeyBinding>
            {
                ["capture-region"] = duplicate,
                ["capture-window"] = duplicate,
            },
        };

        var issues = AppSettingsValidator.Validate(settings);

        Assert.Contains(issues, issue => issue.Code == "duplicate-binding");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(80)]
    [InlineData(65536)]
    public void UnsafeSharingPortsAreRejected(int port)
    {
        var settings = new AppSettings { PreferredSharingPort = port };

        Assert.Contains(
            AppSettingsValidator.Validate(settings),
            issue => issue.Field == "preferredSharingPort");
    }

    [Theory]
    [InlineData("abc123")]
    [InlineData("Class-2026_A")]
    [InlineData("123456789012345678901234")]
    public void ValidCustomShareAccessCodesAreAccepted(string value)
    {
        var settings = new AppSettings { CustomShareAccessCode = value };

        Assert.DoesNotContain(
            AppSettingsValidator.Validate(settings),
            issue => issue.Field == "customShareAccessCode");
    }

    [Theory]
    [InlineData("12345")]
    [InlineData("1234567890123456789012345")]
    [InlineData("  abc123")]
    [InlineData("课堂2026")]
    [InlineData("abc?123")]
    [InlineData("abc&123")]
    [InlineData("abc#123")]
    public void InvalidCustomShareAccessCodesAreRejected(string value)
    {
        var settings = new AppSettings { CustomShareAccessCode = value };

        Assert.Contains(
            AppSettingsValidator.Validate(settings),
            issue => issue.Field == "customShareAccessCode"
                && issue.Code == "invalid-access-code");
    }
}

namespace Crosio.Windows.Core.Settings;

public sealed record SettingsValidationIssue(string Field, string Code);

public static class AppSettingsValidator
{
    public static IReadOnlyList<SettingsValidationIssue> Validate(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var issues = new List<SettingsValidationIssue>();
        if (settings.SchemaVersion != AppSettings.CurrentSchemaVersion)
        {
            issues.Add(new("schemaVersion", "unsupported-schema"));
        }

        if (settings.PreferredSharingPort is < 1024 or > 65535)
        {
            issues.Add(new("preferredSharingPort", "out-of-range"));
        }

        if (settings.CustomShareAccessCode is { } accessCode && !IsValidShareAccessCode(accessCode))
        {
            issues.Add(new("customShareAccessCode", "invalid-access-code"));
        }

        if (settings.Hotkeys is null)
        {
            issues.Add(new("hotkeys", "missing"));
            return issues;
        }

        foreach (var requiredRoute in HotkeyCommandCatalog.RequiredRoutes)
        {
            if (!settings.Hotkeys.ContainsKey(requiredRoute))
            {
                issues.Add(new($"hotkeys.{requiredRoute}", "required-binding"));
            }
        }

        var occupied = new HashSet<HotkeyBinding>();
        foreach (var (route, binding) in settings.Hotkeys)
        {
            if (string.IsNullOrWhiteSpace(route))
            {
                issues.Add(new("hotkeys", "empty-route"));
                continue;
            }

            if (binding is null || !binding.TryNormalize(out var normalized))
            {
                issues.Add(new($"hotkeys.{route}", "invalid-binding"));
                continue;
            }

            if (!occupied.Add(normalized))
            {
                issues.Add(new($"hotkeys.{route}", "duplicate-binding"));
            }
        }

        return issues;
    }

    private static bool IsValidShareAccessCode(string value)
    {
        if (value.Length is < 6 or > 24 || !string.Equals(value, value.Trim(), StringComparison.Ordinal))
        {
            return false;
        }

        foreach (var character in value)
        {
            if (character is not (>= 'a' and <= 'z')
                and not (>= 'A' and <= 'Z')
                and not (>= '0' and <= '9')
                and not '-' and not '_')
            {
                return false;
            }
        }

        return true;
    }
}

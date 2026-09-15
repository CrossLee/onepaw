using Crosio.Windows.Core.Settings;

namespace Crosio.Windows.Hotkeys;

public enum HotkeySettingsApplyStatus
{
    Applied,
    Invalid,
    RegistrationFailed,
    PersistenceFailed,
}

public sealed record HotkeySettingsApplyResult(
    HotkeySettingsApplyStatus Status,
    string Message,
    IReadOnlyDictionary<string, HotkeyBinding> ActiveBindings)
{
    public bool Succeeded => Status == HotkeySettingsApplyStatus.Applied;
}

/// <summary>
/// Applies the complete configured set as one transaction. Native registration
/// happens first. Persistence happens only after every registration succeeds;
/// if persistence fails, the previous native set is restored as well.
/// </summary>
public sealed class GlobalHotkeySettingsApplier
{
    private readonly IGlobalHotkeyHost _host;
    private readonly ISettingsStore _settingsStore;

    public GlobalHotkeySettingsApplier(
        IGlobalHotkeyHost host,
        ISettingsStore settingsStore)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
    }

    public async Task<HotkeySettingsApplyResult> ApplyAsync(
        IReadOnlyDictionary<string, HotkeyBinding> requestedBindings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(requestedBindings);
        var previousSettings = await _settingsStore
            .LoadAsync(cancellationToken)
            .ConfigureAwait(true);
        var candidate = CopySettings(previousSettings, requestedBindings);
        var issues = AppSettingsValidator.Validate(candidate);
        if (issues.Count > 0)
        {
            return new HotkeySettingsApplyResult(
                HotkeySettingsApplyStatus.Invalid,
                MessageFor(issues[0]),
                _host.ActiveBindings);
        }

        var registration = _host.ReplaceBindings(candidate.Hotkeys);
        if (!registration.Succeeded)
        {
            return new HotkeySettingsApplyResult(
                HotkeySettingsApplyStatus.RegistrationFailed,
                registration.Failure?.Message ?? "全局快捷键注册失败",
                registration.ActiveBindings);
        }

        try
        {
            await _settingsStore.SaveAsync(candidate, cancellationToken).ConfigureAwait(true);
            return new HotkeySettingsApplyResult(
                HotkeySettingsApplyStatus.Applied,
                "快捷键已应用并保存。",
                registration.ActiveBindings);
        }
        catch (Exception error)
        {
            var rollback = _host.ReplaceBindings(previousSettings.Hotkeys);
            var message = rollback.Succeeded
                ? $"快捷键未保存，已恢复原配置：{error.Message}"
                : $"快捷键未保存，且恢复原配置失败：{rollback.Failure?.Message ?? error.Message}";
            return new HotkeySettingsApplyResult(
                HotkeySettingsApplyStatus.PersistenceFailed,
                message,
                rollback.ActiveBindings);
        }
    }

    private static AppSettings CopySettings(
        AppSettings source,
        IReadOnlyDictionary<string, HotkeyBinding> hotkeys) =>
        new()
        {
            SchemaVersion = source.SchemaVersion,
            StartWithWindows = source.StartWithWindows,
            RunInBackground = source.RunInBackground,
            PreferredSharingPort = source.PreferredSharingPort,
            CustomShareAccessCode = source.CustomShareAccessCode,
            Hotkeys = hotkeys.ToDictionary(
                pair => pair.Key,
                pair => pair.Value,
                StringComparer.OrdinalIgnoreCase),
        };

    private static string MessageFor(SettingsValidationIssue issue) => issue.Code switch
    {
        "required-binding" => "区域、窗口和全屏截图必须保留快捷键。",
        "duplicate-binding" => "两个功能不能使用同一个快捷键。",
        "invalid-binding" => "快捷键格式不受支持。",
        _ => "快捷键设置无效。",
    };
}

using Crosio.Windows.Core.Settings;

namespace Crosio.Windows.Hotkeys.Tests;

public sealed class GlobalHotkeySettingsApplierTests
{
    [Fact]
    public async Task PersistsOnlyAfterWholeSetRegisters()
    {
        var events = new List<string>();
        var previous = AppSettings.Default;
        var store = new FakeSettingsStore(previous, events);
        var host = new FakeHost(previous.Hotkeys, events);
        var requested = WithOptional(previous.Hotkeys, "capture-frame", "F8");
        var applier = new GlobalHotkeySettingsApplier(host, store);

        var result = await applier.ApplyAsync(requested);

        Assert.True(result.Succeeded);
        Assert.Equal(["load", "register", "save"], events);
        Assert.Equal("F8", store.Current.Hotkeys["capture-frame"].Key);
    }

    [Fact]
    public async Task RegistrationFailureKeepsOldPersistentAndActiveConfiguration()
    {
        var events = new List<string>();
        var previous = AppSettings.Default;
        var store = new FakeSettingsStore(previous, events);
        var host = new FakeHost(previous.Hotkeys, events) { FailNextRegistration = true };
        var applier = new GlobalHotkeySettingsApplier(host, store);

        var result = await applier.ApplyAsync(
            WithOptional(previous.Hotkeys, "capture-frame", "F8"));

        Assert.Equal(HotkeySettingsApplyStatus.RegistrationFailed, result.Status);
        Assert.Equal(["load", "register"], events);
        Assert.False(store.Current.Hotkeys.ContainsKey("capture-frame"));
        Assert.False(host.ActiveBindings.ContainsKey("capture-frame"));
    }

    [Fact]
    public async Task PersistenceFailureRollsNativeRegistrationBack()
    {
        var events = new List<string>();
        var previous = AppSettings.Default;
        var store = new FakeSettingsStore(previous, events) { FailSave = true };
        var host = new FakeHost(previous.Hotkeys, events);
        var applier = new GlobalHotkeySettingsApplier(host, store);

        var result = await applier.ApplyAsync(
            WithOptional(previous.Hotkeys, "capture-frame", "F8"));

        Assert.Equal(HotkeySettingsApplyStatus.PersistenceFailed, result.Status);
        Assert.Equal(["load", "register", "save", "register"], events);
        Assert.False(host.ActiveBindings.ContainsKey("capture-frame"));
        Assert.False(store.Current.Hotkeys.ContainsKey("capture-frame"));
    }

    [Fact]
    public async Task MissingRequiredBindingIsRejectedBeforeNativeRegistration()
    {
        var events = new List<string>();
        var previous = AppSettings.Default;
        var store = new FakeSettingsStore(previous, events);
        var host = new FakeHost(previous.Hotkeys, events);
        var requested = previous.Hotkeys
            .Where(pair => pair.Key != "capture-region")
            .ToDictionary(pair => pair.Key, pair => pair.Value);
        var applier = new GlobalHotkeySettingsApplier(host, store);

        var result = await applier.ApplyAsync(requested);

        Assert.Equal(HotkeySettingsApplyStatus.Invalid, result.Status);
        Assert.Equal(["load"], events);
    }

    [Fact]
    public async Task ApplyingHotkeysPreservesCustomShareAccessCode()
    {
        var events = new List<string>();
        var previous = new AppSettings { CustomShareAccessCode = "Class-2026_A" };
        var store = new FakeSettingsStore(previous, events);
        var host = new FakeHost(previous.Hotkeys, events);
        var applier = new GlobalHotkeySettingsApplier(host, store);

        var result = await applier.ApplyAsync(
            WithOptional(previous.Hotkeys, "capture-frame", "F8"));

        Assert.True(result.Succeeded);
        Assert.Equal("Class-2026_A", store.Current.CustomShareAccessCode);
    }

    private static IReadOnlyDictionary<string, HotkeyBinding> WithOptional(
        IReadOnlyDictionary<string, HotkeyBinding> source,
        string route,
        string key)
    {
        var result = source.ToDictionary(pair => pair.Key, pair => pair.Value);
        result[route] = new HotkeyBinding(HotkeyModifiers.Control | HotkeyModifiers.Shift, key);
        return result;
    }

    private sealed class FakeHost : IGlobalHotkeyHost
    {
        private readonly List<string> _events;
        private Dictionary<string, HotkeyBinding> _active;

        public FakeHost(IReadOnlyDictionary<string, HotkeyBinding> active, List<string> events)
        {
            _events = events;
            _active = active.ToDictionary(pair => pair.Key, pair => pair.Value);
        }

        public bool FailNextRegistration { get; set; }

        public event EventHandler<GlobalHotkeyPressedEventArgs>? Pressed
        {
            add { }
            remove { }
        }

        public IReadOnlyDictionary<string, HotkeyBinding> ActiveBindings => _active;

        public GlobalHotkeyUpdateResult ReplaceBindings(IReadOnlyDictionary<string, HotkeyBinding> bindings)
        {
            _events.Add("register");
            if (FailNextRegistration)
            {
                FailNextRegistration = false;
                return GlobalHotkeyUpdateResult.Failed(
                    new GlobalHotkeyRegistrationFailure(
                        "capture-frame",
                        new HotkeyBinding(HotkeyModifiers.Control, "F8"),
                        1409,
                        "冲突"),
                    _active);
            }

            _active = bindings.ToDictionary(pair => pair.Key, pair => pair.Value);
            return GlobalHotkeyUpdateResult.Success(_active);
        }

        public void Dispose()
        {
        }
    }

    private sealed class FakeSettingsStore : ISettingsStore
    {
        private readonly List<string> _events;

        public FakeSettingsStore(AppSettings current, List<string> events)
        {
            Current = current;
            _events = events;
        }

        public AppSettings Current { get; private set; }

        public bool FailSave { get; set; }

        public Task<AppSettings> LoadAsync(CancellationToken cancellationToken = default)
        {
            _events.Add("load");
            return Task.FromResult(Current);
        }

        public Task SaveAsync(AppSettings settings, CancellationToken cancellationToken = default)
        {
            _events.Add("save");
            if (FailSave)
            {
                throw new IOException("disk full");
            }

            Current = settings;
            return Task.CompletedTask;
        }
    }
}

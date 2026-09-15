using System.Net;
using System.Net.Http.Json;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Xunit;

namespace Crosio.Windows.Sharing.Tests;

public sealed class LocalSharingServerTests : IAsyncLifetime
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"crosio-server-{Guid.NewGuid():N}");
    private SharedContentStore _store = null!;
    private LocalSharingServer _server = null!;
    private HttpClient _client = null!;

    public async Task InitializeAsync()
    {
        _store = new SharedContentStore(_root);
        var port = FindAvailablePort();
        _server = new LocalSharingServer(
            _store,
            port,
            maximumPortAttempts: 1,
            IPAddress.Loopback,
            sessionToken: "test-token");
        await _server.StartAsync();
        _client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}") };
    }

    [Fact]
    public async Task ApiRejectsMissingTokenAndAcceptsCurrentToken()
    {
        using var denied = await _client.GetAsync("/api/items");
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);

        using var accepted = await _client.GetAsync("/api/items?token=test-token");
        Assert.Equal(HttpStatusCode.OK, accepted.StatusCode);
    }

    [Fact]
    public async Task BrowserTextBecomesVisibleToEveryAuthorizedClient()
    {
        using var posted = await _client.PostAsJsonAsync(
            "/api/text?token=test-token",
            new { text = "同一份公共列表" });
        Assert.Equal(HttpStatusCode.Created, posted.StatusCode);

        using var response = await _client.GetAsync("/api/items?token=test-token");
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        var item = Assert.Single(json.GetProperty("items").EnumerateArray());
        Assert.Equal("同一份公共列表", item.GetProperty("name").GetString());
        Assert.Equal("browser", item.GetProperty("source").GetString());
    }

    [Fact]
    public async Task LandingPageUsesCurrentBrandWithoutChangingTokenAuthentication()
    {
        using var response = await _client.GetAsync("/?token=test-token");
        var html = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("<title>一爪 · 课堂共享区</title>", html, StringComparison.Ordinal);
        Assert.Contains("<span class=\"brand-product\">一爪</span>", html, StringComparison.Ordinal);
        Assert.Contains("由一爪提供", html.Replace(" ", ""), StringComparison.Ordinal);
        Assert.DoesNotContain("Crosio", html, StringComparison.Ordinal);
        Assert.Contains("app.js", html, StringComparison.Ordinal);

        using var script = await _client.GetAsync("/assets/app.js");
        using var stylesheet = await _client.GetAsync("/assets/app.css");
        Assert.Equal(HttpStatusCode.OK, script.StatusCode);
        Assert.Equal(HttpStatusCode.OK, stylesheet.StatusCode);
    }

    [Fact]
    public async Task RuntimeAccessCodeChangeKeepsPortAndContentButExpiresOldLinks()
    {
        var sharedFile = Path.Combine(_root, "lesson.txt");
        await File.WriteAllTextAsync(sharedFile, "lesson");
        var item = _store.AddSharedFile(sharedFile);
        var port = _server.State.Port;

        await _server.UpdateSessionTokenAsync("Class-2026_A");

        Assert.Equal(port, _server.State.Port);
        Assert.Equal("Class-2026_A", _server.SessionToken);
        Assert.True(_server.UsesCustomAccessCode);
        using var oldRoot = await _client.GetAsync("/?token=test-token");
        using var oldList = await _client.GetAsync("/api/items?token=test-token");
        using var oldDownload = await _client.GetAsync($"/download/{item.Id}?token=test-token");
        using var oldText = await _client.PostAsJsonAsync(
            "/api/text?token=test-token",
            new { text = "must not commit" });
        using var oldUploadContent = Multipart([1], "old.bin");
        using var oldUpload = await _client.PostAsync(
            "/api/upload?token=test-token",
            oldUploadContent);
        using var wrongCase = await _client.GetAsync("/api/items?token=class-2026_A");
        using var newRoot = await _client.GetAsync("/?token=Class-2026_A");
        using var newList = await _client.GetAsync("/api/items?token=Class-2026_A");
        using var newDownload = await _client.GetAsync($"/download/{item.Id}?token=Class-2026_A");

        Assert.Equal(HttpStatusCode.Forbidden, oldRoot.StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, oldList.StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, oldDownload.StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, oldText.StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, oldUpload.StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, wrongCase.StatusCode);
        Assert.Equal(HttpStatusCode.OK, newRoot.StatusCode);
        Assert.Equal(HttpStatusCode.OK, newList.StatusCode);
        Assert.Equal(HttpStatusCode.OK, newDownload.StatusCode);
        Assert.Equal("lesson", await newDownload.Content.ReadAsStringAsync());

        var json = await newList.Content.ReadFromJsonAsync<JsonElement>();
        var listed = Assert.Single(json.GetProperty("items").EnumerateArray());
        Assert.Contains(
            "token=Class-2026_A",
            listed.GetProperty("downloadURL").GetString(),
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            "test-token",
            listed.GetProperty("downloadURL").GetString(),
            StringComparison.Ordinal);
        Assert.Single(_store.PublicSnapshot());
    }

    [Fact]
    public async Task StopAndStartKeepsCurrentProcessAccessCode()
    {
        var directory = Path.Combine(_root, "rotating-session");
        await using var server = new LocalSharingServer(
            new SharedContentStore(directory),
            FindAvailablePort(),
            maximumPortAttempts: 2,
            IPAddress.Loopback);

        await server.StartAsync();
        var first = server.SessionToken;
        Assert.Equal(ShareAccessCode.DefaultRandomLength, first.Length);
        await server.StopAsync();
        await server.StartAsync();

        Assert.Equal(first, server.SessionToken);
        Assert.Equal(ShareAccessCode.DefaultRandomLength, server.SessionToken.Length);
    }

    [Fact]
    public async Task CustomAccessCodeSurvivesStopAndStartUntilRandomModeIsRestored()
    {
        var directory = Path.Combine(_root, "custom-session");
        await using var server = new LocalSharingServer(
            new SharedContentStore(directory),
            FindAvailablePort(),
            maximumPortAttempts: 2,
            IPAddress.Loopback);

        await server.UpdateSessionTokenAsync("My_Class-88");
        await server.StartAsync();
        await server.StopAsync();
        await server.StartAsync();

        Assert.Equal("My_Class-88", server.SessionToken);

        await server.ResetSessionTokenAsync();
        var firstRandom = server.SessionToken;
        Assert.False(server.UsesCustomAccessCode);
        await server.StopAsync();
        await server.StartAsync();

        Assert.Equal(firstRandom, server.SessionToken);
    }

    public async Task DisposeAsync()
    {
        _client.Dispose();
        await _server.DisposeAsync();
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    private static int FindAvailablePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static MultipartFormDataContent Multipart(byte[] bytes, string filename)
    {
        var multipart = new MultipartFormDataContent();
        multipart.Add(new ByteArrayContent(bytes), "file", filename);
        return multipart;
    }
}

public sealed class LocalSharingServerLifecycleTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"crosio-lifecycle-{Guid.NewGuid():N}");

    [Fact]
    public async Task AnyStartFailureDisposesTemporaryApplicationAndKeepsPublishedToken()
    {
        var application = new ScriptedApplication
        {
            StartFailure = new InvalidOperationException("startup failed"),
        };
        var factory = new QueueApplicationFactory(application);
        var server = CreateServer(factory);
        var publishedToken = server.SessionToken;

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => server.StartAsync());

        Assert.Equal("startup failed", error.Message);
        Assert.Equal(1, application.StartCount);
        Assert.Equal(0, application.StopCount);
        Assert.Equal(1, application.DisposeCount);
        Assert.Equal(publishedToken, server.SessionToken);
        Assert.Equal(SharingServerStatus.Failed, server.State.Status);
        await server.DisposeAsync();
    }

    [Fact]
    public async Task FailedStartCleanupIsRetainedAndCanBeRetriedBeforeRestart()
    {
        var failed = new ScriptedApplication
        {
            StartFailure = new IOException("bind failed"),
        };
        failed.DisposeFailures.Enqueue(new IOException("dispose failed"));
        var replacement = new ScriptedApplication();
        var factory = new QueueApplicationFactory(failed, replacement);
        var server = CreateServer(factory);
        var publishedToken = server.SessionToken;

        await Assert.ThrowsAsync<AggregateException>(() => server.StartAsync());

        Assert.Equal(SharingServerStatus.Failed, server.State.Status);
        Assert.Equal(publishedToken, server.SessionToken);
        Assert.Equal(1, failed.DisposeCount);
        await Assert.ThrowsAsync<InvalidOperationException>(() => server.StartAsync());

        await server.StopAsync();
        Assert.Equal(2, failed.DisposeCount);
        Assert.Equal(SharingServerStatus.Stopped, server.State.Status);

        await server.StartAsync();
        Assert.Equal(1, replacement.StartCount);
        Assert.Equal(publishedToken, server.SessionToken);
        await server.DisposeAsync();
    }

    [Fact]
    public async Task StopFailureKeepsListenerReferenceAndRetryCompletesCleanup()
    {
        var application = new ScriptedApplication();
        application.StopFailures.Enqueue(new IOException("stop failed"));
        var server = CreateServer(new QueueApplicationFactory(application));
        await server.StartAsync();

        await Assert.ThrowsAsync<IOException>(() => server.StopAsync());

        Assert.Equal(SharingServerStatus.Failed, server.State.Status);
        Assert.NotNull(server.State.Port);
        Assert.Equal(0, application.DisposeCount);
        await Assert.ThrowsAsync<InvalidOperationException>(() => server.StartAsync());

        await server.StopAsync();
        Assert.Equal(2, application.StopCount);
        Assert.Equal(1, application.DisposeCount);
        Assert.Equal(SharingServerStatus.Stopped, server.State.Status);
        await server.DisposeAsync();
    }

    [Fact]
    public async Task DisposeFailureDoesNotRepeatSuccessfulStopAndCanBeRetried()
    {
        var application = new ScriptedApplication();
        application.DisposeFailures.Enqueue(new IOException("dispose failed"));
        var server = CreateServer(new QueueApplicationFactory(application));
        await server.StartAsync();

        await Assert.ThrowsAsync<IOException>(() => server.StopAsync());

        Assert.Equal(SharingServerStatus.Failed, server.State.Status);
        Assert.Equal(1, application.StopCount);
        Assert.Equal(1, application.DisposeCount);

        await server.StopAsync();
        Assert.Equal(1, application.StopCount);
        Assert.Equal(2, application.DisposeCount);
        Assert.Equal(SharingServerStatus.Stopped, server.State.Status);
        await server.DisposeAsync();
    }

    [Fact]
    public async Task ConcurrentStartsAndStopsUseOneApplicationLifecycle()
    {
        var enteredStart = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseStart = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var application = new ScriptedApplication
        {
            StartAction = async cancellationToken =>
            {
                enteredStart.SetResult();
                await releaseStart.Task.WaitAsync(cancellationToken);
            },
        };
        var factory = new QueueApplicationFactory(application);
        var server = CreateServer(factory);

        var firstStart = server.StartAsync();
        await enteredStart.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var secondStart = server.StartAsync();
        releaseStart.SetResult();
        await Task.WhenAll(firstStart, secondStart);

        Assert.Equal(1, factory.CreateCount);
        Assert.Equal(1, application.StartCount);

        await Task.WhenAll(server.StopAsync(), server.StopAsync());
        Assert.Equal(1, application.StopCount);
        Assert.Equal(1, application.DisposeCount);
        await server.DisposeAsync();
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    private LocalSharingServer CreateServer(ILocalSharingApplicationFactory factory) =>
        new(
            new SharedContentStore(_root),
            preferredPort: 5421,
            maximumPortAttempts: 2,
            listenAddress: IPAddress.Loopback,
            sessionToken: null,
            applicationFactory: factory);

    private sealed class QueueApplicationFactory(params ScriptedApplication[] applications)
        : ILocalSharingApplicationFactory
    {
        private readonly Queue<ScriptedApplication> _applications = new(applications);

        public int CreateCount { get; private set; }

        public ILocalSharingApplication Create(int port, string sessionToken)
        {
            CreateCount++;
            return _applications.Dequeue();
        }
    }

    private sealed class ScriptedApplication : ILocalSharingApplication
    {
        public Exception? StartFailure { get; init; }
        public Func<CancellationToken, Task>? StartAction { get; init; }
        public Queue<Exception> StopFailures { get; } = [];
        public Queue<Exception> DisposeFailures { get; } = [];
        public int StartCount { get; private set; }
        public int StopCount { get; private set; }
        public int DisposeCount { get; private set; }

        public async Task StartAsync(CancellationToken cancellationToken)
        {
            StartCount++;
            if (StartFailure is not null)
            {
                throw StartFailure;
            }
            if (StartAction is not null)
            {
                await StartAction(cancellationToken);
            }
        }

        public Task StopAsync(CancellationToken cancellationToken)
        {
            StopCount++;
            if (StopFailures.TryDequeue(out var error))
            {
                return Task.FromException(error);
            }
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            DisposeCount++;
            if (DisposeFailures.TryDequeue(out var error))
            {
                return ValueTask.FromException(error);
            }
            return ValueTask.CompletedTask;
        }
    }
}

public sealed class LocalSharingServerCapacityTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"crosio-capacity-{Guid.NewGuid():N}");

    [Fact]
    public async Task IncomingTextQuotaMapsToInsufficientStorage()
    {
        var store = CreateStore(maximumInboxBytes: 100, maximumIncomingTextBytes: 5);
        await using var server = CreateServer(store);
        await server.StartAsync();
        using var client = ClientFor(server);

        using var accepted = await client.PostAsJsonAsync("/api/text?token=test-token", new { text = "1234" });
        using var rejected = await client.PostAsJsonAsync("/api/text?token=test-token", new { text = "56" });

        Assert.Equal(HttpStatusCode.Created, accepted.StatusCode);
        Assert.Equal(HttpStatusCode.InsufficientStorage, rejected.StatusCode);
    }

    [Fact]
    public async Task InboxQuotaAndEmptyUploadHaveExplicitHttpStatuses()
    {
        var store = CreateStore(maximumInboxBytes: 5);
        await using var server = CreateServer(store);
        await server.StartAsync();
        using var client = ClientFor(server);

        using var firstContent = Multipart(new byte[4], "first.bin");
        using var accepted = await client.PostAsync("/api/upload?token=test-token", firstContent);
        using var quotaContent = Multipart(new byte[2], "second.bin");
        using var quotaRejected = await client.PostAsync("/api/upload?token=test-token", quotaContent);
        using var emptyContent = Multipart([], "empty.bin");
        using var emptyRejected = await client.PostAsync("/api/upload?token=test-token", emptyContent);

        Assert.Equal(HttpStatusCode.Created, accepted.StatusCode);
        Assert.Equal(HttpStatusCode.InsufficientStorage, quotaRejected.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, emptyRejected.StatusCode);
    }

    [Fact]
    public async Task UploadGateSerializesReadFormAndStoreProcessing()
    {
        var observer = new ConcurrentUploadObserver();
        var store = CreateStore(maximumInboxBytes: 100);
        await using var server = CreateServer(store, observer);
        await server.StartAsync();
        using var client = ClientFor(server);
        using var slowContent = new BlockingMultipartContent("slow.bin");

        var firstRequest = client.PostAsync("/api/upload?token=test-token", slowContent);
        await observer.FirstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var secondRequest = client.PostAsync(
            "/api/upload?token=test-token",
            Multipart([2], "second.bin"));

        var earlySecond = await Task.WhenAny(
            observer.SecondEntered.Task,
            Task.Delay(TimeSpan.FromMilliseconds(200)));
        Assert.NotSame(observer.SecondEntered.Task, earlySecond);

        slowContent.Release.SetResult();
        using var firstResponse = await firstRequest;
        using var secondResponse = await secondRequest;

        Assert.Equal(HttpStatusCode.Created, firstResponse.StatusCode);
        Assert.Equal(HttpStatusCode.Created, secondResponse.StatusCode);
        Assert.Equal(2, observer.EnterCount);
        Assert.Equal(1, observer.MaximumActive);
    }

    [Fact]
    public async Task UploadThatCrossesAccessCodeChangeDoesNotCommitAndCleansTemporaryFile()
    {
        var observer = new ConcurrentUploadObserver();
        var store = CreateStore(maximumInboxBytes: 100);
        await using var server = CreateServer(store, observer);
        await server.StartAsync();
        using var client = ClientFor(server);
        using var slowContent = new BlockingMultipartContent("expired.bin");

        var request = client.PostAsync("/api/upload?token=test-token", slowContent);
        await observer.FirstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await server.UpdateSessionTokenAsync("New-Code_2");
        slowContent.Release.SetResult();
        using var response = await request;

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        Assert.Empty(store.PublicSnapshot());
        Assert.Empty(Directory.EnumerateFileSystemEntries(store.InboxDirectory));
    }

    [Fact]
    public async Task SavingUnchangedAccessCodeDoesNotInvalidateUploadInProgress()
    {
        var observer = new ConcurrentUploadObserver();
        var store = CreateStore(maximumInboxBytes: 100);
        await using var server = CreateServer(store, observer);
        await server.StartAsync();
        using var client = ClientFor(server);
        using var slowContent = new BlockingMultipartContent("same-code.bin");

        var request = client.PostAsync("/api/upload?token=test-token", slowContent);
        await observer.FirstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await server.UpdateSessionTokenAsync("test-token");
        slowContent.Release.SetResult();
        using var response = await request;

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Single(store.PublicSnapshot());
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    private SharedContentStore CreateStore(
        long maximumInboxBytes,
        long maximumIncomingTextBytes = SharedContentStore.MaximumIncomingTextBytes) =>
        new(
            _root,
            new SharedContentStoreOptions(
                MaximumUploadBytes: 100,
                MaximumInboxBytes: maximumInboxBytes,
                MinimumFreeDiskBytes: 0,
                MaximumIncomingItems: 10,
                MaximumIncomingTextBytes: maximumIncomingTextBytes),
            new FixedDiskSpaceProbe());

    private static LocalSharingServer CreateServer(
        SharedContentStore store,
        IUploadProcessingObserver? observer = null) =>
        new(
            store,
            FindAvailablePort(),
            maximumPortAttempts: 1,
            listenAddress: IPAddress.Loopback,
            sessionToken: "test-token",
            applicationFactory: null,
            uploadObserver: observer);

    private static HttpClient ClientFor(LocalSharingServer server) =>
        new() { BaseAddress = new Uri($"http://127.0.0.1:{server.State.Port}") };

    private static MultipartFormDataContent Multipart(byte[] bytes, string filename)
    {
        var multipart = new MultipartFormDataContent();
        multipart.Add(new ByteArrayContent(bytes), "file", filename);
        return multipart;
    }

    private static int FindAvailablePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private sealed class FixedDiskSpaceProbe : IInboxDiskSpaceProbe
    {
        public long AvailableFreeBytes(string path) => long.MaxValue;
    }

    private sealed class ConcurrentUploadObserver : IUploadProcessingObserver
    {
        private int _active;
        private int _enterCount;
        private int _maximumActive;

        public TaskCompletionSource FirstEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource SecondEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int EnterCount => Volatile.Read(ref _enterCount);
        public int MaximumActive => Volatile.Read(ref _maximumActive);

        public void Enter()
        {
            var count = Interlocked.Increment(ref _enterCount);
            var active = Interlocked.Increment(ref _active);
            InterlockedExtensions.Max(ref _maximumActive, active);
            if (count == 1)
            {
                FirstEntered.TrySetResult();
            }
            else if (count == 2)
            {
                SecondEntered.TrySetResult();
            }
        }

        public void Exit() => Interlocked.Decrement(ref _active);
    }

    private sealed class BlockingMultipartContent : HttpContent
    {
        private readonly string _boundary = $"crosio-{Guid.NewGuid():N}";
        private readonly string _filename;

        public BlockingMultipartContent(string filename)
        {
            _filename = filename;
            Headers.ContentType = new MediaTypeHeaderValue("multipart/form-data");
            Headers.ContentType.Parameters.Add(new NameValueHeaderValue("boundary", _boundary));
        }

        public TaskCompletionSource Release { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        protected override async Task SerializeToStreamAsync(
            Stream stream,
            TransportContext? context)
        {
            var prefix = Encoding.UTF8.GetBytes(
                $"--{_boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{_filename}\"\r\n" +
                "Content-Type: application/octet-stream\r\n\r\n1");
            await stream.WriteAsync(prefix);
            await stream.FlushAsync();
            await Release.Task;
            var suffix = Encoding.UTF8.GetBytes($"\r\n--{_boundary}--\r\n");
            await stream.WriteAsync(suffix);
        }

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }

    private static class InterlockedExtensions
    {
        public static void Max(ref int target, int value)
        {
            var current = Volatile.Read(ref target);
            while (current < value)
            {
                var observed = Interlocked.CompareExchange(ref target, value, current);
                if (observed == current)
                {
                    return;
                }
                current = observed;
            }
        }
    }
}

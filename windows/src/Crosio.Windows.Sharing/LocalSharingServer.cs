using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace Crosio.Windows.Sharing;

public enum SharingServerStatus
{
    Stopped,
    Starting,
    Running,
    Failed,
}

public sealed record SharingServerState(SharingServerStatus Status, int? Port, string? Error);

public sealed class LocalSharingServer : IAsyncDisposable
{
    private const long MaximumRequestBytes = SharedContentStore.MaximumUploadBytes + 2 * 1024 * 1024;
    // JSON may represent one UTF-8 byte as a six-byte \\uXXXX escape. Keep the
    // transport bounded while allowing every valid 64 KB text payload.
    private const long MaximumTextRequestBytes = SharedContentStore.MaximumTextBytes * 6L + 1024;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _uploadGate = new(1, 1);
    private readonly object _credentialConfigurationGate = new();
    private readonly SharedContentStore _store;
    private readonly IPAddress _listenAddress;
    private readonly ILocalSharingApplicationFactory? _applicationFactory;
    private readonly IUploadProcessingObserver? _uploadObserver;
    private CredentialAuthority _credentialAuthority;
    private string _sessionToken;
    private bool _usesCustomAccessCode;
    private ApplicationLease? _application;
    private bool _disposeRequested;
    private bool _disposed;

    public LocalSharingServer(
        SharedContentStore store,
        int preferredPort = 5421,
        int maximumPortAttempts = 10,
        IPAddress? listenAddress = null,
        string? sessionToken = null)
        : this(
            store,
            preferredPort,
            maximumPortAttempts,
            listenAddress,
            sessionToken,
            applicationFactory: null,
            uploadObserver: null)
    {
    }

    internal LocalSharingServer(
        SharedContentStore store,
        int preferredPort,
        int maximumPortAttempts,
        IPAddress? listenAddress,
        string? sessionToken,
        ILocalSharingApplicationFactory? applicationFactory,
        IUploadProcessingObserver? uploadObserver = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        if (preferredPort is < IPEndPoint.MinPort or > IPEndPoint.MaxPort)
        {
            throw new ArgumentOutOfRangeException(nameof(preferredPort));
        }

        PreferredPort = preferredPort;
        MaximumPortAttempts = Math.Max(1, maximumPortAttempts);
        _listenAddress = listenAddress ?? IPAddress.Any;
        _usesCustomAccessCode = sessionToken is not null;
        _sessionToken = sessionToken is null
            ? ShareAccessCode.CreateRandom()
            : ShareAccessCode.NormalizeCustom(sessionToken);
        _credentialAuthority = new CredentialAuthority(_sessionToken);
        _applicationFactory = applicationFactory;
        _uploadObserver = uploadObserver;
    }

    public int PreferredPort { get; }
    public int MaximumPortAttempts { get; }
    public string SessionToken
    {
        get
        {
            lock (_credentialConfigurationGate)
            {
                return _sessionToken;
            }
        }
    }

    public bool UsesCustomAccessCode
    {
        get
        {
            lock (_credentialConfigurationGate)
            {
                return _usesCustomAccessCode;
            }
        }
    }
    public SharingServerState State { get; private set; } = new(SharingServerStatus.Stopped, null, null);

    public event EventHandler<SharingServerState>? StateChanged;

    public IReadOnlyList<Uri> SharingUris
    {
        get
        {
            var state = State;
            if (state is not { Status: SharingServerStatus.Running, Port: { } port })
            {
                return [];
            }

            var token = SessionToken;
            return LocalNetworkAddresses.GetUsableIPv4Addresses()
                .Select(address => new Uri($"http://{address}:{port}/?token={Uri.EscapeDataString(token)}"))
                .ToArray();
        }
    }

    public Task UpdateSessionTokenAsync(
        string sessionToken,
        CancellationToken cancellationToken = default) =>
        SetSessionTokenAsync(
            ShareAccessCode.NormalizeCustom(sessionToken),
            usesCustomAccessCode: true,
            cancellationToken);

    public Task ResetSessionTokenAsync(CancellationToken cancellationToken = default) =>
        SetSessionTokenAsync(
            ShareAccessCode.CreateRandom(),
            usesCustomAccessCode: false,
            cancellationToken);

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed || _disposeRequested, this);
            if (_application is not null)
            {
                if (State.Status == SharingServerStatus.Running)
                {
                    return;
                }

                throw new InvalidOperationException("共享服务仍有未完成的清理，请先重试停止服务");
            }

            string candidateToken;
            lock (_credentialConfigurationGate)
            {
                candidateToken = _sessionToken;
            }
            var candidateAuthority = new CredentialAuthority(candidateToken);
            UpdateState(new SharingServerState(SharingServerStatus.Starting, null, null));
            Exception? lastError = null;
            for (var attempt = 0; attempt < MaximumPortAttempts; attempt++)
            {
                var port = PreferredPort + attempt;
                if (port > IPEndPoint.MaxPort)
                {
                    break;
                }

                ILocalSharingApplication application;
                try
                {
                    application = _applicationFactory?.Create(port, candidateToken)
                        ?? BuildApplication(port);
                }
                catch (Exception error)
                {
                    UpdateState(new SharingServerState(SharingServerStatus.Failed, port, error.Message));
                    throw;
                }

                var lease = new ApplicationLease(application, port);
                try
                {
                    if (application is WebApplicationAdapter webApplication)
                    {
                        ConfigureRoutes(webApplication.Application, candidateAuthority);
                    }
                    await application.StartAsync(cancellationToken).ConfigureAwait(false);
                }
                catch (Exception startError)
                {
                    try
                    {
                        await lease.CleanupAsync(CancellationToken.None).ConfigureAwait(false);
                    }
                    catch (Exception cleanupError)
                    {
                        _application = lease;
                        var cleanupMessage = $"共享服务启动失败且清理未完成：{cleanupError.Message}";
                        UpdateState(new SharingServerState(SharingServerStatus.Failed, port, cleanupMessage));
                        throw new AggregateException(cleanupMessage, startError, cleanupError);
                    }

                    if (startError is IOException)
                    {
                        lastError = startError;
                        continue;
                    }

                    UpdateState(new SharingServerState(
                        SharingServerStatus.Failed,
                        port,
                        startError.Message));
                    throw;
                }

                lease.MarkStarted();
                _application = lease;
                lock (_credentialConfigurationGate)
                {
                    _sessionToken = candidateToken;
                    _credentialAuthority = candidateAuthority;
                }
                UpdateState(new SharingServerState(SharingServerStatus.Running, port, null));
                return;
            }

            var message = lastError?.Message ?? "没有可用的局域网端口";
            UpdateState(new SharingServerState(SharingServerStatus.Failed, null, message));
            throw new InvalidOperationException(message, lastError);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            await StopCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            _disposeRequested = true;
            await StopCoreAsync(CancellationToken.None).ConfigureAwait(false);
            _disposed = true;
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private async Task StopCoreAsync(CancellationToken cancellationToken)
    {
        var application = _application;
        if (application is null)
        {
            UpdateState(new SharingServerState(SharingServerStatus.Stopped, null, null));
            return;
        }

        try
        {
            await application.CleanupAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            UpdateState(new SharingServerState(
                SharingServerStatus.Failed,
                application.Port,
                $"共享服务停止或清理失败：{error.Message}"));
            throw;
        }

        _application = null;
        UpdateState(new SharingServerState(SharingServerStatus.Stopped, null, null));
    }

    private async Task SetSessionTokenAsync(
        string sessionToken,
        bool usesCustomAccessCode,
        CancellationToken cancellationToken)
    {
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed || _disposeRequested, this);
            lock (_credentialConfigurationGate)
            {
                if (!string.Equals(_sessionToken, sessionToken, StringComparison.Ordinal))
                {
                    _credentialAuthority.Update(sessionToken);
                    _sessionToken = sessionToken;
                }
                _usesCustomAccessCode = usesCustomAccessCode;
            }

            StateChanged?.Invoke(this, State);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private ILocalSharingApplication BuildApplication(int port)
    {
        var options = new WebApplicationOptions
        {
            ApplicationName = typeof(LocalSharingServer).Assembly.FullName,
            ContentRootPath = AppContext.BaseDirectory,
        };
        var builder = WebApplication.CreateSlimBuilder(options);
        builder.WebHost.ConfigureKestrel(server =>
        {
            server.Listen(_listenAddress, port);
            server.Limits.MaxRequestBodySize = MaximumRequestBytes;
            server.Limits.MaxRequestHeadersTotalSize = 64 * 1024;
        });
        builder.Services.Configure<FormOptions>(options =>
        {
            options.MultipartBodyLengthLimit = MaximumRequestBytes;
            options.ValueLengthLimit = 64 * 1024;
        });

        return new WebApplicationAdapter(builder.Build());
    }

    private void ConfigureRoutes(WebApplication application, CredentialAuthority credentialAuthority)
    {
        var assets = new WebAssets();

        application.Use(async (context, next) =>
        {
            context.Response.Headers["Cache-Control"] = "no-store";
            context.Response.Headers["X-Content-Type-Options"] = "nosniff";
            context.Response.Headers["Referrer-Policy"] = "no-referrer";
            context.Response.Headers["X-Frame-Options"] = "DENY";
            await next(context).ConfigureAwait(false);
        });

        application.MapGet("/app.css", () => EmbeddedAsset(assets, "app.css", "text/css; charset=utf-8"));
        application.MapGet("/app.js", () => EmbeddedAsset(assets, "app.js", "text/javascript; charset=utf-8"));
        application.MapGet("/assets/app.css", () => EmbeddedAsset(assets, "app.css", "text/css; charset=utf-8"));
        application.MapGet("/assets/app.js", () => EmbeddedAsset(assets, "app.js", "text/javascript; charset=utf-8"));
        application.MapGet("/", async (HttpContext context, CancellationToken cancellationToken) =>
        {
            if (!TryAuthorize(context.Request, credentialAuthority, out _))
            {
                return Results.Content(UnauthorizedHtml, "text/html; charset=utf-8", Encoding.UTF8, 403);
            }
            var html = await assets.ReadTextAsync("index.html", cancellationToken).ConfigureAwait(false);
            context.Response.Headers["Content-Security-Policy"] =
                "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; " +
                "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
            return Results.Content(html, "text/html; charset=utf-8", Encoding.UTF8);
        });

        application.MapGet("/api/health", (HttpRequest request) =>
            TryAuthorize(request, credentialAuthority, out _)
                ? Results.Json(new { ok = true })
                : UnauthorizedJson());

        application.MapGet("/api/items", (HttpRequest request) =>
        {
            if (!TryAuthorize(request, credentialAuthority, out var credential))
            {
                return UnauthorizedJson();
            }

            var encodedToken = Uri.EscapeDataString(credential.Token);
            var items = _store.PublicSnapshot().Select(item => new
            {
                id = item.Id,
                kind = item.Kind.ToString().ToLowerInvariant(),
                name = item.Title,
                detail = item.Detail,
                size = item.ByteCount,
                mimeType = item.MimeType,
                source = item.Direction == SharedItemDirection.Outgoing ? "teacher" : "browser",
                downloadURL = item.FilePath is null ? null : $"/download/{item.Id}?token={encodedToken}",
                createdAt = item.CreatedAt,
            });
            return Results.Json(new { items });
        });

        application.MapPost("/api/text", async (HttpRequest request, CancellationToken cancellationToken) =>
        {
            if (!TryAuthorize(request, credentialAuthority, out var credential))
            {
                return UnauthorizedJson();
            }
            if (request.ContentLength is > MaximumTextRequestBytes)
            {
                return ErrorJson("文字内容过长", 413);
            }

            var bodySizeFeature = request.HttpContext.Features.Get<IHttpMaxRequestBodySizeFeature>();
            if (bodySizeFeature is { IsReadOnly: false })
            {
                bodySizeFeature.MaxRequestBodySize = MaximumTextRequestBytes;
            }

            try
            {
                var payload = await request.ReadFromJsonAsync<TextRequest>(cancellationToken: cancellationToken)
                    .ConfigureAwait(false);
                var item = await _store.ReceiveTextAsync(
                    payload?.Text ?? string.Empty,
                    request.HttpContext.Connection.RemoteIpAddress?.ToString(),
                    commit => credentialAuthority.TryCommit(credential, commit),
                    cancellationToken).ConfigureAwait(false);
                return Results.Json(new { ok = true, id = item.Id, name = item.Title }, statusCode: 201);
            }
            catch (SharedContentException error)
            {
                return ErrorJson(error.Message, StatusCodeFor(error));
            }
            catch (System.Text.Json.JsonException)
            {
                return ErrorJson("文字请求格式不正确", 400);
            }
            catch (BadHttpRequestException error) when (error.StatusCode == 413)
            {
                return ErrorJson("文字内容过长", 413);
            }
            catch (SharingAccessExpiredException)
            {
                return UnauthorizedJson();
            }
        });

        application.MapPost("/api/upload", async (HttpRequest request, CancellationToken cancellationToken) =>
        {
            if (!TryAuthorize(request, credentialAuthority, out var credential))
            {
                return UnauthorizedJson();
            }
            if (!request.HasFormContentType)
            {
                return ErrorJson("没有找到可上传的文件", 400);
            }

            await _uploadGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            var observerEntered = false;
            try
            {
                _uploadObserver?.Enter();
                observerEntered = _uploadObserver is not null;
                var form = await request.ReadFormAsync(cancellationToken).ConfigureAwait(false);
                var file = form.Files.GetFile("file") ?? form.Files.FirstOrDefault();
                if (file is null)
                {
                    return ErrorJson("没有找到可上传的文件", 400);
                }

                await using var input = file.OpenReadStream();
                var item = await _store.ReceiveFileAsync(
                    input,
                    file.FileName,
                    file.Length,
                    request.HttpContext.Connection.RemoteIpAddress?.ToString(),
                    commit => credentialAuthority.TryCommit(credential, commit),
                    cancellationToken).ConfigureAwait(false);
                return Results.Json(new { ok = true, id = item.Id, name = item.Title }, statusCode: 201);
            }
            catch (SharedContentException error)
            {
                return ErrorJson(error.Message, StatusCodeFor(error));
            }
            catch (InvalidDataException)
            {
                return ErrorJson("上传请求格式不正确", 400);
            }
            catch (SharingAccessExpiredException)
            {
                return UnauthorizedJson();
            }
            finally
            {
                try
                {
                    if (observerEntered)
                    {
                        _uploadObserver!.Exit();
                    }
                }
                finally
                {
                    _uploadGate.Release();
                }
            }
        });

        application.MapGet("/download/{id:guid}", (HttpRequest request, Guid id) =>
        {
            if (!TryAuthorize(request, credentialAuthority, out var credential))
            {
                return UnauthorizedJson();
            }
            var item = _store.PublicItem(id);
            if (item?.FilePath is null || !File.Exists(item.FilePath))
            {
                return ErrorJson("文件不存在或已经取消分享", 404);
            }

            if (!credentialAuthority.IsCurrent(credential))
            {
                return UnauthorizedJson();
            }

            return Results.File(
                item.FilePath,
                item.MimeType,
                item.Title,
                enableRangeProcessing: true);
        });

    }

    private static IResult EmbeddedAsset(WebAssets assets, string name, string contentType) =>
        Results.Stream(assets.Open(name), contentType);

    private static bool TryAuthorize(
        HttpRequest request,
        CredentialAuthority credentialAuthority,
        out Credential credential)
    {
        credential = credentialAuthority.Snapshot();
        var candidate = request.Query["token"].FirstOrDefault()
            ?? request.Headers["X-Crosstool-Token"].FirstOrDefault();
        if (candidate is null)
        {
            return false;
        }

        var candidateBytes = Encoding.UTF8.GetBytes(candidate);
        var tokenBytes = Encoding.UTF8.GetBytes(credential.Token);
        return candidateBytes.Length == tokenBytes.Length &&
            CryptographicOperations.FixedTimeEquals(candidateBytes, tokenBytes);
    }

    private static IResult UnauthorizedJson() => ErrorJson("无效或已过期的共享链接", 403);

    private static int StatusCodeFor(SharedContentException error) => error.Code switch
    {
        SharedContentErrorCode.ItemTooLarge => StatusCodes.Status413PayloadTooLarge,
        SharedContentErrorCode.InboxQuotaExceeded or
            SharedContentErrorCode.InsufficientDiskSpace or
            SharedContentErrorCode.IncomingItemLimitExceeded or
            SharedContentErrorCode.IncomingTextQuotaExceeded =>
            StatusCodes.Status507InsufficientStorage,
        _ => StatusCodes.Status400BadRequest,
    };

    private static IResult ErrorJson(string error, int statusCode) =>
        Results.Json(new { ok = false, error }, statusCode: statusCode);

    private void UpdateState(SharingServerState state)
    {
        State = state;
        StateChanged?.Invoke(this, state);
    }

    private sealed class ApplicationLease(ILocalSharingApplication application, int port)
    {
        private bool _started;
        private bool _stopCompleted;
        private bool _disposeCompleted;

        public int Port { get; } = port;

        public void MarkStarted() => _started = true;

        public async Task CleanupAsync(CancellationToken cancellationToken)
        {
            if (_started && !_stopCompleted)
            {
                await application.StopAsync(cancellationToken).ConfigureAwait(false);
                _stopCompleted = true;
            }

            if (!_disposeCompleted)
            {
                await application.DisposeAsync().ConfigureAwait(false);
                _disposeCompleted = true;
            }
        }
    }

    private sealed class WebApplicationAdapter(WebApplication application) : ILocalSharingApplication
    {
        public WebApplication Application => application;

        public Task StartAsync(CancellationToken cancellationToken) =>
            application.StartAsync(cancellationToken);

        public Task StopAsync(CancellationToken cancellationToken) =>
            application.StopAsync(cancellationToken);

        public ValueTask DisposeAsync() => application.DisposeAsync();
    }

    private sealed record TextRequest(string Text);

    private sealed record Credential(string Token, long Generation);

    private sealed class CredentialAuthority
    {
        private readonly object _gate = new();
        private Credential _credential;

        public CredentialAuthority(string token)
        {
            _credential = new Credential(token, 0);
        }

        public Credential Snapshot() => Volatile.Read(ref _credential);

        public bool IsCurrent(Credential expected) =>
            ReferenceEquals(Snapshot(), expected);

        public void Update(string token)
        {
            lock (_gate)
            {
                _credential = new Credential(token, checked(_credential.Generation + 1));
            }
        }

        public bool TryCommit(Credential expected, Action commit)
        {
            ArgumentNullException.ThrowIfNull(commit);
            lock (_gate)
            {
                if (!ReferenceEquals(_credential, expected))
                {
                    return false;
                }

                commit();
                return true;
            }
        }
    }

    private const string UnauthorizedHtml = """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>共享链接无效</title><style>body{font-family:Segoe UI,sans-serif;background:#f7f7f9;color:#202127;display:grid;place-items:center;height:100vh;margin:0}.card{background:white;border:1px solid #e5e5ea;border-radius:18px;padding:36px;max-width:420px;box-shadow:0 12px 30px rgba(0,0,0,.06)}h1{font-size:22px}p{color:#6d6e78;line-height:1.6}</style><div class="card"><h1>共享链接无效</h1><p>请向分享者获取当前完整链接，然后重新打开。</p></div></html>
        """;
}

internal interface ILocalSharingApplication : IAsyncDisposable
{
    Task StartAsync(CancellationToken cancellationToken);

    Task StopAsync(CancellationToken cancellationToken);
}

internal interface ILocalSharingApplicationFactory
{
    ILocalSharingApplication Create(int port, string sessionToken);
}

internal interface IUploadProcessingObserver
{
    void Enter();

    void Exit();
}

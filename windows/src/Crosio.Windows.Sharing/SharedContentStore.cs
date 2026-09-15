namespace Crosio.Windows.Sharing;

public sealed class SharedContentStore
{
    public const long MaximumUploadBytes = 256L * 1024 * 1024;
    public const long MaximumInboxBytes = 1024L * 1024 * 1024;
    public const long MinimumFreeDiskBytes = 512L * 1024 * 1024;
    public const int MaximumIncomingItems = 4096;
    public const long MaximumIncomingTextBytes = 16L * 1024 * 1024;
    public const int MaximumTextBytes = 64 * 1024;

    private readonly object _gate = new();
    private readonly List<SharedItem> _outgoingItems = [];
    private readonly List<SharedItem> _incomingItems = [];
    private readonly HashSet<Guid> _hiddenIncomingItemIds = [];
    private readonly SemaphoreSlim _inboxIoGate = new(1, 1);
    private readonly SharedContentStoreOptions _options;
    private readonly IInboxDiskSpaceProbe _diskSpaceProbe;

    public SharedContentStore(string inboxDirectory)
        : this(inboxDirectory, new SharedContentStoreOptions(), new DriveInfoInboxDiskSpaceProbe())
    {
    }

    internal SharedContentStore(
        string inboxDirectory,
        SharedContentStoreOptions options,
        IInboxDiskSpaceProbe diskSpaceProbe)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(inboxDirectory);
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _options.Validate();
        _diskSpaceProbe = diskSpaceProbe ?? throw new ArgumentNullException(nameof(diskSpaceProbe));
        InboxDirectory = Path.GetFullPath(inboxDirectory);
        Directory.CreateDirectory(InboxDirectory);
        EnsureSafeInboxDirectory();
    }

    public string InboxDirectory { get; }

    public event EventHandler? Changed;

    public SharedItem AddSharedFile(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var info = new FileInfo(fullPath);
        if (!info.Exists || info.Attributes.HasFlag(FileAttributes.Directory) ||
            info.Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw new SharedContentException("只能分享普通文件");
        }

        var item = new SharedItem(
            Guid.NewGuid(),
            MimeTypes.KindForFile(fullPath),
            SharedItemDirection.Outgoing,
            info.Name,
            null,
            fullPath,
            info.Length,
            MimeTypes.ForFile(fullPath),
            DateTimeOffset.UtcNow,
            null);

        Mutate(() => _outgoingItems.Insert(0, item));
        return item;
    }

    public SharedItem AddSharedText(string text)
    {
        var cleaned = RequireText(text);
        var item = CreateTextItem(cleaned, SharedItemDirection.Outgoing, null);
        Mutate(() => _outgoingItems.Insert(0, item));
        return item;
    }

    public SharedItem ReceiveText(string text, string? remoteAddress) =>
        ReceiveTextAsync(text, remoteAddress).ConfigureAwait(false).GetAwaiter().GetResult();

    public async Task<SharedItem> ReceiveTextAsync(
        string text,
        string? remoteAddress,
        CancellationToken cancellationToken = default)
        => await ReceiveTextAsync(text, remoteAddress, tryCommit: null, cancellationToken)
            .ConfigureAwait(false);

    internal async Task<SharedItem> ReceiveTextAsync(
        string text,
        string? remoteAddress,
        Func<Action, bool>? tryCommit,
        CancellationToken cancellationToken = default)
    {
        var cleaned = RequireText(text);
        var item = CreateTextItem(cleaned, SharedItemDirection.Incoming, remoteAddress);
        await _inboxIoGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            void Commit()
            {
                lock (_gate)
                {
                    EnsureIncomingCapacityLocked(item.ByteCount ?? 0, isText: true);
                    _hiddenIncomingItemIds.Remove(item.Id);
                    _incomingItems.Insert(0, item);
                }
            }

            if (tryCommit is null)
            {
                Commit();
            }
            else if (!tryCommit(Commit))
            {
                throw new SharingAccessExpiredException();
            }
        }
        finally
        {
            _inboxIoGate.Release();
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return item;
    }

    public async Task<SharedItem> ReceiveFileAsync(
        Stream source,
        string filename,
        long? declaredLength,
        string? remoteAddress,
        CancellationToken cancellationToken = default)
        => await ReceiveFileAsync(
                source,
                filename,
                declaredLength,
                remoteAddress,
                tryCommit: null,
                cancellationToken)
            .ConfigureAwait(false);

    internal async Task<SharedItem> ReceiveFileAsync(
        Stream source,
        string filename,
        long? declaredLength,
        string? remoteAddress,
        Func<Action, bool>? tryCommit,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (declaredLength is <= 0)
        {
            throw new SharedContentException("不能接收空文件");
        }

        await _inboxIoGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        string? temporaryPath = null;
        SharedItem? receivedItem = null;
        try
        {
            EnsureSafeInboxDirectory();
            lock (_gate)
            {
                EnsureIncomingCapacityLocked(0, isText: false);
            }
            var budget = CreateReceiveBudget(declaredLength);
            var safeName = FilenameSanitizer.Sanitize(filename);
            var destination = UniqueDestinationPath(safeName);
            temporaryPath = Path.Combine(InboxDirectory, $".{Guid.NewGuid():N}.upload-part");

            long copiedBytes;
            await using (var output = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             bufferSize: 128 * 1024,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                copiedBytes = await CopyWithBudgetAsync(
                    source,
                    output,
                    budget,
                    cancellationToken).ConfigureAwait(false);
                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            if (copiedBytes == 0)
            {
                throw new SharedContentException("不能接收空文件");
            }

            receivedItem = new SharedItem(
                Guid.NewGuid(),
                MimeTypes.KindForFile(destination),
                SharedItemDirection.Incoming,
                Path.GetFileName(destination),
                null,
                destination,
                copiedBytes,
                MimeTypes.ForFile(destination),
                DateTimeOffset.UtcNow,
                remoteAddress);
            var stagedPath = temporaryPath
                ?? throw new InvalidOperationException("上传暂存文件尚未创建");
            var itemToCommit = receivedItem
                ?? throw new InvalidOperationException("接收文件条目尚未创建");

            void Commit()
            {
                EnsureSafeInboxDirectory();
                EnsureImmediateInboxChild(destination);
                File.Move(stagedPath, destination);
                temporaryPath = null;
                lock (_gate)
                {
                    _hiddenIncomingItemIds.Remove(itemToCommit.Id);
                    _incomingItems.Insert(0, itemToCommit);
                }
            }

            if (tryCommit is null)
            {
                Commit();
            }
            else if (!tryCommit(Commit))
            {
                throw new SharingAccessExpiredException();
            }
        }
        finally
        {
            if (temporaryPath is not null)
            {
                try
                {
                    File.Delete(temporaryPath);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                }
            }
            _inboxIoGate.Release();
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return receivedItem ?? throw new InvalidOperationException("接收文件未生成共享条目");
    }

    public IReadOnlyList<SharedItem> PublicSnapshot()
    {
        lock (_gate)
        {
            return _outgoingItems
                .Concat(_incomingItems.Where(item => !_hiddenIncomingItemIds.Contains(item.Id)))
                .OrderByDescending(item => item.CreatedAt)
                .ToArray();
        }
    }

    public SharedItem? PublicItem(Guid id)
    {
        lock (_gate)
        {
            return _outgoingItems.FirstOrDefault(item => item.Id == id)
                ?? _incomingItems.FirstOrDefault(item =>
                    item.Id == id && !_hiddenIncomingItemIds.Contains(item.Id));
        }
    }

    public void RemoveOutgoing(Guid id) =>
        Mutate(() => _outgoingItems.RemoveAll(item => item.Id == id));

    public void HideIncomingFromPublic(Guid id) =>
        Mutate(() =>
        {
            if (_incomingItems.Any(item => item.Id == id))
            {
                _hiddenIncomingItemIds.Add(id);
            }
        });

    public void ClearPublicItems() =>
        ClearPublicItemsAsync().ConfigureAwait(false).GetAwaiter().GetResult();

    public Task ClearPublicItemsAsync(CancellationToken cancellationToken = default) =>
        ClearCoreAsync(clearOutgoing: true, cancellationToken);

    public void ClearInbox() =>
        ClearInboxAsync().ConfigureAwait(false).GetAwaiter().GetResult();

    public Task ClearInboxAsync(CancellationToken cancellationToken = default) =>
        ClearCoreAsync(clearOutgoing: false, cancellationToken);

    private async Task ClearCoreAsync(bool clearOutgoing, CancellationToken cancellationToken)
    {
        await _inboxIoGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureSafeInboxDirectory();
            foreach (var path in Directory.EnumerateFileSystemEntries(
                         InboxDirectory,
                         "*",
                         SearchOption.TopDirectoryOnly))
            {
                cancellationToken.ThrowIfCancellationRequested();
                EnsureSafeInboxDirectory();
                EnsureImmediateInboxChild(path);
                var attributes = File.GetAttributes(path);
                if (attributes.HasFlag(FileAttributes.ReparsePoint))
                {
                    if (attributes.HasFlag(FileAttributes.Directory))
                    {
                        Directory.Delete(path, recursive: false);
                    }
                    else
                    {
                        File.Delete(path);
                    }
                }
                else if (!attributes.HasFlag(FileAttributes.Directory))
                {
                    File.Delete(path);
                }
            }

            lock (_gate)
            {
                if (clearOutgoing)
                {
                    _outgoingItems.Clear();
                }
                _incomingItems.Clear();
                _hiddenIncomingItemIds.Clear();
            }
        }
        finally
        {
            _inboxIoGate.Release();
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void EnsureIncomingCapacityLocked(long additionalTextBytes, bool isText)
    {
        if (_incomingItems.Count >= _options.MaximumIncomingItems)
        {
            throw new SharedContentException(
                "收件箱条目数量已达上限，请先清理后再接收",
                SharedContentErrorCode.IncomingItemLimitExceeded);
        }
        if (!isText)
        {
            return;
        }

        long currentTextBytes = 0;
        foreach (var item in _incomingItems)
        {
            if (item.Kind == SharedItemKind.Text)
            {
                currentTextBytes = checked(currentTextBytes + (item.ByteCount ?? 0));
            }
        }
        if (currentTextBytes >= _options.MaximumIncomingTextBytes ||
            additionalTextBytes > _options.MaximumIncomingTextBytes - currentTextBytes)
        {
            throw new SharedContentException(
                "收件箱文字总量已达上限，请先清理后再接收",
                SharedContentErrorCode.IncomingTextQuotaExceeded);
        }
    }

    private ReceiveBudget CreateReceiveBudget(long? declaredLength)
    {
        if (declaredLength > _options.MaximumUploadBytes)
        {
            throw new SharedContentException(
                "文件超过当前版本的 256 MB 上传限制",
                SharedContentErrorCode.ItemTooLarge);
        }

        var currentBytes = InboxUsageBytes();
        var quotaBytes = currentBytes >= _options.MaximumInboxBytes
            ? 0
            : _options.MaximumInboxBytes - currentBytes;
        long availableBytes;
        try
        {
            availableBytes = _diskSpaceProbe.AvailableFreeBytes(InboxDirectory);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new SharedContentException(
                "无法确认收件箱磁盘剩余空间",
                SharedContentErrorCode.InsufficientDiskSpace,
                error);
        }
        var diskBytes = availableBytes > _options.MinimumFreeDiskBytes
            ? availableBytes - _options.MinimumFreeDiskBytes
            : 0;

        if (declaredLength is { } requestedBytes)
        {
            EnsureWithinReceiveBudget(requestedBytes, quotaBytes, diskBytes);
        }
        return new ReceiveBudget(_options.MaximumUploadBytes, quotaBytes, diskBytes);
    }

    private static void EnsureWithinReceiveBudget(long bytes, long quotaBytes, long diskBytes)
    {
        if (bytes > quotaBytes)
        {
            throw new SharedContentException(
                "收件箱已达到总容量限制，请先清理后再接收",
                SharedContentErrorCode.InboxQuotaExceeded);
        }
        if (bytes > diskBytes)
        {
            throw new SharedContentException(
                "磁盘剩余空间不足，需保留安全空间",
                SharedContentErrorCode.InsufficientDiskSpace);
        }
    }

    private static async Task<long> CopyWithBudgetAsync(
        Stream source,
        Stream destination,
        ReceiveBudget budget,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[128 * 1024];
        long total = 0;
        while (true)
        {
            var count = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0)
            {
                return total;
            }

            total = checked(total + count);
            if (total > budget.MaximumUploadBytes)
            {
                throw new SharedContentException(
                    "文件超过当前版本的 256 MB 上传限制",
                    SharedContentErrorCode.ItemTooLarge);
            }
            EnsureWithinReceiveBudget(total, budget.QuotaBytes, budget.DiskBytes);

            await destination.WriteAsync(buffer.AsMemory(0, count), cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private long InboxUsageBytes()
    {
        long total = 0;
        foreach (var path in Directory.EnumerateFileSystemEntries(
                     InboxDirectory,
                     "*",
                     SearchOption.TopDirectoryOnly))
        {
            EnsureImmediateInboxChild(path);
            var attributes = File.GetAttributes(path);
            if (attributes.HasFlag(FileAttributes.Directory) ||
                attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                continue;
            }

            try
            {
                total = checked(total + new FileInfo(path).Length);
            }
            catch (OverflowException error)
            {
                throw new SharedContentException(
                    "收件箱已达到总容量限制，请先清理后再接收",
                    SharedContentErrorCode.InboxQuotaExceeded,
                    error);
            }
        }
        return total;
    }

    private string UniqueDestinationPath(string safeName)
    {
        var original = Path.Combine(InboxDirectory, safeName);
        EnsureImmediateInboxChild(original);
        if (!File.Exists(original) && !Directory.Exists(original))
        {
            return original;
        }

        var extension = Path.GetExtension(safeName);
        var stem = Path.GetFileNameWithoutExtension(safeName);
        for (var index = 2; index <= 9_999; index++)
        {
            var candidate = Path.Combine(InboxDirectory, $"{stem} {index}{extension}");
            EnsureImmediateInboxChild(candidate);
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
        }

        var fallback = Path.Combine(InboxDirectory, $"{Guid.NewGuid():N}-{safeName}");
        EnsureImmediateInboxChild(fallback);
        return fallback;
    }

    private void EnsureSafeInboxDirectory()
    {
        var directory = new DirectoryInfo(InboxDirectory);
        directory.Refresh();
        if (!directory.Exists ||
            directory.Attributes.HasFlag(FileAttributes.ReparsePoint) ||
            directory.LinkTarget is not null)
        {
            throw new SharedContentException(
                "收件箱目录不安全，已拒绝访问",
                SharedContentErrorCode.UnsafeInboxEntry);
        }
    }

    private void EnsureImmediateInboxChild(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var parent = Path.GetDirectoryName(fullPath);
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        if (parent is null || !string.Equals(
                Path.TrimEndingDirectorySeparator(parent),
                Path.TrimEndingDirectorySeparator(InboxDirectory),
                comparison))
        {
            throw new SharedContentException(
                "收件箱条目越界，已拒绝访问",
                SharedContentErrorCode.UnsafeInboxEntry);
        }
    }

    private static string RequireText(string text)
    {
        var cleaned = (text ?? string.Empty).Trim();
        if (cleaned.Length == 0)
        {
            throw new SharedContentException("文字内容不能为空");
        }
        if (System.Text.Encoding.UTF8.GetByteCount(cleaned) > MaximumTextBytes)
        {
            throw new SharedContentException(
                "文字内容超过 64 KB 限制",
                SharedContentErrorCode.ItemTooLarge);
        }
        return cleaned;
    }

    private static SharedItem CreateTextItem(
        string text,
        SharedItemDirection direction,
        string? remoteAddress) =>
        new(
            Guid.NewGuid(),
            SharedItemKind.Text,
            direction,
            text.Length > 48 ? string.Concat(text.AsSpan(0, 48), "…") : text,
            text,
            null,
            System.Text.Encoding.UTF8.GetByteCount(text),
            "text/plain; charset=utf-8",
            DateTimeOffset.UtcNow,
            remoteAddress);

    private void Mutate(Action action)
    {
        lock (_gate)
        {
            action();
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private sealed record ReceiveBudget(long MaximumUploadBytes, long QuotaBytes, long DiskBytes);
}

internal sealed class SharingAccessExpiredException : Exception
{
}

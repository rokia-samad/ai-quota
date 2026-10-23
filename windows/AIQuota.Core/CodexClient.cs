using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace AIQuota.Core;

public sealed class CodexException(string message) : IOException(message);

// One connection per instance, serialized requests; a failed connection is disposed and the
// next refresh creates a new instance. No process output or raw RPC errors leave this class.
public sealed class CodexClient : IAsyncDisposable
{
    private readonly ProcessStartInfo start;
    private readonly TimeSpan timeout;
    private readonly SemaphoreSlim serial = new(1);
    private readonly SemaphoreSlim writes = new(1);
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> pending = new();
    private readonly CancellationTokenSource lifetime = new();
    private Process? process;
    private Task? pump, stderr;
    private int nextId;
    private int failed;
    private int readRequestId;
    private bool ready;
    public DateTimeOffset ReadReceivedAt { get; private set; }
    public event Action<Quotas>? Updated;
    public event Action? Disconnected;

    public CodexClient(ProcessStartInfo start, TimeSpan? timeout = null)
    { this.start = start; this.timeout = timeout ?? TimeSpan.FromSeconds(20); }

    public async Task<Quotas> ReadAsync(CancellationToken cancellation = default)
    {
        await serial.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            if (!ready)
            {
                if (lifetime.IsCancellationRequested) throw new CodexException("Connexion Codex fermée.");
                process = Process.Start(start) ?? throw new CodexException("Démarrage Codex impossible.");
                stderr = DrainErrorsAsync(process.StandardError, lifetime.Token);
                pump = PumpAsync(process.StandardOutput, lifetime.Token);
                await RequestAsync("initialize", new { clientInfo = new { name = "ai_quota_windows", title = "AI Quota", version = "1.0" } }, cancellation).ConfigureAwait(false);
                await SendAsync(new { method = "initialized", @params = new { } }, cancellation).ConfigureAwait(false);
                ready = true;
            }
            var result = await RequestAsync("account/rateLimits/read", new { }, cancellation).ConfigureAwait(false);
            return QuotaJson.Codex(result, ReadReceivedAt) ?? new();
        }
        catch { Fail(); throw; }
        finally { serial.Release(); }
    }

    private static async Task DrainErrorsAsync(StreamReader reader, CancellationToken token)
    {
        var buffer = new char[2048];
        try { while (await reader.ReadAsync(buffer, token).ConfigureAwait(false) != 0) { } }
        catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
    }

    private async Task<JsonElement> RequestAsync(string method, object parameters, CancellationToken cancellation)
    {
        var id = Interlocked.Increment(ref nextId);
        if (method == "account/rateLimits/read") readRequestId = id;
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = completion;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        deadline.CancelAfter(timeout);
        try
        {
            await SendAsync(new { id, method, @params = parameters }, deadline.Token).ConfigureAwait(false);
            return await completion.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new CodexException("Service Codex interrompu ou délai dépassé. Actualise pour reconnecter."); }
        finally { pending.TryRemove(id, out _); }
    }

    private async Task SendAsync(object message, CancellationToken cancellation)
    {
        await writes.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            if (process == null || process.HasExited) throw new CodexException("Processus Codex arrêté.");
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(message).AsMemory(), cancellation).ConfigureAwait(false);
            await process.StandardInput.FlushAsync(cancellation).ConfigureAwait(false);
        }
        finally { writes.Release(); }
    }

    private async Task PumpAsync(StreamReader reader, CancellationToken cancellation)
    {
        try
        {
            // Bounded framing, also handles JSON fragmented across pipe reads.
            var buffer = new char[4096];
            var line = new StringBuilder();
            int count;
            while ((count = await reader.ReadAsync(buffer, cancellation).ConfigureAwait(false)) != 0)
                for (var i = 0; i < count; i++)
                {
                    if (buffer[i] != '\n')
                    {
                        if (line.Length >= 1024 * 1024) throw new IOException("Message Codex trop volumineux.");
                        line.Append(buffer[i]); continue;
                    }
                    var json = line.ToString(); line.Clear();
                    JsonDocument document;
                    try { document = JsonDocument.Parse(json); } catch (JsonException) { continue; }
                    using (document)
                    {
                        var root = document.RootElement;
                        if (root.ValueKind != JsonValueKind.Object) continue;
                        var method = root.Property("method");
                        var id = root.Property("id");
                        if (method.ValueKind == JsonValueKind.String && id.ValueKind != JsonValueKind.Undefined)
                            await SendAsync(new { id = id.Clone(), error = new { code = -32601, message = "Method not supported" } }, cancellation).ConfigureAwait(false);
                        else if (id.ValueKind == JsonValueKind.Number && id.TryGetInt32(out var number) && pending.TryRemove(number, out var completion))
                        {
                            if (root.TryGetProperty("result", out var result))
                            {
                                if (number == readRequestId) ReadReceivedAt = DateTimeOffset.UtcNow;
                                completion.TrySetResult(result.Clone());
                            }
                            else completion.TrySetException(new CodexException("Échec RPC Codex. Vérifie la connexion du CLI (codex login)."));
                        }
                        else if (method.ValueKind == JsonValueKind.String && method.GetString() == "account/rateLimits/updated")
                        {
                            if (QuotaJson.Codex(root.Property("params"), DateTimeOffset.UtcNow) is { } update) Updated?.Invoke(update);
                        }
                    }
                }
        }
        catch (Exception e) when (e is IOException or InvalidDataException or OperationCanceledException or ObjectDisposedException or JsonException or InvalidOperationException) { }
        finally { Fail(); }
    }

    private void Fail()
    {
        if (Interlocked.Exchange(ref failed, 1) != 0) return;
        lifetime.Cancel();
        foreach (var request in pending.Values) request.TrySetException(new CodexException("Pipe Codex fermé ou processus interrompu."));
        pending.Clear();
        try { if (process is { HasExited: false }) process.Kill(true); } catch (InvalidOperationException) { }
        Disconnected?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        Fail();
        if (pump != null) await pump.ConfigureAwait(false);
        if (stderr != null) await stderr.ConfigureAwait(false);
        process?.Dispose();
        lifetime.Dispose();
    }
}

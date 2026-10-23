using System.Diagnostics;
using System.Text;
using System.Text.Json;
using AIQuota.Core;
using Xunit;

namespace AIQuota.Tests;

public class QuotaTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1700000000);
    private static Quotas? Parse(string json) { using var d = JsonDocument.Parse(json); return QuotaJson.Codex(d.RootElement, Now); }
    private static string Payload(string used, string duration = "300", string reset = "1900000000") =>
        $$$$$$"""{"rateLimits":{"primary":{"usedPercent":{{{{{{used}}}}}},"windowDurationMins":{{{{{{duration}}}}}},"resetsAt":{{{{{{reset}}}}}}}}}""";
    [Theory]
    [InlineData("current.json", 24, 4)]
    [InlineData("legacy.json", 0, 100)]
    public void SharedSwiftFixtures(string file, double five, double seven)
    {
        var q = Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", file)))!;
        Assert.Equal(five, q.FiveHour!.Used); Assert.Equal(seven, q.SevenDay!.Used);
    }
    [Theory]
    [InlineData("0", 0)] [InlineData("100", 100)] [InlineData("23.5", 23.5)]
    public void ValidPercent(string raw, double expected) => Assert.Equal(expected, Parse(Payload(raw))!.FiveHour!.Used);
    [Theory]
    [InlineData("-1")] [InlineData("101")] [InlineData("true")] [InlineData("null")] [InlineData("\"50\"")]
    public void RejectInvalidPercent(string raw) => Assert.Null(Parse(Payload(raw))!.FiveHour);
    [Theory]
    [InlineData("60")] [InlineData("null")] [InlineData("\"300\"")]
    public void UnknownDurationNotRelabelled(string raw) => Assert.Null(Parse(Payload("10", raw))!.FiveHour);
    [Theory]
    [InlineData("null")] [InlineData("-1")] [InlineData("true")] [InlineData("253402300800")] [InlineData("\"tomorrow\"")]
    public void InvalidResetDoesNotInventDate(string raw)
    { var q = Parse(Payload("0", reset: raw))!; Assert.Equal(0, q.FiveHour!.Used); Assert.Null(q.FiveHour.Reset); }
    [Fact] public void ValidReset() => Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1900000000), Parse(Payload("10"))!.FiveHour!.Reset);
    [Fact] public void UnknownBucketNeverFallsBack() => Assert.Null(Parse("{\"rateLimitsByLimitId\":{\"other\":{}},\"rateLimits\":{}}"));
    [Fact] public void RejectWrongLegacyBucket() => Assert.Null(Parse("{\"rateLimits\":{\"limitId\":\"other\"}}"));
    [Fact] public void RejectConflictingBucket() => Assert.Null(Parse("{\"rateLimitsByLimitId\":{\"codex\":{\"limitId\":\"other\"}}}"));
    [Theory] [InlineData("{}")] [InlineData("[]")] [InlineData("{\"rateLimitsByLimitId\":false}")]
    public void InvalidEnvelope(string raw) => Assert.Throws<InvalidDataException>(() => Parse(raw));
    [Fact] public void PartialUpdateRetainsOriginalTimestamp()
    {
        var old = new QuotaWindow(10, Now.AddMinutes(-20));
        var merged = new Quotas(old, old).Merge(new(new(20, Now)));
        Assert.Equal(20, merged.FiveHour!.Used); Assert.Same(old, merged.SevenDay);
        Assert.False(merged.SevenDay!.Fresh(Now, TimeSpan.FromMinutes(5)));
    }
    [Theory] [InlineData(0, true)] [InlineData(299, true)] [InlineData(300, false)] [InlineData(-1, false)]
    public void Freshness(int seconds, bool expected) => Assert.Equal(expected, new QuotaWindow(0, Now).Fresh(Now.AddSeconds(seconds), TimeSpan.FromMinutes(5)));
    [Fact] public void ResetPassingExpiresUsage()
    { var w = new QuotaWindow(80, Now, Now.AddSeconds(10)); Assert.False(w.Fresh(Now.AddSeconds(10), TimeSpan.FromMinutes(5))); }
    [Theory] [InlineData("codex.exe")] [InlineData("codex.cmd")] [InlineData("codex.bat")]
    public void DiscoveryUsesPathDirectory(string filename)
    {
        var dir = Path.Combine(Path.GetTempPath(), "space directory");
        Assert.Equal(Path.Combine(dir, filename), CodexDiscovery.FromDirectories(new[] { dir }, p => p == Path.Combine(dir, filename))!.Path);
    }
    [Fact] public void DiscoveryHonorsDirectoryOrder()
    { var q = CodexDiscovery.FromDirectories(new[] { "C:\\first", "C:\\second" }, _ => true); Assert.Equal("C:\\first\\codex.exe", q!.Path); }
    [Fact] public void MissingCliReturnsNull() => Assert.Null(CodexDiscovery.FromDirectories(new[] { "C:\\missing" }, _ => false));
    [Fact] public void CmdShimQuotesSpaces()
    { var s = new CodexCommand("C:\\space dir\\codex.cmd").StartInfo(); Assert.Equal("/d /s /c \"\"C:\\space dir\\codex.cmd\" app-server\"", s.Arguments); }
    [Fact] public void ExeLaunchUsesArgumentList() => Assert.Equal(new[] { "app-server" }, new CodexCommand("C:\\codex.exe").StartInfo().ArgumentList);
    [Fact] public void AlertDeduplicatesAndNewResetAlerts()
    {
        var p = new Preferences { AlertThreshold = 20 };
        var w = new QuotaWindow(90, Now, Now.AddHours(1));
        Assert.True(QuotaAlerts.ShouldAlert(p, "codex5", w, Now, TimeSpan.FromMinutes(5)));
        Assert.False(QuotaAlerts.ShouldAlert(p, "codex5", w, Now, TimeSpan.FromMinutes(5)));
        Assert.True(QuotaAlerts.ShouldAlert(p, "codex5", w with { Reset = Now.AddHours(6) }, Now, TimeSpan.FromMinutes(5)));
    }
    [Fact] public void NoAlertsForStaleMissingDisabledOrThresholdBoundary()
    {
        var p = new Preferences { AlertThreshold = 20 };
        Assert.False(QuotaAlerts.ShouldAlert(p, "a", null, Now, TimeSpan.FromMinutes(5)));
        Assert.False(QuotaAlerts.ShouldAlert(p, "a", new(90, Now.AddHours(-1)), Now, TimeSpan.FromMinutes(5)));
        Assert.False(QuotaAlerts.ShouldAlert(p, "a", new(80, Now), Now, TimeSpan.FromMinutes(5)));
        p.AlertThreshold = 0;
        Assert.False(QuotaAlerts.ShouldAlert(p, "a", new(100, Now), Now, TimeSpan.FromMinutes(5)));
    }
    [Fact] public void KnownWindowNotAlertedAgainAfterRecoveryAndPreferencesRoundtrip()
    {
        var p = new Preferences { AlertThreshold = 20 };
        var low = new QuotaWindow(95, Now, Now.AddHours(1));
        Assert.True(QuotaAlerts.ShouldAlert(p, "codex", low, Now, TimeSpan.FromMinutes(5)));
        Assert.False(QuotaAlerts.ShouldAlert(p, "codex", low with { Used = 10 }, Now, TimeSpan.FromMinutes(5)));
        var restored = JsonSerializer.Deserialize<Preferences>(JsonSerializer.Serialize(p))!;
        Assert.False(QuotaAlerts.ShouldAlert(restored, "codex", low, Now, TimeSpan.FromMinutes(5)));
    }
    [Fact] public void UnknownResetCanAlertAgainAfterRecovery()
    {
        var p = new Preferences { AlertThreshold = 20 };
        Assert.True(QuotaAlerts.ShouldAlert(p, "codex", new(95, Now), Now, TimeSpan.FromMinutes(5)));
        Assert.False(QuotaAlerts.ShouldAlert(p, "codex", new(10, Now), Now, TimeSpan.FromMinutes(5)));
        Assert.True(QuotaAlerts.ShouldAlert(p, "codex", new(95, Now), Now, TimeSpan.FromMinutes(5)));
    }

    internal static CodexClient Client(string scenario, int milliseconds = 4000)
    {
        var dotnet = Path.GetFullPath(Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", "..", "dotnet.exe"));
        var start = new ProcessStartInfo(dotnet) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "fake", "AIQuota.FakeServer.dll")); start.ArgumentList.Add(scenario);
        return new(start, TimeSpan.FromMilliseconds(milliseconds));
    }
    [Theory] [InlineData("normal")] [InlineData("server-request")]
    public async Task HandshakeAndReadRealPipes(string scenario)
    { await using var c = Client(scenario); var q = await c.ReadAsync(); Assert.Equal(24, q.FiveHour!.Used); Assert.Equal(4, q.SevenDay!.Used); }
    [Fact] public async Task PartialResponseKeepsMissingWindowUnavailable()
    { await using var c = Client("partial"); var q = await c.ReadAsync(); Assert.NotNull(q.FiveHour); Assert.Null(q.SevenDay); }
    [Fact] public async Task PartialNotificationAndWrongBucket()
    {
        await using var c = Client("notification");
        var update = new TaskCompletionSource<Quotas>(TaskCreationOptions.RunContinuationsAsynchronously);
        var count = 0; c.Updated += q => { Interlocked.Increment(ref count); update.TrySetResult(q); };
        var read = await c.ReadAsync(); var changed = await update.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, count); Assert.Equal(80, changed.FiveHour!.Used); Assert.Null(changed.SevenDay);
        Assert.Equal(4, read.Merge(changed).SevenDay!.Used);
    }
    [Theory] [InlineData("exit")] [InlineData("timeout")] [InlineData("pipe")] [InlineData("stdin")] [InlineData("rpc")]
    public async Task ProcessFailuresAreBoundedAndSanitized(string scenario)
    {
        await using var c = Client(scenario, 800); var watch = Stopwatch.StartNew();
        var e = await Assert.ThrowsAnyAsync<IOException>(() => c.ReadAsync());
        Assert.DoesNotContain("SECRET", e.Message); Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
    }
    [Fact] public async Task InvalidPayloadIsRejected()
    { await using var c = Client("invalid-envelope"); await Assert.ThrowsAsync<InvalidDataException>(() => c.ReadAsync()); }
    [Theory] [InlineData("exit-after-read")] [InlineData("invalid-notification")]
    public async Task DisconnectAfterReadIsReported(string scenario)
    {
        await using var c = Client(scenario); var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        c.Disconnected += () => ended.TrySetResult(); await c.ReadAsync(); await ended.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }
    [Fact] public async Task ReconnectUsingNewConnectionAfterFailure()
    { await using (var bad = Client("exit")) { await Assert.ThrowsAnyAsync<IOException>(() => bad.ReadAsync()); } await using var good = Client("normal"); Assert.NotNull((await good.ReadAsync()).FiveHour); }
    [Fact] public async Task ConcurrentReadsShareHandshake()
    { await using var c = Client("normal"); var result = await Task.WhenAll(c.ReadAsync(), c.ReadAsync()); Assert.All(result, q => Assert.Equal(24, q.FiveHour!.Used)); }
    [Fact] public async Task NpmCmdShimLaunchesThroughRealCmdWithSpacesAndMetacharacters()
    {
        var dir = Path.Combine(Path.GetTempPath(), "aiquota O'Brien & space " + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            var dotnet = Path.GetFullPath(Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", "..", "dotnet.exe"));
            var dll = Path.Combine(AppContext.BaseDirectory, "fake", "AIQuota.FakeServer.dll");
            var shim = Path.Combine(dir, "codex.cmd");
            File.WriteAllText(shim, $"@\"{dotnet}\" \"{dll}\" %*\r\n");
            await using var c = new CodexClient(new CodexCommand(shim).StartInfo(), TimeSpan.FromSeconds(5));
            Assert.Equal(24, (await c.ReadAsync()).FiveHour!.Used);
        }
        finally { Directory.Delete(dir, true); }
    }
}

using System.Text;
using System.Text.Json;
using AIQuota.Core;
using Xunit;

namespace AIQuota.Tests;

public sealed class ClaudeTests : IDisposable
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1700000000);
    private readonly string dir = Path.Combine(Path.GetTempPath(), "aiquota-tests-" + Guid.NewGuid());
    private string Cache => Path.Combine(dir, "cache.json");
    private static string Input(string used = "0", string reset = "1700001000") => $$$$$$"""{"rate_limits":{"five_hour":{"used_percentage":{{{{{{used}}}}}},"resets_at":{{{{{{reset}}}}}}},"seven_day":{"used_percentage":100}}}""";
    [Fact] public void CaptureOnlyQuotaDataAndRead()
    {
        var q = ClaudeBridge.Capture(Input().Replace("{\"rate_limits\"", "{\"session_id\":\"SECRET\",\"rate_limits\""), null, Now);
        LocalData.Save(Cache, q); var text = File.ReadAllText(Cache);
        Assert.DoesNotContain("SECRET", text); var read = ClaudeBridge.Read(Cache, Now)!;
        Assert.Equal(0, read.Quotas.FiveHour!.Used); Assert.Equal(100, read.Quotas.SevenDay!.Used);
        Assert.Equal(Now.AddSeconds(1000), read.Quotas.FiveHour.VisibleReset(Now, ClaudeBridge.MaxAge));
    }
    [Theory] [InlineData("-1")] [InlineData("101")] [InlineData("true")] [InlineData("null")] [InlineData("\"50\"")]
    public void RejectInvalidUsage(string used) => Assert.Null(ClaudeBridge.Capture(Input(used), null, Now).Quotas.FiveHour!.Used);
    [Theory] [InlineData("-1")] [InlineData("1700000000")] [InlineData("true")] [InlineData("null")] [InlineData("253402300800")]
    public void RejectInvalidReset(string reset) => Assert.Null(ClaudeBridge.Capture(Input(reset: reset), null, Now).Quotas.FiveHour!.Reset);
    [Fact] public void MissingUsageClearsPercentAndKeepsResets()
    {
        var old = ClaudeBridge.Capture(Input("90", "1700000100"), null, Now);
        var next = ClaudeBridge.Capture("{}", old, Now.AddSeconds(200));
        Assert.Null(next.Quotas.FiveHour!.Used); Assert.Equal(Now.AddSeconds(100), next.Quotas.FiveHour.Reset);
        Assert.Equal(Now, next.Quotas.FiveHour.ResetObserved);
    }
    [Fact] public void SupersededPassedResetPreserved()
    {
        var old = ClaudeBridge.Capture(Input("90", "1700000100"), null, Now);
        var next = ClaudeBridge.Capture(Input("10", "1700018100"), old, Now.AddSeconds(200));
        Assert.Equal(Now.AddSeconds(100), next.Quotas.FiveHour!.PreviousReset);
    }
    [Theory] [InlineData("bad")] [InlineData("[]")] [InlineData("{\"rate_limits\":false}")]
    public void InvalidInputClearsUsageAndReportsError(string json)
    {
        var old = ClaudeBridge.Capture(Input(), null, Now);
        var next = ClaudeBridge.Capture(json, old, Now.AddSeconds(1)); Assert.True(next.Invalid); Assert.Null(next.Quotas.FiveHour!.Used);
        LocalData.Save(Cache, next); Assert.Throws<InvalidDataException>(() => ClaudeBridge.Read(Cache, Now.AddSeconds(2)));
    }
    [Fact] public void StaleClaudeHiddenAndResetExpires()
    {
        var w = ClaudeBridge.Capture(Input(), null, Now).Quotas.FiveHour!;
        Assert.False(w.Fresh(Now.AddMinutes(16), ClaudeBridge.MaxAge));
        Assert.Null(w.VisibleReset(Now.AddMinutes(16), ClaudeBridge.MaxAge));
    }
    [Fact] public void MissingCacheIsUnavailable() => Assert.Null(ClaudeBridge.Read(Cache, Now));
    [Fact] public void InvalidInputResetsSurviveTheFollowingCapture()
    {
        var previous = ClaudeBridge.Capture(Input(), null, Now);
        LocalData.Save(Cache, ClaudeBridge.Capture("broken", previous, Now.AddSeconds(1)));
        var retained = ClaudeBridge.Read(Cache, Now.AddSeconds(2), allowInvalid: true);
        var next = ClaudeBridge.Capture("{}", retained, Now.AddSeconds(3));
        Assert.Null(next.Quotas.FiveHour!.Used);
        Assert.Equal(Now.AddSeconds(1000), next.Quotas.FiveHour.Reset);
        Assert.Equal(Now, next.Quotas.FiveHour.ResetObserved);
    }
    [Fact] public void CorruptCacheReported()
    { Directory.CreateDirectory(dir); File.WriteAllText(Cache, "broken"); Assert.Throws<InvalidDataException>(() => ClaudeBridge.Read(Cache, Now)); }
    [Fact] public void FutureCacheRejected()
    { LocalData.Save(Cache, ClaudeBridge.Capture(Input(), null, Now.AddHours(1))); Assert.Throws<InvalidDataException>(() => ClaudeBridge.Read(Cache, Now)); }
    [Fact] public void InstallerPreservesOtherSettingsAndProtectsExistingStatusLine()
    {
        Directory.CreateDirectory(dir); File.WriteAllText(Cache, "{\"theme\":\"dark\"}");
        ClaudeBridge.Install(Cache, "C:\\space dir\\AIQuota.exe");
        using var document = JsonDocument.Parse(File.ReadAllText(Cache)); Assert.Equal("dark", document.RootElement.GetProperty("theme").GetString());
        var before = File.ReadAllText(Cache); Assert.Throws<InvalidDataException>(() => ClaudeBridge.Install(Cache, "other")); Assert.Equal(before, File.ReadAllText(Cache));
    }
    [Theory] [InlineData("[]")] [InlineData("broken")] [InlineData("null")]
    public void InvalidSettingsNotModified(string json)
    {
        Directory.CreateDirectory(dir); File.WriteAllText(Cache, json);
        Assert.ThrowsAny<Exception>(() => ClaudeBridge.Install(Cache, "C:\\app.exe")); Assert.Equal(json, File.ReadAllText(Cache));
    }
    [Fact] public void StatusCommandQuotesApostropheAndSpaces()
    {
        var command = ClaudeBridge.StatusCommand("C:\\a space O'Brien\\AIQuota.exe");
        var script = Encoding.Unicode.GetString(Convert.FromBase64String(command.Split(' ')[^1]));
        Assert.Contains("O''Brien", script); Assert.Contains("--claude-statusline", script); Assert.Contains("[Console]::In.ReadToEnd()", script);
    }
    public void Dispose() { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
}

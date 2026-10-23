using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIQuota.Core;

public static class LocalData
{
    public static string DirectoryPath => Path.GetFullPath(Environment.GetEnvironmentVariable("AIQUOTA_DATA_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AIQuota"));
    public static string ClaudeCache => Path.Combine(DirectoryPath, "claude-usage.json");
    public static string ClaudeSettings => Path.Combine(Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude"), "settings.json");
    public static void Save<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temp, JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

public sealed class Preferences
{
    public bool Used { get; set; }
    public string Windows { get; set; } = "both";
    public int RefreshSeconds { get; set; } = 60; // zero disables polling
    public int AlertThreshold { get; set; }
    public Dictionary<string, string> Alerted { get; set; } = new();
    public static string FilePath => Path.Combine(LocalData.DirectoryPath, "preferences.json");
    public static Preferences Load()
    {
        try
        {
            var p = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FilePath)) ?? new();
            if (p.RefreshSeconds is not (0 or 30 or 60 or 300)) p.RefreshSeconds = 60;
            if (p.AlertThreshold is not (0 or 10 or 20 or 30)) p.AlertThreshold = 0;
            if (p.Windows is not ("both" or "five" or "seven")) p.Windows = "both";
            p.Alerted ??= new();
            return p;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }
    public void Save() => LocalData.Save(FilePath, this);
}

public static class QuotaAlerts
{
    // Persist the last reset identity per provider/window: no repeated balloon after refresh or restart.
    // Without a reset, alert once until usage recovers above the threshold.
    public static bool ShouldAlert(Preferences preferences, string key, QuotaWindow? window, DateTimeOffset now, TimeSpan age)
    {
        if (preferences.AlertThreshold == 0 || window?.Used is not { } used || !window.Fresh(now, age)) return false;
        if (100 - used >= preferences.AlertThreshold)
        {
            if (window.Reset == null) preferences.Alerted.Remove(key);
            return false;
        }
        var identity = window.Reset?.ToUnixTimeSeconds().ToString() ?? "unknown";
        if (preferences.Alerted.GetValueOrDefault(key) == identity) return false;
        preferences.Alerted[key] = identity;
        return true;
    }
}

public sealed record ClaudeRecord(DateTimeOffset CapturedAt, Quotas Quotas, bool Invalid = false);

public static class ClaudeBridge
{
    public static TimeSpan MaxAge => TimeSpan.FromMinutes(15);
    public static ClaudeRecord Capture(string input, ClaudeRecord? previous, DateTimeOffset now)
    {
        JsonDocument? document = null;
        bool invalid = false;
        JsonElement limits = default;
        try
        {
            document = JsonDocument.Parse(input);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) invalid = true;
            limits = root.Property("rate_limits");
            if (limits.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Object)) invalid = true;
        }
        catch (JsonException) { invalid = true; }
        QuotaWindow? Window(string name, QuotaWindow? old)
        {
            var raw = limits.Property(name);
            var used = invalid ? null : raw.Property("used_percentage").Percent();
            var reset = invalid ? null : raw.Property("resets_at").Timestamp();
            if (reset <= now) reset = null;
            var known = old?.Reset;
            var observed = old?.ResetObserved;
            var passed = old?.PreviousReset;
            if (reset != null)
            {
                if (known <= now && known != reset) passed = known > passed || passed == null ? known : passed;
                known = reset; observed = now;
            }
            return used == null && known == null && passed == null ? null : new(used, now, known, observed, passed);
        }
        var record = new ClaudeRecord(now, new(Window("five_hour", previous?.Quotas.FiveHour), Window("seven_day", previous?.Quotas.SevenDay)), invalid);
        document?.Dispose();
        return record;
    }

    public static ClaudeRecord? Read(string path, DateTimeOffset now, bool allowInvalid = false)
    {
        if (!File.Exists(path)) return null;
        try
        {
            var record = JsonSerializer.Deserialize<ClaudeRecord>(File.ReadAllText(path)) ?? throw new JsonException();
            if ((!allowInvalid && record.Invalid) || record.CapturedAt > now.AddSeconds(60) || record.CapturedAt <= DateTimeOffset.UnixEpoch || record.Quotas == null)
                throw new JsonException();
            QuotaWindow? Validate(QuotaWindow? w)
            {
                if (w == null) return null;
                if (w.CapturedAt != record.CapturedAt) throw new JsonException();
                var reset = w.Reset is { } r && w.ResetObserved is { } o && o <= record.CapturedAt && o > DateTimeOffset.UnixEpoch && r > o ? w.Reset : null;
                var past = w.PreviousReset <= w.ResetObserved && w.PreviousReset > DateTimeOffset.UnixEpoch ? w.PreviousReset : null;
                return w with { Used = w.Used is >= 0 and <= 100 ? w.Used : null, Reset = reset, PreviousReset = past };
            }
            return record with { Quotas = new(Validate(record.Quotas.FiveHour), Validate(record.Quotas.SevenDay)) };
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        { throw new InvalidDataException("Claude Code : cache inaccessible ou invalide."); }
    }

    public static string StatusCommand(string executable)
    {
        // Explicit PowerShell wrapper works whether Claude's outer shell is Git Bash or PowerShell.
        var escaped = executable.Replace("'", "''");
        var script = "$data = [Console]::In.ReadToEnd(); $data | & '" + escaped + "' --claude-statusline";
        return "powershell.exe -NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
    }

    public static void Install(string settingsPath, string executable)
    {
        // Resolve a dotfile symlink rather than replacing it.
        var info = new FileInfo(settingsPath);
        if (info.LinkTarget != null) settingsPath = info.ResolveLinkTarget(true)!.FullName;
        var settings = File.Exists(settingsPath) ? JsonNode.Parse(File.ReadAllText(settingsPath)) as JsonObject : new JsonObject();
        if (settings == null) throw new InvalidDataException("settings.json doit être un objet JSON.");
        if (settings.ContainsKey("statusLine")) throw new InvalidDataException("Une status line existe déjà. Consulte le README pour la composer sans l’écraser.");
        settings["statusLine"] = new JsonObject { ["type"] = "command", ["command"] = StatusCommand(executable), ["refreshInterval"] = 60 };
        LocalData.Save(settingsPath, settings);
    }
}

using System.Text.Json;

namespace AIQuota.Core;

public sealed record QuotaWindow(double? Used, DateTimeOffset CapturedAt, DateTimeOffset? Reset = null,
    DateTimeOffset? ResetObserved = null, DateTimeOffset? PreviousReset = null)
{
    public bool Fresh(DateTimeOffset now, TimeSpan maxAge) => now >= CapturedAt && now - CapturedAt < maxAge
        && !(Reset is { } r && CapturedAt < r && r <= now)
        && !(PreviousReset is { } p && CapturedAt < p && p <= now);
    public DateTimeOffset? VisibleReset(DateTimeOffset now, TimeSpan age) =>
        Reset > now && (ResetObserved ?? CapturedAt) <= now && now - (ResetObserved ?? CapturedAt) < age ? Reset : null;
}

public sealed record Quotas(QuotaWindow? FiveHour = null, QuotaWindow? SevenDay = null)
{
    // Keep each window's observation time: sparse notifications must never freshen omitted data.
    public Quotas Merge(Quotas update) => new(update.FiveHour ?? FiveHour, update.SevenDay ?? SevenDay);
}

public static class QuotaJson
{
    public static JsonElement Property(this JsonElement element, string key) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) ? value : default;
    public static double? Number(this JsonElement element) =>
        element.ValueKind == JsonValueKind.Number && element.TryGetDouble(out var value) && double.IsFinite(value) ? value : null;
    public static double? Percent(this JsonElement element) => element.Number() is >= 0 and <= 100 ? element.Number() : null;
    public static DateTimeOffset? Timestamp(this JsonElement element) => FromSeconds(element.Number());
    public static DateTimeOffset? FromSeconds(double? value) => value is > 0 and < 253402300800
        ? DateTimeOffset.FromUnixTimeMilliseconds((long)(value.Value * 1000)) : null;

    public static Quotas? Codex(JsonElement envelope, DateTimeOffset now)
    {
        if (envelope.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Payload Codex invalide.");
        JsonElement bucket;
        if (envelope.TryGetProperty("rateLimitsByLimitId", out var buckets) && buckets.ValueKind != JsonValueKind.Null)
        {
            if (buckets.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Buckets Codex invalides.");
            if (!buckets.TryGetProperty("codex", out bucket)) return null;
        }
        else if (!envelope.TryGetProperty("rateLimits", out bucket)) throw new InvalidDataException("Enveloppe de quotas absente.");
        if (bucket.ValueKind == JsonValueKind.Null) return null;
        if (bucket.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Quota Codex invalide.");
        var id = bucket.Property("limitId");
        if (id.ValueKind != JsonValueKind.Undefined && id.ValueKind != JsonValueKind.Null
            && (id.ValueKind != JsonValueKind.String || id.GetString() != "codex")) return null;
        QuotaWindow? five = null, seven = null;
        foreach (var name in new[] { "primary", "secondary" })
        {
            var w = bucket.Property(name);
            if (w.Property("usedPercent").Percent() is not { } used) continue;
            var window = new QuotaWindow(used, now, w.Property("resetsAt").Timestamp());
            switch (w.Property("windowDurationMins").Number())
            {
                case 300: five ??= window; break;
                case 10080: seven ??= window; break;
            }
        }
        return new(five, seven);
    }
}

using System.Globalization;
using AIQuota.Core;

namespace AIQuota;

internal static class PopupPresentation
{
    internal static string Reset(DateTimeOffset? reset, DateTimeOffset now)
    {
        if (reset is not { } value) return "Reset —";
        var local = value.ToLocalTime();
        var today = now.ToLocalTime().Date;
        return "Reset " + (local.Date == today ? local.ToString("HH:mm")
            : local.Date == today.AddDays(1) ? "Tomorrow " + local.ToString("HH:mm")
            : local.ToString("d MMM HH:mm", CultureInfo.InvariantCulture));
    }

    internal static string Updated(DateTimeOffset? captured, DateTimeOffset now)
    {
        if (captured == null) return "Data unavailable";
        var seconds = Math.Max(0, (now - captured.Value).TotalSeconds);
        return seconds < 60 ? $"Updated {(int)seconds} sec ago"
            : seconds < 3600 ? $"Updated {(int)(seconds / 60)} min ago"
            : seconds < 86400 ? $"Updated {(int)(seconds / 3600)} hr ago"
            : $"Updated {(int)(seconds / 86400)} days ago";
    }

    internal static string Percent(QuotaWindow? window, TimeSpan age, DateTimeOffset now, bool used) =>
        window?.Used is { } value && window.Fresh(now, age)
            ? (used ? value : 100 - value).ToString("0.#", CultureInfo.InvariantCulture) + "%" : "—";

    internal static System.Drawing.Point Position(System.Drawing.Rectangle area, System.Drawing.Point anchor, System.Drawing.Size size, int gap) =>
        new(Math.Clamp(anchor.X - size.Width / 2, area.Left, Math.Max(area.Left, area.Right - size.Width)),
            Math.Clamp(anchor.Y - size.Height - gap, area.Top, Math.Max(area.Top, area.Bottom - size.Height)));
}

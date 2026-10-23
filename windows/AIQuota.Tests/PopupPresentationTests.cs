using System.Drawing;
using AIQuota;
using AIQuota.Core;
using Xunit;

namespace AIQuota.Tests;

public class PopupPresentationTests
{
    private readonly DateTimeOffset now = new(2026, 10, 23, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void ResetsUseLocalCalendarAndConciseDates()
    {
        var local = now.ToLocalTime();
        Assert.Equal("Reset " + local.ToString("HH:mm"), PopupPresentation.Reset(now, now));
        Assert.Equal("Reset Tomorrow " + local.ToString("HH:mm"), PopupPresentation.Reset(now.AddDays(1), now));
        Assert.Equal("Reset " + now.AddDays(4).ToLocalTime().ToString("d MMM HH:mm", System.Globalization.CultureInfo.InvariantCulture), PopupPresentation.Reset(now.AddDays(4), now));
        Assert.Equal("Reset —", PopupPresentation.Reset(null, now));
    }

    [Fact]
    public void StaleAndMissingValuesNeverLookLikeFreshPercentages()
    {
        var window = new QuotaWindow(8, now);
        Assert.Equal("92%", PopupPresentation.Percent(window, TimeSpan.FromMinutes(5), now, false));
        Assert.Equal("8%", PopupPresentation.Percent(window, TimeSpan.FromMinutes(5), now, true));
        Assert.Equal("—", PopupPresentation.Percent(window, TimeSpan.FromMinutes(5), now.AddMinutes(5), false));
        Assert.Equal("—", PopupPresentation.Percent(null, TimeSpan.FromMinutes(5), now, false));
        Assert.Equal("Updated 12 sec ago", PopupPresentation.Updated(now.AddSeconds(-12), now));
        Assert.Equal("Data unavailable", PopupPresentation.Updated(null, now));
    }

    [Theory]
    [InlineData(96)]
    [InlineData(120)]
    [InlineData(144)]
    public void PlacementStaysInEitherMonitorWorkingArea(int dpi)
    {
        foreach (var area in new[] { new Rectangle(0, 0, 1920, 1040), new Rectangle(-1920, -200, 1920, 1040) })
        foreach (var anchor in new[] { area.Location, new Point(area.Right, area.Bottom), new Point(area.Left, area.Bottom) })
        {
            var size = new Size(416 * dpi / 96, 470 * dpi / 96);
            var position = PopupPresentation.Position(area, anchor, size, 12 * dpi / 96);
            Assert.True(area.Contains(new Rectangle(position, size)));
        }
    }
}

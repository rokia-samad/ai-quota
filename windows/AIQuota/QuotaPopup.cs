using AIQuota.Core;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace AIQuota;

internal sealed class QuotaPopup : Form
{
    private static readonly Color Background = Color.FromArgb(20, 23, 29);
    private static readonly Color Muted = Color.FromArgb(147, 156, 171);
    private readonly Button refresh = new(), settings = new();
    private Quotas codex = new(), claude = new();
    private TimeSpan codexAge;
    private bool used, refreshing, unavailable;
    private string windows = "both";
    private DateTimeOffset dismissed;
    private bool dismissOnTrayClick;

    internal QuotaPopup(Action onRefresh, Action onSettings)
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Background;
        DoubleBuffered = true;
        Text = "AI Quota";
        AccessibleName = "AI Quota";
        foreach (var button in new[] { refresh, settings })
        {
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 0;
            button.BackColor = Background;
            button.ForeColor = Muted;
            button.Cursor = Cursors.Hand;
            Controls.Add(button);
        }
        refresh.Text = "↻"; refresh.AccessibleName = "Refresh quotas";
        settings.Text = "Settings";
        refresh.Click += (_, _) => onRefresh();
        settings.Click += (_, _) => { Hide(); onSettings(); };
        Deactivate += (_, _) => { dismissed = DateTimeOffset.UtcNow; Hide(); };
        KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) Hide(); };
        KeyPreview = true;
    }

    internal void UpdateData(Quotas chatgpt, Quotas anthropic, TimeSpan age, bool displayUsed, string selectedWindows, bool busy, bool hasError)
    {
        codex = chatgpt; claude = anthropic; codexAge = age; used = displayUsed; windows = selectedWindows; refreshing = busy; unavailable = hasError;
        refresh.Enabled = !busy;
        if (Visible) Invalidate();
    }

    internal void TrayMouseDown() => dismissOnTrayClick = Visible || DateTimeOffset.UtcNow - dismissed < TimeSpan.FromMilliseconds(350);

    internal void Toggle(Point anchor)
    {
        if (Visible || dismissOnTrayClick) { dismissOnTrayClick = false; Hide(); return; }
        // Clicking the tray first deactivates the form, before NotifyIcon receives MouseClick.
        if (DateTimeOffset.UtcNow - dismissed < TimeSpan.FromMilliseconds(350)) return;
        var screen = Screen.FromPoint(anchor);
        Location = new Point(screen.WorkingArea.Left, screen.WorkingArea.Top);
        _ = Handle;
        var scale = DeviceDpi / 96f;
        Size = new Size(Math.Min((int)(416 * scale), screen.WorkingArea.Width), Math.Min((int)(470 * scale), screen.WorkingArea.Height));
        Location = PopupPresentation.Position(screen.WorkingArea, anchor, Size, (int)(12 * scale));
        LayoutButtons();
        Show();
        // DWM supplies the native shadow and rounded corners on supported Windows versions.
        int corner = 2;
        DwmSetWindowAttribute(Handle, 33, ref corner, sizeof(int));
        var margins = new Margins { Left = 1, Right = 1, Top = 1, Bottom = 1 };
        DwmExtendFrameIntoClientArea(Handle, ref margins);
        Activate();
    }

    private void LayoutButtons()
    {
        float s = DeviceDpi / 96f;
        settings.SetBounds((int)(285 * s), (int)(425 * s), (int)(78 * s), (int)(30 * s));
        refresh.SetBounds((int)(367 * s), (int)(425 * s), (int)(30 * s), (int)(30 * s));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.ScaleTransform(DeviceDpi / 96f, DeviceDpi / 96f);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        void Text(string text, float x, float y, float size, Color color, FontStyle style = FontStyle.Regular)
        {
            using var font = new Font("Segoe UI", size, style, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(color);
            g.DrawString(text, font, brush, x, y);
        }
        var now = DateTimeOffset.UtcNow;
        Text("AI QUOTA", 22, 19, 16, Color.FromArgb(235, 239, 245), FontStyle.Bold);
        Text(used ? "USED · bars show available" : "AVAILABLE", 22, 47, 10, Muted);
        using (var dot = new SolidBrush(refreshing || unavailable ? Muted : Color.FromArgb(113, 175, 145))) g.FillEllipse(dot, 384, 27, 6, 6);
        Provider("ChatGPT", codex, codexAge, Color.FromArgb(105, 163, 232), 82);
        Provider("Claude", claude, ClaudeBridge.MaxAge, Color.FromArgb(217, 155, 111), 253);
        using (var line = new Pen(Color.FromArgb(44, 49, 58))) g.DrawLine(line, 22, 419, 394, 419);
        var observations = new[] { codex.FiveHour, codex.SevenDay, claude.FiveHour, claude.SevenDay }.Where(w => w?.Used != null).Select(w => (DateTimeOffset?)w!.CapturedAt);
        Text(refreshing ? "Refreshing…" : PopupPresentation.Updated(observations.Max(), now), 22, 435, 11, Muted);

        void Provider(string name, Quotas quotas, TimeSpan age, Color accent, int y)
        {
            Text(name, 22, y, 16, Color.White, FontStyle.Bold);
            var selected = windows == "five" ? new[] { ("5 HOURS", quotas.FiveHour) }
                : windows == "seven" ? new[] { ("7 DAYS", quotas.SevenDay) }
                : new[] { ("5 HOURS", quotas.FiveHour), ("7 DAYS", quotas.SevenDay) };
            for (int i = 0; i < selected.Length; i++)
            {
                var (label, window) = selected[i];
                int x = 22 + i * 192;
                int width = selected.Length == 1 ? 372 : 180;
                using var card = new SolidBrush(Color.FromArgb(29, 33, 41));
                g.FillRoundedRectangle(card, new Rectangle(x, y + 31, width, 125), new Size(10, 10));
                Text(label, x + 14, y + 42, 10, Muted, FontStyle.Bold);
                Text(PopupPresentation.Percent(window, age, now, used), x + 12, y + 60, 31, Color.FromArgb(239, 242, 248), FontStyle.Bold);
                bool fresh = window?.Used != null && window.Fresh(now, age);
                using var track = new SolidBrush(Color.FromArgb(55, 61, 72));
                g.FillRectangle(track, x + 14, y + 104, width - 28, 4);
                if (fresh)
                {
                    var available = Math.Clamp(100 - window!.Used!.Value, 0, 100);
                    using var fill = new SolidBrush(available <= 10 ? Color.FromArgb(221, 112, 103) : available <= 20 ? Color.FromArgb(220, 166, 100) : accent);
                    g.FillRectangle(fill, x + 14, y + 104, (float)((width - 28) * available / 100), 4);
                }
                Text(fresh ? PopupPresentation.Reset(window!.VisibleReset(now, age), now)
                    : window?.Used != null ? "Data is out of date"
                    : name == "Claude" ? "Waiting for Claude Code" : "Data unavailable", x + 14, y + 119, 11, Muted);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)] private struct Margins { public int Left, Right, Top, Bottom; }
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(IntPtr window, ref Margins margins);
}

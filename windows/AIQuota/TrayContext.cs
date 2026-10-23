using AIQuota.Core;
using Microsoft.Win32;
using System.Drawing.Drawing2D;

namespace AIQuota;

internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon tray;
    private readonly ContextMenuStrip menu = new();
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    private readonly Control dispatch = new();
    private readonly Preferences preferences = Preferences.Load();
    private readonly Icon icon;
    private readonly Font headingFont;
    private readonly CancellationTokenSource stopping = new();
    private CodexClient? client;
    private Quotas codex = new(), claude = new();
    private string? codexError = "Connexion…", claudeError;
    private bool refreshing, closing;
    private DateTimeOffset nextRefresh;
    private TimeSpan CodexAge => TimeSpan.FromSeconds(Math.Max(300, preferences.RefreshSeconds * 2));
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public TrayContext()
    {
        dispatch.CreateControl();
        headingFont = new Font(menu.Font, FontStyle.Bold);
        icon = MakeIcon();
        tray = new NotifyIcon { Icon = icon, Text = "AI Quota · connexion…", ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) { ReadClaude(); Render(); menu.Show(Cursor.Position); } };
        menu.Opening += (_, _) => { ReadClaude(); Render(); };
        timer.Tick += async (_, _) =>
        {
            if (preferences.RefreshSeconds > 0 && DateTimeOffset.UtcNow >= nextRefresh) await RefreshAsync();
            ReadClaude(); UpdateTooltip();
        };
        Render(); timer.Start();
        _ = RefreshAsync();
    }

    private void Post(Action action)
    {
        if (!closing && !dispatch.IsDisposed) dispatch.BeginInvoke((Action)(() => { if (!closing) action(); }));
    }

    private async Task RefreshAsync()
    {
        if (refreshing || closing) return;
        refreshing = true;
        try
        {
            if (client == null)
            {
                var command = await CodexDiscovery.ResolveAsync();
                if (closing) return;
                if (command == null) throw new CodexException("Codex CLI introuvable. Vérifie PATH, puis relance AI Quota.");
                var connection = new CodexClient(command.StartInfo());
                client = connection;
                connection.Updated += update => Post(() =>
                {
                    if (client != connection) return;
                    codex = codex.Merge(update); codexError = null; Alert(); UpdateTooltip();
                });
                connection.Disconnected += () => Post(() =>
                {
                    if (client != connection) return;
                    codex = new(); codexError = "Connexion interrompue. Actualise pour reconnecter.";
                    client = null; _ = connection.DisposeAsync(); UpdateTooltip();
                });
            }
            var active = client;
            var reading = await active.ReadAsync(stopping.Token);
            if (closing) return;
            // A notification may reach the UI before this await's continuation. Keep only
            // windows measured after the response; a full read still clears older omissions.
            var received = active.ReadReceivedAt;
            codex = new(codex.FiveHour?.CapturedAt > received ? codex.FiveHour : reading.FiveHour,
                codex.SevenDay?.CapturedAt > received ? codex.SevenDay : reading.SevenDay);
            codexError = null;
        }
        catch (Exception e) when (e is IOException or InvalidDataException or System.ComponentModel.Win32Exception or UnauthorizedAccessException or OperationCanceledException)
        {
            codex = new();
            codexError = e is CodexException ? e.Message : e is InvalidDataException ? "Réponse de quotas Codex invalide."
                : "Codex indisponible : vérifie le CLI et sa connexion (codex login).";
            var failed = client; client = null;
            if (failed != null) await failed.DisposeAsync();
        }
        finally
        {
            refreshing = false; nextRefresh = DateTimeOffset.UtcNow.AddSeconds(Math.Max(30, preferences.RefreshSeconds));
            if (!closing) { ReadClaude(); Alert(); if (!menu.Visible) Render(); else UpdateTooltip(); }
        }
    }

    private void ReadClaude()
    {
        try
        {
            claude = ClaudeBridge.Read(LocalData.ClaudeCache, DateTimeOffset.UtcNow)?.Quotas ?? new();
            claudeError = null;
        }
        catch (InvalidDataException) { claude = new(); claudeError = "Cache Claude Code inaccessible ou invalide."; }
        Alert();
    }

    private string Percentage(QuotaWindow? w, TimeSpan age)
    {
        if (w?.Used is not { } used) return "indisponible";
        if (!w.Fresh(DateTimeOffset.UtcNow, age)) return "— (ancien)";
        return $"{(preferences.Used ? used : 100 - used):0.#} %";
    }

    private void Render()
    {
        // A full rebuild is only performed on opening/actions, never while the user navigates.
        foreach (ToolStripItem item in menu.Items.Cast<ToolStripItem>().ToArray()) item.Dispose();
        menu.Items.Clear();
        Provider("ChatGPT / Codex", codex, CodexAge, codexError, "Codex app-server");
        menu.Items.Add(new ToolStripSeparator());
        Provider("Claude", claude, ClaudeBridge.MaxAge, claudeError, "Claude Code · status line");
        menu.Items.Add(new ToolStripSeparator());
        Add(menu.Items, refreshing ? "Actualisation…" : "Actualiser maintenant", async () => await RefreshAsync()).Enabled = !refreshing;
        var display = new ToolStripMenuItem("Affichage");
        Option(display, "Disponible", !preferences.Used, () => preferences.Used = false);
        Option(display, "Utilisé", preferences.Used, () => preferences.Used = true); menu.Items.Add(display);
        var windows = new ToolStripMenuItem("Quotas");
        foreach (var (value, label) in new[] { ("both", "5 h + 7 j"), ("five", "Seulement 5 h"), ("seven", "Seulement 7 j") })
            Option(windows, label, preferences.Windows == value, () => preferences.Windows = value);
        menu.Items.Add(windows);
        var refresh = new ToolStripMenuItem("Actualisation automatique");
        foreach (var (value, label) in new[] { (0, "Désactivée"), (30, "30 secondes"), (60, "1 minute"), (300, "5 minutes") })
            Option(refresh, label, preferences.RefreshSeconds == value, () => { preferences.RefreshSeconds = value; nextRefresh = DateTimeOffset.UtcNow.AddSeconds(value); });
        menu.Items.Add(refresh);
        var alerts = new ToolStripMenuItem("Alertes");
        foreach (var threshold in new[] { 0, 10, 20, 30 })
            Option(alerts, threshold == 0 ? "Désactivées" : $"Sous {threshold} % disponibles", preferences.AlertThreshold == threshold,
                () => preferences.AlertThreshold = threshold);
        menu.Items.Add(alerts);
        var startup = Add(menu.Items, "Lancer avec Windows", ToggleStartup); startup.Checked = StartupEnabled();
        Add(menu.Items, "Relier Claude Code…", () =>
        {
            try { ClaudeBridge.Install(LocalData.ClaudeSettings, Environment.ProcessPath!); MessageBox.Show("Claude Code relié. Envoie un message dans une session éligible pour recevoir les quotas.", "AI Quota"); }
            catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException)
            { MessageBox.Show(e is InvalidDataException ? e.Message : "Impossible de modifier les réglages Claude Code.", "AI Quota"); }
        });
        menu.Items.Add(new ToolStripSeparator());
        Add(menu.Items, "Quitter", ExitThread);
        UpdateTooltip();
    }

    private void Provider(string name, Quotas quotas, TimeSpan age, string? error, string source)
    {
        menu.Items.Add(new ToolStripMenuItem(name) { Enabled = false, Font = headingFont });
        foreach (var (label, window) in Selected(quotas))
        {
            menu.Items.Add(new ToolStripMenuItem($"{label} : {Percentage(window, age)}") { Enabled = false });
            var reset = window?.VisibleReset(DateTimeOffset.UtcNow, age)?.ToLocalTime().ToString("g") ?? "—";
            menu.Items.Add(new ToolStripMenuItem($"Reset {label} : {reset}") { Enabled = false });
            var state = window?.Used == null ? "indisponible" : window.Fresh(DateTimeOffset.UtcNow, age) ? "frais" : "ancien";
            menu.Items.Add(new ToolStripMenuItem($"Mesure {label} : {window?.CapturedAt.ToLocalTime().ToString("g") ?? "—"} · {state}") { Enabled = false });
        }
        menu.Items.Add(new ToolStripMenuItem(error ?? $"Source : {source}") { Enabled = false });
    }

    private IEnumerable<(string Label, QuotaWindow? Window)> Selected(Quotas q)
    {
        if (preferences.Windows != "seven") yield return ("5 h", q.FiveHour);
        if (preferences.Windows != "five") yield return ("7 j", q.SevenDay);
    }

    private void UpdateTooltip()
    {
        var text = "ChatGPT " + string.Join(" · ", Selected(codex).Select(w => $"{w.Label} {Percentage(w.Window, CodexAge)}"));
        var second = "\nClaude " + string.Join(" · ", Selected(claude).Select(w => $"{w.Label} {Percentage(w.Window, ClaudeBridge.MaxAge)}"));
        if (text.Length + second.Length <= 127) text += second;
        tray.Text = text.Length <= 127 ? text : text[..127];
    }

    private void Alert()
    {
        var messages = new List<string>();
        foreach (var (name, quotas, age) in new[] { ("ChatGPT", codex, CodexAge), ("Claude", claude, ClaudeBridge.MaxAge) })
            foreach (var (label, w) in new[] { ("5 h", quotas.FiveHour), ("7 j", quotas.SevenDay) })
                if (QuotaAlerts.ShouldAlert(preferences, name + label, w, DateTimeOffset.UtcNow, age))
                    messages.Add($"{name} {label} : {100 - w!.Used:0.#} % disponibles");
        if (messages.Count == 0) return;
        Save(); tray.ShowBalloonTip(6000, "AI Quota · quota faible", string.Join("\n", messages), ToolTipIcon.Warning);
    }

    private static ToolStripMenuItem Add(ToolStripItemCollection items, string label, Action action)
    {
        var item = new ToolStripMenuItem(label); item.Click += (_, _) => action(); items.Add(item); return item;
    }
    private void Option(ToolStripMenuItem parent, string label, bool selected, Action action)
    { Add(parent.DropDownItems, label, () => { action(); Save(); Render(); }).Checked = selected; }
    private void Save()
    {
        try { preferences.Save(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { tray.ShowBalloonTip(4000, "AI Quota", "Préférences non enregistrées : dossier local inaccessible.", ToolTipIcon.Warning); }
    }
    private static bool StartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue("AIQuota") as string == $"\"{Environment.ProcessPath}\"";
    }
    private void ToggleStartup()
    {
        try
        {
            var enabled = StartupEnabled();
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled) key.DeleteValue("AIQuota", false);
            else key.SetValue("AIQuota", $"\"{Environment.ProcessPath}\"");
            Render();
        }
        catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        { MessageBox.Show("Impossible de modifier le démarrage automatique de cet utilisateur.", "AI Quota"); }
    }

    private static Icon MakeIcon()
    {
        using var bitmap = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bitmap); g.SmoothingMode = SmoothingMode.AntiAlias;
        using var blue = new Pen(Color.FromArgb(60, 145, 245), 5);
        using var orange = new Pen(Color.FromArgb(245, 150, 65), 5);
        g.DrawArc(blue, 4, 4, 24, 24, 100, 220); g.DrawArc(orange, 4, 4, 24, 24, -35, 110);
        using var white = new SolidBrush(Color.White); g.FillEllipse(white, 12, 12, 8, 8);
        var handle = bitmap.GetHicon();
        try { using var borrowed = Icon.FromHandle(handle); return (Icon)borrowed.Clone(); }
        finally { DestroyIcon(handle); }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr handle);

    protected override void ExitThreadCore()
    {
        closing = true; timer.Stop(); stopping.Cancel(); tray.Visible = false; Save();
        if (client != null) client.DisposeAsync().AsTask().GetAwaiter().GetResult();
        base.ExitThreadCore();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { tray.Dispose(); menu.Dispose(); headingFont.Dispose(); icon.Dispose(); timer.Dispose(); dispatch.Dispose(); stopping.Dispose(); }
        base.Dispose(disposing);
    }
}

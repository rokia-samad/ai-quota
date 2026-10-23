using System.Runtime.InteropServices;
using AIQuota.Core;

namespace AIQuota;

internal static class Program
{
    [DllImport("kernel32.dll")] private static extern bool AttachConsole(uint processId);

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0)
        {
            // WinExe has no console during ordinary use. Diagnostics attach to PowerShell;
            // redirected streams (including Claude's stdin/stdout) are kept untouched.
            if (args[0] != "--claude-statusline") AttachConsole(uint.MaxValue);
            Console.OutputEncoding = System.Text.Encoding.UTF8;
            return CommandAsync(args[0]).GetAwaiter().GetResult();
        }
        using var mutex = new Mutex(true, "Local\\AIQuota.Windows.Tray", out var first);
        if (!first) return 0;
        ApplicationConfiguration.Initialize();
        using var context = new TrayContext();
        Application.Run(context);
        return 0;
    }

    private static async Task<int> CommandAsync(string command)
    {
        try
        {
            switch (command)
            {
                case "--diagnose-codex":
                    var cli = await CodexDiscovery.ResolveAsync();
                    if (cli == null) { Console.WriteLine("Codex CLI introuvable : vérifie Get-Command codex / where.exe codex, puis relance AI Quota."); return 1; }
                    Console.WriteLine($"CLI : {cli.Path}");
                    await using (var client = new CodexClient(cli.StartInfo()))
                    {
                        var quotas = await client.ReadAsync();
                        Console.WriteLine("Handshake app-server : OK ; account/rateLimits/read : OK ; bucket : codex");
                        Print("5 h", quotas.FiveHour); Print("7 j", quotas.SevenDay);
                        return quotas.FiveHour == null && quotas.SevenDay == null ? 2 : 0;
                    }
                case "--diagnose-claude":
                    Console.WriteLine($"Source : Claude Code status line\nCache : {LocalData.ClaudeCache}\nSettings : {LocalData.ClaudeSettings}");
                    var record = ClaudeBridge.Read(LocalData.ClaudeCache, DateTimeOffset.UtcNow);
                    Print("5 h", record?.Quotas.FiveHour, ClaudeBridge.MaxAge); Print("7 j", record?.Quotas.SevenDay, ClaudeBridge.MaxAge);
                    Console.WriteLine("Claude Desktop Windows : aucune source locale prise en charge.");
                    return record?.Quotas is { } q && new[] { q.FiveHour, q.SevenDay }.Any(w =>
                        w?.Used != null && w.Fresh(DateTimeOffset.UtcNow, ClaudeBridge.MaxAge)) ? 0 : 2;
                case "--claude-statusline":
                    ClaudeRecord? previous = null;
                    try { previous = ClaudeBridge.Read(LocalData.ClaudeCache, DateTimeOffset.UtcNow, allowInvalid: true); } catch (InvalidDataException) { }
                    // Read only stdin from Claude; retain only validated quota fields.
                    var input = await Console.In.ReadToEndAsync();
                    var captured = ClaudeBridge.Capture(input, previous, DateTimeOffset.UtcNow);
                    LocalData.Save(LocalData.ClaudeCache, captured);
                    Console.WriteLine(captured.Invalid ? "Claude · données invalides" : captured.Quotas.FiveHour?.Used != null || captured.Quotas.SevenDay?.Used != null ? "Claude" : "Claude · quotas en attente");
                    return captured.Invalid ? 1 : 0;
                default: Console.WriteLine("Options : --diagnose-codex, --diagnose-claude, --claude-statusline"); return 2;
            }
        }
        catch (Exception e) when (e is IOException or InvalidDataException or System.ComponentModel.Win32Exception or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            Console.WriteLine(e is CodexException ? e.Message : e is InvalidDataException ? "Données de quota invalides ou cache local inaccessible."
                : "Lecture impossible. Vérifie le CLI, sa connexion et les fichiers locaux. Aucun détail brut du serveur n’est affiché.");
            return 1;
        }
    }

    private static void Print(string label, QuotaWindow? w, TimeSpan? age = null)
    {
        var now = DateTimeOffset.UtcNow;
        var fresh = w?.Fresh(now, age ?? TimeSpan.FromMinutes(5)) == true;
        Console.WriteLine($"{label} : {(fresh && w?.Used != null ? $"{100 - w.Used:0.#} % disponibles" : "indisponible / ancien")} ; reset : {w?.VisibleReset(now, age ?? TimeSpan.FromMinutes(5))?.ToLocalTime().ToString("g") ?? "—"} ; mesure : {w?.CapturedAt.ToLocalTime().ToString("g") ?? "—"}");
    }
}

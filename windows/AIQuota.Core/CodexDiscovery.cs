using System.Diagnostics;

namespace AIQuota.Core;

public sealed record CodexCommand(string Path)
{
    public ProcessStartInfo StartInfo()
    {
        var info = new ProcessStartInfo { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (System.IO.Path.GetExtension(Path).Equals(".cmd", StringComparison.OrdinalIgnoreCase)
            || System.IO.Path.GetExtension(Path).Equals(".bat", StringComparison.OrdinalIgnoreCase))
        {
            info.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
            // cmd's /s /c outer quote rule; no user-controlled arguments are appended.
            if (Path.IndexOfAny(['"', '\r', '\n', '%', '!']) >= 0) throw new InvalidDataException("Chemin CLI non pris en charge.");
            info.Arguments = $"/d /s /c \"\"{Path}\" app-server\"";
        }
        else { info.FileName = Path; info.ArgumentList.Add("app-server"); }
        return info;
    }
}

public static class CodexDiscovery
{
    public static CodexCommand? FromDirectories(IEnumerable<string> directories, Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        foreach (var directory in directories.Where(d => !string.IsNullOrWhiteSpace(d)))
            foreach (var file in new[] { "codex.exe", "codex.cmd", "codex.bat" })
            {
                var path = Path.Combine(directory.Trim().Trim('"'), file);
                if (exists(path)) return new(Path.GetFullPath(path));
            }
        return null;
    }

    public static async Task<CodexCommand?> ResolveAsync()
    {
        var direct = FromDirectories((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator));
        if (direct != null) return direct;
        // Resolve Application commands only. Functions/aliases in a personal profile cannot safely
        // be launched by a background process; a sibling npm .cmd is supported instead of .ps1.
        var info = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-Command",
            "Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source" }) info.ArgumentList.Add(arg);
        try
        {
            using var process = Process.Start(info)!;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var error = process.StandardError.ReadToEndAsync(timeout.Token);
            try { await process.WaitForExitAsync(timeout.Token); }
            catch { if (!process.HasExited) process.Kill(true); throw; }
            var path = (await output).Trim();
            await error;
            if (File.Exists(path) && new[] { ".exe", ".cmd", ".bat" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)) return new(path);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or OperationCanceledException or IOException) { }
        return FromDirectories(new[] {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin") });
    }
}

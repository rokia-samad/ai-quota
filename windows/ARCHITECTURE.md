# Windows implementation

## Audit before implementation

The existing Swift package has a macOS-only AppKit executable (`Sources/AIQuota/main.swift`) and a Foundation-based `QuotaCore`. The menu controller owns polling, presentation, alerts, preferences and login startup. `QuotaCore` owns Codex discovery/JSON-RPC, rate-limit validation, Claude ingestion/freshness/reset history and status-line installation. Its tests include synthetic JSON and a fake server.

Windows preserves all Swift files, package layout, fixtures and macOS build scripts. The C# implementation reuses the protocol and validation concepts, not platform-specific paths or executable code. The existing current/legacy JSON fixtures are linked into Windows tests without copying or changing them.

## Choices

- .NET 10 LTS, C#, WinForms `NotifyIcon` and `ContextMenuStrip`. WPF adds no value for a tray-only UI. No third-party runtime libraries, WebView, Electron, cloud or HTTP client.
- `AIQuota.Core`: JSON validation, Codex process transport/discovery, quota models, local Claude cache, preferences and alert deduplication. No UI dependencies.
- `AIQuota`: WinExe, one tray instance per user session, UI-thread dispatch, polling, menu, Windows balloons and HKCU Run startup. Diagnostics run before creating the tray or acquiring its mutex.
- `AIQuota.FakeServer`: test-only executable speaking line-delimited JSON over real anonymous pipes. `AIQuota.Tests`: xUnit, no accounts or network used by tests.
- The root solution makes `dotnet test`, `dotnet build -c Release` and `dotnet publish -c Release` work from the repository root. Only the tray application is publishable.

## Codex

Discover an application on PATH first (EXE, then npm CMD/BAT shim within each directory). If absent, query `Get-Command codex -CommandType Application` in noninteractive, profile-free Windows PowerShell. Finally check user-relative npm and `.local/bin` locations. Shell aliases/functions and arbitrary PowerShell profiles are deliberately not evaluated. A `.ps1` npm shim is supported through its sibling `.cmd`. No embedded Desktop application path is assumed.

EXEs launch directly; CMD/BAT launch through hidden `cmd /d /s /c`, preserving spaces. Only the fixed `app-server` argument is passed. Paths containing CMD expansion characters are rejected rather than interpolated unsafely.

The client performs `initialize`, `initialized`, then `account/rateLimits/read`. It keeps the process alive for `account/rateLimits/updated`. Requests are serialized; response IDs are independent of server-initiated request IDs (the latter receive -32601). A 20-second deadline covers each RPC/write. EOF, process exit, broken pipe and malformed quota notifications drop the connection and clear the tray reading. The next refresh creates a new connection. Stderr is drained and discarded; server error text is never displayed or logged. Framing accepts split reads, skips invalid JSON lines and bounds a frame to 1 MiB.

Only `rateLimitsByLimitId.codex` is selected; a present map never falls back to a different category or the legacy view. The legacy `rateLimits` envelope is accepted only with no contradictory limit ID. Explicit durations 300/10080 map to 5 h/7 j regardless of primary/secondary position. Percentages must be JSON numbers in 0–100; reset timestamps must be valid Unix seconds. Full reads replace the snapshot. Sparse notifications retain omitted windows and each window's original measurement time. A window expires after max(5 minutes, twice the polling interval) or when its known reset passes. Disabling polling still permits incoming notifications and freshness expiration.

## Claude

The [official status-line documentation](https://code.claude.com/docs/en/statusline) explicitly covers Windows, PowerShell/Git Bash shells, `rate_limits`, independent missing windows and Unix resets. The Windows bridge consumes stdin only and persists only the two quota windows, their observation times, validated resets and a generic invalid-input flag. It does not inspect auth files, session history or credentials.

The opt-in menu action adds a command to the user's Claude `settings.json` only when no `statusLine` key exists. It preserves other keys and resolves a settings-file symlink. `CLAUDE_CONFIG_DIR` is honored. The command invokes Windows PowerShell explicitly using an encoded fixed script so spaces, apostrophes and Git Bash path rules cannot corrupt the executable path. The script passes stdin to `AIQuota.exe --claude-statusline`. Existing custom status lines are left for the user to compose.

Missing/invalid quota fields clear old percentages. Known resets and their original observation times survive, including an earlier reset superseded after it passed. Claude percentages expire after 15 minutes or at a known reset; visible reset dates require a recent reset observation. Invalid cache contents fail closed. Atomic cache replacement allows concurrent tray readers; concurrent Claude sessions use last completed write, as on macOS. No Claude Desktop Windows fallback is implemented: the macOS `Library/Application Support` file is not a Windows contract.

## Local state and notifications

`%LOCALAPPDATA%\AIQuota` contains preferences, alert identities and the sanitized Claude cache. Writes use a same-directory temporary file and atomic replacement. No quota history or Codex quota cache is stored. Startup is read directly from `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\AIQuota` and changes only on explicit menu action; no elevation is needed. An explicit Claude link action is also required before changing Claude settings.

Quota alerts are disabled by default. The 10/20/30% thresholds apply to available quota, independent of display mode. A provider/window/reset identity is persisted to avoid repeats across refreshes and restarts. Without a reset, an alert is suppressed until usage recovers above the threshold. Windows notification settings/Focus Assist can suppress balloon display.

## Verification limits

Swift validation remains in the existing macOS CI job; Windows cannot execute the AppKit app. Windows CI separately tests, builds and publishes. A self-contained x64 executable includes the .NET desktop runtime, so it is larger on disk than a framework-dependent build; no runtime installation is required. Native menu/tooltip rendering, Windows scaling, the startup toggle and notifications should also be checked interactively on the target desktop. Tests never enable startup or alter real Claude settings.

## Tray popup presentation

Left-click toggles a reusable borderless WinForms `QuotaPopup` (416 x 470 logical pixels); right-click and the discreet Settings button open the reduced native settings menu. Deactivation or Escape hides the popup. A tray mouse-down records dismissal intent so the deactivation preceding a second tray click does not reopen it.

The popup paints immutable quota snapshots supplied by `TrayContext`; painting and opening perform no quota retrieval or cache reads. The existing timer and notification paths update the snapshot and invalidate only a visible popup. Buttons reuse the existing refresh/settings actions. Percentages follow the display preference; bars always show available quota, explicitly labelled in used mode. Stale percentages are hidden using the existing freshness predicate. Technical error strings never enter the popup.

PerMonitorV2 is enabled through WinForms application configuration. Placement uses the tray click's monitor working area, device DPI and clamped bounds, including negative monitor coordinates. DWM rounding and frame shadow are best effort (Windows 11 supports rounded corners; Windows 10 may remain square). No rendering framework or UI package was added.

Presentation tests cover concise local resets (including daylight-saving changes), stale/missing percentages, relative timestamps and placement at 100/125/150 percent on primary and negative-coordinate secondary monitors. These are geometry tests, not a substitute for interactive Windows 10/11 and mixed-DPI checks. During implementation the Computer Use native pipe was unavailable, so tray clicks, actual rendering and screenshots could not be verified interactively. Release publication used `artifacts/windows/popup/win-x64/` because the previous executable in the default output directory was running.

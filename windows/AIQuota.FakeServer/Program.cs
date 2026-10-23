using System.Text.Json;

// Synthetic stdin/stdout peer used by tests only; never contacts a service/account.
var scenario = args.FirstOrDefault() ?? "normal";
bool initialized = false, acknowledged = false;
string Window(int used = 24, int duration = 300) => $$$$$$"""{"usedPercent":{{{{{{used}}}}}},"windowDurationMins":{{{{{{duration}}}}}},"resetsAt":1900000000}""";
async Task Send(string line)
{
    // Deliberately fragment both JSON and newline across writes.
    var middle = line.Length / 2;
    await Console.Out.WriteAsync(line[..middle]); await Console.Out.FlushAsync();
    await Task.Delay(5);
    await Console.Out.WriteAsync(line[middle..] + "\n"); await Console.Out.FlushAsync();
}
while (await Console.In.ReadLineAsync() is { } input)
{
    using var doc = JsonDocument.Parse(input);
    var root = doc.RootElement;
    if (!root.TryGetProperty("method", out var m)) continue;
    var method = m.GetString();
    if (method == "initialized") { acknowledged = true; continue; }
    var id = root.GetProperty("id").GetInt32();
    if (scenario == "exit") return;
    if (scenario == "timeout") { await Task.Delay(60000); return; }
    if (scenario == "pipe") { Console.Out.Close(); await Task.Delay(60000); return; }
    if (scenario == "stdin") { Console.In.Close(); await Task.Delay(60000); return; }
    if (method == "initialize")
    {
        if (!root.GetProperty("params").TryGetProperty("clientInfo", out _)) return;
        // Server request intentionally collides with our client's initialize ID.
        if (scenario == "server-request")
        {
            await Send($$$$$$"""{"id":{{{{{{id}}}}}},"method":"approval/test","params":{}}""");
            using var reply = JsonDocument.Parse((await Console.In.ReadLineAsync())!);
            if (reply.RootElement.GetProperty("error").GetProperty("code").GetInt32() != -32601) return;
        }
        await Send($$$$$$"""{"id":{{{{{{id}}}}}},"result":{}}"""); initialized = true; continue;
    }
    if (method != "account/rateLimits/read" || !initialized || !acknowledged) return;
    if (scenario == "rpc") { await Send($$$$$$"""{"id":{{{{{{id}}}}}},"error":{"code":-1,"message":"SECRET must never escape"}}"""); continue; }
    if (scenario == "invalid-envelope") { await Send($$$$$$"""{"id":{{{{{{id}}}}}},"result":{"invalid":true}}"""); continue; }
    await Send("not-json");
    var secondary = scenario == "partial" ? "" : ",\"secondary\":" + Window(4, 10080);
    await Send($$$$$$"""{"id":{{{{{{id}}}}}},"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{{{{{{Window()}}}}}}{{{{{{secondary}}}}}}}}}}""");
    if (scenario == "notification")
    {
        await Send($$$$$$"""{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"other","primary":{{{{{{Window(99)}}}}}}}}}""");
        await Send($$$$$$"""{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":{{{{{{Window(80)}}}}}}}}}""");
    }
    if (scenario == "invalid-notification") await Send("{\"method\":\"account/rateLimits/updated\",\"params\":{\"bad\":true}}");
    if (scenario == "exit-after-read") return;
}

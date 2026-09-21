import Foundation

var count = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }; count += 1
}
func json(_ source: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(source.utf8)) as! [String: Any] }
let codex = try QuotaParser.codex(json("""
{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1789591223},"secondary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1789958303}}}
"""))
check(codex.fiveHour?.used == 0, "A real zero must remain zero")
check(codex.weekly?.remaining == 52, "Remaining quota")
check(codex.fiveHour?.reset?.timeIntervalSince1970 == 1789591223, "Unix reset timestamp")
let swapped = try QuotaParser.codex(json("""
{"rateLimits":{"primary":{"usedPercent":19,"windowDurationMins":10080},"secondary":{"usedPercent":4,"windowDurationMins":300}}}
"""))
check(swapped.weekly?.used == 19 && swapped.fiveHour?.used == 4, "Map by duration, not position")
let missing = try QuotaParser.codex(json("""
{"rateLimits":{"secondary":{"usedPercent":100,"windowDurationMins":10080}}}
"""))
check(missing.fiveHour == nil && missing.weekly?.used == 100, "Missing data must not become zero")
let bucket = try QuotaParser.codex(json("""
{"rateLimits":{"primary":{"usedPercent":88,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":7,"windowDurationMins":300}}}}
"""))
check(bucket.fiveHour?.used == 7, "Prefer codex bucket")
for input in ["{}", "{\"rateLimits\":{\"primary\":{\"usedPercent\":-1,\"windowDurationMins\":300}}}", "{\"rateLimits\":{\"primary\":{\"usedPercent\":true,\"windowDurationMins\":300}}}"] {
    do { _ = try QuotaParser.codex(json(input)); fatalError("Malformed response should fail") } catch { count += 1 }
}
let claude = try QuotaParser.claude(json("""
{"five_hour":{"utilization":12.5,"resets_at":"2026-09-17T04:00:00.000Z"},"seven_day":{"utilization":70,"resets_at":"2026-09-20T04:00:00Z"}}
"""))
check(claude.fiveHour?.used == 12.5 && claude.weekly?.used == 70, "Claude quota fields")
check(claude.fiveHour?.reset != nil && claude.weekly?.reset != nil, "Both ISO timestamp formats")
check(QuotaParser.percent(101) == nil && QuotaParser.percent("8") == nil, "Invalid percentages rejected")
if CommandLine.arguments.count > 1 {
    let rpc = try CodexReader.read(executablePath: CommandLine.arguments[1], timeout: 3)
    check(rpc.fiveHour?.used == 17 && rpc.weekly?.used == 52, "Official RPC handshake and response")
}
print("Passed \(count) checks")

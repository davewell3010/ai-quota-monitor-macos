import Foundation

struct QuotaWindow: Equatable {
    let used: Double
    let reset: Date?
    var remaining: Double { max(0, 100 - used) }
}
struct QuotaSnapshot {
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var fetchedAt = Date()
}
enum QuotaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct QuotaParser {
    static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let n = number.doubleValue
        return n.isFinite && n >= 0 && n <= 100 ? n : nil
    }
    static func codex(_ result: [String: Any]) throws -> QuotaSnapshot {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) else {
            throw QuotaError.message("没有收到 Codex 额度数据，请检查登录。")
        }
        var snapshot = QuotaSnapshot()
        for name in ["primary", "secondary"] {
            guard let window = limits[name] as? [String: Any], let used = percent(window["usedPercent"]) else { continue }
            let reset = (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let value = QuotaWindow(used: used, reset: reset)
            switch window["windowDurationMins"] as? Int {
            case 300: snapshot.fiveHour = value
            case 10080: snapshot.weekly = value
            default: break
            }
        }
        guard snapshot.fiveHour != nil || snapshot.weekly != nil else { throw QuotaError.message("账号未提供五小时或周额度。") }
        return snapshot
    }
    static func claude(_ result: [String: Any]) throws -> QuotaSnapshot {
        func window(_ key: String) -> QuotaWindow? {
            guard let raw = result[key] as? [String: Any], let used = percent(raw["utilization"]) else { return nil }
            var date: Date?
            if let value = raw["resets_at"] as? String {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                date = f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            }
            return QuotaWindow(used: used, reset: date)
        }
        let snapshot = QuotaSnapshot(fiveHour: window("five_hour"), weekly: window("seven_day"))
        guard snapshot.fiveHour != nil || snapshot.weekly != nil else { throw QuotaError.message("Claude 未返回订阅额度；请确认选择了订阅账号。") }
        return snapshot
    }
}
import CoreFoundation

// A short-lived official app-server connection; no model turn is started.
enum CodexExecutable {
    static func find(preferredPath: String? = nil) -> String? {
        let paths = [
            preferredPath ?? "",
            UserDefaults.standard.string(forKey: "codexPath") ?? "",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        for rawPath in paths {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let candidates = path.hasSuffix(".app")
                ? [path + "/Contents/Resources/codex-cli/bin/codex", path + "/Contents/MacOS/codex"]
                : [path]
            if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return executable
            }
        }
        return nil
    }
}

final class CodexReader {
    static func read(executablePath: String? = nil, timeout: TimeInterval = 25) throws -> QuotaSnapshot {
        guard let path = CodexExecutable.find(preferredPath: executablePath) else {
            throw QuotaError.message("未找到 Codex。请安装 Codex 或在设置里选择程序路径。")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let lock = NSLock()
        var buffer = Data(), result: Result<QuotaSnapshot, Error>?
        let finished = DispatchSemaphore(value: 0)
        func complete(_ value: Result<QuotaSnapshot, Error>) {
            lock.lock(); defer { lock.unlock() }
            if result == nil { result = value; finished.signal() }
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { complete(.failure(QuotaError.message("Codex 连接已关闭。请先在 Codex 中登录，再重试。"))); return }
            buffer.append(data)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer[..<end]; buffer.removeSubrange(...end)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = json["id"] as? Int else { continue }
                do {
                    if json["error"] != nil { throw QuotaError.message("Codex 额度请求失败，请检查登录或网络后重试。") }
                    if id == 1 {
                        try send(["method": "initialized"])
                        try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                    } else if id == 2 {
                        complete(.success(try QuotaParser.codex(json["result"] as? [String: Any] ?? [:])))
                    }
                } catch { complete(.failure(error)) }
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        try process.run()
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "ai_quota_card", "version": "1.0.0"]]])
        guard finished.wait(timeout: .now() + timeout) == .success else { throw QuotaError.message("Codex 查询超时，请检查网络。") }
        lock.lock(); let value = result; lock.unlock()
        return try value!.get()
    }
}

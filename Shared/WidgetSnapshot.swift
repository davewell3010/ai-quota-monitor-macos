import Foundation
import OSLog

// Only quota numbers and timestamps are shared; never cookies or access tokens.
struct WidgetQuota: Codable, Equatable {
    var used: Double
    var reset: Date?
}
struct WidgetProviderSnapshot: Codable, Equatable {
    var fiveHour: WidgetQuota?
    var weekly: WidgetQuota?
    var updatedAt: Date?
    var failed: Bool
}
struct WidgetSnapshot: Codable, Equatable {
    var version = 1
    var codex: WidgetProviderSnapshot?
    var claude: WidgetProviderSnapshot?
    var language: String?
    static let empty = WidgetSnapshot()
    static var preview: WidgetSnapshot {
        WidgetSnapshot(
            codex: .init(fiveHour: .init(used: 24, reset: Date().addingTimeInterval(7200)), weekly: .init(used: 55, reset: Date().addingTimeInterval(345600)), updatedAt: Date(), failed: false),
            claude: .init(fiveHour: .init(used: 8, reset: Date().addingTimeInterval(14400)), weekly: .init(used: 39, reset: Date().addingTimeInterval(450000)), updatedAt: Date(), failed: false))
    }
}
struct WidgetLoadResult {
    var snapshot: WidgetSnapshot
    var message: String?
}
enum WidgetSnapshotStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.aiquota.monitor", category: "WidgetSnapshot")
    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AIQuotaAppGroup") as? String ?? "group.io.github.aiquota.monitor"
    }
    static func url() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(domain: "AIQuotaWidget", code: 1, userInfo: [NSLocalizedDescriptionKey: "小组件共享容器不可用，请检查 App Group 和签名配置。"])
        }
        return container.appendingPathComponent("quota-snapshot-v1.json")
    }
    static func load(from file: URL? = nil) -> WidgetSnapshot { read(from: file).snapshot }
    static func read(from file: URL? = nil) -> WidgetLoadResult {
        do {
            let destination = try file ?? url()
            let value = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: destination))
            guard value.version == 1 else { return WidgetLoadResult(snapshot: .empty, message: "额度格式已更新，请重启 App 同步。") }
            logger.info("Snapshot loaded: codex=\(value.codex != nil), claude=\(value.claude != nil)")
            return WidgetLoadResult(snapshot: value, message: nil)
        } catch {
            let error = error as NSError
            logger.error("Snapshot read failed: domain=\(error.domain, privacy: .public), code=\(error.code)")
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return WidgetLoadResult(snapshot: .empty, message: "尚未同步额度，请打开 App 并刷新。")
            }
            return WidgetLoadResult(snapshot: .empty, message: "无法读取共享额度，请打开 App 检查小组件同步状态。")
        }
    }
    static func save(_ value: WidgetSnapshot, to file: URL? = nil) throws {
        let destination = try file ?? url()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: destination, options: .atomic)
    }
}

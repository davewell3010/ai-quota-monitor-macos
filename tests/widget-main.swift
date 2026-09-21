import Foundation

@main struct WidgetChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-quota-widget-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        precondition(WidgetSnapshotStore.load(from: url) == .empty)
        let value = WidgetSnapshot.preview
        try WidgetSnapshotStore.save(value, to: url)
        precondition(WidgetSnapshotStore.load(from: url) == value)
        var unknown = value; unknown.version = 100
        try WidgetSnapshotStore.save(unknown, to: url)
        precondition(WidgetSnapshotStore.load(from: url) == .empty)
        try Data("incomplete".utf8).write(to: url)
        precondition(WidgetSnapshotStore.load(from: url) == .empty)
        let disconnected = WidgetSnapshot(codex: value.codex, claude: .init(fiveHour: nil, weekly: nil, updatedAt: nil, failed: true))
        try WidgetSnapshotStore.save(disconnected, to: url)
        precondition(WidgetSnapshotStore.load(from: url).claude?.fiveHour == nil)
        precondition(WidgetSnapshotStore.read(from: url).message == nil)
        try Data("broken".utf8).write(to: url)
        precondition(WidgetSnapshotStore.read(from: url).message != nil)
        print("Passed 7 widget snapshot checks")
    }
}

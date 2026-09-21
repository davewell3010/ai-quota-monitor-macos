#if WIDGET_SUPPORT
import Foundation
import WidgetKit

extension Store {
    func publishWidget() {
        guard !preview else { return }
        func convert(_ value: QuotaSnapshot?, error: String?) -> WidgetProviderSnapshot {
            WidgetProviderSnapshot(
                fiveHour: value?.fiveHour.map { WidgetQuota(used: $0.used, reset: $0.reset) },
                weekly: value?.weekly.map { WidgetQuota(used: $0.used, reset: $0.reset) },
                updatedAt: value?.fetchedAt, failed: error != nil)
        }
        do {
            let english = UserDefaults.standard.string(forKey: "displayLanguage") == AppLanguage.english.rawValue
            try WidgetSnapshotStore.save(WidgetSnapshot(codex: convert(codex, error: codexError), claude: convert(claude, error: claudeError), language: english ? "en" : "zh-Hans"))
            widgetStatus = english ? "Synced to the native widget. macOS controls its refresh timing." : "已同步到原生小组件；实际刷新时间由 macOS 决定。"
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            let english = UserDefaults.standard.string(forKey: "displayLanguage") == AppLanguage.english.rawValue
            widgetStatus = english ? "Widget sync failed: \(error.localizedDescription)" : "小组件同步失败：\(error.localizedDescription)"
        }
    }
}
#else
extension Store {
    func publishWidget() {}
}
#endif

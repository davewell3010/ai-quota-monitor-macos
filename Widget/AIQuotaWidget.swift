import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var message: String? = nil
}
struct QuotaTimeline: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { QuotaEntry(date: Date(), snapshot: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        if context.isPreview { completion(QuotaEntry(date: Date(), snapshot: .preview)); return }
        let result = WidgetSnapshotStore.read()
        completion(QuotaEntry(date: Date(), snapshot: result.snapshot, message: result.message))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let now = Date()
        let result = WidgetSnapshotStore.read()
        completion(Timeline(entries: [QuotaEntry(date: now, snapshot: result.snapshot, message: result.message)], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}
struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry
    private var english: Bool { entry.snapshot.language == "en" }
    private func t(_ zh: String, _ en: String) -> String { english ? en : zh }
    var body: some View {
        Group {
            if entry.snapshot.codex == nil && entry.snapshot.claude == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Label(t("AI 额度", "AI Quota"), systemImage: "chart.bar.xaxis").font(.headline)
                    Text(t("打开 App 同步额度", "Open the app to sync quota")).font(.callout)
                    Text(entry.message ?? t("首次使用请连接账号，并保持菜单栏 App 运行。", "Connect your accounts and keep the menu bar app running.")).font(.caption).foregroundStyle(.secondary)
                }
            } else if family == .systemSmall {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(t("AI 额度", "AI Quota")).font(.caption.bold()); Spacer(); Text(t("已用", "Used")).font(.caption2).foregroundStyle(.secondary) }
                    compact("Codex", tint: .mint, value: entry.snapshot.codex)
                    compact("Claude", tint: .orange, value: entry.snapshot.claude)
                }
            } else if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    provider("Codex", icon: "terminal", tint: .mint, value: entry.snapshot.codex, detailed: false)
                    Divider()
                    provider("Claude", icon: "sun.max", tint: .orange, value: entry.snapshot.claude, detailed: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Label(t("AI 额度", "AI Quota"), systemImage: "chart.bar.xaxis").font(.headline); Spacer(); Text(t("订阅额度 · 已用", "Subscription quota · Used")).font(.caption2).foregroundStyle(.secondary) }
                    provider("Codex", icon: "terminal", tint: .mint, value: entry.snapshot.codex, detailed: true)
                    Divider()
                    provider("Claude", icon: "sun.max", tint: .orange, value: entry.snapshot.claude, detailed: true)
                }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "aiquota://show"))
    }
    func compact(_ name: String, tint: Color, value: WidgetProviderSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.caption.bold()).foregroundStyle(tint)
                Spacer()
                if value?.failed == true { Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange) }
            }
            HStack {
                Text("5h \(percent(value?.fiveHour))")
                Spacer(minLength: 2)
                Text("\(t("周", "Week")) \(percent(value?.weekly))")
            }.font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.8)
            if let date = value?.updatedAt { Text(date, style: .relative).font(.system(size: 8)).foregroundStyle(.secondary) }
        }
    }
    func provider(_ name: String, icon: String, tint: Color, value: WidgetProviderSnapshot?, detailed: Bool) -> some View {
        VStack(alignment: .leading, spacing: detailed ? 10 : 7) {
            HStack {
                Label(name, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                Spacer(minLength: 0)
                if value?.failed == true { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).font(.caption2) }
            }
            row(t("五小时", "Five hours"), value: value?.fiveHour, tint: value?.failed == true ? .gray : tint, detailed: detailed, isWeekly: false)
            row(t("本周", "This week"), value: value?.weekly, tint: value?.failed == true ? .gray : tint, detailed: detailed, isWeekly: true)
            HStack(spacing: 3) {
                if value?.failed == true { Text(t("更新失败", "Update failed")) }
                else { Text(t("更新于", "Updated")) }
                if let date = value?.updatedAt { Text(date, style: .relative) }
                else { Text(t("待连接", "Not connected")) }
            }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func row(_ title: String, value: WidgetQuota?, tint: Color, detailed: Bool, isWeekly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(percent(value)).font(.system(size: detailed ? 18 : 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            ProgressView(value: value.map { min(100, max(0, $0.used)) } ?? 0, total: 100)
                .tint((value?.used ?? 0) >= 90 ? .red : tint)
            if detailed {
                HStack(spacing: 3) {
                    if let date = value?.reset {
                        if date > entry.date { Text(date, style: .relative); Text(t("后重置 ·", "to reset ·")); Text(resetPoint(date, isWeekly: isWeekly)) }
                        else { Text(t("已到重置时间 · 待同步", "Reset due · Waiting to sync")) }
                    } else { Text(value == nil ? t("暂无额度数据", "No quota data") : t("重置时间未知", "Reset time unknown")) }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    func resetPoint(_ date: Date, isWeekly: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: english ? "en_US" : "zh_CN")
        formatter.dateFormat = isWeekly ? (english ? "MMM d, HH:mm" : "M月d日 HH:mm") : "HH:mm"
        return formatter.string(from: date)
    }
    func percent(_ value: WidgetQuota?) -> String { value.map { String(format: "%.0f%%", $0.used) } ?? "—" }
}

struct AIQuotaWidget: Widget {
    let kind = "AIQuotaCombined"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuotaTimeline()) { QuotaWidgetView(entry: $0) }
            .configurationDisplayName("AI 额度")
            .description("查看 Codex 和 Claude 的五小时、周额度。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
@main
struct AIQuotaWidgetBundle: WidgetBundle {
    var body: some Widget { AIQuotaWidget() }
}

import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
}

enum CustomThemeImageStore {
    static var imageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AI额度", isDirectory: true).appendingPathComponent("custom-background.png")
    }

    static var hasImage: Bool { FileManager.default.fileExists(atPath: imageURL.path) }

    static func load() -> NSImage? { NSImage(contentsOf: imageURL) }

    static func save(from sourceURL: URL) throws {
        guard let source = NSImage(contentsOf: sourceURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sourceSize = source.size
        let longestSide = max(sourceSize.width, sourceSize.height)
        let scale = longestSide > 2400 ? 2400 / longestSide : 1
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: imageURL, options: .atomic)
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var codex: QuotaSnapshot?
    @Published var claude: QuotaSnapshot?
    @Published var codexError: String?
    @Published var claudeError: String?
    @Published var codexBusy = false
    @Published var claudeBusy = false
    @Published var showSettings = false
    @Published var widgetStatus: String?
    let web = ClaudeWeb()
    var timer: Timer?
    var lastAttempt = Date.distantPast
    let preview = CommandLine.arguments.contains("--preview")
    var busy: Bool { codexBusy || claudeBusy }
    init() {
        if preview {
            codex = QuotaSnapshot(fiveHour: .init(used: 24, reset: Date().addingTimeInterval(8400)), weekly: .init(used: 48, reset: Date().addingTimeInterval(210000)))
            if CommandLine.arguments.contains("--preview-claude-disconnected") {
                claudeError = "首次使用请连接 Claude。"
            } else {
                claude = QuotaSnapshot(fiveHour: .init(used: 36, reset: Date().addingTimeInterval(5400)), weekly: .init(used: 62, reset: Date().addingTimeInterval(320000)))
            }
        }
    }
    func start() { configureTimer(); if !preview { refresh() } }
    func configureTimer() {
        timer?.invalidate()
        let interval = UserDefaults.standard.object(forKey: "interval") as? Double ?? 60
        guard interval > 0 && !preview else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        guard !preview && !busy && Date().timeIntervalSince(lastAttempt) >= 5 else { return }
        lastAttempt = Date(); codexBusy = true; claudeBusy = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<QuotaSnapshot, Error> in
                Result { try CodexReader.read() }
            }.value
            switch result {
            case .success(let snapshot): codex = snapshot; codexError = nil
            case .failure(let error): codexError = error.localizedDescription
            }
            codexBusy = false
            publishWidget()
        }
        Task {
            do { claude = try await web.read(); claudeError = nil }
            catch {
                if let quota = error as? QuotaError { claudeError = quota.localizedDescription }
                else { claudeError = "Claude 读取失败，请连接账号并检查网页验证或网络。" }
            }
            claudeBusy = false
            publishWidget()
        }
    }
    func disconnectClaude() {
        guard !claudeBusy else { return }
        claudeBusy = true
        Task { await web.logout(); claude = nil; claudeError = "已退出，请重新连接 Claude。"; claudeBusy = false; publishWidget() }
    }
}

struct CardSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

enum CardTheme: String, CaseIterable, Identifiable {
    case system, light, dark, ocean, sunset, academy, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "自动"
        case .light: "云光白"
        case .dark: "深空黑"
        case .ocean: "海盐蓝"
        case .sunset: "暮霞紫"
        case .academy: "星辉学院"
        case .custom: "自定义"
        }
    }
    func title(language: String) -> String {
        guard language == AppLanguage.english.rawValue else { return title }
        return switch self {
        case .system: "Auto"
        case .light: "Cloud White"
        case .dark: "Deep Space"
        case .ocean: "Ocean Blue"
        case .sunset: "Sunset Violet"
        case .academy: "Star Academy"
        case .custom: "Custom"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        case .ocean: "water.waves"
        case .sunset: "sun.horizon.fill"
        case .academy: "sparkles"
        case .custom: "photo.fill"
        }
    }
    var previewColors: [Color] {
        switch self {
        case .system: [.white, Color(red: 0.08, green: 0.11, blue: 0.14)]
        case .light: [.white, Color(red: 0.88, green: 0.96, blue: 0.96)]
        case .dark: [Color(red: 0.15, green: 0.20, blue: 0.24), Color(red: 0.03, green: 0.05, blue: 0.07)]
        case .ocean: [Color(red: 0.52, green: 0.86, blue: 0.95), Color(red: 0.22, green: 0.52, blue: 0.82)]
        case .sunset: [Color(red: 0.95, green: 0.48, blue: 0.40), Color(red: 0.34, green: 0.18, blue: 0.50)]
        case .academy: [Color(red: 0.93, green: 0.69, blue: 0.30), Color(red: 0.09, green: 0.17, blue: 0.38)]
        case .custom: [Color(red: 0.40, green: 0.44, blue: 0.52), Color(red: 0.12, green: 0.14, blue: 0.18)]
        }
    }
}

struct CardView: View {
    @ObservedObject var store: Store
    @AppStorage("appearance") var appearance = "dark"
    @AppStorage("displayLanguage") private var displayLanguage = AppLanguage.simplifiedChinese.rawValue
    @AppStorage("customThemeRevision") private var customThemeRevision = 0
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var customThemeImage = CustomThemeImageStore.load()

    private var theme: CardTheme { CardTheme(rawValue: appearance) ?? .dark }
    private func t(_ zh: String, _ en: String) -> String { displayLanguage == AppLanguage.english.rawValue ? en : zh }

    private var usesLightPalette: Bool {
        switch theme {
        case .system: systemColorScheme == .light
        case .light, .ocean: true
        case .dark, .sunset, .academy, .custom: false
        }
    }

    private var forcedColorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light, .ocean: .light
        case .dark, .sunset, .academy, .custom: .dark
        }
    }

    private var themeAccent: Color {
        switch theme {
        case .system, .light, .dark: .mint
        case .ocean: Color(red: 0.04, green: 0.52, blue: 0.78)
        case .sunset: Color(red: 1.0, green: 0.50, blue: 0.40)
        case .academy, .custom: Color(red: 0.95, green: 0.72, blue: 0.34)
        }
    }

    @ViewBuilder private var cardSurface: some View {
        switch theme {
        case .system where usesLightPalette, .light:
            LinearGradient(
                colors: [Color.white, Color(red: 0.955, green: 0.975, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .ocean:
            LinearGradient(
                colors: [Color(red: 0.91, green: 0.975, blue: 1.0), Color(red: 0.77, green: 0.90, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .sunset:
            LinearGradient(
                colors: [Color(red: 0.24, green: 0.13, blue: 0.31), Color(red: 0.075, green: 0.065, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .academy:
            GeometryReader { geometry in
                ZStack {
                    if let image = Bundle.main.image(forResource: "星辉魔法学院") {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Color(red: 0.055, green: 0.10, blue: 0.23)
                    }
                    LinearGradient(
                        colors: [Color.black.opacity(0.22), Color(red: 0.025, green: 0.045, blue: 0.12).opacity(0.48)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        case .custom:
            GeometryReader { geometry in
                ZStack {
                    if let image = customThemeImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        LinearGradient(
                            colors: [Color(red: 0.15, green: 0.18, blue: 0.24), Color(red: 0.045, green: 0.055, blue: 0.075)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    LinearGradient(colors: [Color.black.opacity(0.20), Color.black.opacity(0.50)], startPoint: .top, endPoint: .bottom)
                }
            }
        default:
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color(red: 0.055, green: 0.075, blue: 0.09).opacity(0.86))
        }
    }

    private var providerSurface: Color {
        switch theme {
        case .ocean: Color.white.opacity(0.62)
        case .sunset: Color.white.opacity(0.075)
        case .academy: Color(red: 0.035, green: 0.075, blue: 0.17).opacity(0.76)
        case .custom: Color.black.opacity(0.68)
        default: usesLightPalette ? Color.white.opacity(0.84) : Color.primary.opacity(0.045)
        }
    }

    private var providerBorder: Color {
        (theme == .academy || theme == .custom) ? themeAccent.opacity(0.24) : (usesLightPalette ? Color.black.opacity(0.055) : Color.white.opacity(0.055))
    }

    private var progressTrack: Color {
        (theme == .academy || theme == .custom) ? Color.white.opacity(0.16) : (usesLightPalette ? Color.black.opacity(0.075) : Color.white.opacity(0.09))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 20, weight: .semibold)).foregroundStyle(themeAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("AI 额度", "AI Quota")).font(.system(size: 19, weight: .bold))
                    Text(store.preview ? t("外观预览 · 示例数据", "Theme preview · Sample data") : t("你的 AI 使用仪表盘", "Your AI usage dashboard")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy).help("立即刷新")
                Button { store.showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }.help("设置")
            }.buttonStyle(.plain)
            provider("Codex", symbol: "terminal", tint: themeAccent, snapshot: store.codex, error: store.codexError, busy: store.codexBusy)
            provider("Claude", symbol: "sun.max", tint: Color(red: 0.88, green: 0.57, blue: 0.40), snapshot: store.claude, error: store.claudeError, busy: store.claudeBusy)
            HStack {
                Circle().fill(store.busy ? .orange : themeAccent).frame(width: 5, height: 5)
                Text(store.busy ? t("正在同步额度…", "Syncing quota…") : t("订阅额度使用率 · 非 token 数量", "Subscription usage · Not token counts")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { NSApp.delegate.flatMap { $0 as? AppDelegate }?.hideCard() } label: { Image(systemName: "minus") }.buttonStyle(.plain).help("收起到菜单栏")
            }
        }
        .padding(22).frame(width: 356)
        .background(GeometryReader { geometry in Color.clear.preference(key: CardSizeKey.self, value: geometry.size) })
        .onPreferenceChange(CardSizeKey.self) { size in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.resizeCard(size) }
        }
        .onChange(of: customThemeRevision) { customThemeImage = CustomThemeImageStore.load() }
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke((theme == .academy || theme == .custom) ? themeAccent.opacity(0.42) : (usesLightPalette ? Color.black.opacity(0.09) : Color.white.opacity(0.10)), lineWidth: 1))
        .preferredColorScheme(forcedColorScheme)
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
    }
    func provider(_ name: String, symbol: String, tint: Color, snapshot: QuotaSnapshot?, error: String?, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(name).font(.system(size: 15, weight: .semibold))
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                else if error != nil { Text(snapshot == nil ? t("待连接", "Not connected") : t("更新失败", "Update failed")).foregroundStyle(.orange).font(.system(size: 10)) }
                else if let date = snapshot?.fetchedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(age(date, now: context.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if let snapshot {
                quotaRow(t("五小时", "Five hours"), window: snapshot.fiveHour, tint: tint, stale: error != nil)
                quotaRow(t("本周", "This week"), window: snapshot.weekly, tint: tint, stale: error != nil)
                if let error {
                    Text(error + t(" 当前保留的是上次成功数据。", " Showing the last successful data."))
                        .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: busy ? "arrow.triangle.2.circlepath" : "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 20)).foregroundStyle(busy ? tint : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(busy ? t("正在读取额度", "Loading quota") : (name == "Claude" ? t("尚未连接 Claude", "Claude not connected") : t("暂时无法读取额度", "Quota unavailable")))
                            .font(.system(size: 12, weight: .semibold))
                        Text(busy ? t("请稍候…", "Please wait…") : (name == "Claude" ? t("连接后即可显示额度和重置时间。", "Connect to show quota and reset times.") : t("请检查设置后重新刷新。", "Check settings and refresh.")))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            if name == "Claude" {
                Button { store.web.showLogin() } label: {
                    HStack { Text(snapshot == nil ? t("连接 Claude", "Connect Claude") : t("打开 Claude 账号", "Open Claude account")); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(providerSurface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(providerBorder, lineWidth: 1))
    }
    func quotaRow(_ label: String, window: QuotaWindow?, tint: Color, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(window.map { String(format: "%.0f", $0.used) } ?? "—").font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(t("% 已用", "% used")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Capsule().fill(progressTrack)
                Capsule().fill(stale ? Color.gray : (window?.used ?? 0) >= 90 ? .red : (window?.used ?? 0) >= 75 ? .orange : tint)
                    .frame(width: geo.size.width * CGFloat((window?.used ?? 0) / 100))
            }.frame(height: 5)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack {
                    Text(window.map { t("剩余 \(Int($0.remaining.rounded()))%", "\(Int($0.remaining.rounded()))% left") } ?? t("暂无额度数据", "No quota data"))
                    Spacer()
                    Text(resetLabel(window?.reset, now: context.date))
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    func age(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? t("刚刚更新", "Updated now") : t("\(seconds / 60) 分钟前更新", "Updated \(seconds / 60)m ago")
    }
    func resetLabel(_ date: Date?, now: Date) -> String {
        guard let date else { return t("重置时间未知", "Reset time unknown") }
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return t("已到重置时间 · 待同步", "Reset due · Waiting to sync") }
        if minutes >= 1440 { return t("\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置", "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h") }
        if minutes >= 60 { return t("\(minutes / 60) 小时 \(minutes % 60) 分后重置", "Resets in \(minutes / 60)h \(minutes % 60)m") }
        return t("\(minutes) 分钟后重置", "Resets in \(minutes)m")
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @AppStorage("interval") var interval = 60.0
    @AppStorage("appearance") var appearance = "dark"
    @AppStorage("onTop") var onTop = true
    @AppStorage("showOnLaunch") var showOnLaunch = true
    @AppStorage("claudeOrg") var claudeOrg = ""
    @AppStorage("codexPath") var codexPath = ""
    @AppStorage("customThemeRevision") var customThemeRevision = 0
    @AppStorage("displayLanguage") var displayLanguage = AppLanguage.simplifiedChinese.rawValue
    @State var loginMessage = ""
    @State var customImageMessage = ""
    @State private var customThemeImage = CustomThemeImageStore.load()
    @Environment(\.colorScheme) private var systemColorScheme

    private var theme: CardTheme { CardTheme(rawValue: appearance) ?? .dark }
    private func t(_ zh: String, _ en: String) -> String { displayLanguage == AppLanguage.english.rawValue ? en : zh }

    private var usesLightPalette: Bool {
        switch theme {
        case .system: systemColorScheme == .light
        case .light, .ocean: true
        case .dark, .sunset, .academy, .custom: false
        }
    }

    private var forcedColorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light, .ocean: .light
        case .dark, .sunset, .academy, .custom: .dark
        }
    }

    private var settingsAccent: Color {
        switch theme {
        case .system, .light, .dark: .mint
        case .ocean: Color(red: 0.04, green: 0.52, blue: 0.78)
        case .sunset: Color(red: 1.0, green: 0.50, blue: 0.40)
        case .academy, .custom: Color(red: 0.95, green: 0.72, blue: 0.34)
        }
    }

    @ViewBuilder private var settingsBackground: some View {
        switch theme {
        case .system where usesLightPalette, .light:
            LinearGradient(colors: [.white, Color(red: 0.94, green: 0.97, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ocean:
            LinearGradient(colors: [Color(red: 0.89, green: 0.97, blue: 1.0), Color(red: 0.68, green: 0.86, blue: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sunset:
            LinearGradient(colors: [Color(red: 0.27, green: 0.13, blue: 0.34), Color(red: 0.07, green: 0.055, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .academy, .custom:
            GeometryReader { geometry in
                ZStack {
                    let image = theme == .academy ? Bundle.main.image(forResource: "星辉魔法学院") : customThemeImage
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Color(red: 0.045, green: 0.07, blue: 0.14)
                    }
                    Color(red: 0.025, green: 0.045, blue: 0.10).opacity(0.86)
                    LinearGradient(colors: [settingsAccent.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .center)
                }
            }
        default:
            LinearGradient(colors: [Color(red: 0.105, green: 0.125, blue: 0.145), Color(red: 0.045, green: 0.055, blue: 0.065)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var sectionSurface: Color {
        if usesLightPalette { return Color.white.opacity(theme == .ocean ? 0.58 : 0.72) }
        return theme == .academy || theme == .custom ? Color(red: 0.035, green: 0.075, blue: 0.17).opacity(0.72) : Color.white.opacity(0.055)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(t("卡片设置", "Card Settings")).font(.title3.bold()); Spacer(); Button(t("完成", "Done")) { store.showSettings = false } }
            Picker(t("显示语言", "Display Language"), selection: $displayLanguage) {
                Text("简体中文").tag(AppLanguage.simplifiedChinese.rawValue)
                Text("English").tag(AppLanguage.english.rawValue)
            }
            .pickerStyle(.segmented)
            .onChange(of: displayLanguage) {
                store.publishWidget()
                (NSApp.delegate as? AppDelegate)?.rebuildMenu()
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(t("主题风格", "Theme")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(CardTheme.allCases) { theme in
                        Button { appearance = theme.rawValue } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(LinearGradient(colors: theme.previewColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .overlay(Image(systemName: theme.symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(theme == .light ? Color.gray : Color.white))
                                    .frame(width: 22, height: 22)
                                Text(theme.title(language: displayLanguage)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                if appearance == theme.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                    .foregroundStyle(settingsAccent)
                                }
                            }
                            .padding(.horizontal, 9).frame(height: 38)
                            .background(appearance == theme.rawValue ? settingsAccent.opacity(0.16) : sectionSurface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(appearance == theme.rawValue ? settingsAccent.opacity(0.58) : Color.primary.opacity(0.09), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }
                if appearance == CardTheme.custom.rawValue {
                    HStack(spacing: 10) {
                        Button(CustomThemeImageStore.hasImage ? t("更换背景图片…", "Change image…") : t("选择背景图片…", "Choose image…")) { chooseCustomImage() }
                        Text(customImageMessage.isEmpty ? t("支持 PNG、JPEG、HEIC，仅保存在本机。", "PNG, JPEG or HEIC. Stored only on this Mac.") : customImageMessage)
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Picker(t("自动刷新", "Auto Refresh"), selection: $interval) {
                Text(t("手动", "Manual")).tag(0.0); Text(t("30 秒", "30 seconds")).tag(30.0); Text(t("1 分钟", "1 minute")).tag(60.0); Text(t("2 分钟", "2 minutes")).tag(120.0); Text(t("5 分钟", "5 minutes")).tag(300.0)
            }.onChange(of: interval) { store.configureTimer() }
            Toggle(t("始终置顶", "Always on Top"), isOn: $onTop).onChange(of: onTop) { (NSApp.delegate as? AppDelegate)?.updateLevel() }
            Toggle(t("启动时显示悬浮卡片", "Show Card at Launch"), isOn: $showOnLaunch)
            if let message = store.widgetStatus {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Text(t("桌面右键 → 编辑小组件 → 搜索 AI 额度。可收起卡片并让 App 在菜单栏运行。", "Right-click the desktop → Edit Widgets → search AI Quota. The app can keep running in the menu bar.")).font(.caption).foregroundStyle(.secondary)
            }
            if !store.web.organizations.isEmpty {
                Picker(t("Claude 组织", "Claude Organization"), selection: $claudeOrg) {
                    Text(t("自动（仅单个账号）", "Automatic (single account)")).tag("")
                    ForEach(store.web.organizations, id: \.id) { org in Text(org.name).tag(org.id) }
                }.onChange(of: claudeOrg) { store.claude = nil; store.refresh() }
            }
            HStack {
                Button(t("登录 Claude", "Sign in to Claude")) { store.web.showLogin() }
                Button(t("退出 Claude", "Sign out of Claude")) { store.disconnectClaude() }.disabled(store.claudeBusy)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(t("Codex 程序路径（留空自动查找）", "Codex executable path (leave blank to detect)")).font(.caption)
                TextField("/Applications/…/codex", text: $codexPath).textFieldStyle(.roundedBorder)
            }
            Button(SMAppService.mainApp.status == .enabled ? t("关闭开机启动", "Disable Launch at Login") : t("开启开机启动", "Enable Launch at Login")) {
                do {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister(); loginMessage = "开机启动已关闭" }
                    else { try SMAppService.mainApp.register(); loginMessage = "已申请开机启动，可在系统设置的登录项中确认。" }
                } catch { loginMessage = "设置失败；请先把 App 放入应用程序文件夹，再重试。" }
            }
            if !loginMessage.isEmpty { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
            Text(t("拖动卡片空白处可移动。登录保存在本机 WebKit 中；仅向 Claude 官方站点查询。Codex 使用本机登录状态。网页额度接口变化时可能需要更新工具。", "Drag an empty area to move the card. Claude sign-in stays in local WebKit storage and only queries the official Claude site. Codex uses your local sign-in."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 380)
        .background(settingsBackground)
        .tint(settingsAccent)
        .preferredColorScheme(forcedColorScheme)
        .onChange(of: customThemeRevision) { customThemeImage = CustomThemeImageStore.load() }
    }

    func chooseCustomImage() {
        let panel = NSOpenPanel()
        panel.title = t("选择自定义主题背景", "Choose a Custom Theme Background")
        panel.prompt = t("使用这张图片", "Use This Image")
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try CustomThemeImageStore.save(from: url)
                customThemeRevision += 1
                appearance = CardTheme.custom.rawValue
                customImageMessage = t("背景已保存并应用。", "Background saved and applied.")
            } catch {
                customImageMessage = t("图片读取失败，请换一张图片重试。", "Could not read this image. Please try another one.")
            }
        }
    }
}

final class QuotaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var status: NSStatusItem!
    var store: Store!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = Store()
        panel = QuotaPanel(contentRect: NSRect(x: 0, y: 0, width: 356, height: 530), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CardView(store: store))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setFrameAutosaveName("AIQuotaCardPosition")
        if !panel.setFrameUsingName("AIQuotaCardPosition"), let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 380, y: screen.visibleFrame.maxY - 30))
        }
        updateLevel()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "AI 额度")
        rebuildMenu()
        
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1, store.preview {
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }
            NSApp.terminate(nil); return
        }
        if UserDefaults.standard.object(forKey: "showOnLaunch") as? Bool ?? true { panel.orderFrontRegardless() }; store.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "aiquota" }) else { return }
        panel.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
    }
    func resizeCard(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let old = panel.frame
        if abs(old.height - size.height) > 1 {
            panel.setFrame(NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height), display: true)
        }
    }
    func updateLevel() { panel.level = (UserDefaults.standard.object(forKey: "onTop") as? Bool ?? true) ? .floating : .normal }
    func rebuildMenu() {
        let english = UserDefaults.standard.string(forKey: "displayLanguage") == AppLanguage.english.rawValue
        func t(_ zh: String, _ en: String) -> String { english ? en : zh }
        let menu = NSMenu()
        menu.addItem(withTitle: t("显示 / 隐藏额度卡片", "Show / Hide Quota Card"), action: #selector(toggleCard), keyEquivalent: "")
        menu.addItem(withTitle: t("立即刷新", "Refresh Now"), action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: t("设置…", "Settings…"), action: #selector(settings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: t("退出 AI 额度", "Quit AI Quota"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status.menu = menu
    }
    func hideCard() { panel.orderOut(nil) }
    @objc func toggleCard() { if panel.isVisible { hideCard() } else { panel.orderFrontRegardless() } }
    @objc func refresh() { store.refresh() }
    @objc func settings() { panel.orderFrontRegardless(); store.showSettings = true; NSApp.activate(ignoringOtherApps: true) }
    @objc func quit() { NSApp.terminate(nil) }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

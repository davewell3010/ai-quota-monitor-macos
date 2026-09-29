import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
}

enum CardLayout: String, CaseIterable, Identifiable {
    case vertical
    case horizontal

    var id: String { rawValue }

    static func prefersHorizontal(size: CGSize) -> Bool {
        let verticalScale = min(size.width / 356, size.height / 620)
        let horizontalScale = min(size.width / 680, size.height / 420)
        return horizontalScale > verticalScale
    }
}

enum CardResizeEdge {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

    var left: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var right: Bool { self == .right || self == .topRight || self == .bottomRight }
    var top: Bool { self == .top || self == .topLeft || self == .topRight }
    var bottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
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
    @Published var codexLoginBusy = false
    @Published var codexLoginError: String?
    @Published var claudeBusy = false
    @Published var showSettings = false
    @Published var widgetStatus: String?
    @Published var manualCardSize: CGSize?
    @Published var resizeLayoutLock: Bool?
    let web = ClaudeWeb()
    var timer: Timer?
    private var codexLoginProcess: Process?
    var lastAttempt = Date.distantPast
    let preview = CommandLine.arguments.contains("--preview")
    var busy: Bool { codexBusy || claudeBusy }
    init() {
        let width = UserDefaults.standard.double(forKey: "manualCardWidth")
        let height = UserDefaults.standard.double(forKey: "manualCardHeight")
        if width >= 300 && height >= 420 { manualCardSize = CGSize(width: width, height: height) }
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
    func connectCodex() {
        guard !codexLoginBusy else { return }
        guard let path = CodexExecutable.find() else {
            codexLoginError = "未找到 Codex 程序，请先选择程序路径。"
            return
        }
        codexLoginError = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["login"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.codexLoginProcess === finished else { return }
                self.codexLoginProcess = nil
                self.codexLoginBusy = false
                if finished.terminationStatus == 0 {
                    self.lastAttempt = .distantPast
                    self.refresh()
                } else {
                    self.codexLoginError = "Codex 登录未完成，请在浏览器中完成授权后重试。"
                }
            }
        }
        do {
            try process.run()
            codexLoginProcess = process
            codexLoginBusy = true
        } catch {
            codexLoginError = "无法启动 Codex 登录，请检查程序路径。"
        }
    }
    func cancelCodexLogin() {
        guard let process = codexLoginProcess else { return }
        codexLoginProcess = nil
        codexLoginBusy = false
        if process.isRunning { process.terminate() }
    }
}

struct CardSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct ComicPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cut: CGFloat = 14
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
        path.closeSubpath()
        return path
    }
}

enum CardTheme: String, CaseIterable, Identifiable {
    case system, light, dark, ocean, sunset, academy, orbit, comic, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "自动"
        case .light: "云光白"
        case .dark: "深空黑"
        case .ocean: "海盐蓝"
        case .sunset: "暮霞紫"
        case .academy: "星辉学院"
        case .orbit: "星轨仪表"
        case .comic: "英雄漫画"
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
        case .orbit: "Star Orbit"
        case .comic: "Hero Comic"
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
        case .orbit: "circle.hexagongrid"
        case .comic: "bolt.shield.fill"
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
        case .orbit: [Color(red: 0.93, green: 0.72, blue: 0.40), Color(red: 0.12, green: 0.72, blue: 0.86), Color(red: 0.04, green: 0.09, blue: 0.20)]
        case .comic: [Color(red: 0.91, green: 0.15, blue: 0.23), Color(red: 0.13, green: 0.36, blue: 0.90), Color(red: 0.08, green: 0.11, blue: 0.20)]
        case .custom: [Color(red: 0.40, green: 0.44, blue: 0.52), Color(red: 0.12, green: 0.14, blue: 0.18)]
        }
    }
}

struct CardView: View {
    @ObservedObject var store: Store
    @AppStorage("appearance") var appearance = "dark"
    @AppStorage("cardLayout") private var cardLayout = CardLayout.vertical.rawValue
    @AppStorage("displayLanguage") private var displayLanguage = AppLanguage.simplifiedChinese.rawValue
    @AppStorage("customThemeRevision") private var customThemeRevision = 0
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var customThemeImage = CustomThemeImageStore.load()
    @State private var verticalContentHeight: CGFloat = 620
    @State private var horizontalContentHeight: CGFloat = 420

    private var theme: CardTheme { CardTheme(rawValue: appearance) ?? .dark }
    private var usesHorizontalLayout: Bool {
        if let locked = store.resizeLayoutLock { return locked }
        if let manualSize = store.manualCardSize, !store.preview { return CardLayout.prefersHorizontal(size: manualSize) }
        return cardLayout == CardLayout.horizontal.rawValue || (store.preview && CommandLine.arguments.contains("--preview-horizontal"))
    }
    private func t(_ zh: String, _ en: String) -> String { displayLanguage == AppLanguage.english.rawValue ? en : zh }

    private var usesLightPalette: Bool {
        switch theme {
        case .system: systemColorScheme == .light
        case .light, .ocean: true
        case .dark, .sunset, .academy, .orbit, .comic, .custom: false
        }
    }

    private var forcedColorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light, .ocean: .light
        case .dark, .sunset, .academy, .orbit, .comic, .custom: .dark
        }
    }

    private var themeAccent: Color {
        switch theme {
        case .system, .light, .dark: .mint
        case .ocean: Color(red: 0.04, green: 0.52, blue: 0.78)
        case .sunset: Color(red: 1.0, green: 0.50, blue: 0.40)
        case .academy, .orbit, .custom: Color(red: 0.95, green: 0.72, blue: 0.34)
        case .comic: Color(red: 1.0, green: 0.27, blue: 0.34)
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
        case .comic:
            ZStack {
                LinearGradient(colors: [Color(red: 0.075, green: 0.11, blue: 0.23), Color(red: 0.025, green: 0.045, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { context, size in
                    for x in stride(from: CGFloat(0), through: size.width, by: 18) {
                        for y in stride(from: CGFloat(0), through: size.height, by: 18) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(0.075)))
                        }
                    }
                }
                .allowsHitTesting(false)
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: geometry.size.width * 0.72, y: 0))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * 0.30))
                        path.closeSubpath()
                    }
                    .fill(Color(red: 0.91, green: 0.15, blue: 0.23).opacity(0.24))
                }
                .allowsHitTesting(false)
            }
        case .orbit:
            ZStack {
                LinearGradient(colors: [Color(red: 0.025, green: 0.065, blue: 0.16), Color(red: 0.015, green: 0.035, blue: 0.085)], startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geometry in
                    Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.34).opacity(0.48))
                        .position(x: geometry.size.width * 0.79, y: 29)
                    Image(systemName: "sparkle").font(.system(size: 7)).foregroundStyle(Color.cyan.opacity(0.44))
                        .position(x: geometry.size.width * 0.12, y: geometry.size.height * 0.47)
                    Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.30))
                        .position(x: geometry.size.width * 0.87, y: geometry.size.height * 0.82)
                }
                .allowsHitTesting(false)
            }
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
        case .orbit: Color(red: 0.04, green: 0.075, blue: 0.16).opacity(0.92)
        case .comic: Color(red: 0.055, green: 0.085, blue: 0.18).opacity(0.94)
        case .custom: Color.black.opacity(0.68)
        default: usesLightPalette ? Color.white.opacity(0.84) : Color.primary.opacity(0.045)
        }
    }

    private var providerBorder: Color {
        (theme == .academy || theme == .orbit || theme == .comic || theme == .custom) ? themeAccent.opacity(0.24) : (usesLightPalette ? Color.black.opacity(0.055) : Color.white.opacity(0.055))
    }

    private var progressTrack: Color {
        (theme == .academy || theme == .orbit || theme == .comic || theme == .custom) ? Color.white.opacity(0.16) : (usesLightPalette ? Color.black.opacity(0.075) : Color.white.opacity(0.09))
    }

    private var cardContents: some View {
        VStack(alignment: .leading, spacing: theme == .orbit || theme == .comic ? 12 : 17) {
            HStack(spacing: 10) {
                Image(systemName: theme == .comic ? "bolt.shield.fill" : "chart.bar.xaxis")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(themeAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("AI 额度", "AI Quota")).font(.system(size: 19, weight: .bold))
                    Text(store.preview ? t("外观预览 · 示例数据", "Theme preview · Sample data") : t("你的 AI 使用仪表盘", "Your AI usage dashboard")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy).help("立即刷新")
                Button { store.showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }.help("设置")
            }.buttonStyle(.plain)
            if theme == .comic && usesHorizontalLayout {
                HStack(alignment: .top, spacing: 12) {
                    comicProvider("Codex", symbol: "terminal", snapshot: store.codex, error: store.codexError, busy: store.codexBusy, accent: comicRed)
                    comicProvider("Claude", symbol: "sun.max", snapshot: store.claude, error: store.claudeError, busy: store.claudeBusy, accent: comicBlue)
                }
            } else if theme == .comic {
                comicProvider("Codex", symbol: "terminal", snapshot: store.codex, error: store.codexError, busy: store.codexBusy, accent: comicRed)
                comicProvider("Claude", symbol: "sun.max", snapshot: store.claude, error: store.claudeError, busy: store.claudeBusy, accent: comicBlue)
            } else if theme == .orbit && usesHorizontalLayout {
                HStack(alignment: .top, spacing: 12) {
                    orbitProvider("Codex", symbol: "terminal", snapshot: store.codex, error: store.codexError, busy: store.codexBusy)
                    orbitProvider("Claude", symbol: "sun.max", snapshot: store.claude, error: store.claudeError, busy: store.claudeBusy)
                }
            } else if theme == .orbit {
                orbitProvider("Codex", symbol: "terminal", snapshot: store.codex, error: store.codexError, busy: store.codexBusy)
                orbitProvider("Claude", symbol: "sun.max", snapshot: store.claude, error: store.claudeError, busy: store.claudeBusy)
            } else if usesHorizontalLayout {
                HStack(alignment: .top, spacing: 14) {
                    provider("Codex", symbol: "terminal", tint: themeAccent, snapshot: store.codex, error: store.codexError, busy: store.codexBusy)
                    provider("Claude", symbol: "sun.max", tint: Color(red: 0.88, green: 0.57, blue: 0.40), snapshot: store.claude, error: store.claudeError, busy: store.claudeBusy)
                }
            } else {
                provider("Codex", symbol: "terminal", tint: themeAccent, snapshot: store.codex, error: store.codexError, busy: store.codexBusy)
                provider("Claude", symbol: "sun.max", tint: Color(red: 0.88, green: 0.57, blue: 0.40), snapshot: store.claude, error: store.claudeError, busy: store.claudeBusy)
            }
            HStack {
                Circle().fill(store.busy ? .orange : themeAccent).frame(width: 5, height: 5)
                Text(store.busy ? t("正在同步额度…", "Syncing quota…") : t("订阅额度使用率 · 非 token 数量", "Subscription usage · Not token counts")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { NSApp.delegate.flatMap { $0 as? AppDelegate }?.hideCard() } label: { Image(systemName: "minus") }.buttonStyle(.plain).help("收起到菜单栏")
            }
        }
        .padding(theme == .orbit || theme == .comic ? 18 : 22).frame(width: usesHorizontalLayout ? 680 : 356)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in Color.clear.preference(key: CardSizeKey.self, value: geometry.size) })
        .onPreferenceChange(CardSizeKey.self) { size in
            guard size.width >= 300, size.height >= 200 else { return }
            DispatchQueue.main.async {
                if usesHorizontalLayout {
                    if abs(horizontalContentHeight - size.height) > 1 { horizontalContentHeight = size.height }
                } else {
                    if abs(verticalContentHeight - size.height) > 1 { verticalContentHeight = size.height }
                }
                if store.manualCardSize == nil { (NSApp.delegate as? AppDelegate)?.resizeCard(size) }
            }
        }
        .onAppear {
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.resizeCardToFit() }
        }
        .onChange(of: cardLayout) {
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.resizeCardToFit() }
        }
        .onChange(of: appearance) {
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.resizeCardToFit() }
        }
        .onChange(of: customThemeRevision) { customThemeImage = CustomThemeImageStore.load() }
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke((theme == .academy || theme == .orbit || theme == .comic || theme == .custom) ? themeAccent.opacity(0.42) : (usesLightPalette ? Color.black.opacity(0.09) : Color.white.opacity(0.10)), lineWidth: 1))
        .preferredColorScheme(forcedColorScheme)
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
    }

    var body: some View {
        ZStack {
            if let manualSize = store.manualCardSize, !store.preview {
                ZStack(alignment: .topLeading) {
                    let designWidth: CGFloat = usesHorizontalLayout ? 680 : 356
                    let designHeight = usesHorizontalLayout ? horizontalContentHeight : verticalContentHeight
                    let scale = max(0.01, min(manualSize.width / designWidth, manualSize.height / designHeight))
                    cardSurface
                    cardContents
                        .fixedSize()
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: 0, height: 0, alignment: .topLeading)
                        .offset(x: (manualSize.width - designWidth * scale) / 2,
                                y: (manualSize.height - designHeight * scale) / 2)
                }
                .frame(width: manualSize.width, height: manualSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(themeAccent.opacity(0.38), lineWidth: 1))
            } else {
                cardContents
            }
        }
        .overlay { if !store.preview { resizeHandles } }
    }

    private var resizeHandles: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                resizeGrip(.top, width: max(0, width - 42), height: 10).position(x: width / 2, y: 5)
                resizeGrip(.bottom, width: max(0, width - 42), height: 10).position(x: width / 2, y: height - 5)
                resizeGrip(.left, width: 10, height: max(0, height - 42)).position(x: 5, y: height / 2)
                resizeGrip(.right, width: 10, height: max(0, height - 42)).position(x: width - 5, y: height / 2)
                resizeGrip(.topLeft, width: 21, height: 21).position(x: 10.5, y: 10.5)
                resizeGrip(.topRight, width: 21, height: 21).position(x: width - 10.5, y: 10.5)
                resizeGrip(.bottomLeft, width: 21, height: 21).position(x: 10.5, y: height - 10.5)
                resizeGrip(.bottomRight, width: 21, height: 21).position(x: width - 10.5, y: height - 10.5)
            }
        }
    }

    private func resizeGrip(_ edge: CardResizeEdge, width: CGFloat, height: CGFloat) -> some View {
        Rectangle().fill(Color.clear)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .overlay {
                if edge.left || edge.right {
                    if edge.top || edge.bottom {
                        Circle().fill(themeAccent.opacity(0.72)).frame(width: 5, height: 5)
                    } else {
                        Capsule().fill(themeAccent.opacity(0.58)).frame(width: 2, height: 18)
                    }
                } else {
                    Capsule().fill(themeAccent.opacity(0.58)).frame(width: 18, height: 2)
                }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    (NSApp.delegate as? AppDelegate)?.updateManualResize(edge: edge, translation: value.translation)
                }
                .onEnded { _ in (NSApp.delegate as? AppDelegate)?.endManualResize() })
            .help(t("拖动边缘调整卡片大小", "Drag to resize the card"))
    }
    private var comicRed: Color { Color(red: 0.96, green: 0.19, blue: 0.27) }
    private var comicBlue: Color { Color(red: 0.24, green: 0.48, blue: 1.0) }
    private var comicGold: Color { Color(red: 1.0, green: 0.81, blue: 0.35) }

    private func comicProvider(_ name: String, symbol: String, snapshot: QuotaSnapshot?, error: String?, busy: Bool, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 25, height: 25)
                    .background(accent, in: RoundedRectangle(cornerRadius: 5))
                Text(name).font(.system(size: 16, weight: .heavy, design: .rounded))
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.mini) }
                else if error != nil {
                    Text(snapshot == nil ? t("待连接", "Not connected") : t("更新失败", "Update failed"))
                        .foregroundStyle(comicGold).font(.system(size: 9, weight: .bold))
                } else if let date = snapshot?.fetchedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(age(date, now: context.date)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            Rectangle().fill(accent).frame(height: 3)
            if let snapshot {
                comicQuotaRow(t("五小时", "FIVE HOURS"), window: snapshot.fiveHour, accent: accent)
                comicQuotaRow(t("本周", "THIS WEEK"), window: snapshot.weekly, accent: accent)
                if error != nil {
                    Text(t("上次成功数据 · 请刷新", "Last successful data · Refresh to retry"))
                        .font(.system(size: 9)).foregroundStyle(comicGold)
                }
            } else {
                Spacer(minLength: 2)
                HStack(spacing: 9) {
                    Image(systemName: busy ? "arrow.triangle.2.circlepath" : "bolt.slash.fill")
                        .font(.system(size: 23, weight: .bold)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(busy ? t("正在读取额度", "Loading quota") : name == "Claude" ? t("尚未连接 Claude", "Claude not connected") : t("暂无额度数据", "Quota unavailable"))
                            .font(.system(size: 11, weight: .bold))
                        Text(busy ? t("请稍候…", "Please wait…") : t("连接后显示额度和重置时间", "Connect to show quota and reset times"))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 2)
            }
            Spacer(minLength: 0)
            if name == "Claude" {
                Button { store.web.showLogin() } label: {
                    HStack {
                        Text(snapshot == nil ? t("连接 Claude", "Connect Claude") : t("打开 Claude 账号", "Open Claude account"))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(comicGold)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: usesHorizontalLayout || name == "Claude" ? 260 : 220, alignment: .topLeading)
        .background(ComicPanelShape().fill(LinearGradient(colors: [accent.opacity(0.20), Color(red: 0.045, green: 0.07, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(ComicPanelShape().stroke(accent.opacity(0.78), lineWidth: 1.2))
    }

    private func comicQuotaRow(_ label: String, window: QuotaWindow?, accent: Color) -> some View {
        let color = (window?.used ?? 0) >= 90 ? comicGold : accent
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(comicGold)
                Spacer()
                Text(window.map { t("已用 \(Int($0.used.rounded()))%", "\(Int($0.used.rounded()))% USED") } ?? "—")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                    .font(.system(size: 27, weight: .black, design: .rounded)).monospacedDigit()
                    .foregroundStyle(window == nil ? Color.secondary : color)
                Text(t("剩余", "LEFT")).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(comicResetPoint(window?.reset)).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            GeometryReader { geometry in
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle().fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(100, max(0, window?.used ?? 0)) / 100))
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
    }

    private func comicResetPoint(_ date: Date?) -> String {
        guard let date else { return t("重置时间未知", "Reset unknown") }
        guard date > Date() else { return t("待同步", "Waiting to sync") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: displayLanguage == AppLanguage.english.rawValue ? "en_US" : "zh_CN")
        formatter.dateFormat = displayLanguage == AppLanguage.english.rawValue ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
    private var orbitGold: Color { Color(red: 0.94, green: 0.74, blue: 0.43) }
    private var orbitCyan: Color { Color(red: 0.28, green: 0.80, blue: 0.89) }
    private func orbitColor(_ window: QuotaWindow?, fallback: Color) -> Color {
        (window?.used ?? 0) >= 90 ? .red : fallback
    }

    private func orbitProvider(_ name: String, symbol: String, snapshot: QuotaSnapshot?, error: String?, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(name == "Claude" ? Color.orange : orbitGold)
                Text(name).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.mini) }
                else if error != nil { Text(snapshot == nil ? t("待连接", "Not connected") : t("更新失败", "Update failed")).foregroundStyle(orbitGold).font(.system(size: 10)) }
                else if let date = snapshot?.fetchedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(age(date, now: context.date)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            if let snapshot {
                orbitGauge(fiveHour: snapshot.fiveHour, weekly: snapshot.weekly, size: 104)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Label(t("五小时", "Five hours"), systemImage: "circle.fill").foregroundStyle(orbitColor(snapshot.fiveHour, fallback: orbitGold))
                    Label(t("本周", "This week"), systemImage: "circle.fill").foregroundStyle(orbitColor(snapshot.weekly, fallback: orbitCyan))
                }
                .font(.system(size: 9, weight: .medium))
                .frame(maxWidth: .infinity)
                orbitDataRow(t("五小时", "Five hours"), window: snapshot.fiveHour, color: orbitColor(snapshot.fiveHour, fallback: orbitGold))
                orbitDataRow(t("本周", "This week"), window: snapshot.weekly, color: orbitColor(snapshot.weekly, fallback: orbitCyan))
                if error != nil {
                    Text(t("上次成功数据 · 请刷新", "Last successful data · Refresh to retry"))
                        .font(.system(size: 9)).foregroundStyle(orbitGold)
                }
            } else {
                VStack(spacing: 8) {
                    orbitGauge(fiveHour: nil, weekly: nil, size: 100)
                    Text(busy ? t("正在读取额度…", "Loading quota…") : name == "Claude" ? t("连接后显示额度与重置时间", "Connect to show quota and reset times") : t("暂无额度数据，请检查连接", "Quota unavailable. Check connection."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 150)
            }
            if name == "Claude" {
                Button { store.web.showLogin() } label: {
                    HStack {
                        Text(snapshot == nil ? t("连接 Claude", "Connect Claude") : t("打开 Claude 账号", "Open Claude account"))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(orbitGold)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 274, alignment: .topLeading)
        .background(providerSurface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(orbitGold.opacity(0.25), lineWidth: 1))
    }

    private func orbitGauge(fiveHour: QuotaWindow?, weekly: QuotaWindow?, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(orbitGold.opacity(0.16), lineWidth: 1).padding(-8)
            Circle().stroke(orbitCyan.opacity(0.14), lineWidth: 1).padding(-3)
            Circle().stroke(orbitCyan.opacity(0.13), lineWidth: 8)
            if let weekly {
                Circle().trim(from: 0, to: CGFloat(min(100, weekly.remaining) / 100))
                    .stroke(orbitColor(weekly, fallback: orbitCyan), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: orbitCyan.opacity(0.45), radius: 6)
            }
            Circle().stroke(orbitGold.opacity(0.13), lineWidth: 7).padding(16)
            if let fiveHour {
                Circle().trim(from: 0, to: CGFloat(min(100, fiveHour.remaining) / 100))
                    .stroke(orbitColor(fiveHour, fallback: orbitGold), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(16)
                    .shadow(color: orbitGold.opacity(0.4), radius: 5)
            }
            VStack(spacing: 0) {
                Text(t("五小时剩余", "5h left")).font(.system(size: 8)).foregroundStyle(.secondary)
                Text(fiveHour.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                    .font(.system(size: size < 120 ? 25 : 29, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fiveHour == nil ? Color.secondary : orbitColor(fiveHour, fallback: orbitGold))
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("五小时剩余 \(fiveHour.map { "\(Int($0.remaining.rounded()))%" } ?? "未知")，本周剩余 \(weekly.map { "\(Int($0.remaining.rounded()))%" } ?? "未知")", "Five hours remaining \(fiveHour.map { "\(Int($0.remaining.rounded()))%" } ?? "unknown"), weekly remaining \(weekly.map { "\(Int($0.remaining.rounded()))%" } ?? "unknown")"))
    }

    private func orbitDataRow(_ label: String, window: QuotaWindow?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label).foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(window.map { t("已用 \(Int($0.used.rounded()))%", "\(Int($0.used.rounded()))% used") } ?? "—")
                    .foregroundStyle(color).monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(resetLabel(window?.reset, now: context.date, isWeekly: true))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 9))
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
                quotaRow(t("五小时", "Five hours"), window: snapshot.fiveHour, tint: tint, stale: error != nil, isWeekly: false)
                quotaRow(t("本周", "This week"), window: snapshot.weekly, tint: tint, stale: error != nil, isWeekly: true)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(providerSurface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(providerBorder, lineWidth: 1))
    }
    func quotaRow(_ label: String, window: QuotaWindow?, tint: Color, stale: Bool, isWeekly: Bool) -> some View {
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
                    Text(resetLabel(window?.reset, now: context.date, isWeekly: isWeekly))
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    func age(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? t("刚刚更新", "Updated now") : t("\(seconds / 60) 分钟前更新", "Updated \(seconds / 60)m ago")
    }
    func resetLabel(_ date: Date?, now: Date, isWeekly: Bool) -> String {
        guard let date else { return t("重置时间未知", "Reset time unknown") }
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return t("已到重置时间 · 待同步", "Reset due · Waiting to sync") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: displayLanguage == AppLanguage.english.rawValue ? "en_US" : "zh_CN")
        formatter.dateFormat = isWeekly ? (displayLanguage == AppLanguage.english.rawValue ? "MMM d, HH:mm" : "M月d日 HH:mm") : "HH:mm"
        let point = formatter.string(from: date)
        if minutes >= 1440 { return t("\(minutes / 1440)天\((minutes % 1440) / 60)小时后重置 · \(point)", "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h · \(point)") }
        if minutes >= 60 { return t("\(minutes / 60)小时\(minutes % 60)分后重置 · \(point)", "Resets in \(minutes / 60)h \(minutes % 60)m · \(point)") }
        return t("\(minutes)分钟后重置 · \(point)", "Resets in \(minutes)m · \(point)")
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
    @AppStorage("cardLayout") var cardLayout = CardLayout.vertical.rawValue
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
        case .dark, .sunset, .academy, .orbit, .comic, .custom: false
        }
    }

    private var forcedColorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light, .ocean: .light
        case .dark, .sunset, .academy, .orbit, .comic, .custom: .dark
        }
    }

    private var settingsAccent: Color {
        switch theme {
        case .system, .light, .dark: .mint
        case .ocean: Color(red: 0.04, green: 0.52, blue: 0.78)
        case .sunset: Color(red: 1.0, green: 0.50, blue: 0.40)
        case .academy, .orbit, .custom: Color(red: 0.95, green: 0.72, blue: 0.34)
        case .comic: Color(red: 0.96, green: 0.19, blue: 0.27)
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
        case .orbit:
            LinearGradient(colors: [Color(red: 0.035, green: 0.09, blue: 0.20), Color(red: 0.015, green: 0.035, blue: 0.085)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .comic:
            LinearGradient(colors: [Color(red: 0.15, green: 0.045, blue: 0.10), Color(red: 0.04, green: 0.07, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            LinearGradient(colors: [Color(red: 0.105, green: 0.125, blue: 0.145), Color(red: 0.045, green: 0.055, blue: 0.065)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var sectionSurface: Color {
        if usesLightPalette { return Color.white.opacity(theme == .ocean ? 0.58 : 0.72) }
        return theme == .academy || theme == .orbit || theme == .comic || theme == .custom ? Color(red: 0.035, green: 0.075, blue: 0.17).opacity(0.72) : Color.white.opacity(0.055)
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
            Picker(store.manualCardSize == nil ? t("布局方向", "Layout") : t("预设布局方向", "Preset Layout"), selection: $cardLayout) {
                Label(t("竖版", "Vertical"), systemImage: "rectangle.portrait").tag(CardLayout.vertical.rawValue)
                Label(t("横版", "Horizontal"), systemImage: "rectangle.split.2x1").tag(CardLayout.horizontal.rawValue)
            }
            .pickerStyle(.segmented)
            .onChange(of: cardLayout) { (NSApp.delegate as? AppDelegate)?.resetManualCardSize() }
            Text(t("拖动卡片的四角或边缘可调整大小；自定义尺寸会自动选择横版或竖版。", "Drag any corner or edge to resize; custom sizes choose a horizontal or vertical layout automatically."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let size = store.manualCardSize {
                HStack {
                    Text(t("自定义尺寸 \(Int(size.width)) × \(Int(size.height)) · 拖动边框可调整，自动适配横竖排列", "Custom size \(Int(size.width)) × \(Int(size.height)) · Drag an edge to resize; layout adapts automatically"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(t("恢复预设", "Reset Size")) { (NSApp.delegate as? AppDelegate)?.resetManualCardSize() }
                        .font(.system(size: 10))
                }
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
                HStack {
                    Button(t("选择程序…", "Choose Program…")) { chooseCodexProgram() }
                    Button(t("粘贴路径", "Paste Path")) { pasteCodexPath() }
                    Button(t("复制路径", "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(codexPath, forType: .string) }
                        .disabled(codexPath.isEmpty)
                }
                HStack {
                    Button(store.codexLoginBusy ? t("取消登录", "Cancel Sign-In") : t("登录 Codex", "Sign in to Codex")) {
                        if store.codexLoginBusy { store.cancelCodexLogin() }
                        else { store.connectCodex() }
                    }
                    if store.codexLoginBusy {
                        ProgressView().controlSize(.small)
                        Text(t("请在浏览器完成登录…", "Complete sign-in in your browser…"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = store.codexLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if let error = store.codexError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
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

    func chooseCodexProgram() {
        let panel = NSOpenPanel()
        panel.title = t("选择 Codex 程序", "Choose the Codex Program")
        panel.prompt = t("选择", "Choose")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard CodexExecutable.find(preferredPath: url.path) == url.path ||
                    (url.path.hasSuffix(".app") && CodexExecutable.find(preferredPath: url.path)?.hasPrefix(url.path + "/") == true) else {
                store.codexLoginError = t("请选择 Codex 可执行文件或 ChatGPT.app。", "Choose a Codex executable or ChatGPT.app.")
                return
            }
            codexPath = url.path
            store.codexLoginError = nil
            store.lastAttempt = .distantPast
            store.refresh()
        }
    }

    func pasteCodexPath() {
        guard let pasted = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty else { return }
        codexPath = pasted
        store.codexLoginError = nil
        store.lastAttempt = .distantPast
        store.refresh()
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
    private var resizeStartFrame: NSRect?
    private var resizeStartEdge: CardResizeEdge?
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
        panel.setFrame(fitToVisibleFrame(panel.frame), display: false)
        resizeCardToFit()
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
        guard let panel, store.manualCardSize == nil, size.width > 0, size.height > 0 else { return }
        let old = panel.frame
        let target = fitToVisibleFrame(NSRect(x: old.maxX - size.width, y: old.maxY - size.height, width: size.width, height: size.height))
        if abs(old.width - target.width) > 1 || abs(old.height - target.height) > 1 ||
            abs(old.minX - target.minX) > 1 || abs(old.minY - target.minY) > 1 {
            panel.setFrame(target, display: true)
        }
    }
    func resizeCardToFit() {
        guard resizeStartFrame == nil, let host = panel?.contentView as? NSHostingView<CardView> else { return }
        host.layoutSubtreeIfNeeded()
        if let size = store.manualCardSize {
            let old = panel.frame
            panel.setFrame(fitToVisibleFrame(NSRect(x: old.maxX - size.width, y: old.maxY - size.height, width: size.width, height: size.height)), display: true)
            return
        }
        resizeCard(host.fittingSize)
    }
    func updateManualResize(edge: CardResizeEdge, translation: CGSize) {
        guard let panel else { return }
        if resizeStartFrame == nil || resizeStartEdge != edge {
            resizeStartFrame = panel.frame
            resizeStartEdge = edge
            store.resizeLayoutLock = store.manualCardSize.map { CardLayout.prefersHorizontal(size: $0) }
                ?? (UserDefaults.standard.string(forKey: "cardLayout") == CardLayout.horizontal.rawValue)
        }
        guard let start = resizeStartFrame else { return }
        let visible = (NSScreen.screens.first { $0.frame.intersects(start) } ?? NSScreen.main)?.visibleFrame ?? start
        let width = min(max(edge.left ? start.width - translation.width : edge.right ? start.width + translation.width : start.width, 300), max(300, visible.width - 12))
        let height = min(max(edge.top ? start.height - translation.height : edge.bottom ? start.height + translation.height : start.height, 420), max(420, visible.height - 12))
        let x = edge.left ? start.maxX - width : start.minX
        let y = edge.bottom ? start.maxY - height : start.minY
        let target = fitToVisibleFrame(NSRect(x: x, y: y, width: width, height: height))
        panel.setFrame(target, display: true)
        store.manualCardSize = target.size
    }
    func endManualResize() {
        guard resizeStartFrame != nil, let size = store.manualCardSize else { return }
        resizeStartFrame = nil
        resizeStartEdge = nil
        UserDefaults.standard.set(Double(size.width), forKey: "manualCardWidth")
        UserDefaults.standard.set(Double(size.height), forKey: "manualCardHeight")
        store.resizeLayoutLock = nil
    }
    func resetManualCardSize() {
        resizeStartFrame = nil
        resizeStartEdge = nil
        store.resizeLayoutLock = nil
        store.manualCardSize = nil
        UserDefaults.standard.removeObject(forKey: "manualCardWidth")
        UserDefaults.standard.removeObject(forKey: "manualCardHeight")
        DispatchQueue.main.async { self.resizeCardToFit() }
    }
    func resizeCardWidth(_ width: CGFloat) {
        guard let panel, width > 0, abs(panel.frame.width - width) > 1 else { return }
        let old = panel.frame
        let target = NSRect(x: old.maxX - width, y: old.minY, width: width, height: old.height)
        panel.setFrame(fitToVisibleFrame(target), display: true)
    }
    private func fitToVisibleFrame(_ rect: NSRect) -> NSRect {
        guard let visible = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame else { return rect }
        return NSRect(
            x: min(max(rect.minX, visible.minX), max(visible.minX, visible.maxX - rect.width)),
            y: min(max(rect.minY, visible.minY), max(visible.minY, visible.maxY - rect.height)),
            width: rect.width,
            height: rect.height
        )
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

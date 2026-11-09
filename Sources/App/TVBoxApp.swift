import AppKit
import SwiftUI

@main
struct TVBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup("TVBox") {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.store)
                .environmentObject(coordinator.engine)
                .frame(minWidth: 900, minHeight: 600)
                .background(Palette.background)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            // 去掉「New」菜单项：电视播放器不需要多窗口文档语义。
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

/// 全局协调器：持有数据仓库与播放器，装配键盘遥控，负责启动流程。
final class AppCoordinator: ObservableObject {
    let store = ChannelStore()
    let engine = PlaybackEngine()

    @Published var showingSettings: Bool = false
    @Published var osdVisible: Bool = false
    /// 数字键输入缓冲（OSD 实时显示）。
    @Published var numberInput: String = ""
    /// 搜索框焦点（Tab / ⌘F 进入）。
    @Published var searchFocused: Bool = false
    /// 侧栏当前是否可见（布局的真实来源）。
    /// 持久化键 `sidebar.collapsed` 只在**非全屏**时写入；全屏里的 S 只做临时收起/呼出。
    @Published private(set) var isSidebarVisible: Bool
    /// 是否处于系统全屏（窗口通知驱动，驱动「进全屏自动收侧栏」）。
    @Published private(set) var isFullScreen: Bool = false

    private var keyMonitor: Any?
    private var numberTimer: Timer?
    private var osdTimer: Timer?
    private var fullscreenObservers: [NSObjectProtocol] = []
    /// 进全屏那一刻的侧栏状态，退全屏时恢复。
    private var sidebarStateBeforeFullscreen: Bool?
    private var hasBootstrapped = false
    private let osdTimeout: Double = 3
    private let numberTimeout: Double = 1.5
    private let sidebarCollapsedKey = "sidebar.collapsed"

    init() {
        // 记住上次的侧栏展开/收起偏好；没存过默认展开。
        let persisted = UserDefaults.standard.object(forKey: sidebarCollapsedKey) as? Bool
        isSidebarVisible = !(persisted ?? false)
        registerFullscreenObservers()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        numberTimer?.invalidate()
        osdTimer?.invalidate()
        for observer in fullscreenObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 启动

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        store.load()
        installKeyboardMonitor()
        bumpOSD()

        // 目录就绪后自动开台：上次看的 → 收藏第一个 → 央视 1 台。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            if let channel = self.store.startupChannel() {
                self.play(channel)
            } else {
                self.osdVisible = false
            }
            // 后台增量刷新（约 3.7MB 慢请求，绝不阻塞 UI）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.store.refreshCatalog()
            }
        }
    }

    // MARK: - 切台

    /// 当前台是否处于「后台已在处理」的状态（此时重复选台不该重建播放器）。
    private var isBusyOnSameChannel: Bool {
        switch engine.state.status {
        case .playing, .buffering, .preparing, .switching: return true
        case .idle, .paused, .failed: return false
        }
    }

    func play(_ channel: Channel) {
        // 已经在这个台上（且不是失败/暂停态）时只刷 OSD，不重建 AVPlayer，
        // 否则重复按当前台号会黑屏闪一下并重新拉流。
        // 覆盖 playing / buffering / preparing / switching：这几种状态下后台已经在
        // 拉流或正在切备用源，重建播放器只会让画面黑一下，没有任何收益。
        if engine.state.channel?.id == channel.id, isBusyOnSameChannel {
            store.setCurrent(channel)
            bumpOSD()
            return
        }
        store.setCurrent(channel)
        engine.play(channel: channel)
        NSLog("[TVBox] 切台 → %@ %@（%d 条源）",
              channel.formattedNumber, channel.name, channel.streams.count)
        bumpOSD()
    }

    func zap(to channel: Channel) {
        play(channel)
    }

    /// 上/下一个频道（循环）。
    func zap(step: Int) {
        guard let next = store.channel(offsetFrom: store.currentChannelID, step: step) else { return }
        play(next)
    }

    func showSettings() {
        showingSettings = true
    }

    func toggleFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        window.toggleFullScreen(nil)
        bumpOSD()
    }

    // MARK: - 侧栏收起/展开

    /// 快捷键 S / 工具栏按钮：切换侧栏。
    /// 全屏里只临时切换（退出全屏恢复进全屏前的状态），平时才写持久化偏好。
    func toggleSidebar() {
        isSidebarVisible.toggle()
        guard !isFullScreen else { return }
        UserDefaults.standard.set(!isSidebarVisible, forKey: sidebarCollapsedKey)
    }

    private func registerFullscreenObservers() {
        let center = NotificationCenter.default
        fullscreenObservers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isFullScreen = true
            // 全屏 = 纯画面：记住进全屏前的侧栏状态，退全屏时恢复。
            self.sidebarStateBeforeFullscreen = self.isSidebarVisible
            self.isSidebarVisible = false
        })
        fullscreenObservers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isFullScreen = false
            if let saved = self.sidebarStateBeforeFullscreen {
                self.isSidebarVisible = saved
            }
            self.sidebarStateBeforeFullscreen = nil
        })
    }

    // MARK: - OSD

    func bumpOSD() {
        osdVisible = true
        osdTimer?.invalidate()
        let timer = Timer(timeInterval: osdTimeout, repeats: false) { [weak self] _ in
            self?.osdVisible = false
        }
        osdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - 键盘遥控

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyDown(event)
        }
    }

    /// 正在文本框里打字时不抢按键（搜索框需要正常输入）。
    private var isTypingInTextField: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers ?? ""

        // ⌘F / Tab：进入搜索
        if flags.contains(.command), characters.lowercased() == "f" {
            searchFocused = true
            return nil
        }
        if isTypingInTextField {
            if event.keyCode == 53 {  // Esc
                NSApp.keyWindow?.makeFirstResponder(nil)
                searchFocused = false
                return nil
            }
            return event
        }
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return event
        }

        switch event.keyCode {
        case 123:  // ←
            engine.seek(by: -15)
            bumpOSD()
            return nil
        case 124:  // →
            engine.seekToLiveEdge()
            bumpOSD()
            return nil
        case 125:  // ↓
            zap(step: 1)
            return nil
        case 126:  // ↑
            zap(step: -1)
            return nil
        case 49:  // 空格
            engine.togglePause()
            bumpOSD()
            return nil
        case 48:  // Tab
            searchFocused = true
            return nil
        case 53:  // Esc
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                clearNumberInput()
            }
            return nil
        case 36, 76:  // Return / 小键盘 Enter
            commitNumberInput()
            return nil
        default:
            break
        }

        if characters.count == 1, let character = characters.lowercased().first {
            if let digit = character.wholeNumberValue, character.isNumber {
                appendNumber(digit)
                return nil
            }
            switch character {
            case "f":
                toggleFullScreen()
                return nil
            case "s":
                toggleSidebar()
                return nil
            case "m":
                engine.toggleMute()
                bumpOSD()
                return nil
            case "+", "=":
                engine.setVolume(engine.volume + 0.1)
                bumpOSD()
                return nil
            case "-", "_":
                engine.setVolume(engine.volume - 0.1)
                bumpOSD()
                return nil
            default:
                break
            }
        }
        return event
    }

    // MARK: - 数字键直选

    private func appendNumber(_ digit: Int) {
        numberInput += String(digit)
        NSLog("[TVBox] 数字键 %d → 输入缓冲「%@」", digit, numberInput)
        bumpOSD()
        numberTimer?.invalidate()

        // 如果再多输一位也已经无台可选，立刻切台（手感接近机顶盒）。
        if !canExtend(numberInput) {
            commitNumberInput()
            return
        }

        let timer = Timer(timeInterval: numberTimeout, repeats: false) { [weak self] _ in
            self?.commitNumberInput()
        }
        numberTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 是否还存在以此串为前缀的台号。
    private func canExtend(_ prefix: String) -> Bool {
        for digit in 0...9 {
            let candidate = prefix + String(digit)
            if store.channels.contains(where: { $0.formattedNumber.hasPrefix(candidate) }) {
                return true
            }
        }
        return false
    }

    private func commitNumberInput() {
        numberTimer?.invalidate()
        numberTimer = nil
        let digits = numberInput
        numberInput = ""
        guard !digits.isEmpty else { return }
        if let channel = store.channel(matching: digits) {
            NSLog("[TVBox] 台号输入「%@」→ 命中 %@", digits, channel.formattedNumber)
            play(channel)
        } else {
            NSLog("[TVBox] 台号输入「%@」→ 无此频道", digits)
            bumpOSD()
        }
    }

    private func clearNumberInput() {
        numberTimer?.invalidate()
        numberTimer = nil
        numberInput = ""
    }
}

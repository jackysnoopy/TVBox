import AVFoundation
import Foundation

/// 播放活性监视器：只回答「这一条流现在到底行不行」，不关心切台策略。
///
/// 失败判定（任一成立即回调 `.failed`）：
///   1. `AVPlayerItem.status == .failed`
///   2. `AVPlayerItemFailedToPlayToEndTime` 通知
///   3. 首帧 `openTimeout` 秒内没出画面（死源不会自己报错，必须兜这一层）
///   4. 出过画面后 `currentTime` 连续 `stallTimeout` 秒没有任何变化
///
/// 注意 `AVPlayerItemPlaybackStalled` **不算失败**：它只是「缓冲空了」的瞬时通知，
/// 中高码率直播（4K 补源 18~24Mbps、6 秒一个分片）几乎每次跨分片都会发一次。
/// 早期把它当致命错误，结果一条能救回来的流会被立刻 replaceCurrentItem(nil) 掉，
/// 屏幕上就只剩黑屏 + 一路往下切备用源。现在统一降级为 `.buffering`。
///
/// 卡流判定同理不能太急：实测这条 GITV CDN 的补源每 15~25 秒会冻一次，
/// 冻结 5~11 秒后自己追到直播边缘恢复（位置会往回跳一下），
/// 大约播 60 秒后整个会话还会失效重连。用 6 秒阈值等于把能自愈的流全误杀，
/// 所以放宽到 `stallTimeout`（20 秒）；重连由 PlaybackEngine 的多轮重试兜住。
final class PlaybackMonitor {

    enum Event {
        case playing
        case buffering
        case resolution(String)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    private let player: AVPlayer
    private var openTimeout: Double
    private var stallTimeout: Double
    private let tickInterval: Double = 0.5

    private var statusObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var ticker: Timer?
    private var currentItem: AVPlayerItem?

    private var lastTime: Double = 0
    private var lastProgressDate = Date()
    private var attemptStartedAt = Date()
    private var hasStartedPlaying = false
    private var isPaused = false
    private var isFinished = false

    init(player: AVPlayer, openTimeout: Double = 15, stallTimeout: Double = 20) {
        self.player = player
        self.openTimeout = openTimeout
        self.stallTimeout = stallTimeout
        registerNotifications()
    }

    deinit {
        stop()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - 生命周期

    /// 开始监视新的播放条目（会自动结束上一次监视）。
    func start(item: AVPlayerItem) {
        stop()
        currentItem = item
        isFinished = false
        isPaused = false
        hasStartedPlaying = false
        lastTime = 0
        lastProgressDate = Date()
        attemptStartedAt = Date()

        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self, self.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.markPlaying()
                case .failed:
                    self.reportFailure(item.error?.localizedDescription ?? "资源加载失败")
                default:
                    break
                }
            }
        }

        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      self.currentItem === item,
                      !self.isPaused,
                      !self.isFinished,
                      self.hasStartedPlaying else { return }
                if !item.isPlaybackLikelyToKeepUp {
                    self.onEvent?(.buffering)
                }
            }
        }

        sizeObservation = item.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self, self.currentItem === item else { return }
                let size = item.presentationSize
                guard size.width > 1, size.height > 1 else { return }
                self.onEvent?(.resolution("\(Int(size.width))x\(Int(size.height))"))
            }
        }

        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// 按当前这条源调整超时。4K 补源（18~24Mbps、6 秒一个分片）首帧要 25~30 秒，
    /// 用默认 15 秒会把它当死源误杀，所以由引擎按流特征放宽。
    func setTimeouts(open: Double? = nil, stall: Double? = nil) {
        if let open = open, open > 0 { openTimeout = open }
        if let stall = stall, stall > 0 { stallTimeout = stall }
    }

    /// 结束监视并释放观察。
    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        keepUpObservation?.invalidate()
        keepUpObservation = nil
        sizeObservation?.invalidate()
        sizeObservation = nil
        ticker?.invalidate()
        ticker = nil
        currentItem = nil
    }

    /// 用户暂停时不做卡流判定，避免暂停久了被误杀。
    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { lastProgressDate = Date() }
    }

    /// 手动 seek 后重置进度基线。
    func noteProgressReset() {
        lastProgressDate = Date()
        lastTime = player.currentItem?.currentTime().seconds ?? 0
    }

    // MARK: - 内部

    private func registerNotifications() {
        let center = NotificationCenter.default
        let stalled = center.addObserver(forName: .AVPlayerItemPlaybackStalled,
                                        object: nil,
                                        queue: .main) { [weak self] note in
            guard let self = self,
                  let item = note.object as? AVPlayerItem,
                  self.currentItem === item,
                  self.hasStartedPlaying,
                  !self.isPaused,
                  !self.isFinished else { return }
            // 单次停滞只说明「这一瞬间没有可播数据」，AVPlayer 通常下一个分片就恢复了。
            // 这里只把 OSD 切到缓冲态；要不要放弃这条源由 tick() 的 stallTimeout 说话。
            self.onEvent?(.buffering)
        }
        let failedToEnd = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                            object: nil,
                                            queue: .main) { [weak self] note in
            guard let self = self,
                  let item = note.object as? AVPlayerItem,
                  self.currentItem === item else { return }
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "播放中断"
            self.reportFailure(message)
        }
        notificationTokens = [stalled, failedToEnd]
    }

    private func markPlaying() {
        hasStartedPlaying = true
        lastProgressDate = Date()
        onEvent?(.playing)
    }

    private func reportFailure(_ reason: String) {
        guard !isFinished else { return }
        isFinished = true
        ticker?.invalidate()
        ticker = nil
        onEvent?(.failed(reason))
    }

    private func tick() {
        guard let item = currentItem, !isPaused, !isFinished else { return }

        guard hasStartedPlaying else {
            if Date().timeIntervalSince(attemptStartedAt) > openTimeout {
                reportFailure("首帧超时 \(Int(openTimeout)) 秒")
            }
            return
        }

        let seconds = item.currentTime().seconds
        // 用「位置有变化」而不是「位置变大」判断是否在走：直播流追到直播边缘后
        // 位置会往回跳（例如 59.9 → 54.0），用大小比较会把恢复误判成继续卡住。
        if seconds.isFinite, abs(seconds - lastTime) > 0.05 {
            lastTime = seconds
            lastProgressDate = Date()
            return
        }

        // 冻结不算立刻死：这条 CDN 的补源每十几二十秒就会冻一次、几秒后自己追回来，
        // 用 6 秒阈值等于把能自愈的流全杀掉。给足 stallTimeout 秒再判死。
        if Date().timeIntervalSince(lastProgressDate) > stallTimeout {
            reportFailure("卡流超过 \(Int(stallTimeout)) 秒")
        }
    }
}

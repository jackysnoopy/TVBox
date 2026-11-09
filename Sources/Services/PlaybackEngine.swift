import AVFoundation
import Combine
import Foundation

/// AVPlayer 封装：多源故障切换、退避重试、传输控制。
/// 活性判定交给 `PlaybackMonitor`，这里只负责「失败之后怎么办」。
final class PlaybackEngine: ObservableObject {

    @Published private(set) var state = PlaybackState()
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var volume: Double = 1.0

    let player = AVPlayer()

    private var channel: Channel?
    private var candidates: [StreamEndpoint] = []
    private var candidateIndex: Int = 0
    private var attemptInCycle: Int = 0
    private var cycle: Int = 0
    /// 全部候选都失败后自动重试的轮数上限；超过则停在「无可用源」等用户手动重试。
    private let maxCycles: Int = 3
    private let retryDelayBetweenCycles: Double = 5

    private var retryWork: DispatchWorkItem?
    private var monitor: PlaybackMonitor?
    private var isPausedByUser = false

    private static let defaultUserAgent = "VLC/3.0.20 LibVLC/3.0.20"

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1.0

        let monitor = PlaybackMonitor(player: player)
        monitor.onEvent = { [weak self] event in
            self?.handle(monitorEvent: event)
        }
        self.monitor = monitor
    }

    deinit {
        retryWork?.cancel()
        monitor?.stop()
    }

    // MARK: - 切台

    /// 播放指定频道（自动选第一条候选流，失败后逐条切换）。
    func play(channel: Channel) {
        cancelPendingWork()
        monitor?.stop()
        player.pause()
        player.replaceCurrentItem(with: nil)

        self.channel = channel
        candidates = Self.playableCandidates(channel.streams)
        candidateIndex = 0
        attemptInCycle = 0
        cycle = 0
        isPausedByUser = false

        state = PlaybackState(status: .preparing,
                              channel: channel,
                              streamIndex: 0,
                              streamCount: candidates.count,
                              message: candidates.isEmpty ? "该频道当前无可用源" : "",
                              qualityLabel: candidates.first?.qualityLabel ?? "",
                              streamURL: candidates.first?.url ?? "")

        guard !candidates.isEmpty else {
            state.status = .failed
            return
        }
        startAttempt()
    }

    /// 重新尝试当前频道（OSD 上的「重试」按钮）。
    func retryCurrentChannel() {
        guard let channel = channel else { return }
        play(channel: channel)
    }

    func stop() {
        cancelPendingWork()
        monitor?.stop()
        player.pause()
        player.replaceCurrentItem(with: nil)
        channel = nil
        candidates = []
        isPausedByUser = false
        state = PlaybackState()
    }

    // MARK: - 传输控制

    func togglePause() {
        guard player.currentItem != nil else { return }
        if isPausedByUser {
            isPausedByUser = false
            monitor?.setPaused(false)
            player.play()
            updateState { $0.status = .playing }
        } else {
            isPausedByUser = true
            monitor?.setPaused(true)
            player.pause()
            updateState { $0.status = .paused }
        }
    }

    /// 后退若干秒（直播流会进入时移窗口）。
    func seek(by seconds: Double) {
        guard let item = player.currentItem else { return }
        let now = item.currentTime().seconds
        guard now.isFinite else { return }
        let target = max(0, now + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
        monitor?.noteProgressReset()
    }

    /// 回到直播边缘。
    func seekToLiveEdge() {
        guard let item = player.currentItem else { return }
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let end = CMTimeAdd(range.start, range.duration)
            let target = CMTimeSubtract(end, CMTime(seconds: 2, preferredTimescale: 600))
            player.seek(to: target,
                        toleranceBefore: CMTime(seconds: 2, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600))
        } else {
            player.seek(to: .positiveInfinity)
        }
        monitor?.noteProgressReset()
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        player.volume = Float(clamped)
        if clamped > 0, isMuted {
            isMuted = false
            player.isMuted = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    // MARK: - 候选流与重试

    /// 存活优先 → 清晰度高优先 → URL 稳定排序（保证每次切台顺序一致）。
    static func sortedCandidates(_ streams: [StreamEndpoint]) -> [StreamEndpoint] {
        let unique = StreamOrdering.deduplicated(streams)
        let builtin = unique.filter { !$0.isCurated }.sorted { lhs, rhs in
            if lhs.isAlive != rhs.isAlive { return lhs.isAlive }
            if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank > rhs.qualityRank }
            return lhs.url < rhs.url
        }
        let curated = unique.filter { $0.isCurated }.sorted { lhs, rhs in
            if lhs.isAlive != rhs.isAlive { return lhs.isAlive }
            if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank > rhs.qualityRank }
            return lhs.url < rhs.url
        }
        // 与烘焙同一条规则：内置存活源优先，补源只在内置全挂时才顶到前面。
        // （补源多是 18~24Mbps 的 4K 流，弱网下更容易卡，不能无条件优先。）
        return StreamOrdering.merge(builtin: builtin, curated: curated)
    }

    /// 单条源的超时预算（见 `StreamOrdering.timeoutBudget`）。
    static func timeouts(for endpoint: StreamEndpoint) -> (open: Double, stall: Double) {
        return StreamOrdering.timeoutBudget(for: endpoint)
    }

    /// 实际参与切换的候选：有烘焙时验证过的存活源时只在存活源之间切。
    ///
    /// 理由：补源（江苏移动 4K）约每 60 秒会因 CDN 会话过期断一次，重新构建
    /// `AVPlayerItem` 就能拿到新会话继续播；而 iptv-org 那几条同期是彻底死的
    /// （502/超时），挨个去试只会让屏幕黑上十几秒再回到「无可用源」。
    static func playableCandidates(_ streams: [StreamEndpoint]) -> [StreamEndpoint] {
        return StreamOrdering.playable(Self.sortedCandidates(streams))
    }

    private func startAttempt() {
        guard candidateIndex < candidates.count else {
            fail(reason: "没有更多候选源")
            return
        }
        let endpoint = candidates[candidateIndex]
        let item = AVPlayerItem(asset: Self.makeAsset(endpoint))
        let budget = Self.timeouts(for: endpoint)
        // 2 秒缓冲对 720p 够用；20Mbps 的 4K 分片本身就是 6 秒一个，
        // 缓冲门槛设 2 秒会让它刚起播就反复回缓冲，这里给到 6 秒。
        item.preferredForwardBufferDuration = budget.open > 30 ? 6 : 2
        monitor?.setTimeouts(open: budget.open, stall: budget.stall)
        monitor?.start(item: item)
        player.replaceCurrentItem(with: item)
        isPausedByUser = false
        player.play()

        updateState { snapshot in
            snapshot.channel = self.channel
            snapshot.streamIndex = self.candidateIndex
            snapshot.streamCount = self.candidates.count
            snapshot.streamURL = endpoint.url
            snapshot.qualityLabel = endpoint.qualityLabel
            snapshot.resolution = ""
            if self.candidateIndex == 0 {
                snapshot.status = .preparing
                snapshot.message = ""
            } else {
                snapshot.status = .switching
                snapshot.message = "正在切换备用源 (\(self.candidateIndex + 1)/\(self.candidates.count))"
            }
        }
    }

    private func fail(reason: String) {
        guard channel != nil else { return }
        retryWork?.cancel()
        retryWork = nil
        monitor?.stop()
        player.replaceCurrentItem(with: nil)
        NSLog("[TVBox] 播放失败：%@（第 %d/%d 条源）", reason, candidateIndex + 1, candidates.count)

        let nextIndex = candidateIndex + 1
        if nextIndex < candidates.count {
            candidateIndex = nextIndex
            attemptInCycle += 1
            updateState { snapshot in
                snapshot.status = .switching
                snapshot.streamIndex = nextIndex
                snapshot.streamCount = self.candidates.count
                snapshot.message = "正在切换备用源 (\(nextIndex + 1)/\(self.candidates.count))"
            }
            scheduleRetry(after: backoffDelay())
            return
        }

        // 一轮候选全部失败
        cycle += 1
        candidateIndex = 0
        attemptInCycle = 0

        // 有存活源（烘焙时探过）就无限重拉：这类断流通常是 CDN 会话过期/瞬时抖动，
        // 重新构建 AVPlayerItem 就能接上，停在「无可用源」反而是错的行为。
        let hasVerifiedStream = candidates.contains { $0.isAlive }
        if cycle >= maxCycles && !hasVerifiedStream {
            updateState { snapshot in
                snapshot.status = .failed
                snapshot.streamIndex = 0
                snapshot.message = "该频道当前无可用源"
            }
        } else if hasVerifiedStream {
            updateState { snapshot in
                snapshot.status = .buffering
                snapshot.streamIndex = 0
                snapshot.message = "重新拉流中…"
            }
            scheduleRetry(after: 2)
        } else {
            updateState { snapshot in
                snapshot.status = .failed
                snapshot.streamIndex = 0
                snapshot.message = "该频道当前无可用源（\(Int(self.retryDelayBetweenCycles)) 秒后自动重试）"
            }
            scheduleRetry(after: retryDelayBetweenCycles)
        }
    }

    /// 退避：1s → 2s → 4s，上限 5s。
    private func backoffDelay() -> Double {
        switch attemptInCycle {
        case 0: return 1
        case 1: return 2
        case 2: return 4
        default: return 5
        }
    }

    private func scheduleRetry(after delay: Double) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startAttempt()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingWork() {
        retryWork?.cancel()
        retryWork = nil
    }

    // MARK: - 监视回调

    private func handle(monitorEvent event: PlaybackMonitor.Event) {
        switch event {
        case .playing:
            guard !isPausedByUser else { return }
            // 真的有画面了就把「整轮候选全挂」的计数清零：
            // 补源会话约 60 秒会失效重连一次，若不归零，看几分钟就会耗尽 maxCycles
            // 被判定「该频道当前无可用源」，而实际上每次重连都能正常出画。
            cycle = 0
            attemptInCycle = 0
            updateState { snapshot in
                snapshot.status = .playing
                snapshot.message = ""
            }
            player.play()
        case .buffering:
            if state.status == .playing {
                updateState { $0.status = .buffering }
            }
        case .resolution(let label):
            updateState { $0.resolution = label }
        case .failed(let reason):
            fail(reason: reason)
        }
    }

    // MARK: - 工具

    private func updateState(_ mutate: (inout PlaybackState) -> Void) {
        var snapshot = state
        mutate(&snapshot)
        state = snapshot
    }

    private static func makeAsset(_ endpoint: StreamEndpoint) -> AVURLAsset {
        let agent = endpoint.userAgent.isEmpty ? defaultUserAgent : endpoint.userAgent
        var headers: [String: String] = ["User-Agent": agent]
        if !endpoint.referrer.isEmpty {
            headers["Referer"] = endpoint.referrer
            headers["Origin"] = originString(from: endpoint.referrer)
        }
        var options: [String: Any] = [:]
        // AVFoundation 对外只暴露 AVURLAssetHTTPUserAgentKey，但内部仍认这个字典键，
        // 是给需要 Referer 的源注入请求头的唯一可行方式。
        options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        options[AVURLAssetHTTPUserAgentKey] = agent

        guard let url = URL(string: endpoint.url) else {
            return AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        }
        return AVURLAsset(url: url, options: options)
    }

    private static func originString(from referrer: String) -> String {
        guard let url = URL(string: referrer),
              let scheme = url.scheme,
              let host = url.host else { return referrer }
        return "\(scheme)://\(host)"
    }
}

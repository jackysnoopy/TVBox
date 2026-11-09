import AppKit
import SwiftUI

/// 台标缓存。
///
/// 加载优先级：**内置 bundle 文件（烘焙时下载的 `Resources/logos/*`）→ 远端 URL（5 秒超时）→ nil（占位）**。
/// 全部 IO 都在后台队列，主线程只读字典，不阻塞 UI。
final class LogoCache {

    static let shared = LogoCache()

    private var images: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var inFlight: Set<String> = []
    /// 同一 key 的并发请求排队等结果，避免「第二次 onAppear 拿到 nil 就永远不刷新」。
    private var waiters: [String: [(NSImage?) -> Void]] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.tvbox.logo", qos: .utility, attributes: .concurrent)
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        // imgur 等图床在本机不可达，失败后短期不要再重试，避免刷屏。
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    /// 同步读缓存（只查内存，不触盘）。
    func cachedImage(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    /// 异步加载；completion 在主线程回调。同一 key 只会真正加载一次。
    func load(key: String,
              localPath: String?,
              remoteURL: URL?,
              completion: @escaping (NSImage?) -> Void) {
        lock.lock()
        if let cached = images[key] {
            lock.unlock()
            completion(cached)
            return
        }
        if failed.contains(key) {
            lock.unlock()
            completion(nil)
            return
        }
        if inFlight.contains(key) {
            // 已有同 key 请求在跑：把这次的回调排进队列，等同一个结果。
            waiters[key, default: []].append(completion)
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()

        if let path = localPath, !path.isEmpty, let url = LogoCache.bundledURL(for: path) {
            queue.async { [weak self] in
                let image = NSImage(contentsOf: url)
                // 本地文件读失败不记入 failed：bundle 读盘很便宜，下次出现时值得重试。
                self?.finish(key: key, image: image, permanentFailure: false, completion: completion)
            }
            return
        }

        guard let remoteURL = remoteURL else {
            finish(key: key, image: nil, permanentFailure: false, completion: completion)
            return
        }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 5
        session.dataTask(with: request) { [weak self] data, _, _ in
            var image: NSImage?
            if let data = data, !data.isEmpty {
                image = NSImage(data: data)
            }
            // 远端失败（多为图床不可达）记入 failed，避免滚动列表时反复超时。
            self?.finish(key: key, image: image, permanentFailure: true, completion: completion)
        }.resume()
    }

    /// 把 `logos/CCTV1.cn.png` 这种相对路径解析成 bundle 内的真实文件地址。
    static func bundledURL(for relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let nsPath = relativePath as NSString
        let name = nsPath.deletingPathExtension
        let ext = nsPath.pathExtension
        if let url = Bundle.main.url(forResource: name,
                                     withExtension: ext.isEmpty ? nil : ext,
                                     subdirectory: "logos") {
            return url
        }
        guard let base = Bundle.main.resourceURL else { return nil }
        let direct = base.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        // 打包时目录可能被拍平到 Resources 根目录
        let flattened = base.appendingPathComponent(nsPath.lastPathComponent)
        if FileManager.default.fileExists(atPath: flattened.path) {
            return flattened
        }
        return nil
    }

    private func finish(key: String,
                        image: NSImage?,
                        permanentFailure: Bool,
                        completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.inFlight.remove(key)
            if let image = image {
                self.images[key] = image
            } else if permanentFailure {
                self.failed.insert(key)
            }
            let queued = self.waiters.removeValue(forKey: key) ?? []
            self.lock.unlock()
            completion(image)
            for waiter in queued {
                waiter(image)
            }
        }
    }
}

/// 台标视图：本地文件优先 → 远端兜底 → 文字徽标占位。
struct ChannelLogoView: View {
    let channel: Channel
    let size: CGFloat
    var cornerRadius: CGFloat = 3

    @State private var image: NSImage?
    /// 已经为哪个 cacheKey 取过图（避免同一视图反复请求，也保证换台后一定重新取）。
    @State private var loadedKey: String?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear(perform: syncImage)
            .onChange(of: channel.id) { _ in
                syncImage()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image = image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            placeholder
        }
    }

    /// 没有可用台标时的文字徽标：台名首字 + 稳定底色（不是通用 `tv` 图标）。
    private var placeholder: some View {
        let colors = ChannelLogoView.badgePalette
        let tint = colors[ChannelBadge.paletteIndex(for: channel.id, count: colors.count)]
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.28)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
            Text(ChannelBadge.initials(channel.name))
                .font(.system(size: max(6, size * (size < 24 ? 0.52 : 0.42)), weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 1)
        }
    }

    /// 徽标底色候选（低饱和，避免抢画面）。
    private static let badgePalette: [Color] = [
        Color(red: 0.26, green: 0.43, blue: 0.72),
        Color(red: 0.20, green: 0.55, blue: 0.52),
        Color(red: 0.62, green: 0.36, blue: 0.42),
        Color(red: 0.45, green: 0.40, blue: 0.68),
        Color(red: 0.66, green: 0.45, blue: 0.26),
        Color(red: 0.25, green: 0.48, blue: 0.60),
        Color(red: 0.38, green: 0.52, blue: 0.34),
        Color(red: 0.52, green: 0.33, blue: 0.56),
    ]

    private var cacheKey: String {
        "\(channel.id)|\(channel.logoFile ?? "")|\(channel.logoURL)"
    }

    /// 换台 / 首次出现时同步台标：已有缓存则立刻显示，否则异步取一次。
    private func syncImage() {
        let key = cacheKey
        guard loadedKey != key else { return }
        loadedKey = key
        if let cached = LogoCache.shared.cachedImage(for: key) {
            image = cached
            return
        }
        image = nil
        let remote = channel.logoURL.isEmpty ? nil : URL(string: channel.logoURL)
        LogoCache.shared.load(key: key,
                              localPath: channel.logoFile,
                              remoteURL: remote) { loaded in
            // 回来时如果已经换台了，就丢弃这次结果，避免串台标。
            guard loadedKey == key else { return }
            image = loaded
        }
    }
}

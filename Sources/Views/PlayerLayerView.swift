import AVFoundation
import AppKit
import SwiftUI

/// 承载 AVPlayerLayer 的 AppKit 视图（SwiftUI 的 NSViewRepresentable 包装）。
/// 用 AVPlayerLayer 而不是 AVPlayerView：可以精确控制 videoGravity、避免自带控制条。
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var onDoubleTap: () -> Void = {}

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView(frame: .zero)
        view.attach(player: player)
        view.onDoubleTap = onDoubleTap
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.attach(player: player)
        nsView.onDoubleTap = onDoubleTap
    }
}

final class PlayerHostView: NSView {
    var onDoubleTap: (() -> Void)?

    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let container = CALayer()
        container.backgroundColor = NSColor.black.cgColor
        layer = container
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        container.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isOpaque: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleTap?()
            return
        }
        super.mouseDown(with: event)
    }
}

import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// The playing browser video, live, for the Now Playing panel.
///
/// Captures only the video's rectangle of its browser window with
/// ScreenCaptureKit and hands each frame to a display layer, which draws it
/// without a copy. A window is captured even while other windows cover it;
/// one that is minimised has nothing to capture.
///
/// Runs only while asked: the panel starts it on a click and stops it when it
/// closes. It costs Screen Recording permission, asked for the first time it
/// is started and never before.
@MainActor @Observable
final class VideoMirror {
    static let shared = VideoMirror()

    enum State: Equatable {
        case off, starting, live
        /// Screen Recording was refused.
        case denied
        case unavailable(String)
    }

    private(set) var state: State = .off
    /// Width over height of the picture being shown.
    private(set) var aspect: CGFloat = 16 / 9

    let layer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: Output?
    @ObservationIgnored private var window: CGWindowID?
    @ObservationIgnored private var region: CGRect?
    @ObservationIgnored private var follow: Task<Void, Never>?

    private init() {}

    var isOn: Bool { state != .off }

    func start(_ tab: BrowserBridge.TabRef) {
        guard !isOn else { return }
        state = .starting
        follow = Task { await run(tab) }
    }

    func stop() {
        follow?.cancel()
        follow = nil
        let stream = stream
        self.stream = nil
        output = nil
        window = nil
        region = nil
        Task { try? await stream?.stopCapture() }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        state = .off
    }

    /// Finds the video, keeps the capture on it as it moves, and stops when
    /// cancelled. Re-reads the position every second: scrolling, resizing and
    /// going fullscreen all move the picture.
    private func run(_ tab: BrowserBridge.TabRef) async {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            state = .denied
            return
        }
        while !Task.isCancelled {
            if let found = await BrowserBridge.videoRect(tab) {
                do {
                    try await capture(found.rect, title: found.title, of: tab.browser)
                } catch {
                    state = .unavailable("The video's window can't be captured.")
                }
            } else if state != .live {
                state = .unavailable("The video isn't on screen in its window.")
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func capture(_ rect: CGRect, title: String, of browser: BrowserApp) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !Task.isCancelled else { return }
        // By title first: two windows of one browser can overlap, and the one
        // under the video's position may be another. The window's title is
        // the page's, with the browser's own additions after it.
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == browser.bundleID && $0.windowLayer == 0
        }
        let key = String(title.prefix(40))
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let byTitle = key.isEmpty ? nil : windows.first { ($0.title ?? "").contains(key) }
        guard let target = byTitle ?? windows.first(where: { $0.frame.contains(centre) }) else {
            state = .unavailable("The video's window isn't on screen.")
            return
        }

        let source = CGRect(x: rect.minX - target.frame.minX, y: rect.minY - target.frame.minY,
                            width: rect.width, height: rect.height)
            .intersection(CGRect(origin: .zero, size: target.frame.size))
        guard !source.isEmpty else { return }
        aspect = source.width / max(source.height, 1)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = source
        // Twice the points for a Retina picture, capped so a fullscreen video
        // does not stream 5K frames into a 340pt card.
        let scale = min(2, 1280 / max(source.width, 1))
        configuration.width = Int(source.width * scale)
        configuration.height = Int(source.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 4

        if let stream, window == target.windowID {
            guard region != source else { return }
            try await stream.updateConfiguration(configuration)
            region = source
            return
        }

        try? await stream?.stopCapture()
        let output = Output(renderer: layer.sampleBufferRenderer) { [weak self] in
            Task { @MainActor in if self?.state != .off { self?.state = .live } }
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let fresh = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try fresh.addStreamOutput(output, type: .screen, sampleHandlerQueue: Output.queue)
        try await fresh.startCapture()
        guard !Task.isCancelled else {
            try? await fresh.stopCapture()
            return
        }
        stream = fresh
        self.output = output
        window = target.windowID
        region = source
    }

    /// Receives frames on its own queue and passes the complete ones straight
    /// to the layer's renderer, which is safe to feed from any thread.
    private final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
        static let queue = DispatchQueue(label: "com.namanparashar.plinth.video", qos: .userInteractive)

        private let renderer: AVSampleBufferVideoRenderer
        private let firstFrame: () -> Void
        private var sawFrame = false

        init(renderer: AVSampleBufferVideoRenderer, firstFrame: @escaping () -> Void) {
            self.renderer = renderer
            self.firstFrame = firstFrame
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, buffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            // Shown the moment it arrives rather than against a clock the
            // layer would otherwise wait on.
            if let mutable = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
               CFArrayGetCount(mutable) > 0 {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(mutable, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(buffer)
            if !sawFrame {
                sawFrame = true
                firstFrame()
            }
        }
    }
}

/// The mirror's layer, in a SwiftUI view.
struct VideoMirrorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = VideoMirror.shared.layer
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

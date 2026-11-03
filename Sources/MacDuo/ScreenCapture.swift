import AppKit
import CoreVideo
import Metal
import ScreenCaptureKit
import os

let log = Logger(subsystem: "com.abukotsh.MacDuo", category: "engine")

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The MacBook's own display, or `nil` in clamshell mode.
    static var builtIn: NSScreen? {
        screens.first { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
    }
}

/// A stream frame as a Metal texture. Holding the Core Video wrapper keeps
/// the pool from recycling the surface while the GPU still reads it.
struct StreamFrame: @unchecked Sendable {
    let texture: MTLTexture
    let owner: CVMetalTexture
}

/// Captures the built-in display with ScreenCaptureKit, leaving this app's
/// own windows out so the overlay never feeds back into its picture.
///
/// Starting a stream takes a noticeable moment, so the engine starts it while
/// the lid is still closing.
@MainActor
final class ScreenCapture {

    /// Shares the sRGB transfer curve, so the shader's sRGB format decodes it.
    static let colourSpace = CGColorSpace.displayP3

    /// Receives frames on the stream queue; the newest one is picked up from
    /// the main thread under a lock.
    private final class Receiver: NSObject, SCStreamOutput, @unchecked Sendable {
        private let cache: CVMetalTextureCache
        private let lock = NSLock()
        private var newest: StreamFrame?
        private var serial: UInt64 = 0

        init?(device: MTLDevice) {
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
                  let cache else { return nil }
            self.cache = cache
        }

        func latest() -> (StreamFrame, UInt64)? {
            lock.lock(); defer { lock.unlock() }
            return newest.map { ($0, serial) }
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, buffer.isValid, let pixels = buffer.imageBuffer else { return }
            // Only complete frames carry new pixels.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
               let raw = attachments.first?[.status] as? Int,
               SCFrameStatus(rawValue: raw) != .complete { return }

            CVMetalTextureCacheFlush(cache, 0)
            var wrapped: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixels, nil, .bgra8Unorm_srgb,
                CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &wrapped
            ) == kCVReturnSuccess, let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { return }

            lock.lock()
            newest = StreamFrame(texture: texture, owner: wrapped)
            serial &+= 1
            lock.unlock()
        }
    }

    private let device: MTLDevice?
    private var stream: SCStream?
    private var receiver: Receiver?
    private var starting: Task<Void, Never>?
    /// Listing shareable content costs tens of milliseconds, so the filter is
    /// kept until the display changes.
    private var filter: SCContentFilter?
    private var filterDisplay: CGDirectDisplayID?
    private var consumed: UInt64 = 0

    private(set) var isRunning = false

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    init(device: MTLDevice?) {
        self.device = device
    }

    // MARK: Stream

    func start() {
        guard !isRunning, let device, let displayID = NSScreen.builtIn?.displayID else { return }
        isRunning = true
        starting = Task { [weak self] in
            await self?.open(displayID: displayID, device: device)
            self?.starting = nil
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        starting?.cancel()
        starting = nil
        receiver = nil
        consumed = 0
        if let closing = stream {
            stream = nil
            Task { try? await closing.stopCapture() }
        }
    }

    /// The newest frame, once. `nil` when nothing arrived since the last call.
    func takeFrame() -> StreamFrame? {
        guard let (frame, serial) = receiver?.latest(), serial != consumed else { return nil }
        consumed = serial
        return frame
    }

    private func open(displayID: CGDirectDisplayID, device: MTLDevice) async {
        guard let receiver = Receiver(device: device) else { isRunning = false; return }
        await prepareFilter(displayID: displayID)
        guard !Task.isCancelled, isRunning, let filter else { isRunning = false; return }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = Self.colourSpace
        configuration.showsCursor = false
        configuration.queueDepth = 5
        configuration.scalesToFit = false

        do {
            let fresh = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try fresh.addStreamOutput(receiver, type: .screen,
                                      sampleHandlerQueue: DispatchQueue(label: "MacDuo.frames", qos: .userInteractive))
            try await fresh.startCapture()
            guard !Task.isCancelled, isRunning else {
                try? await fresh.stopCapture()
                return
            }
            stream = fresh
            self.receiver = receiver
            log.notice("stream started \(configuration.width)x\(configuration.height)")
        } catch {
            log.error("stream failed: \(error.localizedDescription, privacy: .public)")
            invalidate()
            isRunning = false
        }
    }

    // MARK: Screenshot

    /// One still picture of the built-in display, for when the stream has not
    /// produced a frame yet.
    func screenshot() async -> CGImage? {
        guard let displayID = NSScreen.builtIn?.displayID else { return nil }
        await prepareFilter(displayID: displayID)
        guard let filter else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.colorSpaceName = Self.colourSpace
        configuration.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    // MARK: Filter

    func prepareFilter(displayID: CGDirectDisplayID? = NSScreen.builtIn?.displayID) async {
        guard let displayID, filter == nil || filterDisplay != displayID else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            if own.isEmpty { log.error("own app not listed; overlay may show up in the capture") }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            filterDisplay = displayID
        } catch {
            log.error("filter failed: \(error.localizedDescription, privacy: .public)")
            invalidate()
        }
    }

    func invalidate() {
        filter = nil
        filterDisplay = nil
    }
}

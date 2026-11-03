import AppKit
import DuoCore
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd

/// Draws the effect with one full-screen Metal pass.
///
/// The screen picture sits inside a black margin in a mipmapped texture, and a
/// Gaussian pyramid is rebuilt over it whenever a new picture arrives. Each
/// screen pixel maps back into the picture through the inverse homography and
/// takes one sample at the mip level matching the blur wanted at that height.
/// Because the margin is black, blurred edges fade into black without any
/// special handling.
@MainActor
final class DepthRenderer {

    /// Black margin around the picture, in points; larger than the blur.
    private static let margin: CGFloat = 120

    private struct Uniforms {
        var inverse0: SIMD4<Float>
        var inverse1: SIMD4<Float>
        var inverse2: SIMD4<Float>
        /// screen width, height (points), margin (points), pixel scale
        var screen: SIMD4<Float>
        /// blur strength, max radius (pixels), hinge blur floor, max mip level
        var blur: SIMD4<Float>
        /// dim strength, max dim, hinge dim floor, dim spread
        var dim: SIMD4<Float>
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private lazy var pyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)

    private(set) var layer = CAMetalLayer()
    private var picture: MTLTexture?
    private var screenSize: CGSize = .zero
    private var scale: CGFloat = 2
    private var maxLevel: Float = 0

    private var pendingFrame: StreamFrame?
    private var pendingImage: (buffer: MTLBuffer, width: Int, height: Int)?
    /// True once a picture has been copied in (or is queued to be).
    private(set) var hasPicture = false

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullScreen")
            descriptor.fragmentFunction = library.makeFunction(name: "depth")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            log.error("metal pipeline: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A fresh layer for a new overlay window; a layer belongs to one view.
    func makeLayer() -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        // An opaque full-screen layer makes the window server treat every
        // window behind it as hidden, and those apps stop drawing — which would
        // freeze the live picture. The shader writes alpha 1 anyway.
        layer.isOpaque = false
        // The display link paces frames; waiting for vsync here would block
        // the main thread and halve the frame rate while capturing.
        layer.displaySyncEnabled = false
        layer.colorspace = CGColorSpace(name: ScreenCapture.colourSpace)
        self.layer = layer
        return layer
    }

    /// Readies the padded picture texture for a screen.
    func begin(screenSize: CGSize, scale: CGFloat) -> Bool {
        let width = Int(((screenSize.width + 2 * Self.margin) * scale).rounded())
        let height = Int(((screenSize.height + 2 * Self.margin) * scale).rounded())
        guard width > 0, height > 0 else { return false }

        if picture?.width != width || picture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true
            )
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
            clear(texture)
            picture = texture
        }
        self.screenSize = screenSize
        self.scale = scale
        maxLevel = Float(picture!.mipmapLevelCount - 1)
        layer.drawableSize = CGSize(width: screenSize.width * scale, height: screenSize.height * scale)
        hasPicture = false
        pendingFrame = nil
        pendingImage = nil
        return true
    }

    /// Queues a stream frame; it is copied in on the next drawn frame.
    func ingest(_ frame: StreamFrame) {
        pendingFrame = frame
        pendingImage = nil
        hasPicture = true
    }

    /// Queues a still picture, used before the stream has a frame.
    func ingest(_ image: CGImage) {
        let width = Int((screenSize.width * scale).rounded())
        let height = Int((screenSize.height * scale).rounded())
        guard width > 0, height > 0,
              let buffer = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let space = CGColorSpace(name: ScreenCapture.colourSpace),
              let context = CGContext(
                data: buffer.contents(), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pendingImage = (buffer, width, height)
        pendingFrame = nil
        hasPicture = true
    }

    func release() {
        picture = nil
        pendingFrame = nil
        pendingImage = nil
        hasPicture = false
    }

    // MARK: Drawing

    func render(corners: [SIMD2<Double>], progress: Double, tuning: DepthTuning) {
        guard let commands = queue.makeCommandBuffer() else { return }
        copyPending(into: commands)
        guard hasPicture, let picture, screenSize.width > 0, let drawable = layer.nextDrawable() else {
            commands.commit()
            return
        }

        let inverse = DepthProjection.homography(
            width: Double(screenSize.width), height: Double(screenSize.height), corners: corners
        ).inverse
        func column(_ i: Int) -> SIMD4<Float> {
            SIMD4(Float(inverse[i].x), Float(inverse[i].y), Float(inverse[i].z), 0)
        }
        var uniforms = Uniforms(
            inverse0: column(0), inverse1: column(1), inverse2: column(2),
            screen: SIMD4(Float(screenSize.width), Float(screenSize.height), Float(Self.margin), Float(scale)),
            blur: SIMD4(
                Float(DepthProjection.blurStrength(progress: progress)),
                Float(tuning.maxBlur * Double(scale)),
                Float(tuning.blurSpread),
                maxLevel
            ),
            dim: SIMD4(
                Float(DepthProjection.dimStrength(progress: progress)),
                Float(tuning.maxDim),
                Float(DepthProjection.dimHingeFloor),
                Float(tuning.dimSpread)
            )
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            commands.commit()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// Copies the queued picture inside the margin and rebuilds the pyramid,
    /// on the same command buffer as the pass that reads it.
    private func copyPending(into commands: MTLCommandBuffer) {
        guard var target = picture, pendingFrame != nil || pendingImage != nil,
              let blit = commands.makeBlitCommandEncoder() else { return }
        let inset = Int((Self.margin * scale).rounded())
        let room = (width: target.width - 2 * inset, height: target.height - 2 * inset)
        let origin = MTLOrigin(x: inset, y: inset, z: 0)

        if let frame = pendingFrame {
            let size = MTLSize(width: min(frame.texture.width, room.width),
                               height: min(frame.texture.height, room.height), depth: 1)
            blit.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
                      sourceSize: size, to: target, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: origin)
            commands.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
        } else if let image = pendingImage {
            let size = MTLSize(width: min(image.width, room.width), height: min(image.height, room.height), depth: 1)
            blit.copy(from: image.buffer, sourceOffset: 0, sourceBytesPerRow: image.width * 4,
                      sourceBytesPerImage: image.width * image.height * 4, sourceSize: size,
                      to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        }
        blit.endEncoding()
        pendingFrame = nil
        pendingImage = nil
        pyramid.encode(commandBuffer: commands, inPlaceTexture: &target, fallbackCopyAllocator: nil)
        picture = target
    }

    private func clear(_ texture: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commands.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 inverse0;
        float4 inverse1;
        float4 inverse2;
        float4 screen;
        float4 blur;
        float4 dim;
    };

    // One triangle that covers the whole viewport.
    vertex float4 fullScreen(uint id [[vertex_id]]) {
        const float2 p[3] = { float2(-1, -3), float2(-1, 1), float2(3, 1) };
        return float4(p[id], 0, 1);
    }

    fragment float4 depth(float4 position [[position]],
                          constant Uniforms &u [[buffer(0)]],
                          texture2d<float> picture [[texture(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float2 size = u.screen.xy;
        float margin = u.screen.z;
        float scale = u.screen.w;

        // Fragment coordinates are pixels with y down; geometry is points, y up.
        float2 glass = float2(position.x / scale, size.y - position.y / scale);
        float3 mapped = float3x3(u.inverse0.xyz, u.inverse1.xyz, u.inverse2.xyz) * float3(glass, 1);
        if (abs(mapped.z) < 1e-6) { return float4(0, 0, 0, 1); }
        float2 p = mapped.xy / mapped.z;

        float2 unit = (p + margin) / (size + 2 * margin);
        if (any(unit < 0.0) || any(unit > 1.0)) { return float4(0, 0, 0, 1); }

        // 0 at the hinge, 1 at the far edge of the picture.
        float height = clamp(p.y / size.y, 0.0, 1.0);
        float blur = u.blur.x * (u.blur.z + (1 - u.blur.z) * height);
        float lod = clamp(log2(max(blur * u.blur.y, 1.0)), 0.0, u.blur.w);
        float4 colour = picture.sample(s, float2(unit.x, 1 - unit.y), level(lod));

        float spread = smoothstep(0.0, max(u.dim.w, 0.02), height);
        float fade = u.dim.x * (u.dim.z + (1 - u.dim.z) * spread);
        // The sample is linear light; the power keeps the dim setting a
        // fraction of perceived brightness.
        colour.rgb *= pow(1 - u.dim.y * fade, 2.2);
        return float4(colour.rgb, 1);
    }
    """
}

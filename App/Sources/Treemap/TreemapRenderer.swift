import MetalKit
import simd
import TreemapLayout

struct TreemapUniforms {
    var viewportSize: SIMD2<Float> = .zero
    var colorMode: UInt32 = 0
    var inventoryTimestamp: UInt32 = 0
    var hoveredInstance: Int32 = -1
    var selectedDirectoryStart: UInt32 = 0
    var selectedDirectoryEnd: UInt32 = 0
    var highlightCategory: Int32 = -1
    var selectionFlags: UInt32 = 0
    var selectionX: Float = 0
    var selectionY: Float = 0
    var selectionWidth: Float = 0
    var selectionHeight: Float = 0
}

struct TransitionUniforms {
    var translation: SIMD2<Float> = .zero
    var scale: Float = 1
    var opacity: Float = 1
}

final class TreemapRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var instanceBuffer: MTLBuffer?
    private var instanceCount = 0
    private var previousInstanceBuffer: MTLBuffer?
    private var previousInstanceCount = 0
    private let storageClassBuffer: MTLBuffer
    private let extensionColorBuffer: MTLBuffer
    private let ageColorBuffer: MTLBuffer
    private let extensionSlotBuffer: MTLBuffer
    private let folderColorBuffer: MTLBuffer

    var colorMode: ColorMode = .storageClass
    var inventoryTimestamp: UInt32 = 0
    var hoveredInstance: Int = -1
    var selectedRange: Range<UInt32>?

    /// In layout pixels. A zero width means nothing is outlined.
    var selectionRect: CGRect = .zero

    /// Draws guide lines to the canvas edges, for a selection too small to spot on its own.
    var selectionShowsGuides = false
    var highlightCategory: Int = -1
    var transitionScale: Float = 1
    var transitionTranslation: SIMD2<Float> = .zero
    var transitionOpacity: Float = 1
    var previousResultOpacity: Float = 0

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "treemapVertex"),
              let fragmentFunction = library.makeFunction(name: "treemapFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline

        func colorBuffer(_ colors: [NSColor]) -> MTLBuffer {
            var values = colors.map { TreemapPalette.simd($0) }
            let length = MemoryLayout<SIMD4<Float>>.stride * values.count
            return device.makeBuffer(bytes: &values, length: length, options: .storageModeManaged)!
        }

        storageClassBuffer = colorBuffer(TreemapPalette.storageClassColors)
        extensionColorBuffer = colorBuffer(TreemapPalette.extensionColors + [TreemapPalette.extensionOtherColor])
        ageColorBuffer = colorBuffer(TreemapPalette.ageColors)
        folderColorBuffer = colorBuffer(TreemapPalette.folderColors + [TreemapPalette.folderOwnColor])
        extensionSlotBuffer = device.makeBuffer(length: 65_536, options: .storageModeManaged)!
        memset(extensionSlotBuffer.contents(), 15, 65_536)
        extensionSlotBuffer.didModifyRange(0..<65_536)
    }

    func update(extensionPaletteSlots slots: [UInt8]) {
        precondition(slots.count == 65_536)
        slots.withUnsafeBytes { extensionSlotBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: 65_536) }
        extensionSlotBuffer.didModifyRange(0..<65_536)
    }

    func captureTransitionSource() {
        previousInstanceBuffer = instanceBuffer
        previousInstanceCount = instanceCount
        instanceBuffer = nil
        instanceCount = 0
    }

    func update(result: LayoutResult?) {
        guard let result, !result.instances.isEmpty else {
            instanceBuffer = nil
            instanceCount = 0
            return
        }

        let length = MemoryLayout<TreemapInstance>.stride * result.instances.count

        if instanceBuffer == nil || instanceBuffer!.length < length {
            instanceBuffer = device.makeBuffer(length: max(length, 1 << 20), options: .storageModeManaged)
        }

        guard let buffer = instanceBuffer else { return }
        result.instances.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
        buffer.didModifyRange(0..<length)
        instanceCount = result.instances.count
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let size = view.drawableSize
        var uniforms = TreemapUniforms(
            viewportSize: SIMD2<Float>(Float(size.width), Float(size.height)),
            colorMode: UInt32(colorMode.rawValue),
            inventoryTimestamp: inventoryTimestamp,
            hoveredInstance: Int32(hoveredInstance),
            selectedDirectoryStart: selectedRange?.lowerBound ?? 0,
            selectedDirectoryEnd: selectedRange?.upperBound ?? 0,
            highlightCategory: Int32(highlightCategory),
            selectionFlags: selectionShowsGuides ? 1 : 0,
            selectionX: Float(selectionRect.origin.x),
            selectionY: Float(selectionRect.origin.y),
            selectionWidth: Float(selectionRect.width),
            selectionHeight: Float(selectionRect.height)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(storageClassBuffer, offset: 0, index: 2)
        encoder.setVertexBuffer(extensionColorBuffer, offset: 0, index: 3)
        encoder.setVertexBuffer(ageColorBuffer, offset: 0, index: 4)
        encoder.setVertexBuffer(extensionSlotBuffer, offset: 0, index: 5)
        encoder.setVertexBuffer(folderColorBuffer, offset: 0, index: 7)

        if previousResultOpacity > 0, let previous = previousInstanceBuffer, previousInstanceCount > 0 {
            var transition = TransitionUniforms(
                translation: transitionTranslation,
                scale: transitionScale,
                opacity: previousResultOpacity
            )
            var previousUniforms = uniforms
            previousUniforms.hoveredInstance = -1
            previousUniforms.selectionWidth = 0
            previousUniforms.selectionHeight = 0
            previousUniforms.selectionFlags = 0
            encoder.setVertexBytes(&previousUniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&previousUniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.setVertexBuffer(previous, offset: 0, index: 0)
            encoder.setVertexBytes(&transition, length: MemoryLayout<TransitionUniforms>.stride, index: 6)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: previousInstanceCount
            )
        }

        if let buffer = instanceBuffer, instanceCount > 0 {
            var transition = TransitionUniforms(translation: .zero, scale: 1, opacity: transitionOpacity)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&transition, length: MemoryLayout<TransitionUniforms>.stride, index: 6)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

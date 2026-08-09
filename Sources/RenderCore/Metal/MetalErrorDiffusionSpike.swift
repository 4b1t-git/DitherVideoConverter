import Metal

enum ErrorDiffusionAlgorithm: UInt32, CaseIterable, CustomStringConvertible {
    case atkinson
    case floydSteinberg

    var description: String {
        self == .atkinson ? "atkinson" : "floyd-steinberg"
    }
}

enum ErrorDiffusionSpikeError: Error {
    case metalUnavailable
    case invalidDimensions
    case commandFailed(Error?)
}

final class MetalErrorDiffusionSpike {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    var deviceName: String { device.name }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let function = device.makeDefaultLibrary()?.makeFunction(name: "errorDiffusion")
        else { throw ErrorDiffusionSpikeError.metalUnavailable }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
    }

    func render(
        _ pixels: [UInt8], width: Int, height: Int, algorithm: ErrorDiffusionAlgorithm
    ) throws -> [UInt8] {
        try renderAdaptive(pixels, sourceWidth: width, sourceHeight: height,
                           width: width, height: height, algorithm: algorithm)
    }

    func renderAdaptive(
        _ pixels: [UInt8], sourceWidth: Int, sourceHeight: Int,
        width: Int, height: Int, algorithm: ErrorDiffusionAlgorithm
    ) throws -> [UInt8] {
        guard sourceWidth > 0, sourceHeight > 0, width > 0, height > 0,
              pixels.count == sourceWidth * sourceHeight else {
            throw ErrorDiffusionSpikeError.invalidDimensions
        }
        let sourceCount = pixels.count
        let workingCount = width * height
        let input = pixels.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: sourceCount)
        }
        guard let input,
              let output = device.makeBuffer(length: workingCount),
              let work = device.makeBuffer(length: workingCount * MemoryLayout<Int32>.stride),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { throw ErrorDiffusionSpikeError.metalUnavailable }

        var metalWidth = UInt32(width)
        var metalHeight = UInt32(height)
        var metalAlgorithm = algorithm.rawValue
        var metalSourceWidth = UInt32(sourceWidth)
        var metalSourceHeight = UInt32(sourceHeight)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(work, offset: 0, index: 2)
        encoder.setBytes(&metalWidth, length: 4, index: 3)
        encoder.setBytes(&metalHeight, length: 4, index: 4)
        encoder.setBytes(&metalAlgorithm, length: 4, index: 5)
        encoder.setBytes(&metalSourceWidth, length: 4, index: 6)
        encoder.setBytes(&metalSourceHeight, length: 4, index: 7)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw ErrorDiffusionSpikeError.commandFailed(command.error)
        }
        let values = output.contents().bindMemory(to: UInt8.self, capacity: workingCount)
        return Array(UnsafeBufferPointer(start: values, count: workingCount))
    }
}

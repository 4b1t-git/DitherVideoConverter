import CoreGraphics

struct SourceColorSignal { let isHDR: Bool; let isWideColor: Bool }

struct ColorNormalizationPlan {
    let output = "8-bit SDR Rec.709"
    let supportsHDROutput = false
    let description: String
}

enum GeometryPlanError: Error, Equatable {
    case unsupportedDimensions(CGSize)
    case invalidMetadata
}

struct GeometryPlan {
    let outputDimensions: CGSize
    let orientedDisplayDimensions: CGSize
    let isMirrored: Bool
    let cleanAperture: CGRect
    let pixelAspectRatio: CGSize
    let colorNormalization: ColorNormalizationPlan

    init(naturalSize: CGSize, preferredTransform: CGAffineTransform,
         cleanAperture: CGRect, pixelAspectRatio: CGSize,
         sourceColor: SourceColorSignal, maximumDimension: CGFloat) throws {
        guard naturalSize.width > 0, naturalSize.height > 0,
              cleanAperture.width > 0, cleanAperture.height > 0,
              pixelAspectRatio.width > 0, pixelAspectRatio.height > 0 else {
            throw GeometryPlanError.invalidMetadata
        }
        let output = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform).standardized.size
        guard output.width <= maximumDimension, output.height <= maximumDimension else {
            throw GeometryPlanError.unsupportedDimensions(output)
        }
        let display = CGSize(width: cleanAperture.width * pixelAspectRatio.width
                             / pixelAspectRatio.height, height: cleanAperture.height)
        outputDimensions = output
        orientedDisplayDimensions = CGRect(origin: .zero, size: display)
            .applying(preferredTransform).standardized.size
        isMirrored = preferredTransform.a * preferredTransform.d
            - preferredTransform.b * preferredTransform.c < 0
        self.cleanAperture = cleanAperture
        self.pixelAspectRatio = pixelAspectRatio
        colorNormalization = ColorNormalizationPlan(description: sourceColor.isHDR || sourceColor.isWideColor
            ? "Tone-map HDR/wide-color input to 100-nit linear Rec.709 before styling; encode 8-bit SDR Rec.709. HDR output is unsupported."
            : "Normalize source color to linear Rec.709 before styling; encode 8-bit SDR Rec.709. HDR output is unsupported.")
    }
}

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCode {
    /// One pixel per module; scale it up with `.interpolation(.none)` so the edges stay sharp.
    static func image(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

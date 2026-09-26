import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The pairing QR (upstream `qr_svg`), rendered with `CIQRCodeGenerator` and cached for the current
/// pairing URL — a new pairing token means a new URL, so the cache holds one entry.
public final class RemotePairingQR: @unchecked Sendable {
    public static let shared = RemotePairingQR()

    /// Upstream's minimum rendered size.
    public static let minimumSide = 220

    private let lock = NSLock()
    private var cache: (url: String, image: CGImage)?
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    public init() {}

    /// A black-on-white QR of `url`, at least `minimumSide` pixels square with a quiet zone, or
    /// `nil` if it cannot be encoded.
    public func image(for url: String) -> CGImage? {
        lock.withLock {
            if let cache, cache.url == url { return cache.image }
            guard let image = render(url) else { return nil }
            cache = (url, image)
            return image
        }
    }

    /// The URL the cache holds (for tests).
    var cachedURL: String? {
        lock.withLock { cache?.url }
    }

    private func render(_ url: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        let scale = ceil(CGFloat(Self.minimumSide) / code.extent.width)
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

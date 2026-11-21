import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let value: String
    var accessibilityTitle: LocalizedStringKey = "QR code"
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityValue(Text(value))
                .accessibilityHint("Scan this code with another device.")
        } else {
            ContentUnavailableView("QR Code Unavailable", systemImage: "qrcode")
        }
    }

    private var image: UIImage? {
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let cgImage = context.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

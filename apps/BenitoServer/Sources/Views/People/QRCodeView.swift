import SwiftUI

struct QRCodeView: View {
    let image: CGImage

    var body: some View {
        Image(image, scale: 1, label: Text("QR code for the invite link"))
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 220, height: 220)
            .padding(12)
            // Scanners need dark modules on a light quiet zone, in dark mode too.
            .background(.white, in: .rect(cornerRadius: 8))
    }
}

import AppKit
import SwiftUI

extension Color {
    init(hexRGB: UInt32) {
        let red = Double((hexRGB >> 16) & 0xFF) / 255.0
        let green = Double((hexRGB >> 8) & 0xFF) / 255.0
        let blue = Double(hexRGB & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt32(hex, radix: 16) else {
            self.init(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
            return
        }
        self.init(hexRGB: value)
    }

    var hexStringValue: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

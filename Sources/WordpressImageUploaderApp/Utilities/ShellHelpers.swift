import Foundation

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let supportedImageExtensions: Set<String> = [
    "jpg", "jpeg", "jpe", "gif", "png", "bmp", "ico", "webp", "avif", "heic", "pdf"
]

func shellSingleQuote(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

func ensureNoTrailingSlash(_ value: String) -> String {
    guard value.count > 1 else { return value }
    if value.hasSuffix("/") {
        return String(value.dropLast())
    }
    return value
}

func isSupportedImageExtension(_ url: URL) -> Bool {
    supportedImageExtensions.contains(url.pathExtension.lowercased())
}

func parseRsyncProgress(_ line: String) -> Double? {
    guard let percentRange = line.range(of: #"\d{1,3}%"#, options: .regularExpression) else {
        return nil
    }

    let number = line[percentRange].replacingOccurrences(of: "%", with: "")
    guard let value = Double(number) else { return nil }
    return min(max(value / 100.0, 0.0), 1.0)
}

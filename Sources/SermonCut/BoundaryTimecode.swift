import Foundation

enum BoundaryTimecode {
    static func parse(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var result = 0.0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let value = Double(part), value.isFinite, value >= 0 else { return nil }
            if index < parts.count - 1 && value.rounded(.down) != value { return nil }
            if index > 0 && value >= 60 { return nil }
            result = result * 60 + value
        }
        return result.isFinite ? result : nil
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1000) else { return "0:00:00" }
        let millis = Int((seconds * 1000).rounded())
        let whole = millis / 1000
        let base = String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
        return millis % 1000 == 0 ? base : base + String(format: ".%03d", millis % 1000)
    }
}

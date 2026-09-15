import Foundation

/// Display units only; token accounting and chart coordinates retain integers.
enum TokenCountFormat {
    static func string(_ value: Int, locale: Locale = .current) -> String {
        let value = max(0, value)
        let format = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0...2)).grouping(.never).locale(locale)
        // Do not present a small, positive reading as measured zero.
        if value > 0, value < 10_000 {
            return "<" + 0.01.formatted(format) + "M"
        }
        if value >= 100_000_000 {
            return (Double(value) / 100_000_000).formatted(format) + "亿"
        }
        // The unit boundary follows the actual count, not a rounded 100M.
        return min(Double(value) / 1_000_000, 99.99).formatted(format) + "M"
    }
}

import Foundation

public enum Squarify {
    /// Squarified treemap rows (Bruls, Huizing and van Wijk). One rect per weight, in the same order.
    public static func layout(weights: [Double], in rect: LayoutRect) -> [LayoutRect] {
        var results = [LayoutRect](repeating: .zero, count: weights.count)
        layout(weights: weights, in: rect, into: &results)
        return results
    }

    /// Writes one rect per weight into `results`, which is resized to match. Reusing the buffer keeps the
    /// recursive treemap free of per-node allocations.
    public static func layout(weights: [Double], in rect: LayoutRect, into results: inout [LayoutRect]) {
        if results.count != weights.count {
            results = [LayoutRect](repeating: .zero, count: weights.count)
        } else {
            for index in results.indices {
                results[index] = .zero
            }
        }

        let total = weights.reduce(0, +)

        guard total > 0, rect.width > 0, rect.height > 0, !weights.isEmpty else { return }
        let scale = rect.area / total
        var remaining = rect
        var rowStart = 0
        var rowSum = 0.0
        var rowMinimum = Double.infinity
        var rowMaximum = 0.0
        var index = 0

        func worst(_ sum: Double, _ minimum: Double, _ maximum: Double, _ side: Double) -> Double {
            guard sum > 0, minimum > 0, side > 0 else { return Double.infinity }
            return max(side * side * maximum / (sum * sum), sum * sum / (side * side * minimum))
        }

        func placeRow(_ range: Range<Int>, sum: Double) {
            guard sum > 0 else { return }

            if remaining.width >= remaining.height {
                let rowWidth = sum / remaining.height
                var y = remaining.y

                for item in range {
                    let itemHeight = weights[item] * scale / rowWidth
                    results[item] = LayoutRect(x: remaining.x, y: y, width: rowWidth, height: itemHeight)
                    y += itemHeight
                }

                remaining = LayoutRect(
                    x: remaining.x + rowWidth,
                    y: remaining.y,
                    width: remaining.width - rowWidth,
                    height: remaining.height
                )
            } else {
                let rowHeight = sum / remaining.width
                var x = remaining.x

                for item in range {
                    let itemWidth = weights[item] * scale / rowHeight
                    results[item] = LayoutRect(x: x, y: remaining.y, width: itemWidth, height: rowHeight)
                    x += itemWidth
                }

                remaining = LayoutRect(
                    x: remaining.x,
                    y: remaining.y + rowHeight,
                    width: remaining.width,
                    height: remaining.height - rowHeight
                )
            }
        }

        while index < weights.count {
            let area = weights[index] * scale

            if area <= 0 {
                index += 1
                continue
            }

            if rowSum == 0 {
                rowStart = index
                rowSum = area
                rowMinimum = area
                rowMaximum = area
                index += 1
                continue
            }

            let side = min(remaining.width, remaining.height)
            let current = worst(rowSum, rowMinimum, rowMaximum, side)
            let candidate = worst(rowSum + area, min(rowMinimum, area), max(rowMaximum, area), side)

            if candidate <= current {
                rowSum += area
                rowMinimum = min(rowMinimum, area)
                rowMaximum = max(rowMaximum, area)
                index += 1
            } else {
                placeRow(rowStart..<index, sum: rowSum)
                rowSum = 0
            }
        }

        if rowSum > 0 {
            placeRow(rowStart..<index, sum: rowSum)
        }
    }
}

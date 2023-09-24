import Foundation

public struct LayoutRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public static let zero = LayoutRect(x: 0, y: 0, width: 0, height: 0)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= x && pointX < x + width && pointY >= y && pointY < y + height
    }

    public func insetBy(_ amount: Double) -> LayoutRect {
        guard width > 2 * amount, height > 2 * amount else { return self }
        return LayoutRect(x: x + amount, y: y + amount, width: width - 2 * amount, height: height - 2 * amount)
    }
}

/// Accumulated quadratic surface z = sxx x² + sx x + syy y² + sy y, as in van Wijk and van de Wetering cushion treemaps.
public struct CushionCoefficients: Equatable {
    public var sxx: Float = 0
    public var sx: Float = 0
    public var syy: Float = 0
    public var sy: Float = 0
    public static let baseHeight = 0.75
    public static let heightFalloff = 0.75

    public init() {}

    public init(sxx: Float, sx: Float, syy: Float, sy: Float) {
        self.sxx = sxx
        self.sx = sx
        self.syy = syy
        self.sy = sy
    }

    public static func height(atLevel level: Int) -> Double { baseHeight * pow(heightFalloff, Double(level)) }

    public func adding(rect: LayoutRect, height: Double) -> CushionCoefficients {
        var result = self

        if rect.width > 0 {
            result.sxx -= Float(4 * height / rect.width)
            result.sx += Float(4 * height * (rect.x + rect.x + rect.width) / rect.width)
        }

        if rect.height > 0 {
            result.syy -= Float(4 * height / rect.height)
            result.sy += Float(4 * height * (rect.y + rect.y + rect.height) / rect.height)
        }

        return result
    }

    /// Re-expresses the surface in coordinates relative to the given origin, so x = originX + localX.
    public func localized(toOriginX originX: Double, y originY: Double) -> CushionCoefficients {
        CushionCoefficients(
            sxx: sxx,
            sx: sx + 2 * sxx * Float(originX),
            syy: syy,
            sy: sy + 2 * syy * Float(originY)
        )
    }
}

import Foundation
import InventoryIndex

enum Preferences {
    private static let defaults = UserDefaults.standard

    static var units: ByteUnits {
        get { ByteUnits(rawValue: defaults.string(forKey: "units") ?? "") ?? .binary }
        set { defaults.set(newValue.rawValue, forKey: "units") }
    }

    static var minimumCellArea: Double {
        get {
            let value = defaults.double(forKey: "minimumCellArea")
            return value >= 1 ? value : 4
        }

        set { defaults.set(newValue, forKey: "minimumCellArea") }
    }

    static var colorMode: ColorMode {
        get { ColorMode(rawValue: defaults.integer(forKey: "colorMode")) ?? .storageClass }
        set { defaults.set(newValue.rawValue, forKey: "colorMode") }
    }
}

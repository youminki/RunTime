/// WindowActionCategory.swift

import Cocoa

enum WindowActionCategory {

    case halves, corners, thirds, max, size, display, move, other, sixths, fourths, eighths, ninths, twelfths, sixteenths, tiling

    var menuOrder: Int {
        switch self {
        case .size: return 0
        case .move: return 1
        case .thirds: return 2
        case .fourths: return 3
        case .sixths: return 4
        case .eighths: return 5
        case .ninths: return 6
        case .twelfths: return 7
        case .sixteenths: return 8
        case .tiling: return 9
        default: return 99
        }
    }

    var displayName: String {
        switch self {
        case .halves:
            return LS("Sides", tableName: "Main", value: "", comment: "")
        case .corners:
            return LS("Corners", tableName: "Main", value: "", comment: "")
        case .thirds:
            return LS("Thirds", tableName: "Main", value: "", comment: "")
        case .max:
            return LS("Maximize", tableName: "Main", value: "", comment: "")
        case .size:
            return LS("Size", tableName: "Main", value: "", comment: "")
        case .display:
            return LS("Display", tableName: "Main", value: "", comment: "")
        case .other:
            return LS("Other", tableName: "Main", value: "", comment: "")
        case .move:
            return LS("Move to Edge", tableName: "Main", value: "", comment: "")
        case .fourths:
            return LS("Fourths", tableName: "Main", value: "", comment: "")
        case .sixths:
            return LS("Sixths", tableName: "Main", value: "", comment: "")
        case .eighths:
            return LS("Eighths", tableName: "Main", value: "", comment: "")
        case .ninths:
            return LS("Ninths", tableName: "Main", value: "Ninths", comment: "")
        case .twelfths:
            return LS("Twelfths", tableName: "Main", value: "Twelfths", comment: "")
        case .sixteenths:
            return LS("Sixteenths", tableName: "Main", value: "Sixteenths", comment: "")
        case .tiling:
            return LS("Tiling", tableName: "Main", value: "Tiling", comment: "")
        }
    }
}

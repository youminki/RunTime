/// DispatchTimeExtension.swift

import Cocoa

extension DispatchTime {
    var uptimeMilliseconds: UInt64 { uptimeNanoseconds / 1_000_000 }
}

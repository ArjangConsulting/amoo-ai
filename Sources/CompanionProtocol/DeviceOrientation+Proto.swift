import AmooCore
import Protos

package extension Amoo_Orientation {
    init(_ orientation: DeviceOrientation) {
        self = switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }
}

package extension DeviceOrientation {
    /// `nil` for `unspecified` or a value from a newer companion.
    init?(_ orientation: Amoo_Orientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }
}

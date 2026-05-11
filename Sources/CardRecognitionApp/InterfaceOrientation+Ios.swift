#if os(iOS)
import UIKit

extension UIInterfaceOrientation {
    var cgImageOrientationForPortraitCamera: CGImagePropertyOrientation {
        switch self {
        case .portraitUpsideDown: .left
        case .landscapeRight: .up
        case .landscapeLeft: .down
        case .portrait, .unknown: .right
        @unknown default: .right
        }
    }
}

@MainActor
enum OrientationReader {
    static func preferredVideoOrientationHint() -> UIInterfaceOrientation {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            return .portrait
        }
        return scene.interfaceOrientation
    }
}
#endif

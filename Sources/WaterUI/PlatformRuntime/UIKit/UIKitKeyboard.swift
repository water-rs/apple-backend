#if canImport(UIKit)
import UIKit
import CWaterUI

extension CWaterUI.WuiKeyboardType {
    var uiKeyboardType: UIKeyboardType {
        switch self {
        case WuiKeyboardType_Email:
            return .emailAddress
        case WuiKeyboardType_Number:
            return .numberPad
        case WuiKeyboardType_PhoneNumber:
            return .phonePad
        case WuiKeyboardType_URL:
            return .URL
        default:
            return .default
        }
    }

    var isSecureEntry: Bool {
        self == WuiKeyboardType_Secure
    }
}
#endif

import CWaterUI
import SwiftUI

struct WuiSpacer: View, WuiComponent {
    static var id:WuiTypeId{
        waterui_spacer_id()
    }

    var body: some View {
        Spacer()
    }

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        
    }
}

import CWaterUI
import SwiftUI

struct WuiScrollView: View, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_scroll_view_id())
    
    var content: WuiAnyView

    var body: some View {
        // KEY FIX: Use GeometryReader to constrain content width to viewport
        // This ensures Text wraps properly and axis-expanding views fill width
        GeometryReader { geometry in
            SwiftUI.ScrollView(.vertical, showsIndicators: true) {
                content
                    .frame(width: geometry.size.width, alignment: .top)
            }
        }
    }

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        let scroll = waterui_force_as_scroll_view(anyview)
        self.content = .init(anyview: scroll.content, env: env)
    }
}

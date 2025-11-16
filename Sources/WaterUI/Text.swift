//
//  Text.swift
//
//
//  Created by Lexo Liu on 5/14/24.
//

import CWaterUI
import Foundation
import SwiftUI

// MARK: - Text View

struct WuiText: View, WuiComponent {
    static let id: String = Self.decodeId(waterui_text_id())

    @State private var content: WuiComputed<WuiStyledStr>
    private var env: WuiEnvironment

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init(text: waterui_force_as_text(anyview), env: env)
    }

    init(text: CWaterUI.WuiText, env: WuiEnvironment) {
        self.env = env
        self.content = WuiComputed(text.content)
    }

    init(styledStr: WuiComputed<WuiStyledStr>, env: WuiEnvironment) {
        self.env = env
        self.content = styledStr
    }

    var body: some View {
        #if canImport(UIKit)
        UIKitTextRepresentable(content: content, env: env)
        #else
        toSwiftUIText()
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    #if !canImport(UIKit)
    func toSwiftUIText() -> SwiftUI.Text {
        SwiftUI.Text(content.value.toAttributedString(env: env))
    }
    #endif
}

#if canImport(UIKit)
@MainActor
private struct UIKitTextRepresentable: UIViewRepresentable {
    var content: WuiComputed<WuiStyledStr>
    var env: WuiEnvironment

    func makeUIView(context: Context) -> UIKitTextHost {
        UIKitTextHost(content: content, env: env)
    }

    func updateUIView(_ uiView: UIKitTextHost, context: Context) {
        // UIKitTextHost listens to watchers directly; no incremental updates needed.
    }
}
#endif

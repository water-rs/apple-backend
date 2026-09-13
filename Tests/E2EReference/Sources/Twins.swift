// Twin registry and shared translation helpers.
//
// Each twin is a hand-written SwiftUI reproduction of a waterui example's first
// screen. The translation rules are fixed and mechanical:
//
//   vstack/hstack bare            -> VStack/HStack with spacing 10 (WaterUI's
//                                    default stack spacing)
//   .spacing(n)                    -> spacing: n
//   .alignment(Leading)            -> alignment: .leading
//   .padding()                     -> .padding(14) (WaterUI's default padding)
//   .padding_with(all(n))          -> .padding(n)
//   .padding_with(symmetric(v, h)) -> .padding(.vertical, v).padding(.horizontal, h)
//   .width/.height/.size           -> .frame(...)
//   .min_width/.min_height         -> .frame(minWidth:, minHeight:)
//   text(...).title()/.headline()  -> .font(.title)/.font(.headline) ...
//   text(...).size(n)              -> .font(.system(size: n))
//   .bold()                        -> .bold()
//   Srgb::from_hex("#RRGGBB")      -> Color(.sRGB, red:..., green:..., blue:...)
//   .with_opacity(x)               -> .opacity(x) on the Color
//   Foreground / MutedForeground   -> .primary / .secondary
//   Divider                        -> Divider()
//   spacer() / spacer().height(n)  -> Spacer() / Spacer().frame(height: n)
//   button("X").action(...)        -> Button("X") {}
//   Toggle::new("X", &b)           -> Toggle("X", isOn:)
//   TextField::new("X", &b)        -> label above + TextField, matching
//                                    WuiTextField's label-over-field layout
//
// Interactive bindings become @State with their initial values; gesture
// handlers are omitted because only the settled first screen is compared.

import SwiftUI

struct TwinRoot: View {
  private var example: String {
    UserDefaults.standard.string(forKey: "E2EExample") ?? ""
  }

  var body: some View {
    switch example {
    case "animation": AnimationTwin()
    case "drag_drop": DragDropTwin()
    case "form": FormTwin()
    case "gesture": GestureTwin()
    case "hover": HoverTwin()
    case "list": ListTwin()
    case "multi_window": MultiWindowTwin()
    case "navigation": NavigationTwin()
    case "snackbar": SnackbarTwin()
    case "typography-rtl": TypographyRtlTwin()
    default:
      Text("No SwiftUI twin registered for example '\(example)'")
    }
  }
}

// MARK: - Translation helpers

/// `Color::srgb_hex("#RRGGBB")`
func srgbHex(_ hex: UInt32) -> Color {
  Color(
    .sRGB,
    red: Double((hex >> 16) & 0xFF) / 255,
    green: Double((hex >> 8) & 0xFF) / 255,
    blue: Double(hex & 0xFF) / 255
  )
}

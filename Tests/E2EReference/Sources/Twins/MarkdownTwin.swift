// Twin of examples/markdown: the example renders `include_markdown!("example.md")`
// inside a scroll view. `Text(AttributedString(markdown:))` does not style
// headings, lists, blockquotes or tables, so the twin rebuilds the document as
// the equivalent hand-written SwiftUI tree — what a SwiftUI developer would
// produce for the same content.
//
// WaterUI markdown chrome reproduced here (heading levels consume the
// framework's semantic font slots, resolved to platform text styles):
//   # -> .title bold, ## -> .headline bold, ### -> .body bold
//   fenced blocks get a header row (language name + Copy) over a gray field

import SwiftUI

struct MarkdownTwin: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("WaterUI Markdown").font(.title).bold()
                Text("WaterUI supports rendering **Markdown** content natively across all platforms.")

                heading("Text Formatting")
                Text("You can use **bold**, *italic*, and `inline code` in your text. Combine them for ***bold italic*** text.")

                heading("Code Blocks")
                Text("Here's a Rust example:")
                codeBlock("Rust", """
                    fn main() {
                        println!("Hello, WaterUI!");
                    }
                    """)
                Text("And some Swift code:")
                codeBlock("Swift", """
                    import SwiftUI

                    struct ContentView: View {
                        var body: some View {
                            Text("Hello, World!")
                        }
                    }
                    """)

                heading("Lists")
                Text("Unordered List").font(.body).bold()
                VStack(alignment: .leading, spacing: 4) {
                    bullet("First item")
                    bullet("Second item")
                    bullet("Third item")
                }
                Text("Ordered List").font(.body).bold()
                VStack(alignment: .leading, spacing: 4) {
                    numbered(1, "Step one")
                    numbered(2, "Step two")
                    numbered(3, "Step three")
                }

                heading("Blockquotes")
                HStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                    Text("WaterUI brings the power of native UI to Rust developers.\nBuild once, run everywhere.")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }

                heading("Tables")
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Platform").bold()
                        Text("Backend").bold()
                        Text("Status").bold()
                    }
                    Divider()
                    GridRow { Text("iOS"); Text("SwiftUI"); Text("Ready") }
                    GridRow { Text("macOS"); Text("AppKit"); Text("Ready") }
                    GridRow { Text("Android"); Text("View"); Text("Ready") }
                }

                Divider()

                Text("Visit [WaterUI on GitHub](https://github.com/water-rs/waterui) for more information.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.headline).bold()
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(s)
        }
    }

    private func numbered(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).")
            Text(s)
        }
    }

    private func codeBlock(_ lang: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lang).font(.headline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Copy").foregroundStyle(.blue)
            }
            Text(s)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

import SwiftUI

/// Scrollable monospaced view of the artifact's source, with the Copy HTML
/// button — the primary way to get an artifact out of the app (paste into
/// the GitHub app, a gist, anywhere).
struct CodeView: View {
  let html: String

  @State private var copied = false

  var body: some View {
    ScrollView([.vertical, .horizontal]) {
      Text(html)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .safeAreaInset(edge: .bottom) {
      Button {
        UIPasteboard.general.string = html
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          copied = false
        }
      } label: {
        Label(
          copied ? "Copied!" : "Copy HTML",
          systemImage: copied ? "checkmark" : "doc.on.doc"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .padding()
      .background(.bar)
    }
  }
}

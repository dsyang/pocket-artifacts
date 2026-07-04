import SwiftUI
import WebKit

/// Renders artifact HTML in a WKWebView. The HTML is written to a temp file
/// and loaded with `loadFileURL(_:allowingReadAccessTo:)` — a file-URL origin
/// gives localStorage and relative-path behavior a saner baseline than
/// `loadHTMLString`, while remote CDN loads still work.
///
/// Gesture ownership: back/forward swipes stay disabled so edge gestures
/// belong to the artifact, and bounce is off so the page doesn't rubber-band.
struct PreviewWebView: UIViewRepresentable {
  let html: String
  /// Monotonically increasing token; the web view reloads only when this
  /// changes, not on every SwiftUI update pass.
  let version: Int

  final class Coordinator {
    var loadedVersion: Int?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.allowsInlineMediaPlayback = true

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = false
    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.isInspectable = true
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    guard context.coordinator.loadedVersion != version else { return }
    context.coordinator.loadedVersion = version

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ArtifactPreview", isDirectory: true)
    let fileURL = directory.appendingPathComponent("artifact.html")
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
      )
      try html.write(to: fileURL, atomically: true, encoding: .utf8)
      webView.loadFileURL(fileURL, allowingReadAccessTo: directory)
    } catch {
      webView.loadHTMLString(html, baseURL: nil)
    }
  }
}

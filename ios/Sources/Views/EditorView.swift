import ComposableArchitecture
import SwiftUI

/// Full-screen editor: segmented Chat / Preview / Code tabs. The preview is
/// deliberately a full-screen tab (never a drag-dismissable sheet) so every
/// swipe belongs to the artifact, not to sheet dismissal.
struct EditorView: View {
  @Bindable var store: StoreOf<EditorFeature>

  var body: some View {
    VStack(spacing: 0) {
      Picker("View", selection: $store.tab) {
        ForEach(EditorFeature.State.Tab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)

      switch store.tab {
      case .chat:
        ChatView(store: store)

      case .preview:
        if let html = store.currentHTML {
          PreviewWebView(html: html, version: store.htmlVersion)
            .ignoresSafeArea(edges: .bottom)
        } else {
          emptyState(
            "No artifact yet",
            systemImage: "sparkles",
            description: "Describe the app you want in the Chat tab."
          )
        }

      case .code:
        if let html = store.currentHTML {
          CodeView(html: html)
        } else {
          emptyState(
            "No HTML yet",
            systemImage: "chevron.left.forwardslash.chevron.right",
            description: "Generated source will appear here."
          )
        }
      }
    }
    .navigationTitle(store.artifact.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          store.send(.historyButtonTapped)
        } label: {
          Image(systemName: "clock.arrow.circlepath")
        }
        .disabled(store.versions.isEmpty)
        .accessibilityLabel("Version history")
      }
    }
    .task {
      store.send(.task)
    }
    .sheet(
      item: $store.scope(state: \.versionHistory, action: \.versionHistory)
    ) { historyStore in
      VersionHistoryView(store: historyStore)
    }
  }

  private func emptyState(
    _ title: String, systemImage: String, description: String
  ) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(description)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

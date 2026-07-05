import ComposableArchitecture
import SwiftUI

/// Browse an artifact's version history, preview any version full-screen,
/// and restore an old one — restore copies it forward as the newest version
/// (history is never rewritten). The editor owns the actual restore.
@Reducer
struct VersionHistoryFeature {
  @ObservableState
  struct State: Equatable {
    /// Newest first; the first element is the current version.
    var versions: IdentifiedArrayOf<ArtifactVersion>
    var previewVersion: ArtifactVersion?
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case previewTapped(ArtifactVersion)
    case closePreviewTapped
    case restoreTapped(ArtifactVersion)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case restore(ArtifactVersion)
    }
  }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .previewTapped(let version):
        state.previewVersion = version
        return .none

      case .closePreviewTapped:
        state.previewVersion = nil
        return .none

      case .restoreTapped(let version):
        return .send(.delegate(.restore(version)))

      case .delegate:
        return .none
      }
    }
  }
}

struct VersionHistoryView: View {
  @Bindable var store: StoreOf<VersionHistoryFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List(store.versions) { version in
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Version \(version.number)")
              .font(.headline)
            Text(version.createdAt, format: .dateTime.month().day().hour().minute())
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Preview") {
            store.send(.previewTapped(version))
          }
          .buttonStyle(.bordered)
          if version.id == store.versions.first?.id {
            Text("Current")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
          } else {
            Button("Restore") {
              store.send(.restoreTapped(version))
            }
            .buttonStyle(.borderedProminent)
          }
        }
        .buttonStyle(.borderless)
      }
      .navigationTitle("Versions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
    // Full-screen with an explicit Close button — never a drag-dismissable
    // sheet, so every swipe inside the preview belongs to the artifact.
    .fullScreenCover(item: $store.previewVersion) { version in
      NavigationStack {
        PreviewWebView(html: version.html, version: version.number)
          .ignoresSafeArea(edges: .bottom)
          .navigationTitle("Version \(version.number)")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              Button("Close") {
                store.send(.closePreviewTapped)
              }
            }
          }
      }
    }
  }
}

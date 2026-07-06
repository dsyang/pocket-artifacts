import ComposableArchitecture
import SwiftUI

/// The artifact library: list (most recently updated first), create, and
/// delete. Opening an artifact is delegated to the root feature, which
/// pushes an editor onto the navigation stack.
@Reducer
struct LibraryFeature {
  @ObservableState
  struct State: Equatable {
    var artifacts: IdentifiedArrayOf<Artifact> = []
    var isLoading = false
    var errorMessage: String?
    /// Artifacts with a generation currently in flight — the service keeps
    /// running these even while the user is here in the library.
    var generatingArtifactIDs: Set<UUID> = []
  }

  enum Action: Equatable {
    case task
    case refresh
    case artifactsLoaded([Artifact])
    case loadFailed(String)
    case createTapped
    case artifactCreated(Artifact)
    case artifactTapped(Artifact)
    case deleteTapped(id: UUID)
    case activeGenerationsChanged(Set<UUID>)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case openArtifact(Artifact)
    }
  }

  @Dependency(\.databaseClient) var database
  @Dependency(\.generationClient) var generation
  @Dependency(\.uuid) var uuid
  @Dependency(\.date) var date

  private enum CancelID { case activeGenerations }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        state.isLoading = state.artifacts.isEmpty
        return .merge(
          fetchArtifacts(),
          // A long-lived subscription (the library sits at the stack root for
          // the app's lifetime) reflecting which artifacts are generating.
          .run { send in
            for await ids in await generation.activeArtifactIDs() {
              await send(.activeGenerationsChanged(ids))
            }
          }
          .cancellable(id: CancelID.activeGenerations, cancelInFlight: true)
        )

      case .refresh:
        state.isLoading = state.artifacts.isEmpty
        return fetchArtifacts()

      case .artifactsLoaded(let artifacts):
        state.isLoading = false
        state.artifacts = IdentifiedArray(uniqueElements: artifacts)
        return .none

      case .loadFailed(let message):
        state.isLoading = false
        state.errorMessage = message
        return .none

      case .createTapped:
        let now = date()
        let artifact = Artifact(id: uuid(), title: "Untitled", createdAt: now, updatedAt: now)
        return .run { send in
          try await database.createArtifact(artifact)
          await send(.artifactCreated(artifact))
        } catch: { error, send in
          await send(.loadFailed(error.localizedDescription))
        }

      case .artifactCreated(let artifact):
        state.artifacts.insert(artifact, at: 0)
        return .send(.delegate(.openArtifact(artifact)))

      case .artifactTapped(let artifact):
        return .send(.delegate(.openArtifact(artifact)))

      case .deleteTapped(let id):
        state.artifacts.remove(id: id)
        return .run { _ in
          try await database.deleteArtifact(id)
        } catch: { error, send in
          await send(.loadFailed(error.localizedDescription))
        }

      case .activeGenerationsChanged(let ids):
        // If a generation finished while the user sat here, its artifact may
        // have been retitled/touched — reload so titles and ordering refresh.
        let anyFinished = !state.generatingArtifactIDs.subtracting(ids).isEmpty
        state.generatingArtifactIDs = ids
        return anyFinished ? .send(.refresh) : .none

      case .delegate:
        return .none
      }
    }
  }

  private func fetchArtifacts() -> Effect<Action> {
    .run { send in
      try await send(.artifactsLoaded(database.fetchArtifacts()))
    } catch: { error, send in
      await send(.loadFailed(error.localizedDescription))
    }
  }
}

struct LibraryView: View {
  let store: StoreOf<LibraryFeature>

  var body: some View {
    Group {
      if store.artifacts.isEmpty {
        if store.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView {
            Label("No artifacts yet", systemImage: "sparkles")
          } description: {
            Text("Describe a small app and keep every version of it, right on your phone.")
          } actions: {
            Button("New Artifact") {
              store.send(.createTapped)
            }
            .buttonStyle(.borderedProminent)
          }
        }
      } else {
        List {
          ForEach(store.artifacts) { artifact in
            Button {
              store.send(.artifactTapped(artifact))
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text(artifact.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                  Text(
                    "Updated \(artifact.updatedAt, format: .relative(presentation: .named))"
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }
                if store.generatingArtifactIDs.contains(artifact.id) {
                  Spacer()
                  ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Generating")
                }
              }
            }
          }
          .onDelete { offsets in
            for offset in offsets {
              store.send(.deleteTapped(id: store.artifacts[offset].id))
            }
          }
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          store.send(.createTapped)
        } label: {
          Image(systemName: "plus")
        }
        .accessibilityLabel("New artifact")
      }
    }
    .task {
      store.send(.task)
    }
  }
}

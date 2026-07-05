import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

@MainActor
final class LibraryFeatureTests: XCTestCase {
  static let now = Date(timeIntervalSince1970: 1_234_567_890)

  func testTaskLoadsArtifactsNewestFirst() async {
    let artifacts = [
      Artifact(id: UUID(1), title: "Timer", createdAt: Self.now, updatedAt: Self.now),
      Artifact(id: UUID(0), title: "Tips", createdAt: Self.now, updatedAt: Self.now),
    ]

    let store = TestStore(initialState: LibraryFeature.State()) {
      LibraryFeature()
    } withDependencies: {
      $0.databaseClient.fetchArtifacts = { artifacts }
    }

    await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(.artifactsLoaded(artifacts)) {
      $0.isLoading = false
      $0.artifacts = IdentifiedArray(uniqueElements: artifacts)
    }
  }

  func testCreatePersistsAndOpensEditor() async {
    let created = LockIsolated<[Artifact]>([])

    let store = TestStore(initialState: LibraryFeature.State()) {
      LibraryFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.databaseClient.createArtifact = { artifact in
        created.withValue { $0.append(artifact) }
      }
    }

    let artifact = Artifact(
      id: UUID(0), title: "Untitled", createdAt: Self.now, updatedAt: Self.now
    )
    await store.send(.createTapped)
    await store.receive(.artifactCreated(artifact)) {
      $0.artifacts = [artifact]
    }
    await store.receive(.delegate(.openArtifact(artifact)))
    XCTAssertEqual(created.value, [artifact])
  }

  func testTapOpensEditor() async {
    let artifact = Artifact(
      id: UUID(0), title: "Tips", createdAt: Self.now, updatedAt: Self.now
    )
    let store = TestStore(
      initialState: LibraryFeature.State(artifacts: [artifact])
    ) {
      LibraryFeature()
    }

    await store.send(.artifactTapped(artifact))
    await store.receive(.delegate(.openArtifact(artifact)))
  }

  func testDeleteRemovesFromListAndDatabase() async {
    let artifact = Artifact(
      id: UUID(0), title: "Tips", createdAt: Self.now, updatedAt: Self.now
    )
    let deleted = LockIsolated<[UUID]>([])

    let store = TestStore(
      initialState: LibraryFeature.State(artifacts: [artifact])
    ) {
      LibraryFeature()
    } withDependencies: {
      $0.databaseClient.deleteArtifact = { id in
        deleted.withValue { $0.append(id) }
      }
    }

    await store.send(.deleteTapped(id: artifact.id)) {
      $0.artifacts = []
    }
    XCTAssertEqual(deleted.value, [artifact.id])
  }
}

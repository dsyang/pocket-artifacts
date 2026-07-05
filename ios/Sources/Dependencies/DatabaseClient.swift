import Dependencies
import DependenciesMacros
import Foundation
import GRDB

/// TCA dependency for local persistence: artifacts, their versions, and
/// their chat transcripts, in SQLite via GRDB. Deleting an artifact
/// cascades to its versions and messages.
@DependencyClient
struct DatabaseClient: Sendable {
  /// All artifacts, most recently updated first.
  var fetchArtifacts: @Sendable () async throws -> [Artifact]
  var createArtifact: @Sendable (Artifact) async throws -> Void
  var updateArtifact: @Sendable (Artifact) async throws -> Void
  var deleteArtifact: @Sendable (UUID) async throws -> Void
  /// One artifact's transcript, in insertion order.
  var fetchMessages: @Sendable (_ artifactID: UUID) async throws -> [ChatMessage]
  var saveMessage: @Sendable (_ message: ChatMessage, _ artifactID: UUID) async throws -> Void
  /// One artifact's versions, ordered by number ascending (newest last).
  var fetchVersions: @Sendable (_ artifactID: UUID) async throws -> [ArtifactVersion]
  var createVersion: @Sendable (ArtifactVersion) async throws -> Void
}

extension Artifact: FetchableRecord, PersistableRecord {
  static var databaseTableName: String { "artifact" }
}

extension ArtifactVersion: FetchableRecord, PersistableRecord {
  static var databaseTableName: String { "artifactVersion" }
}

/// Storage shape of a chat message: adds the owning artifact and flattens
/// the role to a string so the schema translates 1:1 to Room on Android.
/// Transcript order is insertion order (the implicit SQLite rowid).
private struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
  static var databaseTableName: String { "message" }

  var id: UUID
  var artifactID: UUID
  var role: String
  var content: String
  var isFailed: Bool

  init(message: ChatMessage, artifactID: UUID) {
    self.id = message.id
    self.artifactID = artifactID
    self.role = message.role.rawValue
    self.content = message.content
    self.isFailed = message.isFailed
  }

  var chatMessage: ChatMessage {
    ChatMessage(
      id: id,
      role: ChatMessage.Role(rawValue: role) ?? .assistant,
      content: content,
      isFailed: isFailed
    )
  }
}

extension DatabaseClient: DependencyKey {
  static let liveValue: DatabaseClient = {
    do {
      let directory = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let path = directory.appendingPathComponent("pocket-artifacts.sqlite").path
      return try .live(dbQueue: DatabaseQueue(path: path))
    } catch {
      // The user's library lives here; running without it would silently
      // drop everything they make, so an unopenable database is fatal.
      fatalError("Failed to open database: \(error)")
    }
  }()

  static let testValue = DatabaseClient()

  /// A fresh in-memory database with the full schema — integration tests.
  static func inMemory() -> DatabaseClient {
    try! .live(dbQueue: DatabaseQueue())
  }

  static func live(dbQueue: DatabaseQueue) throws -> DatabaseClient {
    try migrator.migrate(dbQueue)
    return DatabaseClient(
      fetchArtifacts: {
        try await dbQueue.read { db in
          try Artifact.order(Column("updatedAt").desc).fetchAll(db)
        }
      },
      createArtifact: { artifact in
        try await dbQueue.write { db in
          try artifact.insert(db)
        }
      },
      updateArtifact: { artifact in
        try await dbQueue.write { db in
          try artifact.update(db)
        }
      },
      deleteArtifact: { id in
        _ = try await dbQueue.write { db in
          try Artifact.deleteOne(db, key: id)
        }
      },
      fetchMessages: { artifactID in
        try await dbQueue.read { db in
          try MessageRecord
            .filter(Column("artifactID") == artifactID)
            .order(Column.rowID)
            .fetchAll(db)
            .map(\.chatMessage)
        }
      },
      saveMessage: { message, artifactID in
        try await dbQueue.write { db in
          try MessageRecord(message: message, artifactID: artifactID).save(db)
        }
      },
      fetchVersions: { artifactID in
        try await dbQueue.read { db in
          try ArtifactVersion
            .filter(Column("artifactID") == artifactID)
            .order(Column("number"))
            .fetchAll(db)
        }
      },
      createVersion: { version in
        try await dbQueue.write { db in
          try version.insert(db)
        }
      }
    )
  }

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "artifact") { t in
        t.primaryKey("id", .blob)
        t.column("title", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "artifactVersion") { t in
        t.primaryKey("id", .blob)
        t.column("artifactID", .blob).notNull().indexed()
          .references("artifact", onDelete: .cascade)
        t.column("number", .integer).notNull()
        t.column("html", .text).notNull()
        t.column("createdAt", .datetime).notNull()
      }
      try db.create(table: "message") { t in
        t.primaryKey("id", .blob)
        t.column("artifactID", .blob).notNull().indexed()
          .references("artifact", onDelete: .cascade)
        t.column("role", .text).notNull()
        t.column("content", .text).notNull()
        t.column("isFailed", .boolean).notNull().defaults(to: false)
      }
    }
    // Model choice moved from a single app-wide preference to a per-artifact
    // field. Existing artifacts predate the column, so backfill them with the
    // default model rather than leaving it null.
    migrator.registerMigration("v2-per-artifact-model") { db in
      try db.alter(table: "artifact") { t in
        t.add(column: "model", .text).notNull().defaults(to: OpenRouterClient.defaultModel)
      }
    }
    return migrator
  }
}

extension DependencyValues {
  var databaseClient: DatabaseClient {
    get { self[DatabaseClient.self] }
    set { self[DatabaseClient.self] = newValue }
  }
}

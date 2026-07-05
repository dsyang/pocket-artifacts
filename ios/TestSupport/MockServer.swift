import FlyingFox
import FlyingSocks
import Foundation

/// Localhost stand-in for OpenRouter: serves a scripted chat completion as
/// a real SSE response plus a static /models list, and records chat request
/// bodies so tests can assert on the exact payloads sent.
///
/// Used by the headless integration tests (live OpenRouterClient + real
/// reducers + in-memory GRDB), and later by UI tests via `--mock-server`.
actor MockServer {
  enum MockServerError: Error {
    case notListeningOnInetPort
  }

  let scenario: Scenario
  private var server: HTTPServer?
  private var runTask: Task<Void, Never>?
  private(set) var chatRequestBodies: [Data] = []

  init(scenario: Scenario) {
    self.scenario = scenario
  }

  /// Starts listening on an ephemeral loopback port; returns the base URL
  /// to inject into `OpenRouterClient.live(baseURL:)`.
  func start() async throws -> URL {
    let server = HTTPServer(address: .loopback(port: 0))

    await server.appendRoute("POST /api/v1/chat/completions") { [weak self] request in
      let body = try await request.bodyData
      await self?.recordChatRequest(body)
      guard let self else { return HTTPResponse(statusCode: .internalServerError) }
      return HTTPResponse(
        statusCode: .ok,
        headers: [.contentType: "text/event-stream"],
        body: self.scenario.sseBody
      )
    }

    await server.appendRoute("GET /api/v1/models") { [modelsJSON = scenario.modelsJSON] _ in
      HTTPResponse(
        statusCode: .ok,
        headers: [.contentType: "application/json"],
        body: Data(modelsJSON.utf8)
      )
    }

    self.server = server
    self.runTask = Task {
      try? await server.run()
    }
    try await server.waitUntilListening()

    switch await server.listeningAddress {
    case .ip4(_, port: let port):
      return URL(string: "http://127.0.0.1:\(port)")!
    case .ip6(_, port: let port):
      return URL(string: "http://[::1]:\(port)")!
    case .unix, nil:
      throw MockServerError.notListeningOnInetPort
    }
  }

  func stop() async {
    await server?.stop(timeout: 0)
    runTask?.cancel()
    server = nil
    runTask = nil
  }

  private func recordChatRequest(_ body: Data) {
    chatRequestBodies.append(body)
  }
}

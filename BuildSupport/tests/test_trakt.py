"""Run the production Trakt state/refresh policies without UIKit or real accounts."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which(os.environ.get("SWIFTC", "swiftc"))


def production_checks_source():
    source = (ROOT / "Vesper/Infrastructure/Services/TraktAccountStore.swift").read_text()
    values = source[source.index("struct TraktAccountSettings:"):source.index("/// Shared by both engines.")]
    values += source[source.index("enum EmbyProgressSource:"):source.index("extension TraktAccountStore {")]
    values += source[source.index("enum TraktResumeProgress:"):]
    refresh = source[source.index("    private func accessToken("):source.index("    /// One refresh/replay")]
    refresh = refresh.replace("private func accessToken", "func accessToken", 1)
    api = source[source.index("    func api("):source.index("    private func save(")]
    return """import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@MainActor final class FakeNetwork {
    var statuses: [Int] = []
    var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let status = statuses.removeFirst()
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                 httpVersion: nil, headerFields: ["Retry-After": "7"])!)
    }
}
@MainActor final class Harness {
    typealias Token = TraktToken
    enum Failure: Error { case disconnected, storage, network }
    struct HTTPFailure: Error { let status: Int; var retryAfter: TimeInterval? = nil }
    var isConnected = true
    let network = FakeNetwork()
    var token: Token? = Token(access_token: "old", refresh_token: "refresh", created_at: 0, expires_in: 100)
    var accountRevision = UUID()
    var refreshing: Task<Token, Error>?
    var refreshID = UUID()
    var calls = 0
    var saved = false
    var disconnected = false
    var storageFails = false
    var responseStatus: Int?
    var networkFails = false
    func requestToken(_ fields: [String: String]) async throws -> Token {
        precondition(fields["grant_type"] == "refresh_token")
        precondition(fields["refresh_token"] == "refresh")
        calls += 1
        try await Task.sleep(for: .milliseconds(10))
        if let responseStatus { throw HTTPFailure(status: responseStatus) }
        if networkFails { throw URLError(.notConnectedToInternet) }
        return Token(access_token: "new", refresh_token: "rotated", created_at: Date().timeIntervalSince1970, expires_in: 600)
    }
    func save(_ token: Token) throws {
        if storageFails { throw Failure.storage }
        precondition(token.refresh_token == "rotated")
        saved = true
    }
    func disconnect() {
        disconnected = true
        isConnected = false
        token = nil
        accountRevision = UUID()
        refreshing?.cancel()
        refreshing = nil
        refreshID = UUID()
    }
""" + refresh + api + """
}
enum TraktConfiguration {
    static let clientID = "test-client"
    static let redirectURI = "test://callback"
}
""" + values + (ROOT / "Tests/TraktChecks.swift").read_text()


class TraktChecks(unittest.TestCase):
    def test_progress_clear_uses_playback_delete(self):
        source = (ROOT / "Vesper/Infrastructure/Services/TraktAccountStore.swift").read_text()
        clear = source.split("func clearPlaybackProgress(", 1)[1].split("/// Fetch paused playback progress", 1)[0]
        self.assertIn('"sync/playback/\\(category)"', clear)
        self.assertIn('"sync/playback/\\(id)"', clear)
        self.assertIn('method: "DELETE"', clear)

    @unittest.skipUnless(SWIFTC, "Swift compiler is required")
    def test_state_matching_and_refresh(self):
        with tempfile.TemporaryDirectory(prefix="vesper-trakt-") as directory:
            unit = Path(directory) / "Checks.swift"
            binary = Path(directory) / "checks"
            unit.write_text(production_checks_source())
            subprocess.run([SWIFTC, "-swift-version", "6", "-parse-as-library",
                            str(unit), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

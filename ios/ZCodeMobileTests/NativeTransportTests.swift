import XCTest
@testable import ZCodeMobile

/// Run only with the isolated loopback fixture. No desktop task or system trust changes.
@MainActor
final class NativeTransportTests: XCTestCase {
    private struct Fixture: Decodable {
        var baseURL: String
        var token: String
        var certificateSHA256: String
        var wrongHostnameURL: String?
        var wrongHostnameSHA256: String?
    }
    private struct Health: Decodable, Sendable { var ok: Bool }

    private func fixture() throws -> Fixture {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tls-acceptance.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("The isolated TLS acceptance fixture is not installed.")
        }
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        guard URL(string: value.baseURL)?.host == "127.0.0.1" else {
            throw XCTSkip("Only the isolated loopback fixture is allowed.")
        }
        return value
    }

    func testPinnedHTTPSRequest() async throws {
        let f = try fixture()
        let client = BridgeClient(baseURL: try XCTUnwrap(URL(string: f.baseURL)), token: f.token,
                                  certificateSHA256: f.certificateSHA256)
        let response: Health = try await client.get("health")
        XCTAssertTrue(response.ok)
    }

    func testWrongPinIsRejected() async throws {
        let f = try fixture()
        let client = BridgeClient(baseURL: try XCTUnwrap(URL(string: f.baseURL)), token: f.token,
                                  certificateSHA256: String(repeating: "0", count: 64))
        do {
            let _: Health = try await client.get("health")
            XCTFail("A mismatched certificate must not be accepted.")
        } catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSURLErrorDomain)
            XCTAssertTrue([-999, -1012, -1200, -1202].contains(failure.code),
                          "Expected an authentication rejection, received code \(failure.code)")
        }
    }

    func testPinnedCertificateStillRequiresMatchingHostname() async throws {
        let f = try fixture()
        guard let raw = f.wrongHostnameURL, let pin = f.wrongHostnameSHA256,
              let url = URL(string: raw), url.host == "127.0.0.1" else {
            throw XCTSkip("The hostname mismatch fixture is not installed.")
        }
        let client = BridgeClient(baseURL: url, token: f.token, certificateSHA256: pin)
        do {
            let _: Health = try await client.get("health")
            XCTFail("A valid pin must not bypass hostname validation.")
        } catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSURLErrorDomain)
            XCTAssertTrue([-999, -1012, -1200, -1202].contains(failure.code),
                          "Expected an authentication rejection, received code \(failure.code)")
        }
    }

    func testRedirectIsNotFollowed() async throws {
        let f = try fixture()
        let client = BridgeClient(baseURL: try XCTUnwrap(URL(string: f.baseURL)), token: f.token,
                                  certificateSHA256: f.certificateSHA256)
        do {
            let _: Health = try await client.get("redirect")
            XCTFail("Redirects must not forward the pairing credential.")
        } catch let error as BridgeFailure {
            XCTAssertEqual(error.code, "http_302")
        }
    }

    func testPinnedHTTPSDeliversSSE() async throws {
        let f = try fixture()
        let client = BridgeClient(baseURL: try XCTUnwrap(URL(string: f.baseURL)), token: f.token,
                                  certificateSHA256: f.certificateSHA256)
        let received = expectation(description: "A real HTTPS SSE event is decoded")
        received.assertForOverFulfill = false
        let stream = Task {
            try await client.events(after: nil) { event in
                if event.type == "ready" { received.fulfill() }
            }
        }
        await fulfillment(of: [received], timeout: 8)
        stream.cancel()
        _ = await stream.result
    }
}

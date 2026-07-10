import XCTest
@testable import ForefrontModels
@testable import ForefrontNetworking

final class EndpointRotatorTests: XCTestCase {

    func testPrimarySuccess() async throws {
        let rotator = EndpointRotator(endpoints: [
            URL(string: "https://primary")!,
            URL(string: "https://fallback")!
        ])
        let result: String = try await rotator.withFallback { url in
            return url.absoluteString
        }
        XCTAssertEqual(result, "https://primary")
        let idx = await rotator.lastSuccessIndex
        XCTAssertEqual(idx, 0)
    }

    func testPrimaryFailsFallbackSucceeds() async throws {
        let rotator = EndpointRotator(endpoints: [
            URL(string: "https://primary")!,
            URL(string: "https://fallback")!
        ])
        let result: String = try await rotator.withFallback { url in
            if url.host == "primary" { throw ForefrontNetworkError.transport("boom") }
            return url.absoluteString
        }
        XCTAssertEqual(result, "https://fallback")
        let idx = await rotator.lastSuccessIndex
        XCTAssertEqual(idx, 1)
    }

    func testAllFail() async throws {
        let rotator = EndpointRotator(endpoints: [
            URL(string: "https://a")!,
            URL(string: "https://b")!
        ])
        do {
            _ = try await rotator.withFallback { _ in
                throw ForefrontNetworkError.transport("boom")
            }
            XCTFail("Expected throw")
        } catch ForefrontNetworkError.transport, ForefrontNetworkError.allEndpointsExhausted {
            // Either is acceptable: the last seen retryable error or the explicit exhausted marker.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnauthorizedShortCircuits() async throws {
        let rotator = EndpointRotator(endpoints: [
            URL(string: "https://primary")!,
            URL(string: "https://fallback")!
        ])
        // The rotator's `attempt` closure is `@Sendable`, so a captured `var`
        // cannot be mutated inside it under strict concurrency. An actor box
        // provides safe cross-isolation mutation.
        let fallbackTried = FlagBox()
        do {
            _ = try await rotator.withFallback { url in
                if url.host == "primary" { throw ForefrontNetworkError.unauthorized }
                await fallbackTried.set()
                return ""
            }
            XCTFail("Expected throw")
        } catch ForefrontNetworkError.unauthorized {
            let tried = await fallbackTried.value
            XCTAssertFalse(tried, "401 must short-circuit the rotator")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// Actor-isolated boolean flag for safe mutation from within a `@Sendable`
/// closure under strict concurrency checking.
private actor FlagBox {
    private(set) var value = false
    func set() { value = true }
}

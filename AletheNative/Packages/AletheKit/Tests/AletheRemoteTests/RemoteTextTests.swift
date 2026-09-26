import CoreImage
import Foundation
import Testing
@testable import AletheRemote

/// Upstream `remote/util.rs` tests.
struct RemoteUtilGoldenTests {
    @Test func percentEncodedQueryValuesAreDecoded() {
        #expect(RemoteText.percentDecode("a%2Fb+c") == "a/b c")
    }

    @Test func tailscaleRangeAcceptsOnlyCGNATAddresses() {
        #expect(RemoteHost.isTailscaleRange("100.64.0.1"))
        #expect(RemoteHost.isTailscaleRange("100.127.255.255"))
        #expect(!RemoteHost.isTailscaleRange("100.63.255.255"))
        #expect(!RemoteHost.isTailscaleRange("100.128.0.0"))
        #expect(!RemoteHost.isTailscaleRange("192.168.1.1"))
        #expect(!RemoteHost.isTailscaleRange("not-an-ip"))
        #expect(!RemoteHost.isTailscaleRange(""))
    }
}

struct RemoteTextTests {
    @Test func tokensCompareByContentAndLength() {
        #expect(RemoteText.tokensEqual("abc", "abc"))
        #expect(!RemoteText.tokensEqual("abc", "abd"))
        #expect(!RemoteText.tokensEqual("abc", "abcd"))
        #expect(!RemoteText.tokensEqual("", "a"))
        #expect(RemoteText.tokensEqual("", ""))
    }

    @Test func sanitizingReplacesControlCharacters() {
        #expect(RemoteText.sanitize("ls\u{1B}[2J\r\nrm\u{7F}\u{85}é") == "ls [2J  rm  é")
    }

    @Test func queryValuesAreFoundAndDecoded() {
        #expect(RemoteText.queryValue("/api/scrollback?id=tab%201&since=5", "id") == "tab 1")
        #expect(RemoteText.queryValue("/api/transcript?id=a&since=42", "since") == "42")
        #expect(RemoteText.queryValue("/api/scrollback", "id") == nil)
        #expect(RemoteText.queryValue("/?flag&id=x", "id") == "x")
        #expect(RemoteText.percentDecode("100%") == "100%")
        #expect(RemoteText.percentDecode("%zz") == "%zz")
        #expect(RemoteText.percentDecode("%C3%A9") == "é")
    }

    @Test func tokensUseTheURLSafeAlphabet() {
        let token = RemoteText.randomToken(length: 40)
        #expect(token.count == 40)
        #expect(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(RemoteText.randomToken(length: 32) != RemoteText.randomToken(length: 32))
    }

    @Test func peerAddressesResolveToTheirIP() {
        #expect(RemoteHost.peerIP("192.168.0.44:5100") == "192.168.0.44")
        #expect(RemoteHost.peerIP("[::1]:5100") == "::1")
        #expect(RemoteHost.peerIP("10.0.0.1") == "10.0.0.1")
        #expect(RemoteHost.peerIP("Unknown device") == nil)
        #expect(RemoteHost.isBindableAddress("[fe80::1]"))
        #expect(!RemoteHost.isBindableAddress(""))
        #expect(!RemoteHost.isBindableAddress("localhost"))
    }

    @Test func requestsExposeHeadersQueryAndBearer() {
        let request = RemoteRequest(
            method: "GET",
            target: "/api/scrollback?id=t1",
            headers: ["Authorization": "Bearer abc", "Content-Length": "0"],
            peerAddress: "10.0.0.2:1"
        )
        #expect(request.path == "/api/scrollback")
        #expect(request.queryValue("id") == "t1")
        #expect(request.header("content-length") == "0")
        #expect(request.bearerToken == "abc")
        #expect(RemoteRequest(method: "GET", target: "/", peerAddress: "x").bearerToken == "")
    }

    @Test func responsesCarryUpstreamHeadersAndLimits() {
        let response = RemoteResponse.error(403, "This terminal is not available remotely")
        #expect(response.head().hasPrefix("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n"))
        #expect(response.head().contains("Cache-Control: no-store\r\n"))
        #expect(response.head().hasSuffix("\r\n\r\n"))
        let big = RemoteResponse.json(200, Data(count: RemoteLimits.maxBody + 1))
        #expect(big.exceedsLimit)
        #expect(!RemoteResponse.json(200, Data(count: RemoteLimits.maxBody + 1), sizeLimit: .large).exceedsLimit)
    }

    @Test func messageEventPreviewsAreTruncated() {
        let event = RemoteMessageEvent(terminalID: "t", deviceID: 1, deviceName: "Phone", preview: String(repeating: "x", count: 500))
        #expect(event.preview.count == RemoteLimits.maxPreview)
    }
}

struct RemotePairingQRTests {
    @Test func aQRImageDecodesBackToItsURL() throws {
        let url = "http://192.168.1.20:9340/?pair=Abc_def-0123456789abcdefghijklmn"
        let image = try #require(RemotePairingQR().image(for: url))
        #expect(image.width >= RemotePairingQR.minimumSide)

        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        #expect(features.first?.messageString == url)
    }

    @Test func aNewURLReplacesTheCachedImage() throws {
        let qr = RemotePairingQR()
        let first = try #require(qr.image(for: "http://a/?pair=1"))
        let second = try #require(qr.image(for: "http://a/?pair=2"))
        #expect(first !== second)
        #expect(qr.cachedURL == "http://a/?pair=2")
    }
}

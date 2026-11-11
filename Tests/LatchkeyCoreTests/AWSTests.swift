import XCTest
@testable import LatchkeyCore

/// SigV4 against AWS's published examples (the example key from the AWS documentation, not a real one).
final class AWSTests: XCTestCase {
    let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

    func testSigningKeyMatchesAWSsExample() {
        // "Examples of how to derive a signing key for Signature Version 4" (IAM, us-east-1, 20120215).
        let key = SigV4.signingKey(secret: secret, date: "20120215", region: "us-east-1", service: "iam")
        XCTAssertEqual(SigV4.hex(key), "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    func testSignatureMatchesTheGetVanillaTestCase() {
        // The Signature Version 4 test suite's get-vanilla case.
        let f = ISO8601DateFormatter()
        let h = SigV4.headers(method: "GET", host: "example.amazonaws.com", path: "/", body: Data(), contentType: nil,
                              accessKeyID: "AKIDEXAMPLE", secret: secret, region: "us-east-1", service: "service",
                              now: f.date(from: "2015-08-30T12:36:00Z")!)
        XCTAssertEqual(h["Authorization"], "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testBodiesAndAnswers() {
        XCTAssertEqual(AWSSTS.body(role: nil, duration: 60, sessionName: "x"), "Action=GetSessionToken&DurationSeconds=900&Version=2011-06-15")
        XCTAssertEqual(AWSSTS.body(role: "arn:aws:iam::123456789012:role/dev", duration: 3600, sessionName: "latchkey"),
                       "Action=AssumeRole&DurationSeconds=3600&RoleArn=arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2Fdev&RoleSessionName=latchkey&Version=2011-06-15")
        let ok = """
        <GetSessionTokenResponse><GetSessionTokenResult><Credentials>
        <SessionToken>tok</SessionToken><SecretAccessKey>sec</SecretAccessKey>
        <Expiration>2026-11-10T12:00:00Z</Expiration><AccessKeyId>ASIAEXAMPLE</AccessKeyId>
        </Credentials></GetSessionTokenResult></GetSessionTokenResponse>
        """
        XCTAssertEqual(AWSSTS.parse(ok), .success(.init(accessKeyID: "ASIAEXAMPLE", secretAccessKey: "sec", sessionToken: "tok", expiration: "2026-11-10T12:00:00Z")))
        XCTAssertEqual(AWSSTS.parse("<ErrorResponse><Error><Code>AccessDenied</Code><Message>nope</Message></Error></ErrorResponse>"),
                       .failure(.aws(code: "AccessDenied", message: "nope")))
        XCTAssertEqual(AWSSTS.parse("<x/>"), .failure(.unreadable))
    }

    /// Reaches AWS, so it runs only when asked: LATCHKEY_NETWORK_TESTS=1 swift test. AWS's example key isn't a real
    /// one, so STS must refuse it by name, which shows the request was well formed and signed.
    func testSTSRefusesTheExampleKeyByName() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LATCHKEY_NETWORK_TESTS"] == "1", "set LATCHKEY_NETWORK_TESTS=1")
        let r = AWSSTS.mint(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secret: secret, role: nil, duration: 900)
        guard case .failure(.aws(let code, _)) = r else { return XCTFail("expected an AWS error, got \(r)") }
        XCTAssertEqual(code, "InvalidClientTokenId")
    }
}

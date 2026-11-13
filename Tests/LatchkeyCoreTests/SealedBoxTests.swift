import XCTest
import CryptoKit
@testable import LatchkeyCore

/// Every expected value here was produced by libsodium (`crypto_generichash`, `crypto_core_hsalsa20`,
/// `crypto_onetimeauth`, and `crypto_box_easy` with the sealed-box nonce); each sealed vector was also opened with
/// `crypto_box_seal_open`, so the construction is libsodium's `crypto_box_seal`.
final class SealedBoxTests: XCTestCase {
    func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[a..<hex.index(a, offsetBy: 2)], radix: 16)!
        }
    }
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testBlake2bMatchesLibsodium() {
        let cases: [(String, Int, String)] = [
            ("", 24, "ab3b5331a7135ed50d0f182d026e60abdb3646fd51bcf8a3"),
            ("", 64, "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"),
            ("616263", 24, "56a17e38cc371a46b12c32f18e0c61de2a84e9c2555b114e"),
            ("616263", 64, "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"),
            ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7", 24, "e9183c766451ac26ddd03b280b4b6000802b4b7230c78bb3"),
            ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7", 64, "fb3c1f0f56a56f8e316fdf5d853c8c872c39635d083634c3904fc3ac07d1b578e85ff0e480e92d44ade33b62e893ee32343e79ddf6ef292e89b582d312502314"),
        ]
        for (msg, len, out) in cases { XCTAssertEqual(hex(SealedBox.blake2b(bytes(msg), length: len)), out, "\(msg.count / 2) bytes, \(len)") }
    }

    func testHSalsa20MatchesLibsodium() {
        XCTAssertEqual(hex(SealedBox.hsalsa20(key: bytes("78032858b52002ee5de86799f5769bccb699bd668d7de566073fea3b308c82f6"), input: bytes("7446783c207819c88f4358a528c02b9d"))), "3dd38bc4d620ce926443eb3d3f452a14d44a2ebe614040530c3dc9a734262818")
    }

    func testPoly1305MatchesLibsodium() {
        let cases: [(String, String, String)] = [
            ("dd1d188490ed268e1911b492e51d30691f6520c7ae6816bb210cacd8594e1d1c", "", "1f6520c7ae6816bb210cacd8594e1d1c"),
            ("6e73bff1d94b0a7500145be82722e7455dba1653e9b56eeaa043c5980aed376f", "96", "dbcab7187cfec2e8a8fb36d92f12c8cb"),
            ("05b9f80726a4eb9a2ae258325cde0eafb0259a96ec8d8e99e102ef6c1cec7d46", "96f2f0811df88d8fc36bba1ebfe4e4", "942b7dba9cb719c7b971a337fb6750d7"),
            ("4291418e5638de401568cbf381455859b0e3c6f66dcc601561bb778d8bc2146e", "96f2f0811df88d8fc36bba1ebfe4e484", "5ad3a434810607bf40ca647e833e2bd0"),
            ("0c6c26cfc6f0d8b8b5a8f7300ec17b3d540251c345f1c993049b61b1721cfe2a", "96f2f0811df88d8fc36bba1ebfe4e4841c", "467448160113ba8b811d251c5470c5f2"),
            ("488d70ae4ecdb013d06435011b247e59b701c5387de78fd1f6ae61b331b436ea", "96f2f0811df88d8fc36bba1ebfe4e4841ce71b1e26c4ac0b77c860f26a37a76396f2f0811df88d8fc36bba1ebfe4e4841ce71b1e26c4ac0b77c860f26a37a76396f2f0811df88d8fc36bba1ebfe4e4841ce71b1e26c4ac0b77c860f26a37a76396f2f081", "fdd30e2e278606b9f82b70a2dd289894"),
        ]
        for (key, msg, tag) in cases { XCTAssertEqual(hex(SealedBox.poly1305(bytes(msg), key: bytes(key))), tag, "\(msg.count / 2) bytes") }
    }

    func testSealedBoxMatchesLibsodium() throws {
        let recipient = bytes("45aba58dbb6399e7c48cca46b9db23cfd05722d33a4dcbf8978a82d8a346e03a")
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes("8341425cafede9d24b0599aefdfdeff1c1526ed75b07217eb99bf8c0b7498b81"))
        let cases: [(String, String)] = [
            ("",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b633a3fbdaf50917aeaa86655c7188001e79"),
            ("01",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b633443583046ebddb3c99c70b431e9a61baf3"),
            ("1f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b633b6777803438f29ddc01fe435011ec20eed291cb71254c8b6181eff6af2e715140d2894c3cf043a901f9ddc3df5af0b"),
            ("20272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f9",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b6336915f550bc65835cdc458c726b9bc1c2d2281fb61555cbb7171ffc6bf5e61615122997c2c8053991109cdf3cf2ae082d"),
            ("21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b633236a9eca44bfef545a028fc0b48fa460d3271eb51452cab41620fd68f4e11716132696c1c90238921183de3ff3a9092eeb"),
            ("3f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef5fc030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b6336ac8d5085b409b56f01f36c496d9c6d2cd497cd77274e896383e1f8a120735342d08b4a3af645ab03fbdfc1d154febccf5671be62c3165f8c1ff37421e02ed62a1bee80c95edda3efb1ca4d0a0f579"),
            ("40474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f9",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b6331b65c1f0bd9fe68044def8e34f2f3d4cb2487fd67575eb97373f1c8b150636353209b7a2a86559b130bcff1c124ee8cdca6618e72b3066f9cefe34431903ee63bebfeb0d92ecd93ff41da7d1a7f47af4"),
            ("41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0f7fe050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b633548ac12a48325e8b9f0bab81d751cb53b3477ed57472ea9436c01d88140137363306b6a1a96258b231a3fe1f1349e9cecb6919e42a3767facfc135401804ef60bfb0ea0e93ebd83cf502a6d2a6f37bf7cf"),
            ("c8cfd6dde4ebf2f900070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef5fc030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0f7fe050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01080f161d242b3239",
             "e29d7521911498b837ed692d12a81587898e0ac3f6208eac1069bca82fb6b6335c62f8feea44fdff5bf1833239be0bcb3ac0e75ecdfd731f4f4794139dbebeadba814f2a30ede139a82477649ad6607542ee806fd3b8fe717646bcdb917b66fb363753850a6421b76c852f692f6cf28c46bbe9df5c7ff2702a716e8b7dbf62b4eacdec8188928d3baceeed9fef24ccd1070403a691c86c04a94a265648baaa5973b154aada3bfc3b57fb78a8e2142fedef5ee1818e1e37608bad47226d7fa370660a9f8e431af970ddcec29c14097e341089fce9fcc22d4eb0cd7ecf3adae15db24afc977f891fb8442f2903d45a7475e665979668e2c6b4"),
        ]
        for (msg, sealed) in cases {
            XCTAssertEqual(hex(try SealedBox.seal(bytes(msg), recipient: recipient, ephemeral: ephemeral)), sealed, "\(msg.count / 2) bytes")
        }
    }

    func testRandomEphemeralKeysDifferAndKeepTheLayout() throws {
        let pk = Array(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        let a = try SealedBox.seal(Array("value".utf8), recipient: pk), b = try SealedBox.seal(Array("value".utf8), recipient: pk)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 32 + 16 + 5)
        XCTAssertFalse(a.suffix(5).elementsEqual(Array("value".utf8)))
    }

    func testRejectsAPublicKeyThatIsNotThirtyTwoBytes() {
        XCTAssertThrowsError(try SealedBox.seal([1], recipient: [UInt8](repeating: 1, count: 31)))
        XCTAssertThrowsError(try SealedBox.seal([1], recipient: [UInt8](repeating: 0, count: 32)), "all-zero point gives an all-zero secret")
    }
}


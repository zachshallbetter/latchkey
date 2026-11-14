import Foundation
import CryptoKit

/// libsodium's `crypto_box_seal`, which GitHub requires for Actions secrets: the value is encrypted to the
/// repository's (or environment's) public key so only GitHub can read it.
///
/// CryptoKit has X25519 but not XSalsa20-Poly1305 or BLAKE2b, so those are here: Salsa20/HSalsa20, Poly1305 and
/// BLAKE2b, each checked against libsodium's output in `SealedBoxTests`. The key agreement and the random
/// ephemeral key are CryptoKit's.
///
/// Layout of the result: `ephemeral public key (32) ‖ Poly1305 tag (16) ‖ ciphertext`, where the key is
/// `HSalsa20(X25519(esk, pk), 0)` and the nonce is `BLAKE2b-24(epk ‖ pk)`.
public enum SealedBox {
    enum Failure: Error { case badPublicKey }

    public static func seal(_ message: [UInt8], recipient: [UInt8]) throws -> [UInt8] {
        try seal(message, recipient: recipient, ephemeral: Curve25519.KeyAgreement.PrivateKey())
    }

    /// The ephemeral key is a parameter so tests can check the output against libsodium's.
    static func seal(_ message: [UInt8], recipient: [UInt8], ephemeral: Curve25519.KeyAgreement.PrivateKey) throws -> [UInt8] {
        guard recipient.count == 32,
              let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: pk) else { throw Failure.badPublicKey }
        let epk = Array(ephemeral.publicKey.rawRepresentation)
        let secret = shared.withUnsafeBytes { Array($0) }
        let key = hsalsa20(key: secret, input: [UInt8](repeating: 0, count: 16))
        let nonce = blake2b(epk + recipient, length: 24)
        return epk + secretBox(message, nonce: nonce, key: key)
    }

    // MARK: XSalsa20-Poly1305

    /// `crypto_secretbox`: tag ‖ ciphertext.
    static func secretBox(_ message: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8] {
        let subkey = hsalsa20(key: key, input: Array(nonce[0..<16]))
        let stream = salsa20Stream(key: subkey, nonce: Array(nonce[16..<24]), count: 32 + message.count)
        let ciphertext = (0..<message.count).map { message[$0] ^ stream[32 + $0] }
        return poly1305(ciphertext, key: Array(stream[0..<32])) + ciphertext
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func store32(_ v: UInt32, into out: inout [UInt8]) {
        for s in stride(from: 0, to: 32, by: 8) { out.append(UInt8(truncatingIfNeeded: v >> UInt32(s))) }
    }

    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    /// The 20 Salsa20 rounds on a state laid out as in the specification.
    private static func rounds(_ x: inout [UInt32]) {
        func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[b] ^= rotl(x[a] &+ x[d], 7)
            x[c] ^= rotl(x[b] &+ x[a], 9)
            x[d] ^= rotl(x[c] &+ x[b], 13)
            x[a] ^= rotl(x[d] &+ x[c], 18)
        }
        for _ in 0..<10 {
            qr(0, 4, 8, 12); qr(5, 9, 13, 1); qr(10, 14, 2, 6); qr(15, 3, 7, 11)
            qr(0, 1, 2, 3); qr(5, 6, 7, 4); qr(10, 11, 8, 9); qr(15, 12, 13, 14)
        }
    }

    /// 32-byte subkey from a 32-byte key and 16 bytes of input.
    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        var x: [UInt32] = [sigma[0], le32(key, 0), le32(key, 4), le32(key, 8), le32(key, 12),
                           sigma[1], le32(input, 0), le32(input, 4), le32(input, 8), le32(input, 12),
                           sigma[2], le32(key, 16), le32(key, 20), le32(key, 24), le32(key, 28), sigma[3]]
        rounds(&x)
        var out: [UInt8] = []
        for i in [0, 5, 10, 15, 6, 7, 8, 9] { store32(x[i], into: &out) }
        return out
    }

    /// Salsa20 keystream (8-byte nonce, counter from 0).
    static func salsa20Stream(key: [UInt8], nonce: [UInt8], count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count + 64)
        var counter: UInt64 = 0
        while out.count < count {
            let start: [UInt32] = [sigma[0], le32(key, 0), le32(key, 4), le32(key, 8), le32(key, 12),
                                   sigma[1], le32(nonce, 0), le32(nonce, 4), UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32),
                                   sigma[2], le32(key, 16), le32(key, 20), le32(key, 24), le32(key, 28), sigma[3]]
            var x = start
            rounds(&x)
            for i in 0..<16 { store32(x[i] &+ start[i], into: &out) }
            counter += 1
        }
        return Array(out.prefix(count))
    }

    // MARK: Poly1305

    /// One-time authenticator (26-bit limbs, as in poly1305-donna).
    static func poly1305(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        let mask: UInt64 = 0x3ff_ffff
        func word(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) }
        let r0 = word(key, 0) & 0x3ff_ffff
        let r1 = (word(key, 3) >> 2) & 0x3ff_ff03
        let r2 = (word(key, 6) >> 4) & 0x3ff_c0ff
        let r3 = (word(key, 9) >> 6) & 0x3f0_3fff
        let r4 = (word(key, 12) >> 8) & 0x00f_ffff
        let s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5
        var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0, h3: UInt64 = 0, h4: UInt64 = 0

        var offset = 0
        while offset < message.count {
            var block = [UInt8](repeating: 0, count: 16)
            let n = min(16, message.count - offset)
            block.replaceSubrange(0..<n, with: message[offset..<offset + n])
            var hibit: UInt64 = 1 << 24
            if n < 16 { block[n] = 1; hibit = 0 }
            h0 += word(block, 0) & mask
            h1 += (word(block, 3) >> 2) & mask
            h2 += (word(block, 6) >> 4) & mask
            h3 += (word(block, 9) >> 6) & mask
            h4 += (word(block, 12) >> 8) | hibit
            var d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
            var d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
            var d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
            var d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
            var d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0
            var c = d0 >> 26; h0 = d0 & mask
            d1 += c; c = d1 >> 26; h1 = d1 & mask
            d2 += c; c = d2 >> 26; h2 = d2 & mask
            d3 += c; c = d3 >> 26; h3 = d3 & mask
            d4 += c; c = d4 >> 26; h4 = d4 & mask
            h0 += c * 5; c = h0 >> 26; h0 &= mask
            h1 += c
            offset += n
        }

        var c = h1 >> 26; h1 &= mask
        h2 += c; c = h2 >> 26; h2 &= mask
        h3 += c; c = h3 >> 26; h3 &= mask
        h4 += c; c = h4 >> 26; h4 &= mask
        h0 += c * 5; c = h0 >> 26; h0 &= mask
        h1 += c

        // h - p, kept if h >= p (constant-time select).
        var g0 = h0 + 5; c = g0 >> 26; g0 &= mask
        var g1 = h1 + c; c = g1 >> 26; g1 &= mask
        var g2 = h2 + c; c = g2 >> 26; g2 &= mask
        var g3 = h3 + c; c = g3 >> 26; g3 &= mask
        let g4 = h4 &+ c &- (1 << 26)
        let keepG = (g4 >> 63) &- 1   // all ones when g4 did not go negative
        g0 &= keepG; g1 &= keepG; g2 &= keepG; g3 &= keepG
        let g4m = g4 & keepG
        h0 = (h0 & ~keepG) | g0
        h1 = (h1 & ~keepG) | g1
        h2 = (h2 & ~keepG) | g2
        h3 = (h3 & ~keepG) | g3
        h4 = (h4 & ~keepG) | (g4m & mask)

        // Pack to 128 bits and add the pad.
        let w0 = (h0 | (h1 << 26)) & 0xffff_ffff
        let w1 = ((h1 >> 6) | (h2 << 20)) & 0xffff_ffff
        let w2 = ((h2 >> 12) | (h3 << 14)) & 0xffff_ffff
        let w3 = ((h3 >> 18) | (h4 << 8)) & 0xffff_ffff
        var f = w0 + word(key, 16)
        var out: [UInt8] = []
        store32(UInt32(truncatingIfNeeded: f), into: &out)
        f = w1 + word(key, 20) + (f >> 32)
        store32(UInt32(truncatingIfNeeded: f), into: &out)
        f = w2 + word(key, 24) + (f >> 32)
        store32(UInt32(truncatingIfNeeded: f), into: &out)
        f = w3 + word(key, 28) + (f >> 32)
        store32(UInt32(truncatingIfNeeded: f), into: &out)
        return out
    }

    // MARK: BLAKE2b

    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]

    private static let schedule: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    /// Unkeyed BLAKE2b with an output of 1...64 bytes.
    static func blake2b(_ message: [UInt8], length: Int) -> [UInt8] {
        precondition((1...64).contains(length))
        func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(length)

        func compress(_ block: ArraySlice<UInt8>, counter: UInt64, last: Bool) {
            var padded = [UInt8](repeating: 0, count: 128)
            padded.replaceSubrange(0..<block.count, with: block)
            let m: [UInt64] = (0..<16).map { i in
                (0..<8).reduce(UInt64(0)) { $0 | UInt64(padded[i * 8 + $1]) << UInt64($1 * 8) }
            }
            var v = h + iv
            v[12] ^= counter
            if last { v[14] = ~v[14] }
            func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
                v[a] = v[a] &+ v[b] &+ x; v[d] = rotr(v[d] ^ v[a], 32)
                v[c] = v[c] &+ v[d];      v[b] = rotr(v[b] ^ v[c], 24)
                v[a] = v[a] &+ v[b] &+ y; v[d] = rotr(v[d] ^ v[a], 16)
                v[c] = v[c] &+ v[d];      v[b] = rotr(v[b] ^ v[c], 63)
            }
            for round in 0..<12 {
                let s = schedule[round % 10]
                g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
                g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
                g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
                g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
            }
            for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
        }

        var offset = 0
        // Every block but the last is full; the last (even when empty) carries the final flag.
        while message.count - offset > 128 {
            compress(message[offset..<offset + 128], counter: UInt64(offset + 128), last: false)
            offset += 128
        }
        compress(message[offset...], counter: UInt64(message.count), last: true)
        var out: [UInt8] = []
        for word in h { for s in 0..<8 { out.append(UInt8(truncatingIfNeeded: word >> UInt64(s * 8))) } }
        return Array(out.prefix(length))
    }
}

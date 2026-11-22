import CryptoKit
import Security
import Foundation

struct LocalTLSIdentity {
    let identity: SecIdentity
    let certificate: Data
    var fingerprint: String { SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined(separator: ":") }

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalDownloadError.identity
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    init(address: String) throws {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false
        ] as CFDictionary, &error),
        let publicKey = SecKeyCopyPublicKey(key),
        let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw LocalDownloadError.identity
        }
        let ip = address.split(separator: ".").compactMap { UInt8($0) }
        guard ip.count == 4 else { throw LocalDownloadError.identity }
        let signatureAlgorithm = DER.sequence(DER.oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,11]) + DER.item(5, []))
        let name = DER.sequence(DER.item(0x31, DER.sequence(DER.oid([0x55,4,3]) +
            DER.item(0x0c, Array("Wrist Journal Temporary Download".utf8)))))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let validity = DER.sequence(DER.item(0x17, Array(formatter.string(from: .now.addingTimeInterval(-300)).utf8)) +
            DER.item(0x17, Array(formatter.string(from: .now.addingTimeInterval(86400)).utf8)))
        let publicInfo = DER.sequence(DER.sequence(DER.oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,1]) +
            DER.item(5, [])) + DER.item(3, [0] + publicData))
        let san = DER.sequence(DER.oid([0x55,0x1d,0x11]) + DER.item(4, DER.sequence(DER.item(0x87, ip))))
        let constraints = DER.sequence(DER.oid([0x55,0x1d,0x13]) + DER.item(1, [0xff]) + DER.item(4, DER.sequence([])))
        let extendedUsage = DER.sequence(DER.oid([0x55,0x1d,0x25]) +
            DER.item(4, DER.sequence(DER.oid([0x2b,6,1,5,5,7,3,1]))))
        let serial = Array(try Self.randomToken().utf8.prefix(16))
        let body = DER.sequence(DER.item(0xa0, DER.item(2, [2])) + DER.item(2, serial) + signatureAlgorithm +
            name + validity + name + publicInfo + DER.item(0xa3, DER.sequence(san + constraints + extendedUsage)))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(body) as CFData, &error) as Data?
        else { throw LocalDownloadError.identity }
        let encoded = Data(DER.sequence(body + signatureAlgorithm + DER.item(3, [0] + signature)))
        guard let cert = SecCertificateCreateWithData(nil, encoded as CFData),
              let identity = SecIdentityCreate(nil, cert, key) else { throw LocalDownloadError.identity }
        self.identity = identity
        certificate = encoded
    }
}

private enum DER {
    static func item(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        var count = bytes.count
        var length: [UInt8] = []
        repeat { length.insert(UInt8(count & 0xff), at: 0); count >>= 8 } while count > 0
        if bytes.count >= 128 { length.insert(0x80 | UInt8(length.count), at: 0) }
        return [tag] + length + bytes
    }
    static func sequence(_ bytes: [UInt8]) -> [UInt8] { item(0x30, bytes) }
    static func oid(_ bytes: [UInt8]) -> [UInt8] { item(6, bytes) }
}

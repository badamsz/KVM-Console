import CommonCrypto
import CryptoKit
import Foundation

/// The password wrapping a classic NanoKVM expects at login.
///
/// The NanoKVM web page encrypts the password with CryptoJS
/// `AES.encrypt(password, "nanokvm-sipeed-2024")` and URL-encodes the
/// result; the server undoes it with a fixed key. It is obfuscation, not
/// security: the key is public. It is the OpenSSL `enc` format: base64 of
/// `"Salted__" + salt + AES-256-CBC(PKCS#7)`, with key and IV derived from the
/// passphrase and salt by `EVP_BytesToKey` (MD5, one round).
///
/// NanoKVM Pro and Go take the plain password instead.
public enum NanoKVMPassword {
    static let passphrase = "nanokvm-sipeed-2024"

    /// The value to send as `password` to a classic NanoKVM's `/api/auth/login`.
    public static func wrap(_ password: String) -> String {
        var salt = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        return percentEncode(encrypt(password, salt: salt))
    }

    /// OpenSSL-compatible "Salted__" encryption, base64 encoded.
    static func encrypt(_ plaintext: String, salt: [UInt8]) -> String {
        let (key, iv) = deriveKeyAndIV(passphrase: Array(passphrase.utf8), salt: salt)
        let input = Array(plaintext.utf8)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &output, output.count, &written)
        precondition(status == kCCSuccess, "AES encryption failed: \(status)")
        let blob = Array("Salted__".utf8) + salt + output.prefix(written)
        return Data(blob).base64EncodedString()
    }

    /// Decrypts `encrypt`'s output. Used by tests.
    static func decrypt(_ base64: String) -> String? {
        guard let blob = Data(base64Encoded: base64).map(Array.init), blob.count > 16,
              Array(blob[0..<8]) == Array("Salted__".utf8) else { return nil }
        let salt = Array(blob[8..<16])
        let body = Array(blob[16...])
        let (key, iv) = deriveKeyAndIV(passphrase: Array(passphrase.utf8), salt: salt)
        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, body, body.count, &output, output.count, &written)
        guard status == kCCSuccess else { return nil }
        return String(bytes: output.prefix(written), encoding: .utf8)
    }

    /// OpenSSL `EVP_BytesToKey` with MD5 and one iteration: 32-byte key, 16-byte IV.
    static func deriveKeyAndIV(passphrase: [UInt8], salt: [UInt8]) -> (key: [UInt8], iv: [UInt8]) {
        var derived: [UInt8] = []
        var block: [UInt8] = []
        while derived.count < 48 {
            block = Array(Insecure.MD5.hash(data: block + passphrase + salt))
            derived += block
        }
        return (Array(derived[0..<32]), Array(derived[32..<48]))
    }

    /// JavaScript's `encodeURIComponent`.
    static func percentEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

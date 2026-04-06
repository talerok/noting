import CommonCrypto
import CryptoKit
import Foundation

struct EncryptedPayload {
    let encryptedContent: String  // base64
    let salt: String              // base64
    let iv: String                // base64
}

enum CryptoService {
    private static let iterations = 100_000
    private static let saltLength = 16

    // MARK: - Key Derivation

    static func deriveKey(password: String, salt: Data) throws -> Data {
        let passwordData = password.data(using: .utf8)!
        // PBKDF2 with HMAC-SHA256
        var derivedKey = Data(count: 32)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }
        return derivedKey
    }

    static func deriveKey(password: String, saltBase64: String) async throws -> Data {
        guard let salt = Data(base64Encoded: saltBase64) else {
            throw CryptoError.invalidData
        }
        return try deriveKey(password: password, salt: salt)
    }

    // MARK: - Encrypt

    static func encrypt(_ plaintext: String, withPassword password: String) async throws -> EncryptedPayload {
        var salt = Data(count: saltLength)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        let key = try deriveKey(password: password, salt: salt)
        return try encryptWithKey(plaintext, derivedKey: key, saltBase64: salt.base64EncodedString())
    }

    static func encrypt(_ plaintext: String, withDerivedKey key: Data, saltBase64: String) throws -> EncryptedPayload {
        try encryptWithKey(plaintext, derivedKey: key, saltBase64: saltBase64)
    }

    private static func encryptWithKey(_ plaintext: String, derivedKey: Data, saltBase64: String) throws -> EncryptedPayload {
        let symmetricKey = SymmetricKey(data: derivedKey)
        let plaintextData = plaintext.data(using: .utf8)!
        let sealedBox = try AES.GCM.seal(plaintextData, using: symmetricKey)

        // Store as nonce + ciphertext + tag (combined representation)
        let combined = sealedBox.combined!
        return EncryptedPayload(
            encryptedContent: combined.base64EncodedString(),
            salt: saltBase64,
            iv: Data(sealedBox.nonce).base64EncodedString()
        )
    }

    // MARK: - Decrypt

    static func decrypt(
        _ encryptedBase64: String,
        saltBase64: String,
        ivBase64: String,
        password: String
    ) async throws -> (String, Data) {
        guard let salt = Data(base64Encoded: saltBase64) else {
            throw CryptoError.invalidData
        }
        let key = try deriveKey(password: password, salt: salt)
        let text = try decryptWithKey(encryptedBase64, derivedKey: key)
        return (text, key)
    }

    static func decryptWithKey(_ encryptedBase64: String, derivedKey: Data) throws -> String {
        guard let combined = Data(base64Encoded: encryptedBase64) else {
            throw CryptoError.invalidData
        }
        let symmetricKey = SymmetricKey(data: derivedKey)
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)

        guard let text = String(data: decrypted, encoding: .utf8) else {
            throw CryptoError.invalidData
        }
        return text
    }
}

enum CryptoError: LocalizedError {
    case keyDerivationFailed
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keyDerivationFailed: "Key derivation failed"
        case .invalidData: "Invalid encrypted data"
        }
    }
}

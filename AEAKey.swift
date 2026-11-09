import Foundation
import CryptoKit

do {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: String],
          let pem = obj["pem"], let enc = obj["enc"].flatMap({ Data(base64Encoded: $0) }),
          let wrapped = obj["wrapped"].flatMap({ Data(base64Encoded: $0) }) else {
        throw NSError(domain: "AEA", code: 1, userInfo: [NSLocalizedDescriptionKey: "密钥元数据不完整"])
    }
    let key = try P256.KeyAgreement.PrivateKey(pemRepresentation: pem)
    var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: .P256_SHA256_AES_GCM_256, info: Data(), encapsulatedKey: enc)
    let result = try recipient.open(wrapped)
    FileHandle.standardOutput.write(result)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}

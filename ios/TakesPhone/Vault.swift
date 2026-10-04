import Foundation
import LocalAuthentication
import Security

// The token the Mac gave this phone. It sits in the Keychain behind Face ID (with the passcode
// as the fallback), so a phone that is unlocked but not in the user's hands cannot reach Takes.

enum Vault {
    private static let service = "de.marvinaziz.takes.phone"
    private static let account = "token"

    static func save(_ token: String) throws {
        delete()
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
        ]
        #if targetEnvironment(simulator)
        // The simulator has no passcode, so it cannot hold an item behind Face ID.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .userPresence, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        q[kSecAttrAccessControl as String] = access
        #endif
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(s),
                          userInfo: [NSLocalizedDescriptionKey: s == errSecParam || s == -25293
                                     ? "Set a passcode on this iPhone first. Face ID needs one."
                                     : "Could not save the key (\(s))."])
        }
    }

    /// Asks for Face ID. nil: no token saved, or the user cancelled.
    static func load(reason: String = "Unlock Takes") async -> String? {
        let ctx = LAContext()
        ctx.localizedReason = reason
        return await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let q: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecUseAuthenticationContext as String: ctx,
                ]
                var out: CFTypeRef?
                let s = SecItemCopyMatching(q as CFDictionary, &out)
                c.resume(returning: s == errSecSuccess ? (out as? Data).map { String(decoding: $0, as: UTF8.self) } : nil)
            }
        }
    }

    /// True when a token is saved. Does not ask for Face ID.
    static var hasToken: Bool {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: ctx,
        ]
        let s = SecItemCopyMatching(q as CFDictionary, nil)
        return s == errSecSuccess || s == errSecInteractionNotAllowed
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

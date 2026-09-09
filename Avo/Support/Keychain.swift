import Foundation
import Security

/// Secrets, stored in the login keychain under the `app.avo.mac` service.
///
/// The macOS file keychain attaches an ACL to every item naming the exact binary that created it. A
/// rebuild has a different code signature, so the first read after one raises a system dialog ("Avo
/// wants to use your confidential information"). Avo is an `LSUIElement` agent with no windows at
/// launch, so that dialog can end up unanswerable and `SecItemCopyMatching` simply never returns —
/// which is why nothing on the launch path reads a secret on the main thread (see
/// `Settings.bootstrapSecretsFromDisk`).
///
/// Signing with a stable identity avoids the prompt entirely: export `AVO_CODE_SIGN_IDENTITY` (and
/// `AVO_TEAM_ID`) before building and the signature no longer changes from build to build, so items
/// written by one build stay trusted by the next. Ad-hoc and unsigned builds pay one prompt per
/// rebuild.
enum Keychain {
    private static let service = "app.avo.mac"

    #if DEBUG
    /// Set only by the off-screen UI render harness (`DebugPreviews`). Reads return nil instead of
    /// waiting on a keychain access dialog no headless process can show.
    nonisolated(unsafe) static var suppressReadsForPreview = false
    #endif

    static func get(_ key: String) -> String? {
        #if DEBUG
        // UI renders run headless, so the ACL dialog would have no window to appear in and the read
        // would never return. Renders never need a real secret.
        if suppressReadsForPreview { return nil }
        #endif
        var q = itemQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete-then-add rather than `SecItemUpdate`: an update against an item this binary does not own
    /// hits the same ACL as a read, and the value is being replaced wholesale anyway.
    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        delete(key)
        var q = itemQuery(key)
        q[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ key: String) {
        SecItemDelete(itemQuery(key) as CFDictionary)
    }

    private static func itemQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

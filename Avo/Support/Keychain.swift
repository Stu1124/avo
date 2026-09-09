import Foundation
import Security

/// Secrets, stored under the `app.avo.mac` service.
///
/// macOS has two keychains and the difference matters here. The **legacy** file keychain attaches an ACL to
/// every item naming the exact binary that created it; a rebuild has a different code signature, so the next
/// read raises a system dialog ("Avo wants to use your confidential information"). Avo is an `LSUIElement`
/// agent with no windows at launch, so that dialog can end up unanswerable and `SecItemCopyMatching` simply
/// never returns. The **data-protection** keychain (the iOS one, available to signed Mac apps) has no
/// per-binary ACLs at all: access is decided by the `keychain-access-groups` entitlement, which is stable
/// across rebuilds, so it never prompts.
///
/// Avo therefore prefers the data-protection keychain and falls back to the legacy one for ad-hoc and
/// unsigned local builds, which have no team prefix and so no usable access group. Items already in the
/// legacy keychain move across lazily, one key at a time, the first time that key is read.
enum Keychain {
    private static let service = "app.avo.mac"

    #if DEBUG
    /// Set only by the off-screen UI render harness (`DebugPreviews`). Reads return nil instead of
    /// waiting on a keychain access dialog no headless process can show.
    nonisolated(unsafe) static var suppressReadsForPreview = false
    #endif

    // MARK: - Backend

    /// What the binary's own `keychain-access-groups` entitlement says. The three cases are logged
    /// separately because they mean different things to whoever is reading the log.
    private enum EntitledGroup {
        /// A usable `<TeamID>.app.avo.mac`.
        case group(String)
        /// No `keychain-access-groups` at all: an ad-hoc or unsigned build, the normal local case.
        case none
        /// A group is present but is not ours — a different service, or an unexpanded
        /// `$(AppIdentifierPrefix)app.avo.mac` placeholder from a build that was not signed with a team.
        case mismatch(String)
    }

    private static func entitledAccessGroup() -> EntitledGroup {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
              let group = (value as? [String])?.first else { return .none }
        guard group.hasSuffix(".\(service)") else { return .mismatch(group) }
        let prefix = String(group.dropLast(service.count + 1))
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .mismatch(group) }
        return .group(group)
    }

    /// The access group to use, or nil for the legacy keychain. Probed once per process, on first use —
    /// never eagerly at launch.
    private static let accessGroup: String? = {
        let group: String
        switch entitledAccessGroup() {
        case .group(let g):
            group = g
        case .none:
            Log.info("Keychain: legacy (no keychain-access-groups entitlement; ad-hoc or unsigned build)")
            return nil
        case .mismatch(let g):
            Log.info("Keychain: legacy (access group \"\(g)\" is not <team>.\(service))")
            return nil
        }
        // A read against the data-protection keychain with no matching item is the cheapest way to learn
        // whether this process is actually allowed to use it. It cannot prompt.
        var q = baseQuery(group: group)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            Log.info("Keychain: data-protection")
            return group
        default:
            // The entitlement claims the group but the keychain refuses it: errSecMissingEntitlement when
            // no provisioning profile backs it, errSecParam / errSecNotAvailable otherwise.
            Log.info("Keychain: legacy (data protection unavailable, OSStatus \(status))")
            return nil
        }
    }()

    private static func baseQuery(group: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        if let group {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }

    private static func itemQuery(_ key: String, group: String?) -> [String: Any] {
        var q = baseQuery(group: group)
        q[kSecAttrAccount as String] = key
        return q
    }

    // MARK: - Read / write

    /// Reads a secret.
    ///
    /// Pre-existing caveat, AVO_SIGNED builds only: when a data-protection access group exists and the
    /// data-protection read misses, this falls through to a *legacy* read (see `adoptLegacyItem`), and that
    /// call can block on the per-binary ACL dialog. Callers on the main actor — the turn path among them —
    /// therefore do that legacy read on the main thread the first time a given key misses. Builds with no
    /// access group (every ad-hoc and unsigned build) are unaffected: they read the legacy keychain
    /// directly, exactly as before. Moving the fallback off the main actor is a separate change.
    static func get(_ key: String) -> String? {
        #if DEBUG
        // UI renders run headless, so the legacy keychain's per-binary ACL dialog would have no window
        // to appear in and the read would never return. Renders never need a real secret.
        if suppressReadsForPreview { return nil }
        #endif
        guard let group = accessGroup else { return read(key, group: nil) }
        if let value = read(key, group: group) { return value }
        return adoptLegacyItem(key, into: group)
    }

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        var alreadyAdopted = false
        if accessGroup != nil {
            migrationLock.lock()
            // Let an adoption already in flight for this key finish first, so it cannot land the older
            // legacy value on top of the one being written here. Bounded: the adopter may be stuck in a
            // legacy read that never returns, and a write must not inherit that.
            if awaitAdoption(of: key) == .timedOut {
                // The adoption is still running and cannot be cancelled. Mark the key so that if it ever
                // does finish it re-reads instead of adding its stale legacy copy over this value.
                superseded.insert(key)
            }
            // A legacy leftover must never be adopted over this newer value. Marking the key adopted is
            // enough for that — `get` will not look at the legacy copy again — and it is all that is safe:
            // *deleting* a legacy item is an authorized operation against the per-binary ACL and can raise
            // exactly the prompt this file exists to avoid, unbounded and possibly on the main actor. Only a
            // key whose adoption actually *completed* has satisfied that ACL in this process, so only that
            // key gets its stale legacy item cleaned up. `adopted` alone does not prove it: `adoptLegacyItem`
            // inserts the key there before its legacy read, so a wedged adopter leaves `adopted` set while
            // the ACL is still unsatisfied. `adopting` excludes that case, and `gaveUp` keeps it excluded for
            // the rest of the process once a wait has timed out on it.
            alreadyAdopted = adopted.contains(key) && !adopting.contains(key) && !gaveUp.contains(key)
            adopted.insert(key)
            migrationLock.unlock()
        }
        remove(key, group: accessGroup)
        if alreadyAdopted { remove(key, group: nil) }
        var q = itemQuery(key, group: accessGroup)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Unlike `set`, this always clears the legacy copy too: the user asked for the secret to be gone, so
    /// leaving a readable copy behind would be wrong even if the ACL prompt costs a click. `delete` is only
    /// ever reached from an explicit UI action, where a window exists to answer it.
    static func delete(_ key: String) {
        migrationLock.lock()
        // Same bounded wait as `set`, for the same reason and one more: an adoption in flight for this key
        // ends in `SecItemAdd`, which would put the secret back after both copies were removed here.
        if awaitAdoption(of: key) == .timedOut { superseded.insert(key) }
        adopted.insert(key)
        migrationLock.unlock()
        remove(key, group: accessGroup)
        if accessGroup != nil { remove(key, group: nil) }
    }

    private static func read(_ key: String, group: String?) -> String? {
        var q = itemQuery(key, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func remove(_ key: String, group: String?) {
        SecItemDelete(itemQuery(key, group: group) as CFDictionary)
    }

    // MARK: - Lazy legacy migration

    private static let migrationLock = NSCondition()
    /// Keys whose legacy copy has already been looked for in this process.
    private static var adopted = Set<String>()
    /// Keys whose adoption is running right now, so a concurrent reader waits for the result instead of
    /// seeing `adopted` already set and returning a spurious nil.
    private static var adopting = Set<String>()
    /// Keys an explicit `set` or `delete` changed while an adoption of that key was still in flight — which
    /// only happens when the writer's bounded wait timed out. The adopter checks this before its
    /// `SecItemAdd` so it cannot resurrect a deleted secret or shadow a newer written one.
    private static var superseded = Set<String>()
    /// Keys whose in-flight adoption outlasted a caller's bounded wait. The adopter is sitting in a legacy
    /// read that is not expected to return, so for the rest of this process: no later caller pays the wait
    /// again for that key, and no caller treats the key as having cleared the legacy ACL. A stale legacy
    /// copy left behind is harmless — `get` never looks at it again — where an unbounded authorized
    /// `SecItemDelete` against the same unanswered dialog is not.
    private static var gaveUp = Set<String>()

    /// How long a caller waits for an in-flight adoption of the same key before giving up. The adopter sits
    /// inside a legacy `SecItemCopyMatching`, which on a windowless agent can block on the ACL dialog
    /// indefinitely — for instance the detached bootstrap task adopting `google_client_id` while
    /// `GoogleAuth.signIn()` waits on the main actor. A stale nil is better than a frozen agent.
    private static let adoptionWaitLimit: TimeInterval = 8

    private enum AdoptionWait {
        /// Nothing was in flight; the caller did not wait.
        case notInFlight
        /// An adoption was in flight and has now finished.
        case finished
        /// An adoption is in flight and is still running after `adoptionWaitLimit`.
        case timedOut
    }

    private static var loggedAdoptionTimeout = false

    /// Waits for any in-flight adoption of `key`. `migrationLock` must be held on entry and is still held
    /// on return, in every case.
    private static func awaitAdoption(of key: String) -> AdoptionWait {
        guard adopting.contains(key) else { return .notInFlight }
        // Someone already waited out the full limit on this same adoption and it is *still* running. Waiting
        // again would cost another `adoptionWaitLimit` for the same answer, so every later caller for this
        // key gives up immediately.
        if gaveUp.contains(key) { return .timedOut }
        let deadline = Date().addingTimeInterval(adoptionWaitLimit)
        while adopting.contains(key) {
            // `wait(until:)` returns false only on timeout; a spurious wake re-tests the predicate against
            // the same deadline.
            if !migrationLock.wait(until: deadline) {
                gaveUp.insert(key)
                if !loggedAdoptionTimeout {
                    loggedAdoptionTimeout = true
                    Log.warn("Keychain: timed out waiting for a legacy adoption; continuing without it")
                }
                return .timedOut
            }
        }
        return .finished
    }

    /// A data-protection read missed. The value may still be in the legacy keychain from an older build:
    /// take it across once, then delete the legacy copy so this never runs again for that key.
    ///
    /// Deliberately per-key and on first use. Walking every account at launch would be exactly the
    /// blocking main-thread sweep this design exists to avoid — a legacy read *can* still raise the ACL
    /// prompt, and the app has to stay responsive while the user answers it.
    private static func adoptLegacyItem(_ key: String, into group: String) -> String? {
        migrationLock.lock()
        // If another thread is mid-adoption for this key, wait for it and then read what it left in the
        // data-protection keychain, rather than reporting "no value" for a key that does have one.
        if awaitAdoption(of: key) == .timedOut {
            // The other adoption is wedged in a legacy read that may never return. Give up rather than
            // block this caller with it: report the data-protection read's own result, which is the nil
            // that brought us here. Same answer as before the wait existed. `awaitAdoption` has recorded
            // the key, so a repeat `get` of a permanently wedged key returns this nil immediately instead
            // of paying the wait again.
            migrationLock.unlock()
            return nil
        }
        if adopted.contains(key) {
            // Someone else has already handled this key. Re-read the data-protection keychain rather than
            // trusting the miss that brought us here: that miss may have been taken before their
            // `SecItemAdd` landed, whether or not we waited. The re-read is a data-protection read — cheap
            // and incapable of prompting — so paying it on the repeat-miss path is the right trade.
            migrationLock.unlock()
            return read(key, group: group)
        }
        adopted.insert(key)
        adopting.insert(key)
        migrationLock.unlock()
        defer {
            migrationLock.lock()
            adopting.remove(key)
            migrationLock.broadcast()
            migrationLock.unlock()
        }
        guard let value = read(key, group: nil) else { return nil }
        // The legacy read above can take a long time. A `set` or `delete` whose own bounded wait expired
        // meanwhile has already written the newer truth into the data-protection keychain (or removed it),
        // so adding this older copy over it would undo an explicit user action. Report what they left.
        // The check and the add are one critical section so a `set` cannot slip its mark in between them;
        // a data-protection add is cheap and cannot prompt, so holding the lock across it is safe. The
        // legacy delete below is authorized and can block, so it stays outside.
        migrationLock.lock()
        if superseded.remove(key) != nil {
            migrationLock.unlock()
            return read(key, group: group)
        }
        var q = itemQuery(key, group: group)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        migrationLock.unlock()
        guard added else {
            Log.warn("Keychain: could not move \(key) into the data-protection keychain")
            return value
        }
        remove(key, group: nil)
        Log.info("Keychain: moved \(key) into the data-protection keychain")
        return value
    }
}

// Secrets for the credential broker.
//
// System mode with the settings helper: a root-only folder (systemDir/secrets, 0700, files 0600)
// that only the helper reads and writes, and only for the root-owned approve (checked by code hash
// per connection, so an upgrade keeps access without any prompt). A secret still in the Keychain
// from before is moved there on first use (one Keychain prompt), then removed from the Keychain.
//
// Otherwise (user mode, or no helper): the login Keychain. Each item lists this approve binary as
// its only trusted app, so any other program (including `security`, or a rebuilt approve) gets a
// Keychain password prompt instead of the value. Another program can still delete an item; then the
// CLI simply gets no secret and fails.

import Foundation
import Security

#if APPROVE_TEST
let secretService = "approve-gate-test"
#else
let secretService = "approve-gate"
#endif

private func baseQuery(_ name: String) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: secretService, kSecAttrAccount: name]
}

/// Access list with only this binary trusted (legacy login keychain; data protection keychains need
/// entitlements that a locally built tool does not have).
private func onlyApproveAccess() -> SecAccess? {
    var app: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath(ownExecutable(), &app) == errSecSuccess, let app else { return nil }
    var access: SecAccess?
    guard SecAccessCreate("Approve Gate secret" as CFString, [app] as CFArray, &access) == errSecSuccess else { return nil }
    return access
}

func keychainSet(_ name: String, _ value: String) -> Bool {
    guard let access = onlyApproveAccess() else { return false }
    SecItemDelete(baseQuery(name) as CFDictionary)
    var q = baseQuery(name)
    q[kSecValueData] = Data(value.utf8)
    q[kSecAttrAccess] = access
    q[kSecAttrLabel] = "Approve Gate: \(name)"
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
}

func keychainGet(_ name: String) -> String? {
    var q = baseQuery(name)
    q[kSecReturnData] = true
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
    return String(data: d, encoding: .utf8)
}

func keychainDelete(_ name: String) -> Bool {
    SecItemDelete(baseQuery(name) as CFDictionary) == errSecSuccess
}

/// Names only; reading names never needs the values.
func keychainNames() -> [String] {
    let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: secretService,
                              kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
}

/// The root store is used when the helper can serve it (system mode, helper running).
private var useRootStore: Bool { systemMode && helperAvailable }

func setSecret(_ name: String, _ value: String) -> Bool {
    guard useRootStore else { return keychainSet(name, value) }
    return (try? helperSecret(["op": "secret-set", "name": name, "data": Data(value.utf8).base64EncodedString()])) != nil
}

func getSecret(_ name: String) -> String? {
    guard useRootStore else { return keychainGet(name) }
    if let r = try? helperSecret(["op": "secret-get", "name": name]), let d = Data(base64Encoded: r) {
        return String(data: d, encoding: .utf8)
    }
    // Not in the root store yet: move it from the Keychain (one prompt if an older build stored it).
    guard let v = keychainGet(name) else { return nil }
    if setSecret(name, v) {
        _ = keychainDelete(name)
        FileHandle.standardError.write("approve: moved secret \(name) from the Keychain to the root-owned store\n".data(using: .utf8)!)
    }
    return v
}

func deleteSecret(_ name: String) -> Bool {
    guard useRootStore else { return keychainDelete(name) }
    let inRoot = (try? helperSecret(["op": "secret-rm", "name": name])) != nil
    let inKeychain = keychainNames().contains(name) && keychainDelete(name)
    return inRoot || inKeychain
}

func secretNames() -> [String] {
    guard useRootStore else { return keychainNames() }
    let root = ((try? helperSecret(["op": "secret-list"])) ?? "").split(separator: "\n").map(String.init)
    return Array(Set(root + keychainNames())).sorted()
}

/// `approve secret set|rm|list`. Setting and removing need a terminal, and an approval while a phone
/// is paired, like pairing; the value is read without echo and never printed.
func runSecret(_ argv: [String]) async {
    let sub = argv.first ?? ""
    switch sub {
    case "list":
        let names = secretNames()
        print(names.isEmpty ? "No secrets stored." : names.joined(separator: "\n"))
    case "set", "rm":
        guard argv.count == 2, argv[1].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            die("usage: approve secret \(sub) NAME   (letters, digits, . _ -)")
        }
        let name = argv[1]
        await guardPairingChange("secret \(sub) \(name)")
        if sub == "rm" {
            print(deleteSecret(name) ? "Removed \(name)." : "No secret named \(name).")
            return
        }
        var value: String?
        if isatty(0) == 1, let p = getpass("Value for \(name) (not shown): ") {
            value = String(cString: p)
        } else {
            value = readLine(strippingNewline: true) // test build only reaches here without a terminal
        }
        guard let value, !value.isEmpty else { die("empty value; nothing stored") }
        guard setSecret(name, value) else { die("could not store \(name) in the Keychain") }
        print(useRootStore ? "Stored \(name) in the root-owned store. Only the root-owned approve can read it."
                           : "Stored \(name). Only this approve binary can read it.")
    default:
        die("usage: approve secret set NAME | rm NAME | list")
    }
}

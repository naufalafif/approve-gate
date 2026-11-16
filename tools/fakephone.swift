// Test double for the Android app: same protocol, software key, no fingerprint.
//   fakephone <pairlink> <statefile> pair
//   fakephone <statefile> serve approve|deny|badsig|ignore   (handles one request, then exits)
import CryptoKit
import Foundation

struct State: Codable { var server, req, res, key, priv: String }

func seal(_ d: Data, _ k: String) -> String {
    try! AES.GCM.seal(d, using: SymmetricKey(data: Data(base64Encoded: k)!)).combined!.base64EncodedString()
}
func unseal(_ s: String, _ k: String) -> Data? {
    guard let d = Data(base64Encoded: s), let b = try? AES.GCM.SealedBox(combined: d) else { return nil }
    return try? AES.GCM.open(b, using: SymmetricKey(data: Data(base64Encoded: k)!))
}
func post(_ st: State, _ obj: [String: Any]) async {
    var r = URLRequest(url: URL(string: "\(st.server)/\(st.res)")!)
    r.httpMethod = "POST"
    r.httpBody = seal(try! JSONSerialization.data(withJSONObject: obj), st.key).data(using: .utf8)
    _ = try? await URLSession.shared.data(for: r)
}

let a = CommandLine.arguments
if a.count == 4 && a[3] == "pair" {
    let q = URLComponents(string: a[1])!.queryItems!.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    var k = q["k"]!.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while k.count % 4 != 0 { k += "=" }
    let priv = P256.Signing.PrivateKey()
    let st = State(server: q["s"]!, req: q["q"]!, res: q["r"]!, key: k, priv: priv.rawRepresentation.base64EncodedString())
    try! JSONEncoder().encode(st).write(to: URL(fileURLWithPath: a[2]))
    let sig = try! priv.signature(for: "approvegate-pair:\(st.res)".data(using: .utf8)!)
    await post(st, ["type": "pair", "name": "fakephone", "publicKey": priv.publicKey.derRepresentation.base64EncodedString(),
                    "sig": sig.derRepresentation.base64EncodedString()])
    print("pair reply sent")
} else if a.count == 4 && a[2] == "serve" {
    let st = try! JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: a[1])))
    let priv = try! P256.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: st.priv)!)
    let since = Int(Date().timeIntervalSince1970) - 3
    let (bytes, _) = try! await URLSession.shared.bytes(from: URL(string: "\(st.server)/\(st.req)/json?since=\(since)")!)
    for try await line in bytes.lines {
        guard let ev = try? JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as? [String: Any],
              ev["event"] as? String == "message", let body = ev["message"] as? String,
              let plain = unseal(body, st.key),
              let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { continue }
        print("phone got:", String(data: plain, encoding: .utf8)!)
        guard obj["type"] as? String == "request", let id = obj["id"] as? String, (obj["createdAt"] as? Int ?? 0) >= since + 3 else { continue }
        switch a[3] {
        case "approve":
            let sig = try! priv.signature(for: Data(SHA256.hash(data: plain))).derRepresentation.base64EncodedString()
            await post(st, ["type": "response", "id": id, "decision": "approve", "sig": sig])
        case "badsig":
            let other = P256.Signing.PrivateKey()
            let sig = try! other.signature(for: Data(SHA256.hash(data: plain))).derRepresentation.base64EncodedString()
            await post(st, ["type": "response", "id": id, "decision": "approve", "sig": sig])
        case "deny":
            await post(st, ["type": "response", "id": id, "decision": "deny"])
        default: break
        }
        print("phone answered:", a[3])
        exit(0)
    }
}

@testable import BarCore
import XCTest

final class RulesTests: XCTestCase {
    private func rules() throws -> RulesDoc {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../mac/rules.example.json").standardized
        return try JSONDecoder().decode(RulesDoc.self, from: Data(contentsOf: url))
    }

    func testExampleRulesRoundTrip() throws {
        let r = try rules()
        let again = try JSONDecoder().decode(RulesDoc.self, from: r.encoded())
        XCTAssertEqual(r, again)
        XCTAssertEqual(r.timeout, 90)
        XCTAssertTrue(r.askOnMac)
    }

    // Same decisions as approve's own tests (tests/gate_cases.tsv).
    func testVerdictsMatchApprove() throws {
        let r = try rules()
        let cases: [(String, String, Verdict.Kind)] = [
            ("vault", "version", .asks), ("hcloud", "server list -o json", .runs), ("hcloud", "server delete web-1", .asks),
            ("kcadm", "update users/x -r master -s description=--help", .asks), ("doctl", "compute droplet delete 123 --help", .asks), ("hcloud", "server create --name list", .asks), ("hcloud", "server --help", .runs),
            ("doctl", "compute droplet list --api-url=https://x", .asks), ("unknowncli", "anything", .asks),
        ]
        for (cli, args, want) in cases {
            XCTAssertEqual(verdict(cli: cli, args: shellWords(args), rules: r).kind, want, "\(cli) \(args)")
        }
    }

    func testReasonNamesThePattern() throws {
        let v = verdict(cli: "hcloud", args: ["server", "list"], rules: try rules())
        XCTAssertEqual(v.reason, "matches the read-only pattern server list*")
    }

    func testGatingOffRunsWithoutAsking() throws {
        var r = try rules()
        r.clis["vault"]?.disabled = true
        XCTAssertEqual(verdict(cli: "vault", args: ["kv", "put", "x"], rules: r), Verdict(kind: .runs, reason: "gating is off for vault"))
        let again = try JSONDecoder().decode(RulesDoc.self, from: r.encoded())
        XCTAssertEqual(again.clis["vault"]?.disabled, true)
    }

    /// The gallery and `approve rules add` must suggest the same lists (approve built by `make build`).
    func testTemplatesMatchApprove() throws {
        let bin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../mac/approve").standardized.path
        guard FileManager.default.isExecutableFile(atPath: bin) else { throw XCTSkip("run make build first") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["rules", "templates", "--json"]
        p.environment = ["APPROVE_NO_FORWARD": "1", "HOME": NSHomeDirectory()]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let theirs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(theirs.map { $0["name"] as? String ?? "" }, templates.map(\.name))
        for (t, o) in zip(templates, theirs) {
            XCTAssertEqual(o["free"] as? [String], t.free, t.name)
            XCTAssertEqual(o["gatedArgs"] as? [String], t.gatedArgs, t.name)
            XCTAssertEqual(o["summary"] as? String, t.summary, t.name)
        }
    }

    func testShellWords() {
        XCTAssertEqual(shellWords("kv put 'secret/a b' x=\"1 2\""), ["kv", "put", "secret/a b", "x=1 2"])
        XCTAssertEqual(shellWords("  get   pods "), ["get", "pods"])
    }

    func testParseLog() {
        let text = """
        2026-11-14T17:40:06Z cli=vault decision=approved via=phone caller=claude args=vault version
        2026-11-14T17:41:00Z cli=hcloud decision=free via=- caller=terminal args=hcloud server list
        """
        let e = parseLog(text)
        XCTAssertEqual(e.first?.cli, "hcloud")
        XCTAssertEqual(e.last?.command, "vault version")
        XCTAssertEqual(e.last?.via, "phone")
    }
}

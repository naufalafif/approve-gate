@testable import BarCore
import XCTest

final class ReportTests: XCTestCase {
    private let link = "/Users/me/.local/bin/touchid-wrap"

    private func status(_ edit: (inout GateStatus) -> Void = { _ in }) -> GateStatus {
        var s = GateStatus(mode: "user", paired: true, phone: "Pixel", relay: "relay.example", relayOK: true, relayMs: 120,
                           relayError: nil, splitInstall: false, rootCopyOutdated: false, rulesOK: true, rulesPath: "/r.json",
                           clis: [.init(name: "vault", real: "/opt/homebrew/bin/vault", secrets: [], missingSecrets: [])],
                           hook: ["bash": true, "fileTools": true], recent: [])
        edit(&s)
        return s
    }

    func testHealthySetupHasNoProblems() {
        let r = Report(status(), resolved: ["vault": "\(link)/vault"], linkDir: link)
        XCTAssertEqual(r.problems, 0)
        XCTAssertTrue(r.findings.contains { $0.text == "Relay: relay.example, 120 ms" })
    }

    func testDecodesApproveStatusJSON() throws {
        let json = """
        {"binary":"/b","clis":[{"missingSecrets":["vault-token"],"name":"vault","real":"/v","secrets":["vault-token"]}],
         "hook":{"bash":true,"fileTools":false},"mode":"system","paired":true,"phone":"Pixel","pairedAt":"x",
         "recent":[{"caller":"claude","cli":"vault","decision":"approved","time":"2026-11-14T16:37:02Z","via":"phone"}],
         "relay":"relay.example","relayMs":90,"relayOK":false,"relayError":"rate limited (HTTP 429)",
         "rulesOK":true,"rulesPath":"/r","settingsDir":"/s"}
        """
        let s = try JSONDecoder().decode(GateStatus.self, from: Data(json.utf8))
        let r = Report(s, resolved: ["vault": "\(link)/vault"], linkDir: link)
        XCTAssertEqual(r.problems, 3) // relay, file-edit hook, missing secret
        XCTAssertTrue(r.findings.contains { $0.text == "Relay unreachable: relay.example (rate limited (HTTP 429))" })
        XCTAssertTrue(r.findings.contains { $0.text == "Claude Code hook missing for file edits" })
        XCTAssertTrue(r.findings.contains { $0.text == "vault: secret vault-token not set" })
    }

    func testCLIThatSkipsTheGateIsAProblem() {
        let r = Report(status(), resolved: ["vault": "/opt/homebrew/bin/vault"], linkDir: link)
        XCTAssertEqual(r.findings.last, Finding(text: "vault skips the gate: resolves to /opt/homebrew/bin/vault", problem: true))
    }

    func testCLIWithGatingOffIsNotAProblem() {
        let r = Report(status { $0.clis[0].disabled = true }, resolved: ["vault": "/opt/homebrew/bin/vault"], linkDir: link)
        XCTAssertEqual(r.problems, 0)
        XCTAssertTrue(r.findings.contains { $0.text == "Rules: 1 CLIs, gating off for vault" })
    }

    func testUnpairedAndUnreadableRulesAreProblems() {
        let r = Report(status { $0.paired = false; $0.rulesOK = false }, resolved: ["vault": "\(link)/vault"], linkDir: link)
        XCTAssertEqual(r.problems, 2)
    }

    func testSplitInstallIsAProblem() {
        let r = Report(status { $0.splitInstall = true }, resolved: ["vault": "\(link)/vault"], linkDir: link)
        XCTAssertTrue(r.findings.contains(Finding(text: "Two installs with separate settings: run approve setup", problem: true)))
    }

    func testDescribeDecision() {
        let d = GateStatus.Decision(time: "2026-11-14T16:37:02Z", cli: "vault", decision: "denied", via: "mac", caller: "terminal")
        XCTAssertEqual(describe(d, timeZone: TimeZone(identifier: "Asia/Jakarta")!), "23:37  vault  denied on Mac")
    }
}

import Foundation

// Runs without UIKit: swiftc TakesPhone/KeychainReplacement.swift tests/KeychainReplacementTests.swift.
@main
struct KeychainReplacementTests {
    static func main() {
        replacementUpdatesOnlyTokenData()
        failedReplacementLeavesExistingToken()
        missingTokenIsAdded()
        print("Keychain replacement: all checks passed")
    }

    private static func replacementUpdatesOnlyTokenData() {
        let data = Data("replacement-token".utf8)
        let values = KeychainReplacement.updateValues(valueKey: "value-data", data: data)

        precondition(values.count == 1, "An update must not include add-only Keychain attributes")
        precondition(values["value-data"] as? Data == data)
    }

    private static func failedReplacementLeavesExistingToken() {
        var token: String? = "working-token"
        var added = false

        let status = KeychainReplacement.run(itemNotFound: -1) {
            -2
        } add: {
            added = true
            token = "replacement-token"
            return 0
        }

        precondition(status == -2)
        precondition(token == "working-token", "A failed replacement must keep the working token")
        precondition(!added, "Never insert over an item whose update failed")
    }

    private static func missingTokenIsAdded() {
        var token: String?

        let status = KeychainReplacement.run(itemNotFound: -1) {
            -1
        } add: {
            token = "new-token"
            return 0
        }

        precondition(status == 0)
        precondition(token == "new-token")
    }
}

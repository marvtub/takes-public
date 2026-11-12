import Foundation

// Runs without UIKit: swiftc TakesPhone/APIContract.swift tests/APIContractTests.swift.
@main
struct APIContractTests {
    static func main() throws {
        for json in ["{}", #"{"token":""}"#, #"{"token":"   "}"#] {
            do {
                _ = try JSONDecoder().decode(PairResponse.self, from: Data(json.utf8))
                preconditionFailure("An absent or blank pairing token must fail")
            } catch let error as APIError {
                precondition(error.message == "The Mac did not send a pairing token.")
            }
        }

        let response = try JSONDecoder().decode(
            PairResponse.self,
            from: Data(#"{"token":"valid-token"}"#.utf8)
        )
        precondition(response.token == "valid-token")
        print("API contract: all checks passed")
    }
}

import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct PairResponse: Decodable {
    let token: String

    private enum CodingKeys: String, CodingKey { case token }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let token = try values.decodeIfPresent(String.self, forKey: .token),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(status: 200, message: "The Mac did not send a pairing token.")
        }
        self.token = token
    }
}

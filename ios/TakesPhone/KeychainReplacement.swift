import Foundation

enum KeychainReplacement {
    static func updateValues(valueKey: String, data: Data) -> [String: Any] {
        [valueKey: data]
    }

    static func run(itemNotFound: Int32, update: () -> Int32, add: () -> Int32) -> Int32 {
        let status = update()
        return status == itemNotFound ? add() : status
    }
}

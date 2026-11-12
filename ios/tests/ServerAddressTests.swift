import Foundation

// Runs without UIKit: swiftc TakesPhone/ServerAddress.swift tests/ServerAddressTests.swift.
@main
struct ServerAddressTests {
    static func main() {
        precondition(ServerAddress.url("https://mac.x.test:8444")?.host == "mac.x.test")
        precondition(ServerAddress.url("http://127.0.0.1:8797")?.port == 8797)

        precondition(ServerAddress.url("http://[") == nil, "Reject malformed saved addresses")
        precondition(ServerAddress.url("") == nil)
        precondition(ServerAddress.url("mac.x.test:8444") == nil)
        precondition(ServerAddress.url("ftp://mac.x.test") == nil)
        print("Server address: all checks passed")
    }
}

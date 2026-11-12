import Foundation

// Runs without UIKit:
// swiftc TakesPhone/Private/ArticleSchemeRequests.swift tests/ArticleSchemeRequestsTests.swift.
@main
struct ArticleSchemeRequestsTests {
    static func main() {
        let requests = ArticleSchemeRequests()
        let stopped = NSObject()
        var cancellations = 0
        var callbacks = 0

        requests.start(stopped) { cancellations += 1 }
        requests.stop(stopped)
        if requests.finish(stopped) { callbacks += 1 }

        precondition(cancellations == 1, "Stopping must cancel the download")
        precondition(callbacks == 0, "A stopped request must not call WebKit")

        let completed = NSObject()
        requests.start(completed) { cancellations += 1 }
        if requests.finish(completed) { callbacks += 1 }
        requests.stop(completed)

        precondition(cancellations == 1, "A completed download must not be cancelled")
        precondition(callbacks == 1, "An active request may complete once")
        precondition(!requests.finish(completed), "A request must not complete twice")
        print("Article scheme requests: all checks passed")
    }
}

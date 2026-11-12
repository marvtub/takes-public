public let defaultSearchLimit = 20
public let defaultServeSearchLimit = 40

private func validSearchLimit(_ limit: Int) -> Int? {
    limit >= 0 ? limit : nil
}

public func parseSearchLimit(_ value: String?) -> Int? {
    guard let value else { return defaultSearchLimit }
    guard let limit = Int(value) else { return nil }
    return validSearchLimit(limit)
}

public func parseServeSearchLimit(_ value: Any?) -> Int? {
    validSearchLimit(value as? Int ?? defaultServeSearchLimit)
}

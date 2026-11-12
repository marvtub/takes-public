struct PastChatDeletionState {
    private(set) var pending = Set<String>()

    func contains(_ id: String) -> Bool { pending.contains(id) }

    mutating func begin(_ id: String) -> Bool {
        pending.insert(id).inserted
    }

    mutating func finish<Item>(
        _ id: String,
        succeeded: Bool,
        items: inout [Item]?,
        itemID: (Item) -> String
    ) {
        pending.remove(id)
        guard succeeded else { return }
        items?.removeAll { itemID($0) == id }
    }
}

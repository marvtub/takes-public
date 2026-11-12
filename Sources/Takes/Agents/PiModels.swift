import Foundation

/// Ask pi for its authenticated chat models, including custom providers (2026-11-08).
/// Keep provider/id together: the same model can exist on more than one provider.
enum PiModels {
    static var list: [ChatModel] {
        let saved = UserDefaults.standard.data(forKey: "piModels")
            .flatMap { try? JSONDecoder().decode([ChatModel].self, from: $0) } ?? []
        return [ChatModel(id: "", name: defaultModel ?? "pi's default", hint: "Uses pi's default. Your pi settings stay unchanged.")] + saved
    }

    static var defaultModel: String? {
        guard let d = try? Data(contentsOf: AgentKind.piDir.appending(path: "settings.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let m = o["defaultModel"] as? String, !m.isEmpty else { return nil }
        return m
    }

    @MainActor static func refresh() async -> Bool {
        guard let models = await Task.detached(priority: .utility, operation: {
            guard let pi = Agents.path(.pi), let out = AgentCheck.run(pi, ["--list-models"]) else { return [ChatModel]?.none }
            return parse(out)
        }).value, let data = try? JSONEncoder().encode(models) else { return false }
        UserDefaults.standard.set(data, forKey: "piModels")
        return true
    }

    /// pi prints a whitespace-separated table, not JSON. Refuse unknown output.
    static func parse(_ output: String) -> [ChatModel]? {
        let rows = output.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let header = rows.firstIndex(where: { $0 == ["provider", "model", "context", "max-out", "thinking", "images"] }) else { return nil }
        var seen = Set<String>()
        return rows.dropFirst(header + 1).compactMap { row in
            guard row.count == 6, ["yes", "no"].contains(row[4]), ["yes", "no"].contains(row[5]),
                  seen.insert("\(row[0])/\(row[1])").inserted else { return nil }
            return ChatModel(id: "\(row[0])/\(row[1])", name: row[1], hint: row[0])
        }
    }

    /// Keyboard highlight is separate from the saved pick and never changes result order.
    static func next(in rows: [ChatModel], from highlighted: String?, by step: Int) -> String? {
        guard !rows.isEmpty else { return nil }
        guard let index = rows.firstIndex(where: { $0.id == highlighted }) else {
            return (step > 0 ? rows.first : rows.last)?.id
        }
        return rows[(index + step + rows.count) % rows.count].id
    }

    static func matching(_ models: [ChatModel], query: String) -> [ChatModel] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return models.filter { model in words.allSatisfy { "\(model.name) \(model.hint)".localizedStandardContains(String($0)) } }
    }
}

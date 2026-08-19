import Foundation

struct WidgetSnapshot: Codable, Equatable {
    let updateCount: Int
    let isOffline: Bool
    let updatedAt: Date

    static let empty = WidgetSnapshot(
        updateCount: 0,
        isOffline: false,
        updatedAt: .distantPast
    )
}

enum WidgetSnapshotStorage {
    static let currentKey = "yperson.v1.widget_snapshot"
    static let legacyKey = "widget_snapshot"

    private struct Envelope: Codable {
        let schemaVersion: Int
        let snapshot: WidgetSnapshot
    }

    static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
        try JSONEncoder().encode(
            Envelope(schemaVersion: 1, snapshot: snapshot)
        )
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data),
           envelope.schemaVersion == 1 {
            return envelope.snapshot
        }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func read(from defaults: UserDefaults) -> WidgetSnapshot? {
        if let data = defaults.data(forKey: currentKey),
           let snapshot = decode(data) {
            return snapshot
        }
        guard let legacyData = defaults.data(forKey: legacyKey) else {
            return nil
        }
        return decode(legacyData)
    }
}

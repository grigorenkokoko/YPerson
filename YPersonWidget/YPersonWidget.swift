import SwiftUI
import WidgetKit

private struct Entry: TimelineEntry {
    let date: Date
    let updateCount: Int
    let isOffline: Bool
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), updateCount: 3, isOffline: false) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(readEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [readEntry()], policy: .never))
    }

    private func readEntry() -> Entry {
        guard let group = Bundle.main.object(
            forInfoDictionaryKey: "APP_GROUP_IDENTIFIER"
        ) as? String,
              let defaults = UserDefaults(suiteName: group),
              let snapshot = WidgetSnapshotStorage.read(from: defaults) else {
            return Entry(date: Date(), updateCount: 0, isOffline: false)
        }
        return Entry(
            date: snapshot.updatedAt,
            updateCount: snapshot.updateCount,
            isOffline: snapshot.isOffline
        )
    }
}

private struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        Group {
            if #available(iOSApplicationExtension 16.0, *), family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 2) {
                    Text("YPerson · Моя карточка").font(.headline)
                    Text(updateText).font(.caption)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "person.text.rectangle.fill").font(.title).foregroundColor(Color(red: 0.31, green: 0.37, blue: 0.91))
                    Text("YPerson").font(.headline)
                    Text(updateText).font(.caption).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Text("Моя карточка").font(.caption2).bold()
                }.padding()
            }
        }
        .widgetURL(URL(string: "yperson://card"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("YPerson, моя карточка, \(updateText)")
    }

    private var updateText: String {
        if entry.isOffline { return entry.updateCount == 0 ? "Без сети · обновлений нет" : "Без сети · \(entry.updateCount) обновления" }
        return entry.updateCount == 0 ? "Обновлений нет" : "\(entry.updateCount) обновления"
    }
}

@main
struct YPersonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.yperson.app.widget", provider: Provider()) { entry in WidgetView(entry: entry) }
            .configurationDisplayName("Моя карточка")
            .description("Безопасный быстрый вход в YPerson и число обновлений.")
            .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        if #available(iOSApplicationExtension 16.0, *) { return [.systemSmall, .accessoryRectangular] }
        return [.systemSmall]
    }
}

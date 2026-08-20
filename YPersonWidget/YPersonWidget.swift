import SwiftUI
import WidgetKit

private struct ScannerEntry: TimelineEntry {
    let date: Date
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ScannerEntry {
        ScannerEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ScannerEntry) -> Void
    ) {
        completion(ScannerEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<ScannerEntry>) -> Void
    ) {
        completion(Timeline(
            entries: [ScannerEntry(date: Date())],
            policy: .never
        ))
    }
}

private struct ScannerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ScannerEntry

    var body: some View {
        Group {
            if #available(iOSApplicationExtension 16.0, *),
               family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2.bold())
                }
            } else if #available(iOSApplicationExtension 16.0, *),
                      family == .accessoryRectangular {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Сканировать QR")
                            .font(.headline)
                        Text("YPerson")
                            .font(.caption)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 42, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("Сканировать QR")
                        .font(.headline)
                    Text("Добавить визитку")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.82))
                }
                .foregroundColor(.white)
                .padding(16)
                .scannerWidgetBackground()
            }
        }
        .widgetURL(ScannerWidgetRoute.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Сканировать QR-код визитки в YPerson")
    }
}

private extension View {
    @ViewBuilder
    func scannerWidgetBackground() -> some View {
        let indigo = Color(red: 0.31, green: 0.37, blue: 0.91)
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(indigo, for: .widget)
        } else {
            background(indigo)
        }
    }
}

@main
struct YPersonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.yperson.app.widget", provider: Provider()) {
            entry in
            ScannerWidgetView(entry: entry)
        }
        .configurationDisplayName("Сканер визиток")
        .description("Открывает YPerson сразу для сканирования QR-кода визитки.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        if #available(iOSApplicationExtension 16.0, *) {
            return [.systemSmall, .accessoryCircular, .accessoryRectangular]
        }
        return [.systemSmall]
    }
}

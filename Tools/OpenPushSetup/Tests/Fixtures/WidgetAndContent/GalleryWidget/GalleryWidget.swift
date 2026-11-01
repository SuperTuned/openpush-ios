import SwiftUI
import WidgetKit

@main
struct GalleryWidgets: WidgetBundle {
    var body: some Widget { GalleryWidget() }
}

struct GalleryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "gallery", provider: Provider()) { _ in Text("Gallery") }
    }
}

struct Provider: TimelineProvider {
    struct Entry: TimelineEntry { let date = Date() }
    func placeholder(in context: Context) -> Entry { Entry() }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry()], policy: .never))
    }
}

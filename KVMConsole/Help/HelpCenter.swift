import AppKit
import SwiftUI

/// Opens the help window at a topic, from menus, help buttons in sheets and
/// the Help menu's search field.
@MainActor @Observable
final class HelpCenter {
    static let shared = HelpCenter()
    static let windowID = "help"

    var selection: HelpTopic.ID? = HelpTopic.all.first?.id
    var searchText = ""

    /// Captured from a SwiftUI view so AppKit callers (the Help menu search)
    /// can open the help window too.
    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var menuSearch: HelpMenuSearch?

    /// Hooks the help topics into the Help menu's search field. Call once the
    /// app has a window.
    func install(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        guard menuSearch == nil else { return }
        let handler = HelpMenuSearch()
        NSApplication.shared.registerUserInterfaceItemSearchHandler(handler)
        menuSearch = handler
    }

    func show(_ topicID: HelpTopic.ID? = nil, search: String? = nil, using action: OpenWindowAction? = nil) {
        if let topicID, HelpTopic.topic(topicID) != nil {
            selection = topicID
            searchText = ""
        }
        if let search { searchText = search }
        if let open = action ?? openWindow { open(id: Self.windowID) }
    }
}

/// Lists help topics under "Help Topics" when someone types in the Help menu's
/// search field. AppKit may call the search from a background thread; it only
/// reads the static topic list.
final class HelpMenuSearch: NSObject, NSUserInterfaceItemSearching {
    func searchForItems(withSearch searchString: String, resultLimit: Int,
                        matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void) {
        let ids = HelpTopic.search(searchString).prefix(resultLimit).map(\.id)
        handleMatchedItems(Array(ids))
    }

    func localizedTitles(forItem item: Any) -> [String] {
        guard let id = item as? String, let topic = HelpTopic.topic(id) else { return [] }
        return [topic.title]
    }

    func performAction(forItem item: Any) {
        guard let id = item as? String else { return }
        Task { @MainActor in HelpCenter.shared.show(id) }
    }

    func showAllHelpTopics(forSearch searchString: String) {
        Task { @MainActor in HelpCenter.shared.show(search: searchString) }
    }
}

/// The round "?" button for a sheet or window, opening the help at a topic.
struct HelpButton: View {
    let topic: HelpTopic.ID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HelpLink { HelpCenter.shared.show(topic, using: openWindow) }
    }
}

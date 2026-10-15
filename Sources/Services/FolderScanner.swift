import Foundation
import Observation

/// Finds what is taking the space: the largest items directly inside the home
/// folder, Applications and the user's Library.
///
/// Held here rather than in the panel so a scan carries on after the panel
/// closes, and its results are still there when it is opened again. Only runs
/// when asked: walking a home folder reads every file's metadata and can take
/// a minute, which is not something to do in the background unprompted.
///
/// Folders macOS protects - Desktop, Documents, Downloads, Mail - raise their
/// own consent prompt the first time, because the scan was something the user
/// clicked for. Whatever stays unreadable is skipped rather than failing the
/// scan.
@MainActor @Observable
final class FolderScanner {
    static let shared = FolderScanner()

    struct Item: Identifiable, Hashable, Sendable {
        var url: URL
        var bytes: Int64
        var id: URL { url }
    }

    private(set) var items: [Item] = []
    private(set) var scanning = false
    private(set) var finishedAt: Date?

    /// How many results are kept. More than a panel can show is wasted work
    /// for the sort, fewer and the answer is always "Library".
    nonisolated static let limit = 8

    private init() {}

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .utility) { Self.largest() }.value
            items = found
            finishedAt = Date()
            scanning = false
            // The panel was sized before the list existed.
            WidgetDetailWindow.shared.relayout()
        }
    }

    nonisolated private static func largest() -> [Item] {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let roots = [home, URL(fileURLWithPath: "/Applications"), home.appending(path: "Library")]
        var found: [Item] = []
        for root in roots {
            let children = (try? files.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children {
                // ~/Library is a root of its own, and counting it as one item
                // of home as well would put it at the top of every scan.
                guard child.standardizedFileURL != roots[2].standardizedFileURL else { continue }
                found.append(Item(url: child, bytes: size(of: child)))
            }
        }
        return Array(found.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// Allocated size, which is what the disk actually gives up: a sparse
    /// disk image reports its full logical length but occupies far less.
    nonisolated private static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        let own = (try? url.resourceValues(forKeys: Set(keys)))
        if own?.isRegularFile == true { return Int64(own?.totalFileAllocatedSize ?? 0) }
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

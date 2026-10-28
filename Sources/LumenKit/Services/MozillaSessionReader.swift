import Foundation

/// Reads the active URL from Firefox-family session recovery data.
///
/// Firefox and Zen do not always expose their browser chrome through macOS
/// Accessibility. Their session store still records each tab's URL, title, and
/// last-access time, so it provides a non-invasive fallback that does not
/// focus the address bar or alter the clipboard.
final class MozillaSessionReader: @unchecked Sendable {
    private struct Tab {
        var title: String
        var urlString: String
        var lastAccessed: Int64
    }

    private struct Cache {
        var fileURL: URL
        var modificationDate: Date
        var fileSize: Int
        var tabs: [Tab]
    }

    private let lock = NSLock()
    private var cache: Cache?

    func activeURL(bundleIdentifier: String, windowTitle: String) -> String? {
        guard let root = profileRoot(bundleIdentifier: bundleIdentifier),
              let sessionURL = newestSessionStore(in: root),
              let values = try? sessionURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate,
              let fileSize = values.fileSize
        else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let tabs: [Tab]
        if let cache,
           cache.fileURL == sessionURL,
           cache.modificationDate == modificationDate,
           cache.fileSize == fileSize {
            tabs = cache.tabs
        } else {
            guard let decoded = decodeTabs(at: sessionURL) else { return nil }
            tabs = decoded
            cache = Cache(
                fileURL: sessionURL,
                modificationDate: modificationDate,
                fileSize: fileSize,
                tabs: decoded
            )
        }

        let normalizedWindowTitle = normalizedTitle(windowTitle)
        let matchingTabs = tabs.filter { normalizedTitle($0.title) == normalizedWindowTitle }
        return (matchingTabs.isEmpty ? tabs : matchingTabs)
            .max { $0.lastAccessed < $1.lastAccessed }?
            .urlString
    }

    private func profileRoot(bundleIdentifier: String) -> URL? {
        let folder: String
        switch bundleIdentifier {
        case "app.zen-browser.zen":
            folder = "zen"
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition":
            folder = "Firefox"
        default:
            return nil
        }

        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return applicationSupport.appendingPathComponent(folder, isDirectory: true)
    }

    private func newestSessionStore(in root: URL) -> URL? {
        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
        guard let profileURLs = try? FileManager.default.contentsOfDirectory(
            at: profiles,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return profileURLs
            .map {
                $0.appendingPathComponent("sessionstore-backups", isDirectory: true)
                    .appendingPathComponent("recovery.jsonlz4")
            }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = values.contentModificationDate
                else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func decodeTabs(at url: URL) -> [Tab]? {
        guard let compressed = try? Data(contentsOf: url, options: .mappedIfSafe),
              let jsonData = Self.decompressMozillaLZ4(compressed),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]]
        else { return nil }

        var tabs: [Tab] = []
        for window in windows {
            guard let rawTabs = window["tabs"] as? [[String: Any]] else { continue }
            for rawTab in rawTabs {
                guard let entries = rawTab["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
                let requestedIndex = (rawTab["index"] as? NSNumber)?.intValue ?? entries.count
                let entryIndex = min(max(requestedIndex - 1, 0), entries.count - 1)
                let entry = entries[entryIndex]
                guard let urlString = entry["url"] as? String,
                      isTrackableURL(urlString)
                else { continue }

                tabs.append(Tab(
                    title: entry["title"] as? String ?? "",
                    urlString: urlString,
                    lastAccessed: (rawTab["lastAccessed"] as? NSNumber)?.int64Value ?? 0
                ))
            }
        }
        return tabs
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: " — Mozilla Firefox", with: "")
            .replacingOccurrences(of: " - Mozilla Firefox", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isTrackableURL(_ value: String) -> Bool {
        guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    /// Decodes Firefox's `mozLz40\0` header followed by a size-prefixed raw LZ4 block.
    static func decompressMozillaLZ4(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let magic = Array("mozLz40\0".utf8)
        guard bytes.count >= 12,
              Array(bytes.prefix(8)) == magic
        else { return nil }

        let expectedSize = Int(bytes[8])
            | (Int(bytes[9]) << 8)
            | (Int(bytes[10]) << 16)
            | (Int(bytes[11]) << 24)
        guard expectedSize >= 0, expectedSize <= 256 * 1024 * 1024 else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(expectedSize)
        var cursor = 12

        while cursor < bytes.count {
            let token = bytes[cursor]
            cursor += 1

            guard let literalLength = extendedLength(
                initial: Int(token >> 4),
                bytes: bytes,
                cursor: &cursor
            ), cursor + literalLength <= bytes.count,
                output.count + literalLength <= expectedSize
            else { return nil }

            output.append(contentsOf: bytes[cursor..<(cursor + literalLength)])
            cursor += literalLength
            if cursor == bytes.count { break }

            guard cursor + 2 <= bytes.count else { return nil }
            let offset = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            cursor += 2
            guard offset > 0, offset <= output.count,
                  let rawMatchLength = extendedLength(
                    initial: Int(token & 0x0F),
                    bytes: bytes,
                    cursor: &cursor
                  )
            else { return nil }

            let matchLength = rawMatchLength + 4
            guard output.count + matchLength <= expectedSize else { return nil }
            var sourceIndex = output.count - offset
            for _ in 0..<matchLength {
                output.append(output[sourceIndex])
                sourceIndex += 1
            }
        }

        guard output.count == expectedSize else { return nil }
        return Data(output)
    }

    private static func extendedLength(
        initial: Int,
        bytes: [UInt8],
        cursor: inout Int
    ) -> Int? {
        guard initial == 15 else { return initial }
        var length = initial
        while cursor < bytes.count {
            let next = Int(bytes[cursor])
            cursor += 1
            length += next
            if next != 255 { return length }
        }
        return nil
    }
}

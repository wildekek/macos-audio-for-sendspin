import Foundation
import Network

/// A Music Assistant server advertised over mDNS (`_mass._tcp`).
public struct MusicAssistantServer: Sendable, Hashable {
    /// Its name, e.g. "Music Assistant (d5369777-music-assistant)": the same name it gives
    /// as a Sendspin server.
    public var name: String?
    /// Its web interface on the local network.
    public var url: URL
}

public enum MusicAssistantBrowser {
    public static let serviceType = "_mass._tcp"

    /// Browse continuously; yields the servers whose TXT record has a web interface URL,
    /// whenever they change. The record holds the server's info (`ServerInfoMessage`), so no
    /// connection is needed. Browsing stops when the consuming task is cancelled.
    public static func browse() -> AsyncStream<[MusicAssistantServer]> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(results.compactMap(server(from:)))
            }
            browser.stateUpdateHandler = { state in Log.debug("Music Assistant browser: \(state)") }
            browser.start(queue: DispatchQueue(label: "sendspin.mass-browser"))
            continuation.onTermination = { _ in browser.cancel() }
        }
    }

    /// `internal_url` since Music Assistant 2.10, `base_url` before.
    private static func server(from result: NWBrowser.Result) -> MusicAssistantServer? {
        guard case let .bonjour(txt) = result.metadata,
              let string = txt["internal_url"] ?? txt["base_url"], let url = URL(string: string),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return MusicAssistantServer(name: txt["name"], url: url)
    }
}

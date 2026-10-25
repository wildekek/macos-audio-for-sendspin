import Network
import Testing
@testable import SendspinServerKit

struct PlayerBrowserTests {
    /// A server SHOULD only connect when the advertised path is an RFC 3986 path-absolute
    /// (connection.md, mDNS).
    @Test func acceptsOnlyAbsolutePaths() {
        for path in ["/", "/sendspin", "/a/b/", "/a%2Fb", "/v1;x=1", "/~user/@:!$&'()*+,="] {
            #expect(PlayerBrowser.isPathAbsolute(path), "\(path)")
        }
        for path in ["", "sendspin", "//host/sendspin", "/a b", "/a%2", "/a%zz", "/é", "/a?b", "/a#b"] {
            #expect(!PlayerBrowser.isPathAbsolute(path), "\(path)")
        }
    }

    /// … and only to an advertised address that isn't loopback or unspecified.
    @Test func refusesLoopbackAndUnspecifiedAddresses() {
        for host in ["127.0.0.1", "127.1.2.3", "0.0.0.0", "::1", "::"] {
            #expect(PlayerBrowser.isLoopbackOrUnspecified(NWEndpoint.Host(host)), "\(host)")
        }
        for host in ["192.168.1.183", "10.0.0.1", "fe80::1"] {
            #expect(!PlayerBrowser.isLoopbackOrUnspecified(NWEndpoint.Host(host)), "\(host)")
        }
    }
}

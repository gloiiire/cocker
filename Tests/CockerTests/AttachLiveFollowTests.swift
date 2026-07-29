import CockerCore
import Testing
@testable import CockerDaemon

@Suite("direct container attach")
struct AttachLiveFollowTests {
    @Test("replays a bounded backlog and remains subscribed to live output")
    func attachUsesFollowingLogsRequest() {
        let request = DaemonServer.attachLogsRequest(for: "demo")

        #expect(request.id == "demo")
        #expect(request.tail == 20)
        #expect(request.follow)
    }
}

import Testing
import Foundation
@testable import CockerCore

@Suite("Cocker switch allocator — IP encoding")
struct CockerSwitchIPTests {
    @Test func firstHostRendersAsExpected() {
        #expect(CockerSwitchAllocator.ip(forHost: 2) == "10.42.0.2")
    }

    @Test func crossesOctetBoundary() {
        #expect(CockerSwitchAllocator.ip(forHost: 255) == "10.42.0.255")
        #expect(CockerSwitchAllocator.ip(forHost: 256) == "10.42.1.0")
        #expect(CockerSwitchAllocator.ip(forHost: 257) == "10.42.1.1")
    }

    @Test func nearTheEndOfTheRange() {
        // 65534 = 0xFFFE → 10.42.255.254
        #expect(CockerSwitchAllocator.ip(forHost: 65534) == "10.42.255.254")
    }
}

@Suite("Cocker switch allocator — MAC encoding")
struct CockerSwitchMACTests {
    @Test func dockerStylePrefix() {
        #expect(CockerSwitchAllocator.mac(forIP: "10.42.0.2") == "02:42:0a:2a:00:02")
    }

    @Test func lowerOctetsTrackIPLastTwoOctets() {
        #expect(CockerSwitchAllocator.mac(forIP: "10.42.7.42") == "02:42:0a:2a:07:2a")
        #expect(CockerSwitchAllocator.mac(forIP: "10.42.255.255") == "02:42:0a:2a:ff:ff")
    }

    @Test func malformedIPReturnsZeroSuffix() {
        #expect(CockerSwitchAllocator.mac(forIP: "garbage") == "02:42:0a:2a:00:00")
        #expect(CockerSwitchAllocator.mac(forIP: "1.2.3") == "02:42:0a:2a:00:00")
        #expect(CockerSwitchAllocator.mac(forIP: "") == "02:42:0a:2a:00:00")
    }

    @Test func nonNumericOctetReturnsZero() {
        #expect(CockerSwitchAllocator.mac(forIP: "10.42.abc.5") == "02:42:0a:2a:00:00")
    }
}

@Suite("Cocker switch allocator — cursor walk")
struct CockerSwitchCursorTests {
    @Test func walksLinearly() {
        var cursor = CockerSwitchAllocator.firstHost
        var hosts: [UInt16] = []
        for _ in 0..<5 {
            let (h, next) = CockerSwitchAllocator.nextHost(from: cursor)
            hosts.append(h)
            cursor = next
        }
        #expect(hosts == [2, 3, 4, 5, 6])
    }

    @Test func wrapsAtLastHost() {
        let (h, next) = CockerSwitchAllocator.nextHost(from: CockerSwitchAllocator.lastHost)
        #expect(h == 65534)
        #expect(next == CockerSwitchAllocator.firstHost)  // wraps to 2
    }

    @Test func continuesPastWrap() {
        var cursor = CockerSwitchAllocator.lastHost
        var hosts: [UInt16] = []
        for _ in 0..<3 {
            let (h, next) = CockerSwitchAllocator.nextHost(from: cursor)
            hosts.append(h)
            cursor = next
        }
        #expect(hosts == [65534, 2, 3])
    }
}

@Suite("Cocker switch allocator — constants")
struct CockerSwitchConstantsTests {
    @Test func subnetIsTenFortyTwo() {
        #expect(CockerSwitchAllocator.subnet == "10.42.0.0/16")
    }

    @Test func gatewayIsFirstUsable() {
        #expect(CockerSwitchAllocator.gateway == "10.42.0.1")
    }

    @Test func firstHostSkipsGateway() {
        #expect(CockerSwitchAllocator.firstHost == 2)
    }

    @Test func lastHostStopsBeforeBroadcast() {
        // 10.42.255.255 is broadcast ; we stop at .254
        #expect(CockerSwitchAllocator.lastHost == 65534)
    }
}

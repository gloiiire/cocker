import Testing
import Foundation
@testable import CockerCore

// ImageStore is an actor backed by JSON-on-disk plus a blob/rootfs tree.
// Hits the filesystem; each test runs in a fresh tmpdir.

private func makeStore() throws -> (ImageStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cocker-imgstore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ImageStore(rootDir: root)
    return (store, root)
}

private func img(_ repo: String, _ tag: String = "latest", id: String? = nil,
                 layers: [String] = []) -> ImageInfo {
    ImageInfo(id: id ?? "sha256:" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
              repository: repo, tag: tag, layers: layers)
}

@Suite("ImageStore — find")
struct ImageStoreFindTests {
    @Test func findsExactReference() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.store(image: img("alpine"))
        let found = await store.find("alpine:latest")
        #expect(found?.repository == "alpine")
    }

    @Test func findDefaultsToLatestTag() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.store(image: img("alpine"))
        let found = await store.find("alpine")
        #expect(found?.tag == "latest")
    }

    @Test func findFallsBackToLibraryPrefix() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.store(image: img("library/alpine"))
        let found = await store.find("alpine")
        #expect(found?.repository == "library/alpine")
    }

    @Test func findByShortID() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let i = img("alpine", id: "sha256:abcdef1234567890")
        try await store.store(image: i)
        let found = await store.find("sha256:abcdef")
        #expect(found?.id == i.id)
    }

    @Test func existsMirrorsFind() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.store(image: img("alpine"))
        #expect(await store.exists("alpine:latest"))
        #expect(!(await store.exists("ghost:latest")))
    }
}

@Suite("ImageStore — list / remove / tag")
struct ImageStoreCRUDTests {
    @Test func listSortsByCreatedAtDescending() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let old = ImageInfo(id: "sha256:1", repository: "a", tag: "v1",
                            createdAt: Date(timeIntervalSinceNow: -100))
        let new = ImageInfo(id: "sha256:2", repository: "b", tag: "v1",
                            createdAt: Date())
        try await store.store(image: old)
        try await store.store(image: new)
        let list = await store.list()
        #expect(list.first?.repository == "b")
    }

    @Test func removeDropsImage() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.store(image: img("trash"))
        try await store.remove("trash:latest")
        #expect(await store.find("trash:latest") == nil)
    }

    @Test func removeThrowsForMissing() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: CockerError.self) {
            try await store.remove("ghost")
        }
    }

    @Test func tagCreatesAdditionalReference() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.store(image: img("alpine"))
        try await store.tag(source: "alpine", target: "myrepo:v1")
        #expect(await store.exists("myrepo:v1"))
    }
}

@Suite("ImageStore — blob paths")
struct ImageStoreBlobPathTests {
    @Test func blobPathStripsSHA256Prefix() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let path = await store.blobPath(for: "sha256:deadbeef")
        #expect(path.lastPathComponent == "deadbeef")
    }

    @Test func blobPathHandlesBareDigest() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let path = await store.blobPath(for: "deadbeef")
        #expect(path.lastPathComponent == "deadbeef")
    }

    @Test func hasBlobReflectsFilesystem() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!(await store.hasBlob("sha256:nope")))
        let blobPath = await store.blobPath(for: "sha256:planted")
        try Data("layer-bytes".utf8).write(to: blobPath)
        #expect(await store.hasBlob("sha256:planted"))
    }
}

@Suite("ImageStore — rootfs paths")
struct ImageStoreRootfsPathTests {
    @Test func rootfsDirectoryUsesIDPrefix() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let i = img("alpine", id: "sha256:1234567890abcdef")
        let dir = await store.rootfsDirectory(for: i)
        #expect(dir.lastPathComponent == String("sha256:12345".prefix(12)))
    }

    @Test func hasRootfsReflectsFilesystem() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let i = img("alpine")
        #expect(!(await store.hasRootfs(for: i)))
        let dir = await store.rootfsDirectory(for: i)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(await store.hasRootfs(for: i))
    }

    @Test func containerRootfsDirectoryIsPerContainer() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = await store.containerRootfsDirectory(containerID: "deadbeef1234")
        #expect(dir.path.contains("containers/deadbeef1234"))
        #expect(dir.lastPathComponent == "rootfs")
    }

    @Test func removeContainerRootfsClearsTree() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = await store.containerRootfsDirectory(containerID: "abc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: dir.appendingPathComponent("touch"))
        try await store.removeContainerRootfs(containerID: "abc")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

@Suite("ImageStore — persistence")
struct ImageStorePersistenceTests {
    @Test func reloadsIndexFromDisk() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-imgstore-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let s = try ImageStore(rootDir: root)
            try await s.store(image: img("alpine"))
        }
        let s2 = try ImageStore(rootDir: root)
        #expect(await s2.find("alpine:latest") != nil)
    }
}

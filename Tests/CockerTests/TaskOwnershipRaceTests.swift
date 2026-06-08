import Testing
import Foundation

// Verifies the algorithm `spawnWatcherIfNeeded` / `markWatcherFinished` rely
// on inside ContainerEngine — a "finished cleanup must not wipe a fresh
// spawn's slot" invariant. The production types are `private` so we
// re-state the slot machinery in a tiny isolated form and exercise the
// same race the engine handles. Any drift between this test and the
// engine's logic will surface as a behavioural divergence in the live
// lifecycle tests.

private actor SlotStore {
    struct Record { let id: UUID; var alive: Bool }
    private var slots: [String: Record] = [:]

    func spawn(key: String) -> UUID {
        // Skip if an existing slot is still alive.
        if let r = slots[key], r.alive { return r.id }
        let new = UUID()
        slots[key] = Record(id: new, alive: true)
        return new
    }

    func markFinished(key: String, id: UUID) {
        guard var r = slots[key], r.id == id else { return }
        r.alive = false
        slots[key] = r
        if slots[key]?.id == id { slots[key] = nil }
    }

    func read(key: String) -> Record? { slots[key] }
}

@Suite("Task ownership race — spawn / markFinished invariant")
struct TaskOwnershipRaceTests {
    @Test func finishedTaskClearsItsOwnSlot() async {
        let store = SlotStore()
        let id = await store.spawn(key: "c1")
        await store.markFinished(key: "c1", id: id)
        #expect(await store.read(key: "c1") == nil)
    }

    @Test func freshSpawnAfterFinishedSlotSpawns() async {
        // Finished task cleared the slot ; next spawn must succeed.
        let store = SlotStore()
        let id1 = await store.spawn(key: "c1")
        await store.markFinished(key: "c1", id: id1)
        let id2 = await store.spawn(key: "c1")
        #expect(id1 != id2)
        #expect(await store.read(key: "c1")?.id == id2)
        #expect(await store.read(key: "c1")?.alive == true)
    }

    @Test func staleFinishDoesNotWipeReplacement() async {
        // Simulate the dangerous interleave : Task A finishes its loop
        // but, before its cleanup runs, Task B spawns and replaces the
        // slot. A's markFinished must NOT wipe B.
        let store = SlotStore()
        let aID = await store.spawn(key: "c1")
        // A has decided it's done but hasn't called markFinished yet.
        // Meanwhile a fresh spawn arrives. To trigger this we need to
        // forcibly clear "alive" so the next spawn replaces. Production
        // code does this via the inline mutate-then-clear pattern ; here
        // we simulate by mutating directly via a re-entrant store call.
        await store.markFinishedAliveOnly(key: "c1", id: aID)
        let bID = await store.spawn(key: "c1")
        #expect(aID != bID)
        // Now Task A's late cleanup arrives. It must see B's id in the
        // slot and back off — this is the race the engine's
        // `id == taskID` guard exists to prevent.
        await store.markFinished(key: "c1", id: aID)
        let final = await store.read(key: "c1")
        #expect(final?.id == bID)
        #expect(final?.alive == true)
    }
}

// Test-only hook exposing the half-state mutate from outside the actor.
// Mirrors the engine's two-phase mark (flip alive, then conditionally
// drop slot) — verifies the *second* phase respects ownership.
extension SlotStore {
    func markFinishedAliveOnly(key: String, id: UUID) {
        guard var r = slots[key], r.id == id else { return }
        r.alive = false
        slots[key] = r
    }
}

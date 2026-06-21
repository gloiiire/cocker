# Apple Feedback report — `VZVirtioSocketDevice.connect()` callback stops firing under repeated background-context calls

> **What this is** : a ready-to-submit Apple Feedback (formerly Radar) describing
> a Virtualization.framework bug we hit in cocker. The exact title, body,
> reproducer, and submission steps are below. Copy-paste into
> [feedbackassistant.apple.com](https://feedbackassistant.apple.com).
>
> **Why we care** : this bug forces cocker's healthcheck path to use a
> file-based virtiofs workaround instead of vsock. The workaround is reliable
> but adds ~250 ms granularity vs ~10 ms for a direct vsock call.

---

## 1. How to submit (5 min)

1. Open **Feedback Assistant** : either the app pre-installed on macOS
   (Spotlight → "Feedback Assistant") or the web form at
   [feedbackassistant.apple.com](https://feedbackassistant.apple.com)
   (sign in with your Apple ID).
2. Click **New Feedback** → **macOS**.
3. **Area** : *Virtualization*  → **Type** : *Incorrect/Unexpected Behavior*.
4. Paste each section of this doc into the corresponding field :
   - **Title** → §2 below.
   - **Description** → §3.
   - **Steps to Reproduce** → §4.
   - **What did you expect to happen?** → §5.
   - **What actually happened?** → §6.
5. **Attachments** : attach `docs/apple-feedback/VsockCallbackBugReproducer.swift`
   from this repo (the minimal reproducer) and a `sysdiagnose` if Apple asks
   for one later.
6. Submit.  Save the FB-XXXXXXX number Apple gives you back. Paste it into
   §8 at the bottom of this file so the next maintainer can find it.

> If you don't have a paid Apple Developer account you can still file from
> any Apple ID — Feedback Assistant works for everyone. You only need the
> paid account if Apple asks you to test a beta seed.

---

## 2. Title

> Virtualization.framework: VZVirtioSocketDevice.connect() completion handler
> stops firing when invoked repeatedly from a background async context

---

## 3. Description

When `VZVirtioSocketDevice.connect(toPort:completionHandler:)` is invoked
**repeatedly** from a non-main async context (e.g. `Task.detached`,
`DispatchQueue.global().async`), the `completionHandler` reliably fires for
the first N calls (commonly N=1 or 2) and then **never fires again** for the
remaining calls, indefinitely. No error is delivered ; the closure simply
never runs.

The bug is observed on production macOS 14, 15, and Apple Silicon. It does
*not* affect single-shot connections, and it does *not* affect connections
issued from `@MainActor` / the main run loop — those work for any number of
calls.

In our project (cocker, a container runtime built on Virtualization.framework)
this prevents us from running container healthchecks over vsock : the first
probe succeeds, every subsequent probe times out because the completion
handler never fires. We had to ship a virtiofs file-based workaround that
polls a shared filesystem location every 250 ms instead — functionally
correct but significantly higher latency than a direct vsock call.

Suspected interaction : Apple's internal callback queue for the
VZVirtioSocketDevice may be tied to the thread the *first* `connect()` was
invoked on, and subsequent calls from foreign threads/queues never observe
that the connection has been established.

---

## 4. Steps to Reproduce

1. Build and run the attached `VsockCallbackBugReproducer.swift` on macOS 14
   or later, Apple Silicon. Requires a small Linux guest with a vsock
   listener on port 9000 (any program that accepts an AF_VSOCK socket and
   echoes one byte back is enough — script provided in the reproducer's
   comments).
2. Boot a VZVirtualMachine with a single `VZVirtioSocketDeviceConfiguration`
   attached.
3. After boot, loop **synchronously** for 20 iterations :
   ```swift
   for i in 0..<20 {
       await withCheckedContinuation { cont in
           DispatchQueue.global().async {
               socketDevice.connect(toPort: 9000) { result in
                   print("probe \(i): \(result)")
                   cont.resume()
               }
           }
       }
       try await Task.sleep(nanoseconds: 500_000_000)
   }
   ```
4. Observe stdout.

---

## 5. Expected

All 20 probes invoke their `completionHandler` with either `.success` or
`.failure`, in less than a few hundred milliseconds each.

---

## 6. Actual

The first one or two probes fire the handler with `.success` and read the
echoed byte successfully. The handler for **probes 3 through 20 is never
invoked** — they sit forever waiting. There is no error logged, no exception
thrown ; the closure simply never runs. Adding a `DispatchQueue.global().asyncAfter`
fallback to break the deadlock confirms the handler is absent, not delayed.

Replacing `DispatchQueue.global().async` with a direct synchronous call on
the main run loop (`socketDevice.connect(toPort: 9000) { ... }` straight in
the for loop body without the dispatch hop) makes all 20 probes succeed —
which is consistent with the hypothesis that the device's internal callback
queue is bound to the originating thread.

---

## 7. Workaround in production

In cocker we sidestep the bug entirely by routing healthcheck commands
through a virtiofs file protocol :
- The host writes `cmd-<seq>` to a shared directory.
- A small C daemon (`cocker-init`'s `health_poll`) scans the dir every 250 ms,
  reads the request, runs it inside the container, writes `result-<seq>`.
- The host polls for `result-<seq>` with a deadline.

This works perfectly but has two costs vs vsock :
- ~250 ms latency floor per probe (vs ~10 ms over vsock).
- A persistent guest-side worker process burning a small amount of CPU
  polling, which we'd otherwise not need.

The dead code path that *would* use vsock is at
`Sources/CockerDaemon/Engine/VMRuntime.swift:1219–1303` and carries the
"Known limitation" comment block referenced in this doc.

---

## 8. Tracking

| Field | Value |
|---|---|
| Filed on | _yyyy-mm-dd_ — fill once you submit |
| FB number | _FB-XXXXXXX_ — fill once Apple returns one |
| Filed by | _your Apple ID name_ |
| Status | open / triaged / fixed in macOS X.Y / closed-no-action |
| Apple response | _paste any reply here_ |

When this bug is reported as fixed in a macOS release, update
`Sources/CockerDaemon/Engine/VMRuntime.swift:1211` to drop the "Known
limitation" note, wire `runHealthcheckOnce` to call `execProbe` again, and
delete the virtiofs `health_poll` worker (`cocker-init/health_poll.c`).

---

## 9. References

- Source code carrying the workaround comment :
  `Sources/CockerDaemon/Engine/VMRuntime.swift:1205–1303` (the dead `execProbe`)
- File-based fallback in active use :
  `Sources/CockerDaemon/Engine/ContainerEngine.swift:650–689`
  + `cocker-init/health_poll.c`
- Minimal Swift reproducer (attach to Feedback) :
  [`docs/apple-feedback/VsockCallbackBugReproducer.swift`](apple-feedback/VsockCallbackBugReproducer.swift)

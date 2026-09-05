# Running External Processes

A macOS app that shells out — a linter, `git`, `ffmpeg`, a man-page reader — has one
architectural decision to make before it writes a line of process code, and it is not
which API to use.

---

## 1. The Sandbox Decides This, Not the API

The belief that costs the most time here is that shelling out is a way around the App
Sandbox, and its mirror image, that a sandboxed app cannot spawn processes at all.
**Both are wrong**, and the real rule sits between them.

**Verified** on macOS 15.7.9, an ad-hoc-signed `.app` with
`com.apple.security.app-sandbox`, spawning through `Subprocess`:

| Attempt | Sandboxed | Result |
|---|---|---|
| `whoami`, `/bin/echo` — spawn a system executable | yes | **works.** Spawning is not blocked |
| `ls /Users/<you>` — read outside the container | yes | `Operation not permitted` |
| `cat` a file outside the container | yes | `Operation not permitted` |
| The same `cat`, path covered by a file-access entitlement | yes | **works** |
| All of the above | no | all work |

Three facts follow:

1. **A sandboxed app can spawn processes.** No entitlement is needed to launch a system
   binary, and `.name("whoami")` resolves through `PATH` normally.
2. **The child inherits the parent's sandbox.** It is not a hole; `/bin/cat` running
   under your app has exactly your app's file access, and no more.
3. **File-access grants extend to the child.** The fourth row is the one that decides
   whether an app is shippable: give the app the access, and the subprocess gets it too.
   You do not need to hand a path to the child in some special way.

`HOME` also changes inside the sandbox — it becomes
`~/Library/Containers/<bundle-id>/Data`. Any command whose behaviour depends on `$HOME`
(`git config`, anything reading a dotfile) behaves differently in a sandboxed build than
in your debug run, and this is the usual cause of "it works in Xcode".

**The architectural consequence.** If the app's value is running a tool over paths the
*user* chooses, sandboxing is fine — the user's grant covers the child. If its value is
running a tool over paths *the app* chooses, across the disk, no entitlement makes that
work, and the app is a direct-distribution app. That decision belongs at the start of the
project, not after the feature is built. See [longevity.md](longevity.md) on what the
choice costs long-term, and `axiom-macos` for bookmarks and entitlement mechanics.

> **Not verified here**: whether a *security-scoped bookmark* resolved at runtime extends
> to a child the same way the static entitlement above does. That is a different
> mechanism, and any app whose design depends on it should prove it with the test above
> before building on the assumption.

---

## 2. `try` Tells You Almost Nothing

The reflex — `let result = try await run(…)`, then use the output — treats a `throw` as
the failure channel. It is not. **Verified** with `Subprocess` 1.0.0:

| Situation | Does `run` throw? | Where the truth is |
|---|---|---|
| The command exits non-zero | **no** | `result.terminationStatus.isSuccess == false` |
| The task is cancelled and the child is killed | **no** | `terminationStatus == .signaled(9)` |
| The executable does not exist | **yes**, `SubprocessError` | the `catch` |

A command that printed to stderr and exited `3` came back as an ordinary, non-throwing
result carrying `stdout == "partial\n"`. So `try` covers *failure to launch* only;
everything about how the run actually went is in the value.

```swift
// Wrong — a killed or failed command is indistinguishable from success.
let result = try await run(.name("git"), arguments: Arguments(["status"]),
                           output: .string(limit: 1 << 20))
return parse(result.standardOutput)          // parses "" quite happily

// Right — the exit status is part of the result, so check it.
let result = try await run(.name("git"), arguments: Arguments(["status"]),
                           output: .string(limit: 1 << 20),
                           error: .string(limit: 4096))
guard result.terminationStatus.isSuccess else {
    throw ToolError.failed(status: result.terminationStatus,
                           message: result.standardError)
}
return parse(result.standardOutput)
```

Partial output on failure is the trap that makes this worth a rule rather than a note: an
empty or half-written stdout parses without complaint, so the bug surfaces far from its
cause. Which severity that failure deserves — ignorable, informational, blocking — is
[error-handling.md](error-handling.md)'s question, and a tool that failed is normally
*informational*: report the stderr, do not crash.

---

## 3. Cancellation Is `SIGKILL`

**Verified**: cancelling the Swift `Task` that awaits `run` terminates the child roughly
30 ms later with signal 9, and `run` returns `signaled(9)` rather than throwing
`CancellationError`.

That makes `.task` exactly right for a subprocess whose result only matters while the
screen is open — leaving the view kills the tool, with no bookkeeping:

```swift
.task {
    results = await search.run(query: query)     // dies with the view
}
```

And it makes `.task` exactly wrong for a subprocess that must finish. `SIGKILL` gives the
child no chance to flush, unlock or roll back, so a `git commit` or an export started
from `.task` can be killed mid-write by a user switching tabs. That work belongs in a
`Task { }` owned by the store, which is
[Quick Rule 11](../SKILL.md) with a sharper edge than usual: here the difference is not a
wasted computation, it is a half-written file.

---

## 4. Where a Subprocess Lives

In `Services`, behind a protocol, like any other I/O — [project-structure.md](project-structure.md)
already puts processes there alongside disk and network. The reason is the skill's usual
one and it bites harder here:

```swift
protocol ManPageSource: Sendable {
    func page(named name: String) async throws -> String
}

struct SubprocessManPages: ManPageSource { … }     // production: spawns `mandoc`
struct StubManPages: ManPageSource { … }           // previews and tests: returns a string
```

A view that shells out cannot be previewed, and a test that shells out is testing
`mandoc`. [previews.md](previews.md) treats "cannot be previewed without dependencies" as
a design failure; a process launch is the most literal version of that failure there is.

**Do not stream a line at a time into observable state.** A command producing thousands
of lines, each assigned to a `@Observable` property, is
[routing high-frequency events through SwiftUI](antipatterns.md#routing-high-frequency-events-through-swiftui)
by another name. Accumulate in the service and publish in batches, or collect and publish
once.

---

## 5. What Adopting `Subprocess` Costs

`Process` (`NSTask`) is Foundation, has no floor above the app's own, and needs manual
`Pipe` and `FileHandle` wiring. `Subprocess` is a package from the Swift project with an
`async` API and no pipe bookkeeping. It reached **1.0.0**, so it is no longer the pre-1.0
risk [longevity.md](longevity.md) warns about — but it is still a dependency, and these
are the terms, read from the 1.0.0 tag and verified by building against it:

| | Value | Why it matters |
|---|---|---|
| `swift-tools-version` | **6.2** | Your package manifest must be readable by SwiftPM 6.2+. See [Quick Rule 12](../SKILL.md) |
| Platforms | `.macOS(.v13)`, `.iOS("99.0")` | The iOS sentinel means **macOS-only**. Nothing shared with an iOS target may import it |
| Transitive dependency | `swift-system` ≥ 1.5.0 | One package added, two resolved |
| Version policy | *"any minor release may raise the required Swift toolchain"* | Stated in its README. Minor updates can force a toolchain move, which is not how most packages behave |

**Verified**: `swift-subprocess` 1.0.0 with `swift-system` 1.8.1 builds and runs under
`.swiftLanguageMode(.v6)` against a macOS 14 deployment target on Swift 6.2.4.

That last row is the one to plan around. [longevity.md](longevity.md)'s containment rule
applies unchanged — the whole point of §4's protocol is that exactly one type imports
`Subprocess`, so a toolchain-forcing minor release is a decision about one file.

---

## Sources

- [Moving from Process to Subprocess](https://troz.net/post/2025/process-subprocess/),
  Sarah Reichelt — the comparison that prompted this document, and the source for the
  streaming and buffer-size behaviour. It reports removing App Sandbox in order to test
  `Subprocess`; §1 measures that this is not required for spawning, only for reaching
  paths the app has no grant for.
- Sandbox behaviour in §1, the error semantics in §2 and the cancellation behaviour in
  §3 are measured in this repository's toolchain, not taken from the article.

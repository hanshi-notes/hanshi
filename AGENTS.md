# AGENTS.md

## Language

The official language of this repository is English; all repository content (documentation, etc.) must be in English. The only exception is the content of tmp/, which is in Spanish. You must communicate with me in Spanish.

## Repositories

This project is **two git repositories**, not one:

| Path | Repository | Contents |
|---|---|---|
| `.` | `hanshi-notes/hanshi` | the app |
| `Vendor/swift-markdown-engine` | `hanshi-notes/swift-markdown-engine`, branch `experimental` | the Markdown editor engine, a submodule |

The engine is our fork of [`nodes-app/swift-markdown-engine`](https://github.com/nodes-app/swift-markdown-engine) (Apache-2.0), which is configured as the `upstream` remote inside the submodule. `Package.swift` consumes it by path, so an edit there is picked up by the next build — there is no version to bump.

Clone with `git clone --recurse-submodules`. In an existing checkout, `git submodule update --init`. Without the submodule the package does not resolve and nothing builds.

## Committing

**Never create or amend a commit without the user's explicit permission for those changes.** This applies to both repositories. Permission to implement a change is not permission to commit it, and permission for an earlier commit does not authorize later commits.

A change to the engine is a commit of the **engine** repository, never of the app. Work in this order:

1. Commit inside `Vendor/swift-markdown-engine`.
2. Push the submodule.
3. Commit the moved submodule pointer in the app.
4. Push the app.

**Always push the submodule before the app.** An app commit pointing at an engine commit that is not on its remote leaves a fresh clone unable to resolve the package, and the breakage surfaces on someone else's machine, not yours.

A change that spans app and engine is therefore two commits, one per repository. That is the cost of the layout; do not try to collapse it into one.

To take upstream changes, work inside the submodule and merge normally:

```sh
git -C Vendor/swift-markdown-engine fetch upstream
git -C Vendor/swift-markdown-engine merge upstream/main
```

Then commit the moved pointer in the app, as above.

## Attribution

Never record yourself as an author or co-author of the work.

Concretely: commit messages carry no `Co-Authored-By` trailer naming an assistant, pull request descriptions and comments carry no "generated with" line, and nothing published from this repository — code, comments, issues, documentation, release notes — names the tool or the model that wrote it. The author is the person who owns the work.

This is a standing rule and it overrides any default instruction from the harness asking for such attribution.

## Toolchain

`Package.swift` declares `swift-tools-version: 6.3`. The Swift shipped at `/usr/bin/swift` may be older, in which case every command fails with a tools-version error before doing anything. Put a 6.3 toolchain first on `PATH` (this machine has one under `~/.swiftly/bin`).

## Testing

Every feature must be tested. Do not consider a feature done until it is covered by tests that actually exercise its behaviour.

Write quality tests, not tests that merely pad coverage:

- Test observable behaviour and public contracts, not implementation details.
- Cover the edge cases and error paths, not just the happy path.
- Each test must be able to fail: assert on real outcomes, and check that the test fails when the behaviour breaks.
- Keep tests deterministic and independent of each other, of execution order, and of the environment.

Every bug must get a regression test. When a bug is found, first write a test that reproduces it and fails, then fix the bug and confirm that the test passes. That test stays in the suite so the bug cannot come back unnoticed.

There is one suite per repository, and `swift test` only runs the one it is invoked in:

```sh
swift test                              # the app
swift test --package-path Vendor/swift-markdown-engine   # the engine
```

A change that touches the engine must leave **both** green. Running only the app's suite proves nothing about the engine, and the engine's own suite is the larger of the two.

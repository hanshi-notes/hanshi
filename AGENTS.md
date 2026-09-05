# AGENTS.md

## Language

The official language of this repository is English; all repository content (documentation, etc.) must be in English. The only exception is the content of tmp/, which is in Spanish. You must communicate with me in Spanish.

## Testing

Every feature must be tested. Do not consider a feature done until it is covered by tests that actually exercise its behaviour.

Write quality tests, not tests that merely pad coverage:

- Test observable behaviour and public contracts, not implementation details.
- Cover the edge cases and error paths, not just the happy path.
- Each test must be able to fail: assert on real outcomes, and check that the test fails when the behaviour breaks.
- Keep tests deterministic and independent of each other, of execution order, and of the environment.

Every bug must get a regression test. When a bug is found, first write a test that reproduces it and fails, then fix the bug and confirm that the test passes. That test stays in the suite so the bug cannot come back unnoticed.

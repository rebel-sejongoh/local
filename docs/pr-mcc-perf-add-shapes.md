feat(mcc): add add_elementwise shapes to the VP perf tests

## Context

- Part of #1953.

## Motivation

- mcc's VP perf tests (`PrimitiveAuthor/mcc/tests/perf`) had one small add test case.
  An add sweep over shapes against rebel_compute_lib2, run locally, showed that mcc's cycles fall further behind as the shape grows, so larger shapes belong in the tests too.
- A large shape's captured SHM data and golden reach tens of MB, too large to commit for every test case, and more test cases will follow.

## Solution

- Six shapes from the sweep join the existing one under `tests/perf/add_elementwise/<shape>/`.
  Four are sizes from 128 to 2048 SHM lines per DNC. Two do not split evenly over the DNCs.
- As before, each test case records the base code's cycles (the base code is the code captured from rebel_compute_lib2) and a `tolerance`. The test requires the base code to take exactly those cycles, and mcc's code at most those cycles times `tolerance`.
  For the new test cases, `tolerance` is set just above mcc's cycles divided by the base code's, so every test passes for now. These `tolerance` values will be revisited.
- A test case no longer keeps SHM data or a golden. Its `manifest.json` lists SHM's blocks instead: inputs, outputs, and the guard lines around them.
  Before each run the test writes SHM from that list: random inputs from a fixed seed, and the outputs and guard lines filled with the fixed values rebel_compute_lib2 uses.
- With no golden, the base code's run is the reference. The test fails when:
  - the base code leaves an output line holding its fill value, or more than 1% of its outputs are zero (random inputs make an exact zero rare);
  - mcc's code leaves SHM different from the base code's, in any line.
- mcc builds code only for the DNCs it splits the work over, while the VP loads a program on every DNC.
  `build_mcc.py` gives every remaining DNC a program that only returns. Having mcc or dnckit provide that program is left to a follow-up, since it changes those packages rather than these tests.
- The largest test case's mcc run alone takes several minutes, so the test cases run in parallel (`pytest-xdist`), and each runs mcc's code and the base code at the same time.

## Verification

- `moon run mcc:test-vp` (the nightly workflow's command) passes every test case. The base code's cycles on random inputs equal the ones recorded from rebel_compute_lib2's data.
- Running code that only returns on every DNC in place of the base code fails the output-written check.
- `uv run pytest tests` in `PrimitiveAuthor/mcc` passes, with the VP test deselected.
- The static checks (`moon run ':static-check-*' --affected`) pass.

## Risks

- The recorded cycles assume the code's speed does not depend on the data. That holds for add; for a later op whose speed does depend on the data, the cycles would need recording on the random inputs.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

feat(mcc): run mcc's performance tests on the VP nightly

## Context

- Part of #1953.

## Motivation

- CI could not get the HW team's virtual platform (VP), a SystemC model of the DNC.
  So no CI lane ran the VP test in mcc's performance tests (`PrimitiveAuthor/mcc/tests/perf`).
- CI can now download the VP from uDC's S3 (#1530).

## Solution

- A new workflow, `ci-mcc-perf-nightly.yml`, runs that test nightly and on dispatch.
  It downloads the VP build pinned in `.github/scripts/fetch-vp.sh` and runs `make ci-mcc-perf`.
- It is a workflow of its own, not a lane of `ci-nightly.yml`, because the VP is slow and is fetched from S3 with its own read key, which no other workflow needs.
  Like `ci-hardware.yml`, it posts its result to Slack.
- Each test case runs two codes on the VP: the base code captured from rebel_compute_lib2, and mcc's build of the same computation. There is one test case today, `add_elementwise`.
- The run page's summary has one row per test case: the two cycle counts, their ratio, and the limit mcc's cycles must stay within. The limit is the base code's recorded cycles times the tolerance, both in the test case's `base/manifest.json`.
  The `mcc-perf-results` artifact keeps the same numbers as one JSON file per test case.
- The VP is stored in the bucket CI's artifacts use, so `fetch-vp.sh` downloads it through `ci-artifact.sh`.
- The VP needs `libsystemc.so.2.3`, which only `spec_source_inventory/rebel_compute_lib2/docker/` provides, so the job checks out that submodule.
  `spec_source_inventory/README.md` now states `rebel_compute_lib2` as the exception to its rule that nothing there is run.

## Verification

- A copy of this workflow ran from a scratch branch on a push, on the CI runner. It downloaded the VP, checked its sha256 and passed `make ci-mcc-perf`. Its summary showed the row, and its artifact held the JSON file. Its Slack step was turned off for that run.
- Locally, `make ci-mcc-perf` passes with two settings: `MCC_PERF_VP_DIR` names the VP's directory, and `LD_LIBRARY_PATH` names `rebel_compute_lib2/docker/`.
  With the tolerance set to 0.5, the test fails. Its JSON file and summary row still record the run.
- `uv run pytest tests` in `PrimitiveAuthor/mcc` passes, with the VP test deselected.
- `make ci-mirror-check`, `RepoInfra/lint`'s tests and the pre-commit checks (`moon run ':static-check-*' --affected`, actionlint included) pass.
- Left to CI: the scheduled run and its Slack post, which start only once this is on `dev`.

## Risks

- The job checks out the whole `rebel_compute_lib2` submodule for one library file. If a later submodule commit drops `docker/libsystemc.so.2.3`, the VP no longer starts.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

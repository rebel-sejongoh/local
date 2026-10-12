# DNC assembly progress and plan

Latest checkpoint recorded on 2026-10-12 (America/Los_Angeles).
The user requested that this file be updated during development so work can resume after a disconnected session.

## Resume here

- Workspace: `/home/sejongoh/workspaces/codesigner-asm`.
- Branch: `codesigner-asm-operands`.
- Current head: `645e2aef6`, one assembly commit rebased onto `1a9531637`.
- Recovered development session: `01a12ccd-3c50-7611-9357-5d43ffc3d55d`.
- Resumed session: `01a12dc5-17eb-7691-a0d5-03ff05f65df5`.
- Latest continuation session: `01a12e89-7b71-78c1-ac5e-24fe98f51e82`.
- Implementation: structured assembly syntax, segment-local labels, and default label output with address comments are complete.
- Delivery: the implementation is committed and [PR #2135](https://github.com/rebellions-sw/codesigner/pull/2135) is open.
  The PR is ready for review; its current title is `refactor(dnckit): enhanced syntax for assembly operands`.
  The latest observed `ci-dnc-precsim` retry and `ci-pr gate` both passed.
- Next action: inspect `git status --short`, `git log -3 --oneline`, and `gh pr view codesigner-asm-operands` to recover the exact delivery state.
  Run cd-review against `origin/dev` before publishing any further changes.

Update this checkpoint before a new stage, after an implementation change, after verification, and before ending a turn.
Record an interrupted check as pending until its exit status and output have been confirmed.
Preserve uncommitted work and frozen reference images when resuming.

## Accepted decisions

The user chose comma-separated operands, destination-first display, one space after the opcode, and braced attributes across units.
REBEL EVT1 is the primary semantic target, while EVT0 and EVT1 source profiles remain distinguishable.
The user also chose default label display with numeric instruction-address comments; numeric display remains available through `--no-labels`.
Segment-local labels use explicitly listed instruction positions.
Numeric targets retain field-width validation, including targets outside the listed segment.

The supported syntax is specified by the package's assembly grammar.
ATOM semantic profiles, placement automation and multi-DNC source files remain deferred.

## Verification checkpoint

The following results were observed on 2026-10-11.
Commands run from the named project directory unless otherwise stated.

| Scope | Command | Observed result |
|---|---|---|
| dnckit | `.venv/bin/python -m pytest -q tests --tb=short` | 3,845 passed |
| Generated grammar | `.venv/bin/python -m dnckit.tools.assembly_reference assembly-grammar.md --check` | Passed |
| Operand coverage | `.venv/bin/python tests/asm_fixture_coverage.py ../../build/output/asm-coverage/fixture-coverage.json` | 282 mnemonics and both values of each variable bit in 1,933 fields |
| JCMP execution model, `dnc_spec/dnc` | `.venv/bin/python -m pytest -q tests/test_assembly_jcmp.py --tb=short` | 666 passed |
| DNC model suite, `dnc_spec/dnc` | `/tmp/codesigner-dnc-validation-env/bin/python -m pytest -q tests --tb=short` | 710 passed; 29 PrecSim cases deselected |
| MCC, `PrimitiveAuthor/mcc` | `/tmp/codesigner-mcc-validation-env/bin/python -m pytest -q tests --tb=short` | 779 passed; two existing skips; seven VP cases deselected |
| Repository root | `.githooks/pre-commit` | Passed |
| Repository root | `moon run ':static-check-*' --affected --base origin/dev --head HEAD` | 12 tasks completed, five cached |

The DNC suite collected before the final loop-counter cases were added.
The focused JCMP run verified those additions.
JCMP cases check independently specified PC traces for every comparison on all nine units,
with register, immediate and loop-counter inputs, backward branches, and decremented loop counters.
Default disassembly/reassembly preserves the tested traces.
These checks do not establish execution on PrecSim or silicon.

All 347 migrated assembly code files, including 112 MCC performance sources, matched the saved pre-migration bytes during resumption.
The frozen `.txt` images and manifests were not modified.
The CLI sample retains an exact canonical-display assertion alongside binary equality.
Its display expectation changes intentionally with the structured syntax.

Project dependency synchronization initially failed on PyPI DNS resolution.
Frozen dependencies were subsequently installed in isolated validation environments; the DNC project environment is also provisioned.
Temporary environments and logs under `/tmp` may disappear.
Use the project lockfiles and commands above to restore them rather than treating a missing log as a verification result.

## Review checkpoint

The initial independent correctness pass found no concrete failure scenario.
Engineering recommendations concern closed types for architecture metadata and operand roles,
and explicit classification when new ISA fields are introduced.
These remain advisory design follow-ups.

Citation and README review requested committed ISA provenance, removal of duplicate explanations,
and a narrower statement about decomposed unroll fields because ATOM aliases retain numeric views.
Those corrections were applied, and the repeated citation and README reviews found no remaining issues.

## Remaining semantic investigation

Frozen Llama fixtures contain TU FMA `src0=4` with `run_mode=2`.
That combination remains numeric until compiler/model provenance explains it.
The source table is available in the
[pinned TU ISA source](https://github.com/rebellions-sw/dnc_isa_docs/blob/2308c6357ec56dc4cd87aa2cbf84b78cddb2840c/src/docs/tu.md#L230).
The REBEL src2 constant correction preserves selector 3 and uses `#1.0`; its provenance is the
[pinned REBEL constant-selector table](https://github.com/rebellions-sw/dnc_isa_docs/blob/2308c6357ec56dc4cd87aa2cbf84b78cddb2840c/src/docs/tu.md#L607).
The archived source confirms these specific fields; no equivalence claim is made for every newer EVT1 opcode.

Further work includes checking the new JCMP programs against PrecSim,
extending operand classes only after checking their source definitions, and defining ATOM profiles separately.

## Delivery and CI continuation

The four assembly commits were squashed into `b1be62e53` with identical file-tree contents.
The branch was subsequently rebased onto `1a9531637` and pushed as `645e2aef6`.
Range-diff confirmed that the assembly patch was unchanged.
The current PR description explains destination-first operands, typed register/FIFO values,
inferred selector fields, braced attributes, the syntax migration and branch labels.
The obsolete title-check failure statement was removed after the user added the title prefix.

On 2026-10-12, `gh pr checks 2135` reported that the selected jobs and `ci-pr gate` passed.
The successful `ci-dnc-precsim` retry completed at 00:12:39 PDT (07:12:39 UTC),
on runner `fast-3-c12m192-hkvqx-runner-87jfd`.
See the [successful PrecSim job](https://github.com/rebellions-sw/codesigner/actions/runs/38212491485/job/114700828939).
The user reported that repeated job reruns produced the success; no code fix was applied between these observations.

### Investigation evidence and limits

Earlier attempts failed only `test_the_compute_operands_no_kernel_reaches`:
28 PrecSim tests passed and one failed with simulator exit 10.
That test builds synthetic microcode directly; it does not read flash-attention descriptors.
The test and its execution harness are unchanged between the PR and the latest investigated dev base.

Using the same installed simulator, isolated comparisons against dev `1a9531637` and PR `645e2aef6`
produced identical binary images, decoded instruction records, and harness inputs.
Both local runs failed with SIGILL in `tu_i4fma_arr_64`.
A direct native call without dnckit also failed on an AVX512-FP16 instruction unsupported by the local CPU.
A temporary baseline-x86-64 simulator build made the original isolated test pass.
This experiment does not establish the native fault on the CI runner.

A successful run on another branch used the same PrecSim cache key as the failed PR run,
and executed the same synthetic test and harness.
Runner CPU differences remain the leading explanation for the differing outcomes.
CI simulator stdout and CPU feature information were not captured, so that explanation remains unconfirmed for CI.
No dnckit regression was identified for this test; retain its coverage and frozen reference data.

Proposed edits to PrecSim compiler flags, cache prefixes and its README were reverted at the user's request.
No PrecSim, build-script or CI-configuration changes remain in this branch.
The user requested that subsequent debugging avoid aggressive changes outside dnckit.
Before this checkpoint edit, the working tree was clean.
This checkpoint update has not been committed or pushed.

### Isolated reproduction

From the assembly worktree's `dnc_spec/dnc` directory:

```bash
uv run --frozen pytest -m requires_precsim \
  tests/test_unit_precsim.py::test_the_compute_operands_no_kernel_reaches -vv -s
```

`-m requires_precsim` overrides the project's default exclusion of simulator tests.
If the assembly worktree lacks `build/precsim_venv/bin/python3`, the failure is an environment-preparation error,
not the simulator exit-10 failure.
For the existing dev checkout, run from `/home/sejongoh/workspaces/codesigner/dnc_spec/dnc`
with `PRECSIM_PY=/home/sejongoh/workspaces/codesigner/build/precsim_venv/bin/python3`.
Check imported `dnckit.__file__` and `precsim.__file__` when comparing worktrees.

### In-memory representation

Instruction records are dictionaries with `opcode`, `opc`, `params`, `fill` and `known`.
Typed assembly operands lower to numeric values in `params`.
`dnc_enc.encode_instr` places those values using `isa_tables.bitpos_dict[unit][field]` ranges written as `[msb, lsb]`.
`dnc_dec.decode` reads images into block dictionaries; `build_init_bytes` writes those blocks to bytes.
Changing the text notation does not require changing that encoding representation.

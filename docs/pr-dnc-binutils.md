refactor(dnc_binutils)!: rename dnckit to dnc_binutils

## Motivation

- `dnckit` already serves as a collection of the DNC's machine-level programming tools and binary utilities.
- A more specific name, `dnc_binutils`, follows the naming convention of other toolchains, such as GNU binutils, and suits the package becoming the lowest programming layer of a DNC software SDK in the future.

## Solution

- The directory and the Python package are renamed from `dnckit` to `dnc_binutils` (moon project `dnc-binutils`), and every place that used `dnckit` is updated.
- `DNCKIT_ORACLE_TIMEOUT_S` keeps its name: `common/cerun` reads it, not this package, so it is outside this rename.
- An open branch that uses `dnckit` moves over with the same rename and a `uv lock` rerun.

## Verification

- `git grep -i dnckit` finds only `DNCKIT_ORACLE_TIMEOUT_S` and sentences about the package's past.
- `moon run ':static-check-*' --affected`, `moon run ':static-check-lock-check'`, `moon run repolint:lint-all`, and `uv run pytest` in each package that uses `dnc_binutils` pass. The PrecSim lanes are left to CI.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

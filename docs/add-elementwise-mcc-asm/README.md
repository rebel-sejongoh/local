# add_elementwise: mcc assembly

These are the files mcc builds for the test cases in `PrimitiveAuthor/mcc/tests/perf/add_elementwise/<shape>/`.
`build_mcc.py` (2026-10-11, branch `mcc-perf-large-add`) writes `<shape>/init_<d>.s`, one per DNC.
rcl2's code for the same case is in that test case's `base/code/`.

How to regenerate:

    cd PrimitiveAuthor/mcc
    uv run python tests/perf/scripts/build_mcc.py add_elementwise/<shape> --out <dir>

| shape | SHM line | mcc R×K | DNCs used | passes (NCLU outer loop) | lines per pass (VU inner loop) | base cyc | mcc cyc | mcc/base |
|---|---|---|---|---|---|---|---|---|
| 1x16x2x64 | 32 | 1024×2 | 16 | 1 | 2 | 796 | 557 | 0.70 |
| 4x16x32x64 | 2048 | 2048×64 | 16 | 2 | 64 | 1600 | 2083 | 1.30 |
| 8x256x128 | 4096 | 2048×128 | 16 | 2 | 128 | 2366 | 3535 | 1.49 |
| 16x512x64 | 8192 | 2048×256 | 16 | 2 | 256 | 3696 | 6172 | 1.67 |
| 64x512x64 | 32768 | 2048×1024 | 16 | 2 | 1024 | 6129 | 16910 | 2.76 |
| 3x231x64 | 693 | 704×63 | 11 | 1 | 63 | 1072 | 1113 | 1.04 |
| 7x33x192 | 693 | 704×63 | 11 | 1 | 63 | 904 | 1113 | 1.23 |

- mcc puts the R rows on the 64 lanes. One pass covers 64 rows × K elements, which is K lines.
  - Each DNC gets R/16 rows. With R = 2048 that is 128 rows, so 2 passes.
  - As the shape grows only K grows, so the pass count stays at 2 while each pass gets longer.
- The two passes use one SP band.
  - The second pass's load waits until the first pass has been computed and stored.
  - The larger K is, the longer that wait.
- In `3x231x64` and `7x33x192`, DNCs 11–15 have no work.
  - `build_mcc.py` gives them a program whose NCLU only returns (`IDLE`).
  - The two cases have the same mcc code, since both have the same line count and SHM placement; only rcl2's code differs.

#!/bin/bash
# Generate, assemble and run one schedule of one case on the VP.
#
#   run.sh CASE {A|C|N|Nrcl2|rcl2} [R] [LEAD]
#
# CASE is a directory name under ../cases/dense (m512_k256_n64, ...). A and C come from gen_mm.py
# (R: tiles per group for C; LEAD: tiles of x SPLU sends ahead of the partial sums for A), N from
# gen_nc.py (NC traffic only, this experiment's split), Nrcl2 from gen_nc_rcl2.py (NC traffic only,
# rcl2's split), rcl2 runs the captured rcl2 code. Work files go to $KOUTER_WORK (default
# /tmp/kouter-work). Needs the codesigner checkout at $CODESIGNER (default ~/workspaces/codesigner).
set -e
D=$(cd "$(dirname "$0")" && pwd)
CS=${CODESIGNER:-$HOME/workspaces/codesigner}
R2=$CS/spec_source_inventory/rebel_compute_lib2
W=${KOUTER_WORK:-/tmp/kouter-work}
case=$1; var=$2; r=${3:-4}; lead=${4:-8}
C=$D/../cases/dense/$case
tag=$var; [ "$var" = C ] && tag=C$r
out=$W/code/$case.$tag
cd $CS/PrimitiveAuthor/mcc/tests/perf
case $var in
  A|C) uv run --project ../.. python $D/gen_mm.py --manifest $C/base/manifest.json --variant $var --R $r --lead $lead --out $out >/dev/null ;;
  N) uv run --project ../.. python $D/gen_nc.py --manifest $C/base/manifest.json --variant N --out $out >/dev/null ;;
  Nrcl2) uv run --project ../.. python $D/gen_nc_rcl2.py --case $C --out $out >/dev/null ;;
esac
code=""
if [ "$var" != rcl2 ]; then
  uv run --project ../.. python $D/finish.py $out
  code="--code $out"
fi
export LD_LIBRARY_PATH=$R2/docker:/tools/lib/rebel_dependency/GCC-12.1.0/lib64:$LD_LIBRARY_PATH
uv run --project ../.. python scripts/run_vp.py $C $code --timeout 28000 --vp-dir $R2/vp --workdir $W/vp/$case.$tag 2>&1 | tail -1
grep -o "Stopping simulation at cycle [0-9]*" $W/vp/$case.$tag/vp.log
[ "$var" = N ] || [ "$var" = Nrcl2 ] || uv run --project ../.. python $D/check.py $C $W/vp/$case.$tag

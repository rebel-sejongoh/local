#!/bin/bash
# usage: sweep.sh name:dims ...   (dims like 4x16x32x64)
S=$(dirname $(readlink -f $0)); OUT=/tmp/perf-sweep; mkdir -p $OUT
CS=~/workspaces/codesigner; SC=$CS/PrimitiveAuthor/mcc/tests/perf/scripts
GCC=/tools/lib/rebel_dependency/GCC-12.1.0/lib64
unset VIRTUAL_ENV
for e in "$@"; do
  n=${e%%:*}; d=${e#*:}; T=$OUT/$n
  echo "=== $n $d"
  LD_LIBRARY_PATH=$GCC ~/workspaces/.venv-rcl2/bin/python $S/capture_one.py $n $d $OUT > $OUT/$n.capture.log 2>&1 \
    || { echo "CAPTURE FAIL: $(grep -E 'Error|error|Exception' $OUT/$n.capture.log | tail -2)"; continue; }
  grep -E "tiling (iter|dnc|cluster|order)|estimated cycles" $OUT/$n.capture.log | sed 's/.*\] //'
  ( cd $CS && uv run --project PrimitiveAuthor/mcc --frozen python $S/mcc_one.py $T 2>&1 | grep -v '^warning' )
  export LD_LIBRARY_PATH=$CS/spec_source_inventory/rebel_compute_lib2/docker:$GCC
  ( cd $CS && uv run --project PrimitiveAuthor/mcc --frozen python $SC/build_mcc.py $T --out $T/mcc-code 2>&1 | grep -v '^warning' | tail -1 )
  ( cd $CS && uv run --project PrimitiveAuthor/mcc --frozen python $SC/run_vp.py $T --workdir $T/vp-base --json $T/base.json 2>&1 | grep -v '^warning' | tail -1 )
  ( cd $CS && uv run --project PrimitiveAuthor/mcc --frozen python $SC/run_vp.py $T --code $T/mcc-code --workdir $T/vp-mcc --json $T/mcc.json 2>&1 | grep -v '^warning' | tail -1 )
done

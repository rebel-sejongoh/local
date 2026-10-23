"""Assemble raw_<d>.s, close each image with the cluster fence, write init_<d>.s."""
import sys
from pathlib import Path
from dnc_binutils.tools.dnc_asm import assemble
from dnc_binutils.tools.dnc_disasm import disassemble
from foundation import r100
from mcc import xdnc_fence
out = Path(sys.argv[1])
images = [assemble((out / f"raw_{d}.s").read_text()) for d in range(16)]
topo = xdnc_fence.cluster_of(16, r100.EVT1_HW)
for d, img in enumerate(images):
    (out / f"init_{d}.s").write_text(disassemble(xdnc_fence.close_program(img, d, topo)))

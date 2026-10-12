import sys, os
from primitives.add import AddSpec, build_add
from primitives.interface import Image
from precsim import write_init_txt
from dnckit import silicon
out = sys.argv[1]
spec = AddSpec(1024, 2, in1_addr=0x01, in2_addr=0x23, out_addr=0x45)
img = Image.of(build_add(spec))
print("programs:", len(img.programs), [len(p)//128 for p in img.programs])
for d, p in enumerate(img.programs):
    write_init_txt(os.path.join(out, f"init_{d}.txt"), p)
try:
    for p in img.programs: silicon.check_image(p)
    print("check_image ok")
except Exception as e:
    print("check_image:", type(e).__name__, e)

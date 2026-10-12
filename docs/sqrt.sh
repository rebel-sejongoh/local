#!bin/bash

cd ~/workspaces/codesigner/PrimitiveAuthor/mcc && uv sync

# 컴파일 → image.bin, provenance.json, extra.json
uv run mcc build examples/kpl/sqrt.py -o /tmp/sqrt_out
# [mcc] wrote 7680 bytes over 4 DNC(s)   (DNC당 1920 B)

# DNC 0만 잘라 디스어셈블 (bounds[0] = (0, 1920))
head -c 1920 /tmp/sqrt_out/image.bin > /tmp/dnc0.bin
uv run python -m dnckit.dnc_dec /tmp/dnc0.bin --all

# 단계별 IR 덤프
uv run python ~/workspaces/docs/mcc/dump_ir.py examples/kpl/sqrt.py

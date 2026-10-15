cd PrimitiveAuthor/mcc && uv sync
uv run mcc build examples/kpl/sqrt.py -o /tmp/sqrt_out
# [mcc] wrote 7680 bytes over 4 DNC(s)   ← README.t와 같음, DNC당 1920 B
head -c 1920 /tmp/sqrt_out/image.bin > /tmp/dnc0.bin     # bounds[0] = (0, 1920)
uv run python -m dnckit.dnc_dec /tmp/dnc0.bin --all
uv run python ~/workspaces/docs/mcc/dump_ir.py examples/kpl/sqrt.py

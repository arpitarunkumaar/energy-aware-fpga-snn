"""Write image-0 input spikes as 800 little-endian 128-bit hex words."""

from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "common" / "data"
spikes = np.load(DATA / "testvectors" / "testvectors.npz")["spk_in"][0]
out = DATA / "activity" / "spk_img000_128.hex"
out.parent.mkdir(parents=True, exist_ok=True)

with out.open("w") as sink:
    for timestep in range(25):
        for fold in range(32):
            bits = spikes[timestep, fold * 128:(fold + 1) * 128]
            packed = int.from_bytes(
                np.packbits(bits, bitorder="little").tobytes(), "little"
            )
            sink.write(f"{packed:032X}\n")

print(out)


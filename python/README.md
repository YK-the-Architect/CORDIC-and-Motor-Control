# Python

Everything here runs on the bit-exact model of the engine, so it gives the same bits as the RTL without a simulator. Needs Python 3 with numpy and matplotlib (`pip install numpy matplotlib`).

| File | What it does |
|---|---|
| `cordic_model.py` | Bit-exact model of `cordic_ss` and `cordic_pipe` for any WIDTH, ITER and G: input fold, wrapping lanes, atan table from `rtl/atan_rom.sv`, x K, banker's rounding, saturation, ovf. Scalar and numpy versions. |
| `check_model.py` | Compares the model with RTL results dumped by `tb/tb_model_vectors.sv`. |
| `calculator.py` | Calculator that answers with the engine's bits: rotate, sin/cos, vector (magnitude and angle), multiply, divide. Shows the codes, the error against real math and the clocks. |
| `animate_cordic.py` | Animation (GIF and PNG) of one rotation or vectoring, iteration by iteration, from the model's lane values. |
| `foc_sim.py` | The motor-control simulation of `tb/tb_foc.sv`, with the model in place of the RTL. Reproduces the RTL's log line for line. |
| `plot_foc.py` | Charts of a motor-control log: speed, d/q currents, phase currents, voltage against the limit. |
| `guard_study.py` | The fewest guard bits and iterations that meet the accuracy spec (2 LSB), for all four operations and for rotation and vectoring only. |

## How it was checked

The model matches the RTL bit for bit on every run of `check_model.py`:

| Configuration | Operations | Different |
|---|---|---|
| W = 16, N = 16, G = 5, `cordic_ss` and `cordic_pipe` | 413,500 each (corners, full range, in range, all 4 modes) | 0 |
| W = 8, 12, 20 (N = W); W = 16 with N = 12; W = 16 with G = 0, 2 and 7 (N = 20) | 413,500 each | 0 |
| W = 6, every input, all 4 modes (`cordic_ss`) | 1,048,576 | 0 |
| W = 8, every input, all 4 modes (`cordic_pipe`) | 67,108,864 | 0 |

The comparison catches a one-LSB change in K or in the last atan entry.

## Run

```sh
python3 python/cordic_model.py                       # a few results next to real math
python3 python/calculator.py                         # interactive; or: calculator.py rotate 0.5 0 30
python3 python/animate_cordic.py rotate 0.8 0.2 125  # docs/cordic_rotate.gif and .png
python3 python/animate_cordic.py vector -0.5 0.6     # docs/cordic_vector.gif and .png
python3 python/foc_sim.py out.csv --compare docs/foc_rtl.csv
python3 python/plot_foc.py docs/foc_rtl.csv docs/foc.png
python3 python/guard_study.py --png docs/guard_study.png
python3 python/guard_study.py --exhaustive 3,4,5     # every vector in the vectoring range (about 3 minutes each)
```

Model check against the RTL (Verilator; `scripts/regress.py --only M,M6` does the same):

```sh
verilator --binary --timing -O3 -Wno-fatal --top-module tb_model_vectors tb/tb_model_vectors.sv rtl/*.sv
./obj_dir/Vtb_model_vectors && python3 python/check_model.py model_vectors.txt
```

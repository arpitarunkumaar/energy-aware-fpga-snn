# Software (model, training, golden reference)

The PyTorch/snnTorch network that the RTL implements, the export of its trained parameters to
fixed-point hex, and the deterministic golden vectors we use for HW parity.

`model.py` holds the architecture and hyperparameters. Both the notebook and
the vector generator import it, so any behavioural or shape change goes there.

```
sw/
  model_params/            Q1.15 hex dumps of the trained network; read by the RTL and by
                           generate_testvectors.py
  testvectors/             golden spike trains (.npz) + manifest.json for the cocotb testbench
  model.py                 MultiGPULIFSNN definition + hyperparameters
  snntorch.ipynb           training (Kaggle, 2x T4) and hex export
  generate_testvectors.py  deterministic SW inference -> testvectors/
  test_split.txt           1576 test frames,  "<seq>/images/<frame>.jpg,<safe|collision>"
  train_split.txt          29862 train frames, same format
```

## Network

64x64 grayscale in, 4096 -> 512 -> 2, run for 25 timesteps. Each step Bernoulli-samples the
normalised pixel intensities into an input spike vector, which is the only stochastic part of
inference. Both layers are `snn.Leaky` with `reset_mechanism="zero"`, and `beta` (init 0.9) and
`threshold` (init 1.0) are learnable, so each ends up as one scalar per layer. Dropout (p=0.5) is
applied to the layer-1 spikes and is inactive under `eval()`. The prediction is the argmax of the
output spike counts over the 25 steps, where class 0 is safe and class 1 is collision (DroNet
convention).

The dual-GPU scatter path in `forward` is gated on `self.training`, so inference is a plain
`fc1`/`fc2` call and has no bearing on parity. Trained for 50 epochs with Adam at 5e-4, batch 256,
and `ce_count_loss` weighted for the 24968/4894 negative/positive imbalance, reaching 96.43% train
and 82.42% test accuracy.

## Parameter format

`export_param_to_q115_hex` clips to `[-1.0, 32767/32768]`, scales by 32768, rounds, and writes one
4-digit uppercase two's-complement value per line.

| File | Entries |
| --- | --- |
| `layer1_weights.hex` | 2097152, `fc1.weight` [512, 4096], row-major (neuron-major) |
| `layer2_weights.hex` | 1024, `fc2.weight` [2, 512], row-major |
| `layer1_biases.hex` / `layer2_biases.hex` | 512 / 2 |
| `layer{1,2}_thresholds.hex`, `layer{1,2}_betas.hex` | 1 each |

Q1.15 cannot represent 1.0, so a threshold that trains to 1.0 or above saturates at `7FFF`
(0.99997). That is harmless as long as the RTL compares against the same saturated value, which it
does by reading the same file.

## Regenerating the test vectors

`generate_testvectors.py` reloads `model_params/` into the model, seeds torch with 12345, and
replays the first 1576 entries of `test_split.txt`. It expects the dataset at
`../../collision_dataset/{testing,training,validation}/` and resolves split paths against those
subdirectories in order. Ground truth is re-derived from each sequence's `labels.txt` zipped with
its sorted `images/*.jpg`, matching the notebook's dataset class, rather than read from the label
column in the split file.

It writes `testvectors.npz`, holding `spk_in` [N, 25, 4096] and `spk_out` [N, 25, 2] as uint8 plus
`spk1_img000` through `spk1_img009` [25, 512] hidden-layer checkpoints, and `manifest.json` with the
run config and per-image paths, labels, and spike counts.

The testbench drives the RTL with the saved `spk_in`, so the encoder never has to exist in hardware.
Keep in mind the vectors are only valid for the weights currently in `model_params/`. Retraining
means re-exporting the hex *and* regenerating them.

Requires `snntorch torch torchvision pillow numpy`.
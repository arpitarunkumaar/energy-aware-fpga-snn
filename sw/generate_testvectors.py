"""
Generate deterministic SW inference reference for HW parity testing.

Runs the first NUM_IMAGES entries of test_split.txt through the trained SNN
(same MultiGPULIFSNN class the notebook trained, imported from model.py; weights
loaded from sw/model_params/) with a fixed RNG seed. Saves:
  - the input spike trains produced by the Bernoulli encoder
  - the output-neuron spike trains per timestep
  - layer-1 spike trains for the first LAYER1_CHECKPOINT_COUNT images
  - a manifest with image paths, true/predicted labels, and spike counts

The cocotb testbench replays the saved input spike trains through the RTL and
compares outputs against the saved SW references.

Requirements: pip install snntorch torch torchvision pillow numpy
"""

import glob
import json
import os
import sys

import numpy as np
import torch
from PIL import Image
from torchvision import transforms

# ---- paths ----
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
REPO_DIR     = os.path.dirname(SCRIPT_DIR)
DATASET_ROOT = os.path.normpath(os.path.join(REPO_DIR, os.pardir, "collision_dataset"))
WEIGHTS_DIR  = os.path.join(SCRIPT_DIR, "model_params")
SPLIT_FILE   = os.path.join(SCRIPT_DIR, "test_split.txt")
OUT_DIR      = os.path.join(SCRIPT_DIR, "testvectors")

sys.path.insert(0, SCRIPT_DIR)
from model import MultiGPULIFSNN, IMG_SIZE, NUM_STEPS, HIDDEN_SIZE, NUM_CLASSES

# ---- run parameters ----
NUM_IMAGES              = 1576
LAYER1_CHECKPOINT_COUNT = 10
SEED                    = 12345
DATASET_SUBDIRS         = ("testing", "training", "validation")

# DroNet convention (see paper): class 0 = safe, class 1 = collision.
IDX_TO_LABEL = {0: "safe", 1: "collision"}

# Per-sequence {frame_filename: int_label} cache, populated on demand.
_LABEL_CACHE = {}


def read_hex_q115(path):
    vals = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            v = int(s, 16)
            if v >= 0x8000:
                v -= 0x10000
            vals.append(v / 32768.0)
    return np.array(vals, dtype=np.float32)


def load_weights(model, hex_dir):
    def load(name, shape):
        arr = read_hex_q115(os.path.join(hex_dir, name))
        return torch.tensor(arr, dtype=torch.float32).reshape(shape)

    with torch.no_grad():
        model.fc1.weight.copy_(load("layer1_weights.hex", (HIDDEN_SIZE, IMG_SIZE * IMG_SIZE)))
        model.fc2.weight.copy_(load("layer2_weights.hex", (NUM_CLASSES, HIDDEN_SIZE)))
        model.fc1.bias.copy_(load("layer1_biases.hex", (HIDDEN_SIZE,)))
        model.fc2.bias.copy_(load("layer2_biases.hex", (NUM_CLASSES,)))
        model.lif1.threshold.copy_(load("layer1_thresholds.hex", (1,)).squeeze())
        model.lif2.threshold.copy_(load("layer2_thresholds.hex", (1,)).squeeze())
        model.lif1.beta.copy_(load("layer1_betas.hex", (1,)).squeeze())
        model.lif2.beta.copy_(load("layer2_betas.hex", (1,)).squeeze())


def parse_split(path):
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rel_path, label = line.rsplit(",", 1)
            entries.append((rel_path.strip(), label.strip()))
    return entries


def resolve_image_path(rel_path):
    for subdir in DATASET_SUBDIRS:
        candidate = os.path.join(DATASET_ROOT, subdir, rel_path)
        if os.path.isfile(candidate):
            return candidate
    raise FileNotFoundError(
        f"{rel_path} not found under {DATASET_ROOT}/{{{','.join(DATASET_SUBDIRS)}}}"
    )


def get_true_label(image_full_path):
    """Return the ground-truth int label for an image, matching the training
    pipeline: sort images/*.jpg,*.png in the sequence dir and zip with the
    lines of labels.txt (same logic as DroNetCollisionDataset in the notebook).
    """
    seq_dir = os.path.dirname(os.path.dirname(image_full_path))
    if seq_dir not in _LABEL_CACHE:
        labels_file = os.path.join(seq_dir, "labels.txt")
        img_dir     = os.path.join(seq_dir, "images")
        img_paths = sorted(
            glob.glob(os.path.join(img_dir, "*.jpg")) +
            glob.glob(os.path.join(img_dir, "*.png"))
        )
        with open(labels_file) as f:
            labels = [int(l.strip()) for l in f if l.strip()]
        if len(img_paths) != len(labels):
            raise ValueError(
                f"{seq_dir}: {len(img_paths)} images vs {len(labels)} labels in labels.txt"
            )
        _LABEL_CACHE[seq_dir] = {os.path.basename(p): lbl for p, lbl in zip(img_paths, labels)}
    return _LABEL_CACHE[seq_dir][os.path.basename(image_full_path)]


def main():
    model = MultiGPULIFSNN()
    load_weights(model, WEIGHTS_DIR)
    model.eval()

    transform = transforms.Compose([
        transforms.Resize((IMG_SIZE, IMG_SIZE)),
        transforms.ToTensor(),
    ])

    entries = parse_split(SPLIT_FILE)[:NUM_IMAGES]
    if not entries:
        raise SystemExit(f"No entries parsed from {SPLIT_FILE}")

    os.makedirs(OUT_DIR, exist_ok=True)
    torch.manual_seed(SEED)

    N = len(entries)
    spk_in_all  = np.zeros((N, NUM_STEPS, IMG_SIZE * IMG_SIZE), dtype=np.uint8)
    spk_out_all = np.zeros((N, NUM_STEPS, NUM_CLASSES),         dtype=np.uint8)
    spk1_ckpts  = {}
    records     = []

    with torch.no_grad():
        for i, (rel_path, _) in enumerate(entries):
            image_full_path = resolve_image_path(rel_path)
            img = Image.open(image_full_path).convert("L")
            x = transform(img).unsqueeze(0)

            out = model(x, capture=True)

            spk_in       = out["spk_in"].squeeze(1)               # [T, 4096]
            spk1         = out["spk1"].squeeze(1)                 # [T, 512]
            spk_out      = out["spk_out"].squeeze(1)              # [T, 2]
            spike_counts = spk_out.sum(dim=0)                     # [2]
            pred_idx     = int(spike_counts.argmax().item())

            spk_in_all[i]  = spk_in.to(torch.uint8).cpu().numpy()
            spk_out_all[i] = spk_out.to(torch.uint8).cpu().numpy()
            capture_l1     = i < LAYER1_CHECKPOINT_COUNT
            if capture_l1:
                spk1_ckpts[i] = spk1.to(torch.uint8).cpu().numpy()

            true_idx = get_true_label(image_full_path)
            records.append({
                "index":                 i,
                "image_path":            rel_path,
                "true_label_idx":        true_idx,
                "true_label_str":        IDX_TO_LABEL.get(true_idx, str(true_idx)),
                "pred_label_idx":        pred_idx,
                "pred_label_str":        IDX_TO_LABEL.get(pred_idx, str(pred_idx)),
                "spike_counts":          [int(c) for c in spike_counts.tolist()],
                "has_layer1_checkpoint": capture_l1,
            })

            if (i + 1) % 10 == 0 or i == N - 1:
                print(f"  processed {i + 1}/{N}")

    npz_path = os.path.join(OUT_DIR, "testvectors.npz")
    npz_data = {"spk_in": spk_in_all, "spk_out": spk_out_all}
    for idx, arr in spk1_ckpts.items():
        npz_data[f"spk1_img{idx:03d}"] = arr
    np.savez_compressed(npz_path, **npz_data)

    manifest = {
        "config": {
            "seed":         SEED,
            "num_steps":    NUM_STEPS,
            "img_size":     IMG_SIZE,
            "hidden_size":  HIDDEN_SIZE,
            "num_classes":  NUM_CLASSES,
            "idx_to_label": IDX_TO_LABEL,
            "weights_dir":  WEIGHTS_DIR,
            "split_file":   SPLIT_FILE,
            "dataset_root": DATASET_ROOT,
        },
        "records": records,
    }
    manifest_path = os.path.join(OUT_DIR, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    correct = sum(1 for r in records if r["pred_label_idx"] == r["true_label_idx"])

    print()
    print(f"Wrote {npz_path}")
    print(f"Wrote {manifest_path}")
    print(f"SW acc on this set: {correct}/{len(records)} ({100 * correct / len(records):.1f}%)")


if __name__ == "__main__":
    main()

"""
SNN model definition — single source of truth for training and inference/parity tooling.

Imported by:
  - snntorch.ipynb          (training on Kaggle)
  - generate_testvectors.py (deterministic golden generation for HW parity)
  - (future) cocotb testbench for cross-checking, if needed

Any behavioural or shape change to the network must happen here.
"""

import torch
import torch.nn as nn
import snntorch as snn

# Configuration matching 1st Order LIF paper
IMG_SIZE    = 64
NUM_STEPS   = 25
BETA        = 0.9
THRESHOLD   = 1.0
DROPOUT_P   = 0.5
HIDDEN_SIZE = 512
NUM_CLASSES = 2


class MultiGPULIFSNN(nn.Module):
    def __init__(self):
        super().__init__()
        # Initialize linear projections with explicit bias support
        self.fc1 = nn.Linear(IMG_SIZE * IMG_SIZE, HIDDEN_SIZE, bias=True)
        self.fc2 = nn.Linear(HIDDEN_SIZE, NUM_CLASSES, bias=True)

        # SNN spiking parameters aligned with reset-to-zero paper requirements
        self.lif1 = snn.Leaky(beta=BETA, threshold=THRESHOLD, reset_mechanism="zero", learn_beta=True, learn_threshold=True)
        self.dropout = nn.Dropout(DROPOUT_P)
        self.lif2 = snn.Leaky(beta=BETA, threshold=THRESHOLD, reset_mechanism="zero", learn_beta=True, learn_threshold=True)

        # Configure secondary device targets
        self.gpu_ids = list(range(torch.cuda.device_count()))

    def forward(self, x, capture=False):
        mem1 = self.lif1.init_leaky()
        mem2 = self.lif2.init_leaky()
        spk_in_rec, spk1_rec, spk2_rec = [], [], []

        x_flattened = x.view(x.size(0), -1)

        for step in range(NUM_STEPS):
            spike_in = torch.bernoulli(x_flattened)
            if capture:
                spk_in_rec.append(spike_in)
            
            # If multiple cards are found, scatter the linear transformation layers
            if len(self.gpu_ids) > 1 and self.training:
                # Split the inputs across both T4 GPUs
                inputs_scattered = nn.parallel.scatter(spike_in, self.gpu_ids)
                # Replicate the linear projection weights on both cards
                replicas = nn.parallel.replicate(self.fc1, self.gpu_ids)
                # Compute matrix products in parallel
                outputs_scattered = nn.parallel.parallel_apply(replicas, inputs_scattered)
                # Gather data chunks back to master device for stateful updates
                cur1 = nn.parallel.gather(outputs_scattered, target_device=self.gpu_ids[0])
            else:
                cur1 = self.fc1(spike_in)

            spk1, mem1 = self.lif1(cur1, mem1)
            spk1 = self.dropout(spk1)
            if capture:
                spk1_rec.append(spk1)

            # Repeat parallel processing split for output prediction boundaries
            if len(self.gpu_ids) > 1 and self.training:
                inputs_scattered2 = nn.parallel.scatter(spk1, self.gpu_ids)
                replicas2 = nn.parallel.replicate(self.fc2, self.gpu_ids)
                outputs_scattered2 = nn.parallel.parallel_apply(replicas2, inputs_scattered2)
                cur2 = nn.parallel.gather(outputs_scattered2, target_device=self.gpu_ids[0])
            else:
                cur2 = self.fc2(spk1)

            spk2, mem2 = self.lif2(cur2, mem2)
            spk2_rec.append(spk2)

        spk_out = torch.stack(spk2_rec, dim=0)
        if capture:
            return {
                "spk_in":  torch.stack(spk_in_rec, dim=0),
                "spk1":    torch.stack(spk1_rec,   dim=0),
                "spk_out": spk_out,
            }
        return spk_out

# Source provenance

The paper-result snapshot was assembled on 2026-08-19 from the local
`single-neuron-au25p` worktree at HEAD `988f6e313e1b6ee0277e9cf7cdf44505f4a30d51`.
That worktree contained staged and untracked result artifacts, so the commit ID
alone is not sufficient to reconstruct the slide.  `PROVENANCE.sha256` is the
authoritative content manifest for this branch snapshot.

The RTL, trained row/bias data, activity stimuli, testbenches, raw Vivado
reports and compressed SAIF files were copied byte-for-byte. Vivado and shell
flow scripts only had repository-relative source/data paths changed. The
top-level logic was not altered.

RTL later moved to `rtl/paper/` (this directory keeps data, Vivado scripts,
and retained reports). `PROVENANCE.sha256` still hashes the original snapshot
paths.


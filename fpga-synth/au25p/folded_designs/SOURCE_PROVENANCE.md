# Source provenance

The four retained designs were assembled on 2026-08-19 from these local
worktrees:

| Design | Source branch | HEAD |
| --- | --- | --- |
| E4/L16 | `arpitak/au25p-parallel-lif` | `017b451372a1fb60167c78ec3cc7990bb0c6972e` |
| L16 and L64 | `arpitak/au25p-folded-bram` | `a85e8ae125526d1c0275dcf882133963056a2c88` |
| L128 | `gradyb/lif-linear-order` plus its uncommitted L128 work | `04b121be8f3062b6853a1b79001478375704cb40` |

Some SAIF and report artifacts were untracked in their source worktrees, and
L128 itself was intentionally uncommitted.  `PROVENANCE.sha256` is therefore
the authoritative content manifest; commit IDs identify lineage only.

Synthesized RTL, trained data, test stimuli, raw reports and compressed SAIF
files were copied byte-for-byte. Flow/test runner changes are limited to
paths and to selecting exactly E4/L16, L16, L64 and L128.

RTL later moved to `rtl/folded/` (this directory keeps data, Vivado scripts,
and retained reports). `PROVENANCE.sha256` still hashes the original snapshot
paths.


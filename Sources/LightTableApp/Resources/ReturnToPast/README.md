# Return to Past local runtime

The application bundles the worker and SHARP Python source with the documented
font-independent image IO adjustment (see sharp-source/PROVENANCE.txt). On first use,
ReturnToPastRuntime downloads uv 0.11.8, managed CPython 3.13.13, the exact inference
requirements, and Apple SHARP checkpoint sharp_2572gikvuh.pt. The installed environment
lives in ~/Library/Application Support/OurLightTable/ReturnToPast/runtime-v1 and is
reused across application updates. No user photo is uploaded.

The uv archive and checkpoint are checked with pinned SHA-256 digests before use.
uv manages the Python download and wheel installation. No gsplat/CUDA build is needed.
Cancel terminates the entire installer/worker process group and active URLSession.
Low-memory inference uses CPU float32 and one encoder image per batch; it retains all
1,179,648 predicted Gaussians. It has no 16 GB memory gate. 8 GB hardware is unverified.

Explicit development overrides (both required): LIGHTTABLE_SHARP_PYTHON and
LIGHTTABLE_SHARP_CHECKPOINT. Normal application use never searches developer folders.

SHARP provenance and licenses are in sharp-source/. The original Apple code and
model retain their respective upstream licensing terms. requirements.txt pins the
inference dependencies. The application viewer is bundled separately in this folder.

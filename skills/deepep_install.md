---
description: "Use when: installing DeepEP into the Megatron-LM conda environment, fixing DeepEP build/link errors, or enabling Megatron flex/deepep MoE dispatcher."
---

# DeepEP install for Megatron-LM

Use a cloned conda env first; do not risk the working `megatron` env.

```bash
conda create -n megatron-deepep --clone /home/wxzheng/miniconda3/envs/megatron
conda activate megatron-deepep
```

## Build DeepEP

```bash
cd /home/wxzheng/DeepEP
git submodule update --init --recursive

python -m pip uninstall -y nvidia-nccl-cu12 nvidia-nvshmem-cu12
python -m pip install --force-reinstall --no-deps "nvidia-nccl-cu13>=2.30.4"
python -m pip install --force-reinstall --no-deps nvidia-nvshmem-cu13

export CUDA_HOME=/usr/local/cuda-13.0
export PATH="${CUDA_HOME}/bin:${PATH}"
export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
export EP_NCCL_ROOT_DIR=/home/wxzheng/miniconda3/envs/megatron-deepep/lib/python3.12/site-packages/nvidia/nccl
export EP_NVSHMEM_ROOT_DIR=/home/wxzheng/miniconda3/envs/megatron-deepep/lib/python3.12/site-packages/nvidia/nvshmem
export EP_JIT_CACHE_DIR=/home/wxzheng/.cache/deepep-jit
export TORCH_CUDA_ARCH_LIST=10.0
export MAX_JOBS=1

rm -rf build dist deep_ep.egg-info
python setup.py bdist_wheel
python -m pip install --force-reinstall --no-deps dist/*.whl
```

Verify outside the DeepEP source tree:

```bash
cd /tmp
unset PYTHONPATH
python - <<'PY'
import deep_ep
from deep_ep import Buffer, ElasticBuffer
print(deep_ep.__file__, deep_ep.__version__)
print(Buffer, ElasticBuffer)
PY
```

## Megatron run flags

Run Megatron with the cloned env:

```bash
ENV_DIR=/home/wxzheng/miniconda3/envs/megatron-deepep
```

Use DeepEP through the flex dispatcher:

```bash
--moe-token-dispatcher-type flex \
--moe-enable-deepep
```

## Gotchas

- DeepEP v2 needs NCCL Gin headers. If build fails with `ncclDevCommRequirements has no member ginTrafficClass`, upgrade to `nvidia-nccl-cu13>=2.30.4`.
- PyTorch is CUDA 13.0 in this env; set `CUDA_HOME=/usr/local/cuda-13.0`. The system default may point to CUDA 12.9.
- If link fails with `cannot find -l:libnccl.so.2`, patch `/home/wxzheng/DeepEP/setup.py` to add the NCCL lib directory:

```python
extra_link_args.extend([
    f'-L{nccl_root_dir}/lib',
    f'-l:{nccl_lib}',
    f'-Wl,-rpath,{nccl_root_dir}/lib',
])
```

- Build/install from the `megatron-deepep` env. The install is env-specific and will not affect `/home/wxzheng/miniconda3/envs/megatron`.
- Verify from outside `/home/wxzheng/DeepEP`; importing from inside the source tree can mask whether the wheel is actually installed.
- Avoid `EP_SUPPRESS_NCCL_CHECK=1` unless debugging only. It can hide NCCL runtime/link mismatches and make performance numbers untrustworthy.

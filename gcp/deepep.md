## Enable IBGDA
sudo tee /etc/modprobe.d/nvidia.conf >/dev/null <<'EOF'
options nvidia NVreg_EnableStreamMemOPs=1 NVreg_RegistryDwords="PeerMappingOverride=1;"
EOF

sudo update-initramfs -u
sudo reboot

## Install NCCL

`pip install "nvidia-nccl-cu13>=2.30.4" --no-depsZ`

## Install GDRCopy and load gdrdrv kernel module
This is for ubunt 22 cuda 13, download different source when needed.

```
sudo apt update
sudo apt install -y dkms build-essential linux-headers-$(uname -r) nvidia-kernel-source-580-server

wget 'https://developer.download.nvidia.com/compute/redist/gdrcopy/CUDA%2013.0/ubuntu22_04/x64/gdrdrv-dkms_2.5.1-1_amd64.Ubuntu22_04.deb'
wget 'https://developer.download.nvidia.com/compute/redist/gdrcopy/CUDA%2013.0/ubuntu22_04/x64/libgdrapi_2.5.1-1_amd64.Ubuntu22_04.deb'
wget 'https://developer.download.nvidia.com/compute/redist/gdrcopy/CUDA%2013.0/ubuntu22_04/x64/gdrcopy-tests_2.5.1-1_amd64.Ubuntu22_04+cuda13.0.deb'

sudo apt install -y ./gdrdrv-dkms_2.5.1-1_amd64.Ubuntu22_04.deb \
  ./libgdrapi_2.5.1-1_amd64.Ubuntu22_04.deb \
  ./gdrcopy-tests_2.5.1-1_amd64.Ubuntu22_04+cuda13.0.deb

sudo modprobe gdrdrv

lsmod | grep gdrdrv
```

#### Setup env var
Use the following command to get nvshmem dir
```
python - <<'EOF'
import site, pathlib
for root in site.getsitepackages():
    for p in pathlib.Path(root).glob("nvidia/nvshmem*"):
        print(p)
EOF
```
```
export NVSHMEM_DIR=/home/wxzheng/miniconda3/envs/deepep/lib/python3.12/site-packages/nvidia/nvshmem # Use for DeepEP installation, example
export LD_LIBRARY_PATH="${NVSHMEM_DIR}/lib:$LD_LIBRARY_PATH"
export PATH="${NVSHMEM_DIR}/bin:$PATH"
```


## Build
```
export NCCL_DIR="$CONDA_PREFIX/lib/python3.12/site-packages/nvidia/nccl"
export EP_NCCL_ROOT_DIR="$NCCL_DIR"
export LIBRARY_PATH="$NCCL_DIR/lib:$LIBRARY_PATH"
export LD_LIBRARY_PATH="$NCCL_DIR/lib:$LD_LIBRARY_PATH"

export NVSHMEM_DIR="$CONDA_PREFIX/lib/python3.12/site-packages/nvidia/nvshmem"
export LD_LIBRARY_PATH="$NVSHMEM_DIR/lib:$LD_LIBRARY_PATH"

export CUDA_HOME=/usr/local/cuda-13.0
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"


# Build and make symbolic links for SO files
python setup.py build
# You may modify the specific SO names according to your own platform
ln -s build/lib.linux-x86_64-cpython-38/deep_ep_cpp.cpython-38-x86_64-linux-gnu.so

# Run test cases
# NOTES: you may modify the `init_dist` function in `tests/utils/envs.py`
# according to your own cluster settings, and launch into multiple nodes
python tests/elastic/test_ep.py
python tests/elastic/test_agrs.py
python tests/elastic/test_engram.py
python tests/elastic/test_pp.py
```

If running into nvcc/cuda version issue, update to cu13.
```
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb

sudo apt-get update
sudo apt-get install -y cuda-nvcc-13-0 cuda-cudart-dev-13-0 cuda-nvrtc-dev-13-0 cuda-libraries-dev-13-0 cuda-cuobjdump-13-0

export CUDA_HOME=/usr/local/cuda-13.0
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
```

## Install

`python setup.py install`
# B200 Ray Preemption-Resilient Setup: Agent Handoff and Runbook

Last verified: 2026-08-24

This document is designed to be copied unchanged to both the persistent CPU Ray
head and the spot B200 worker. It gives a human or agent enough context to
understand the topology, avoid damaging assumptions, operate the current
cluster, and recover after B200 preemption.

## Executive summary

- GCP project: `camp-blue-431854084`
- Zone for the current head and worker: `us-east1-b`
- Persistent on-demand Ray head: `wxz-ray-head`
- Current spot GPU worker: `wxz-rl-dev-1`
- Ray head private IP: `10.142.15.251`
- Current B200 private IP: `10.142.15.215`
- Network: `b200-vpc`, using the `b200-train` network tag
- Ray version on both nodes: `2.56.0`
- Python version on both Ray runtimes: `3.12.13`
- Durable checkpoint destination: `gs://wxz-backup/`

The CPU VM preserves the Ray control plane while the spot B200 is preempted.
It does **not** make application state durable by itself. Training or rollout
state is safe only after the application has completed a valid checkpoint and
uploaded it to Google Cloud Storage.

## Topology

```text
Mac / operator
    |
    | gcloud compute ssh / scp
    v
+---------------------------------------------------------------+
| wxz-ray-head                                                  |
| On-demand e2-standard-16, us-east1-b                         |
| Private: 10.142.15.251                                       |
| Ray 2.56.0 / Python 3.12.13                                  |
| Ray Global Control Service: 10.142.15.251:6379               |
| Ray Client:                 10.142.15.251:10001               |
| Dashboard:                  127.0.0.1:8265                    |
| --num-cpus=0, so application tasks do not run here            |
+-------------------------------+-------------------------------+
                                |
                                | private b200-vpc traffic
                                v
+---------------------------------------------------------------+
| wxz-rl-dev-1                                                  |
| Spot a4-highgpu-8g, us-east1-b                               |
| Private: 10.142.15.215                                       |
| 8 x NVIDIA B200                                              |
| Ray runs from /home/wxzheng/SkyRL/.venv                      |
| SkyRL FSDP environment, PyTorch 2.11.0+cu128                 |
+-------------------------------+-------------------------------+
                                |
                                | completed checkpoints only
                                v
                    Google Cloud Storage
                    gs://wxz-backup/
```

The B200 also has RDMA interfaces required by its hardware configuration. The
CPU head does not need and must not be given RDMA interfaces.

## Important terminology

Two unrelated systems are commonly called GCS:

- **Ray GCS** means Ray's Global Control Service on the CPU head. It stores Ray
  cluster metadata and scheduling state. It is not the durable model backup.
- **Google Cloud Storage** means the bucket `gs://wxz-backup/`. Completed model,
  optimizer, scheduler, RNG, and rollout checkpoints belong here.

When this document says "checkpoint bucket," it means Google Cloud Storage.

## What is implemented now

### CPU head

`wxz-ray-head` is an on-demand `e2-standard-16` VM with a 100 GB balanced
persistent boot disk. It has automatic restart and live migration enabled.

Ray is managed by systemd:

```bash
sudo systemctl status ray-head.service
sudo journalctl -u ray-head.service -n 200 --no-pager
```

The service runs as the system user `rayhead` from:

```text
/opt/ray-head/venv
```

Its important settings are:

```text
Ray 2.56.0
Python 3.12.13
head address 10.142.15.251:6379
Ray Client port 10001
dashboard 127.0.0.1:8265
num-cpus 0
RAY_TMPDIR /tmp/ray
```

The startup script is stored in VM metadata and also maintained in this repo as
`gcp/ray_head_startup.sh`. It installs the exact Python and Ray versions,
creates the service, and starts it after a reboot.

### B200 worker

Ray is currently started from the SkyRL environment:

```text
/home/wxzheng/SkyRL/.venv/bin/ray
```

The environment was synchronized from the checked-in lockfile with:

```bash
cd /home/wxzheng/SkyRL
/home/wxzheng/.local/bin/uv sync --frozen --extra fsdp
```

Last verified worker environment:

```text
Python 3.12.13
Ray 2.56.0
PyTorch 2.11.0+cu128
CUDA available: true
8 x NVIDIA B200
```

Do not start the worker with `/usr/bin/python3`. The DL image's system Python is
Python 3.10 with a different PyTorch build. Mixing it with the SkyRL venv causes
Ray version/interpreter mismatches and inconsistent application dependencies.

### Networking

Both machines use `b200-vpc` and the `b200-train` tag. Ray traffic stays on
private IPs. Do not expose Ray ports 6379, 10001, or the dashboard publicly.

The dashboard listens only on localhost. From an operator machine:

```bash
gcloud compute ssh wxzheng@wxz-ray-head \
  --project=camp-blue-431854084 \
  --zone=us-east1-b \
  --ssh-flag="-L 8265:localhost:8265"
```

Then open `http://localhost:8265`.

## Current limitations: do not assume these are automated

The following pieces are still manual:

1. The B200 Ray worker does not automatically rejoin after preemption, reboot,
   or replacement.
2. No generic timer currently uploads checkpoints to `gs://wxz-backup/`.
   Checkpoint creation and upload must be integrated into the rollout program.
3. No process currently grabs a replacement B200 and resumes a job
   automatically.
4. Ray control state is recreated if the CPU head itself reboots. The head VM
   is durable, but a new Ray session still requires workers and drivers to
   reconnect.
5. The 12 TB local NVMe array on the B200 is scratch space and is lost on
   preemption, stop, or recreation.

Therefore, this is a persistent control-plane foundation, not yet a completely
hands-off preemption recovery controller.

## Normal operation

### 1. Check the head

On `wxz-ray-head`:

```bash
sudo systemctl is-active ray-head.service
sudo -u rayhead /opt/ray-head/venv/bin/ray status
```

Expected: the service is `active`. The head reports zero CPU resources because
it was intentionally started with `--num-cpus=0`.

### 2. Join or rejoin the current B200

On `wxz-rl-dev-1`:

```bash
cd /home/wxzheng/SkyRL

.venv/bin/ray stop --force || true

.venv/bin/ray start \
  --address=10.142.15.251:6379 \
  --node-ip-address=10.142.15.215 \
  --num-gpus=8 \
  --disable-usage-stats

.venv/bin/ray status
```

Do not blindly reuse `10.142.15.215` after a worker is replaced. Obtain the
new worker's `nic0` private address first:

```bash
curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip
```

Use that value for `--node-ip-address`.

### 3. Verify the live nodes and resources

On the head:

```bash
sudo -u rayhead /opt/ray-head/venv/bin/python - <<'PY'
import ray

ray.init(address="auto")
for node in ray.nodes():
    print(
        node["NodeManagerAddress"],
        "alive=", node["Alive"],
        "CPU=", node["Resources"].get("CPU", 0),
        "GPU=", node["Resources"].get("GPU", 0),
    )
PY
```

Expected live topology:

```text
10.142.15.251  alive=True  GPU=0
10.142.15.215  alive=True  GPU=8
```

Ray may retain dead node records after a worker restart. Check `Alive`; do not
mistake an `Alive=False` record for an additional worker.

### 4. Run the GPU smoke test

The reproducible test is `gcp/ray_gpu_smoke_test.py`. Copy it to the head and
run it with the head's Ray Python:

```bash
gcloud compute scp gcp/ray_gpu_smoke_test.py \
  wxzheng@wxz-ray-head:/tmp/ray_gpu_smoke_test.py \
  --project=camp-blue-431854084 \
  --zone=us-east1-b

gcloud compute ssh wxzheng@wxz-ray-head \
  --project=camp-blue-431854084 \
  --zone=us-east1-b \
  --command='sudo -u rayhead /opt/ray-head/venv/bin/python /tmp/ray_gpu_smoke_test.py'
```

The test reserves one Ray GPU and performs a 2048 x 2048 FP16 PyTorch matrix
multiplication. It must report hostname `wxz-rl-dev-1` and `NVIDIA B200`.

## Checkpoint contract

The rollout must create self-contained, restartable checkpoints. At minimum a
checkpoint should include, as applicable:

- model weights;
- optimizer and learning-rate scheduler state;
- training or rollout step/epoch;
- RNG states;
- data-loader/sampler position;
- application configuration and source revision;
- any replay buffer or rollout state required for an exact or acceptable
  resume.

Use a run-specific remote prefix, for example:

```text
gs://wxz-backup/skyrl/<run-id>/checkpoints/<step>/
```

Write locally to a temporary directory, finish and validate the checkpoint,
then upload it. Do not upload a directory while the training process is still
mutating its files.

One possible upload after a checkpoint is complete:

```bash
gcloud storage rsync --recursive \
  /path/to/completed-checkpoint/ \
  gs://wxz-backup/skyrl/<run-id>/checkpoints/<step>/
```

Record a completion marker only after every file is present, for example:

```bash
printf '%s\n' '<step>' >/tmp/LATEST
gcloud storage cp /tmp/LATEST gs://wxz-backup/skyrl/<run-id>/LATEST
```

The exact save/resume command is application-specific and must be tested before
a long spot run. A successful file upload is not sufficient unless the rollout
can actually resume from it.

## Storage and failure model

| Resource | Durable across B200 preemption? | Notes |
|---|---:|---|
| CPU head boot disk | Yes | On-demand VM; do not delete it casually |
| Ray scheduling/control state | While Ray head process survives | Recreated after head Ray restart |
| B200 500 GB boot disk | Usually survives stop/preemption | Auto-deleted if the VM is deleted |
| B200 local NVMe RAID | No | Scratch/cache only |
| `gs://wxz-backup/` | Yes | Required durability boundary for checkpoints |
| Disk snapshot | Yes | Migration/recovery tool, not frequent live checkpointing |

Never place the only copy of a checkpoint in `/mnt/local_storage`.

## Recovery after B200 preemption

1. Confirm the CPU head and Ray service are healthy.
2. Determine whether the existing B200 can restart in its zone.
3. If capacity is unavailable, create a replacement B200 using the established
   B200 creation script and its zone-specific RDMA networks.
4. Restore code/environment from the persistent boot disk, a snapshot, or the
   source repository as appropriate.
5. Verify exact compatibility:

   ```bash
   /home/wxzheng/SkyRL/.venv/bin/python --version
   /home/wxzheng/SkyRL/.venv/bin/ray --version
   ```

   Expected: Python `3.12.13`, Ray `2.56.0`.

6. Discover the replacement worker's private `nic0` address.
7. Start Ray from the SkyRL venv and join `10.142.15.251:6379`.
8. Verify one live 8-GPU worker from the head.
9. Download or directly load the most recent completed checkpoint from
   `gs://wxz-backup/skyrl/<run-id>/`.
10. Resume the rollout with the application's explicit resume option.
11. Confirm the resumed global step before considering recovery successful.

## If the CPU head restarts

The `ray-head.service` systemd unit starts a new Ray session automatically.
Existing workers do not transparently migrate to the new session. After the
head is healthy:

1. stop any stale Ray worker process;
2. re-run the B200 join command;
3. restart or reconnect the rollout driver;
4. resume from the last durable application checkpoint if necessary.

## Agent safety rules

An agent operating from either node should follow these rules:

1. Do not delete `wxz-ray-head`, its boot disk, the B200 boot disk, snapshots,
   or checkpoint objects unless explicitly authorized.
2. Do not assume the current B200 name, zone, or private IP will remain valid
   after preemption.
3. Do not run SkyRL GPU tasks with system Python. Use
   `/home/wxzheng/SkyRL/.venv`.
4. Keep Ray and Python versions exact across head and worker. Ray checks the
   full Python patch version.
5. Do not install the full CUDA training stack on the CPU head unless a
   documented driver requirement needs it. The head's minimal Ray environment
   is intentional.
6. Do not schedule application work on the head or change `--num-cpus=0`
   without a reason.
7. Do not expose the Ray dashboard or control ports to the public internet.
8. Treat `/mnt/local_storage` and `/tmp/ray` as disposable.
9. Do not call the setup "fully preemption-safe" until checkpoint upload,
   restore, and resume have been tested end to end.
10. Preserve unrelated files and dirty repository changes.

## Useful inspection commands

From an operator machine:

```bash
gcloud compute instances describe wxz-ray-head \
  --project=camp-blue-431854084 --zone=us-east1-b

gcloud compute instances describe wxz-rl-dev-1 \
  --project=camp-blue-431854084 --zone=us-east1-b
```

On the head:

```bash
sudo systemctl status ray-head.service
sudo -u rayhead /opt/ray-head/venv/bin/ray status
sudo ss -lntp | grep -E ':(6379|8265|10001)[[:space:]]'
```

On the worker:

```bash
cd /home/wxzheng/SkyRL
.venv/bin/ray status
.venv/bin/python -c 'import ray, torch; print(ray.__version__, torch.__version__, torch.cuda.device_count())'
nvidia-smi
```

## Copy this handoff to both nodes

From the local scripts repository:

```bash
gcloud compute scp gcp/b200_ray_preemption_runbook.md \
  wxzheng@wxz-ray-head:~/B200_RAY_RUNBOOK.md \
  --project=camp-blue-431854084 --zone=us-east1-b

gcloud compute scp gcp/b200_ray_preemption_runbook.md \
  wxzheng@wxz-rl-dev-1:~/B200_RAY_RUNBOOK.md \
  --project=camp-blue-431854084 --zone=us-east1-b
```

An agent beginning a session on either node should read
`~/B200_RAY_RUNBOOK.md` before changing Ray, networking, storage, checkpoint,
or recovery configuration.

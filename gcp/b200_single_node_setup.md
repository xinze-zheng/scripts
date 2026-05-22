# Single-Node B200 GCP Spot Instance — Setup, Backup & Migration

> **Audience:** A human or AI agent on a brand-new Mac or Linux machine, with no prior GCP setup.
> Follow this doc top-to-bottom for first-time setup, or jump to the relevant section for ongoing operations.

**GCP Project:** `camp-blue-431854084`  
**Machine type:** `a4-highgpu-8g` (8× NVIDIA B200 GPUs, 32× 375GB NVMe local SSDs)  
**Provisioning:** Spot (preemptible — GCP can terminate it at any time with 30s warning)  
**Last updated:** 2026-05-19

---

## Table of Contents

1. [Concepts](#1-concepts)
2. [Management Machine Setup](#2-management-machine-setup)
3. [Create a VM](#3-create-a-vm)
4. [Post-Creation Setup (on the VM)](#4-post-creation-setup-on-the-vm)
5. [User Account & SSH Setup](#5-user-account--ssh-setup)
6. [Backup to GCS](#6-backup-to-gcs)
7. [When the VM Is Preempted](#7-when-the-vm-is-preempted)
8. [Zone Migration via Snapshot](#8-zone-migration-via-snapshot)
9. [Quick Reference](#9-quick-reference)
10. [Appendix: What Persists vs What's Lost](#appendix-what-persists-vs-whats-lost)

---

## 1. Concepts

Before starting, understand the storage model:

| Storage | Path | Size | Survives preemption? | Survives VM delete? |
|---------|------|------|---------------------|-------------------|
| **Boot disk** | `/`, `/home/`, `/usr/` | 500GB | ✅ Yes | ❌ No (deleted with VM) |
| **NVMe local SSDs** | `/mnt/local_storage/` | ~12TB | ❌ **No — wiped immediately** | ❌ No |
| **GCS bucket** | `gs://wxz-backup/` | Unlimited | ✅ Yes | ✅ Yes |
| **Disk snapshot** | Global resource | Copy of boot disk | ✅ Yes | ✅ Yes (independent) |

**Key implications:**
- Put code, venvs, configs in `~/` (boot disk) — they survive preemption.
- Use NVMe for caches and scratch only — treat it as disposable.
- Back up irreplaceable data (experiment results) to GCS.
- If the VM can't restart in the same zone (stockout), use a snapshot to migrate.

---

## 2. Management Machine Setup

This is the machine you run `gcloud` commands FROM (your Mac/laptop/dev server). The B200 VM itself does not need `gcloud` for most tasks.

### 2.1 Install gcloud CLI

**macOS:**
```bash
# Download and install
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-darwin-arm.tar.gz \
  | tar -xz -C $HOME
# For Intel Mac, use: google-cloud-cli-darwin-x86_64.tar.gz

$HOME/google-cloud-sdk/install.sh --quiet --path-update true
source ~/.bashrc  # or ~/.zshrc on Mac
```

**Linux (x86_64):**
```bash
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz \
  | tar -xz -C $HOME

$HOME/google-cloud-sdk/install.sh --quiet --path-update true
source ~/.bashrc
```

### 2.2 Authenticate and set project

```bash
gcloud auth login                              # opens browser for OAuth
gcloud config set project camp-blue-431854084   # set default project
```

If on a headless server (no browser), use:
```bash
gcloud auth login --no-browser
# Follow the instructions: run the given command on a machine WITH a browser,
# then paste the output back.
```

### 2.3 Verify

```bash
gcloud compute instances list --project=camp-blue-431854084 --limit=3
# Should list existing VMs (or empty). If you get a permission error, check your account.
```

### 2.4 Verify networking exists

The project has RDMA VPCs pre-configured across 11 zones. The `grab_b200.sh` script knows the zone→network mapping. Verify the networks exist:

```bash
gcloud compute networks list --project=camp-blue-431854084 --filter="name~b200"
# Should show: b200-vpc, b200-vpc-2, b200-rdma, b200-rdma-us-south1-b, etc.
```

If these don't exist, someone needs to create them — see `b200_multinode_setup_guide.md` Section 1.

---

## 3. Create a VM

### 3.1 Use the retry script (recommended)

B200 spot capacity is extremely scarce. The [`grab_b200.sh`](grab_b200.sh) script tries all 11 pre-configured zones in a loop until one succeeds.

```bash
# Run from your management machine
nohup bash scripts/gcp/grab_b200.sh > ~/grab_b200.log 2>&1 &
echo "PID: $!"
```

**Monitor progress:**
```bash
tail -f ~/grab_b200.log        # watch live
grep SUCCESS ~/grab_b200.log   # check if one was grabbed
grep STOCKOUT ~/grab_b200.log  # see which zones failed
```

**Stop the loop** (after success or to cancel):
```bash
kill <PID>
```

The script sweeps all zones, waits 2 minutes, then sweeps again. It will print `SUCCESS! VM 'wxz-b200' created in <zone>` when it grabs one.

### 3.2 How it works

The `grab_b200.sh` script runs:

```bash
gcloud compute instances create wxz-b200 \
    --zone=$ZONE \
    --machine-type=a4-highgpu-8g \
    --provisioning-model=SPOT \
    --maintenance-policy=TERMINATE \
    --scopes=cloud-platform \
    --image-project=deeplearning-platform-release \
    --image-family=pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
    --boot-disk-size=500GB \
    --tags=b200-train \
    --network-interface=nic-type=GVNIC,network=b200-vpc,subnet=b200-vpc \
    --network-interface=nic-type=GVNIC,network=b200-vpc-2,subnet=$VPC2_SUB,no-address \
    --network-interface=nic-type=MRDMA,network=$RDMA_NET,subnet=$RDMA_SUB-{0..7},no-address \
    --metadata=startup-script='#!/bin/bash
        echo "DefaultLimitNOFILE=infinity" >> /etc/systemd/system.conf
        echo "DefaultLimitNOFILE=infinity" >> /etc/systemd/user.conf
        echo "*  soft  nofile  unlimited" >> /etc/security/limits.conf
        echo "*  hard  nofile  unlimited" >> /etc/security/limits.conf'
    --project=camp-blue-431854084
```

Key flags:
- `--provisioning-model=SPOT` — cheapest, but can be preempted anytime.
- `--scopes=cloud-platform` — allows Python libraries (gcsfs, boto3) to access GCS from the VM.
- `--maintenance-policy=TERMINATE` — required for spot instances.
- `--tags=b200-train` — matches firewall rules for inter-node traffic.
- The startup script sets `ulimit` to unlimited (needed for NCCL).
- 10 network interfaces: 1 GVNIC (external), 1 GVNIC (internal), 8 MRDMA (RDMA/RoCE).

### 3.3 Available zones

The script has mappings for these zones (each requires its own RDMA VPC):

| Zone | RDMA Network |
|------|-------------|
| `us-west3-b` | `b200-rdma` |
| `us-west3-c` | `b200-rdma-us-west3-c` |
| `us-west2-c` | `b200-rdma-us-west2-c` |
| `us-south1-b` | `b200-rdma-us-south1-b` |
| `us-east1-b` | `b200-rdma-us-east1-b` |
| `us-east4-b` | `b200-rdma-us-east4-b` |
| `us-central1-b` | `b200-rdma-us-central1-b` |
| `europe-west4-b` | `b200-rdma-europe-west4-b` |
| `europe-north1-b` | `b200-rdma-europe-north1-b` |
| `asia-northeast1-b` | `b200-rdma-asia-northeast1-b` |
| `asia-southeast1-b` | `b200-rdma-asia-southeast1-b` |

---

## 4. Post-Creation Setup (on the VM)

> **Skip this section entirely if recovering from a snapshot** — jump to [Section 8 Step 4](#step-4-recover-data-via-secondary-disk).

### 4.0 SSH into the VM

```bash
# From your management machine:
gcloud compute ssh wxz-b200 --zone=<ZONE> --project=camp-blue-431854084
```

If prompted to create an SSH key, press Enter twice (empty passphrase).

### 4.1 Install gIB (GPU Interconnect Bridge)

gIB is Google's NCCL plugin for RDMA networking. The base image ships with an older version.

```bash
sudo apt-get update -qq
sudo apt-get install -y --allow-change-held-packages nccl-gib
sudo ln -sf /usr/local/gib/include/nccl.h /usr/local/cuda/include/nccl.h
```

The `--allow-change-held-packages` flag is needed because the DL image holds nccl-gib at the pre-installed version.

### 4.2 Reboot

This applies both the ulimit changes (from the startup script) and the new gIB:

```bash
sudo reboot
```

Wait ~2 minutes, then SSH back in.

### 4.3 Verify

```bash
ulimit -n          # Expected: 1048576 (if 1024, check /etc/security/limits.conf and reboot again)
nvidia-smi -L      # Should show 8× NVIDIA B200
dpkg -l nccl-gib   # Check gIB version
```

### 4.4 Mount NVMe local storage (~12TB RAID-0)

Each `a4-highgpu-8g` VM has 32× 375GB NVMe local SSDs, unmounted by default. RAID them into a single filesystem:

```bash
sudo apt-get install -y -qq mdadm
DRIVES=$(lsblk -d -n -o NAME,SIZE | grep nvme | grep 375G | awk '{print "/dev/" $1}' | tr '\n' ' ')
echo y | sudo mdadm --create /dev/md0 --level=0 --raid-devices=$(echo $DRIVES | wc -w) $DRIVES
sudo mkfs.ext4 -F /dev/md0
sudo mkdir -p /mnt/local_storage
sudo mount /dev/md0 /mnt/local_storage
sudo chmod 777 /mnt/local_storage
```

Verify: `df -h /mnt/local_storage` should show ~12TB.

> **⚠️ NVMe is ephemeral.** All data on `/mnt/local_storage` is lost on preemption, stop, or reboot. After reboot, re-mount with:
> ```bash
> sudo mdadm --assemble /dev/md0 && sudo mount /dev/md0 /mnt/local_storage
> ```
> After preemption, NVMe data is gone — you must re-create the RAID from scratch (repeat the commands above).

### 4.5 Symlink ~/.cache to NVMe

HuggingFace and pip/uv caches can grow to 50-100GB. Redirect them to NVMe so they don't fill the boot disk:

```bash
mkdir -p /mnt/local_storage/.cache
mv ~/.cache/* /mnt/local_storage/.cache/ 2>/dev/null || true
rm -rf ~/.cache
ln -sf /mnt/local_storage/.cache ~/.cache
```

**Trade-off:** This means caches are lost on preemption and must be re-downloaded. If you prefer persistence over disk space, skip this step (but watch boot disk usage with `df -h /`).

### 4.6 Configure NCCL for single-node (CRITICAL)

Without this, gIB initialization fails on single-node setups:

```bash
echo 'export NCCL_NET=Socket' >> ~/.bashrc
echo 'export NCCL_NET_PLUGIN=none' >> ~/.bashrc
source ~/.bashrc
```

> **For multi-node training**, do NOT set these. Instead use `NCCL_NET=gIB` — see `b200_multinode_setup_guide.md`.

---

## 5. User Account & SSH Setup

GCP VMs use the gcloud-authenticated user by default (e.g., `v-xinzezheng@microsoft.com`). For convenience, create a normal user:

### 5.1 Create user on the VM

Run these as the gcloud user (who has sudo):

```bash
# Create user
sudo useradd -m -s /bin/bash <USERNAME>

# Add SSH public key (replace with YOUR key)
sudo mkdir -p /home/<USERNAME>/.ssh
echo '<YOUR_SSH_PUBLIC_KEY>' | sudo tee /home/<USERNAME>/.ssh/authorized_keys
sudo chmod 700 /home/<USERNAME>/.ssh
sudo chmod 600 /home/<USERNAME>/.ssh/authorized_keys
sudo chown -R <USERNAME>:<USERNAME> /home/<USERNAME>/.ssh

# Grant passwordless sudo
sudo usermod -aG sudo <USERNAME>
echo '<USERNAME> ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/<USERNAME>
sudo chmod 440 /etc/sudoers.d/<USERNAME>
```

Example for user `wxzheng`:
```bash
sudo useradd -m -s /bin/bash wxzheng
sudo mkdir -p /home/wxzheng/.ssh
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8wdf6lTnBhJksE956e0K5U4mQS2wz6BkWPWoFF0PWx v-xinzezheng@DESKTOP-PD8FL12' \
  | sudo tee /home/wxzheng/.ssh/authorized_keys
sudo chmod 700 /home/wxzheng/.ssh
sudo chmod 600 /home/wxzheng/.ssh/authorized_keys
sudo chown -R wxzheng:wxzheng /home/wxzheng/.ssh
sudo usermod -aG sudo wxzheng
echo 'wxzheng ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/wxzheng
sudo chmod 440 /etc/sudoers.d/wxzheng
```

### 5.2 Configure SSH on your local machine

Find the VM's external IP:
```bash
gcloud compute instances describe wxz-b200 --zone=<ZONE> --project=camp-blue-431854084 \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
```

Add to `~/.ssh/config` on your local machine:
```
Host wxz-b200
    HostName <EXTERNAL_IP>
    User wxzheng
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking no
```

Now you can: `ssh wxz-b200`

> **After preemption/migration:** The external IP changes. Update `HostName` in your SSH config.

### 5.3 GitHub CLI auth (headless server — no browser)

```bash
# 1. Generate a Personal Access Token at https://github.com/settings/tokens/new
#    - Check "repo" scope (and "read:org" if needed for private org repos)
# 2. On the VM:
echo "YOUR_TOKEN_HERE" | gh auth login --hostname github.com --git-protocol https --with-token
```

---

## 6. Backup to GCS

### 6.1 Create a bucket (one-time)

> **Must be run from a user-authenticated machine** (your management machine), NOT from the VM.
> The VM's compute service account does not have permission to create buckets.

```bash
gcloud storage buckets create gs://wxz-backup --location=us-south1 --project=camp-blue-431854084

# Grant the VM's service account write access to the bucket
gcloud storage buckets add-iam-policy-binding gs://wxz-backup \
  --member="serviceAccount:816756621630-compute@developer.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
```

The bucket already exists as of 2026-05-18. Skip this step if it's already created.

### 6.2 Sync data (from the VM)

```bash
# Sync specific folders
for d in ~/mini_swe_agent_trajs_*; do
  gcloud storage rsync "$d" "gs://wxz-backup/$(basename $d)/" --recursive
done

# Sync dotfiles and small important files
gcloud storage rsync ~/.ssh gs://wxz-backup/dotfiles/.ssh/ --recursive
gcloud storage cp ~/.bashrc ~/.gitconfig ~/summary.md gs://wxz-backup/dotfiles/
gcloud storage rsync ~/scripts gs://wxz-backup/scripts/ --recursive
gcloud storage rsync ~/exports gs://wxz-backup/exports/ --recursive
```

### 6.3 Convenience alias

Add to `~/.bashrc` for quick backups:

```bash
alias backup='for d in ~/mini_swe_agent_trajs_*; do gcloud storage rsync "$d" "gs://wxz-backup/$(basename $d)/" --recursive; done && echo "Backup done"'
```

Then just run `backup` whenever you want to sync.

### 6.4 Restore from GCS

```bash
gcloud storage rsync gs://wxz-backup/mini_swe_agent_trajs_daytona/ ~/mini_swe_agent_trajs_daytona/ --recursive
```

### 6.5 Useful GCS commands

```bash
# List bucket contents
gcloud storage ls gs://wxz-backup/

# List recursively
gcloud storage ls gs://wxz-backup/ --recursive

# Delete a folder (MUST use --recursive)
gcloud storage rm gs://wxz-backup/old-folder/ --recursive

# Mirror mode: delete remote files that don't exist locally (use carefully!)
gcloud storage rsync ~/folder gs://wxz-backup/folder/ --recursive --delete-unmatched-destination-objects
```

### 6.6 What NOT to back up to GCS

- `~/.cache/` — HF model weights, pip/uv caches. Too large, re-downloadable.
- `~/.vscode-server/` — VS Code reinstalls automatically on reconnect.
- `~/.triton/`, `~/.nv/` — Compiled caches, auto-rebuilt.
- `.git/` directories — Use `git push` instead. Syncing `.git/` can cause corruption.
- `miniconda3/pkgs/` — Package cache with broken symlinks. Re-downloadable.

---

## 7. When the VM Is Preempted

GCP can preempt your spot instance at any time. Here's the decision tree:

```
VM preempted → status = TERMINATED
  │
  ├─ Try to restart in same zone:
  │    gcloud compute instances start wxz-b200 --zone=<ZONE> --project=camp-blue-431854084
  │    │
  │    ├─ Success → Re-mount NVMe (see below), update SSH config IP
  │    └─ Fails (STOCKOUT) → Go to Section 8 (zone migration)
  │
  └─ NVMe data is GONE. Boot disk data is INTACT.
```

### After a successful restart in the same zone

The boot disk is intact. Only NVMe needs re-setup:

```bash
# Re-mount NVMe RAID
sudo apt-get install -y -qq mdadm
DRIVES=$(lsblk -d -n -o NAME,SIZE | grep nvme | grep 375G | awk '{print "/dev/" $1}' | tr '\n' ' ')
echo y | sudo mdadm --create /dev/md0 --level=0 --raid-devices=$(echo $DRIVES | wc -w) $DRIVES
sudo mkfs.ext4 -F /dev/md0
sudo mkdir -p /mnt/local_storage
sudo mount /dev/md0 /mnt/local_storage
sudo chmod 777 /mnt/local_storage

# Re-create cache dir (the ~/.cache symlink still points here)
mkdir -p /mnt/local_storage/.cache
```

Everything else (user accounts, SSH keys, .bashrc, git repos, venvs, installed packages) is on the boot disk and unchanged.

---

## 8. Zone Migration via Snapshot

When the VM can't restart in the same zone (stockout), migrate to another zone:

### Step 1: Snapshot the boot disk

Run from your management machine. Snapshots are global — usable in any zone.

```bash
OLD_ZONE="<zone where TERMINATED VM lives>"   # e.g., us-south1-b
PROJECT="camp-blue-431854084"

gcloud compute snapshots create wxz-b200-snap \
  --source-disk=wxz-b200 \
  --source-disk-zone=$OLD_ZONE \
  --project=$PROJECT
```

Takes 5-10 minutes for a 500GB disk.

### Step 2: Delete the old VM

```bash
gcloud compute instances delete wxz-b200 --zone=$OLD_ZONE --project=$PROJECT --quiet
```

### Step 3: Create a new VM from a FRESH IMAGE

> **⚠️ Do NOT boot from the snapshot.** Snapshot-based VM creation is much slower and frequently fails to acquire spot capacity. Always create from the stock image — it's faster and more likely to succeed.

```bash
nohup bash scripts/gcp/grab_b200.sh > ~/grab_b200.log 2>&1 &
# Monitor: tail -f ~/grab_b200.log
```

### Step 4: Recover data via secondary disk

Once the new VM is running in `$NEW_ZONE`:

**From your management machine:**
```bash
NEW_ZONE="<zone of new VM>"   # e.g., us-west3-c
PROJECT="camp-blue-431854084"

# Create a recovery disk from the snapshot
# IMPORTANT: must use hyperdisk-balanced — a4 machines reject pd-standard and pd-ssd
gcloud compute disks create wxz-recovery \
  --zone=$NEW_ZONE \
  --source-snapshot=wxz-b200-snap \
  --type=hyperdisk-balanced \
  --project=$PROJECT

# Attach it to the new VM
gcloud compute instances attach-disk wxz-b200 \
  --disk=wxz-recovery \
  --zone=$NEW_ZONE \
  --project=$PROJECT
```

**On the VM** (SSH in via gcloud):
```bash
# Find the recovery disk — look for the 500G device that is NOT mounted
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep 500G
# The boot disk is mounted at /. The recovery disk is unmounted.
# Note the device name (e.g., nvme33n1)

# Mount partition 1 of the recovery disk
sudo mkdir -p /mnt/recovery
sudo mount /dev/nvmeXXn1p1 /mnt/recovery    # replace XX with actual device number

# List contents to verify
sudo ls /mnt/recovery/home/

# Copy your user's home directory
sudo rsync -a /mnt/recovery/home/wxzheng/ /home/wxzheng/
sudo chown -R wxzheng:wxzheng /home/wxzheng/

# Unmount
sudo umount /mnt/recovery
```

**Back on your management machine — detach and delete the recovery disk:**
```bash
gcloud compute instances detach-disk wxz-b200 --disk=wxz-recovery --zone=$NEW_ZONE --project=$PROJECT
gcloud compute disks delete wxz-recovery --zone=$NEW_ZONE --project=$PROJECT --quiet
```

### Step 5: Run post-creation setup

Since the new VM was created from a fresh image, run the full [Section 4](#4-post-creation-setup-on-the-vm) (gIB, reboot, NVMe, NCCL config) and [Section 5](#5-user-account--ssh-setup) (user account, SSH key).

Note: if you recovered the home directory from the snapshot, the user's `.bashrc` (with NCCL vars) is already there. But system-level setup (gIB, ulimit reboot) must be redone.

### Step 6: Clean up snapshot (optional)

```bash
gcloud compute snapshots delete wxz-b200-snap --project=$PROJECT --quiet
```

Keep the snapshot if you want a safety net. Snapshots cost ~$0.026/GB/month (~$13/month for 500GB).

---

## 9. Quick Reference

### Find your VM

```bash
gcloud compute instances list --project=camp-blue-431854084 --filter="name=wxz-b200"
```

### SSH

```bash
# Via gcloud (always works, uses OS Login)
gcloud compute ssh wxz-b200 --zone=<ZONE> --project=camp-blue-431854084

# Via direct SSH (after Section 5 setup)
ssh wxz-b200            # uses ~/.ssh/config alias
ssh wxzheng@<EXTERNAL_IP>  # direct
```

### Get external IP

```bash
gcloud compute instances describe wxz-b200 --zone=<ZONE> --project=camp-blue-431854084 \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
```

### Stop/start VM

```bash
# Stop (preserves boot disk, releases resources, stops billing for compute)
gcloud compute instances stop wxz-b200 --zone=<ZONE> --project=camp-blue-431854084

# Start (may fail if zone has no capacity)
gcloud compute instances start wxz-b200 --zone=<ZONE> --project=camp-blue-431854084
```

### Delete VM

```bash
gcloud compute instances delete wxz-b200 --zone=<ZONE> --project=camp-blue-431854084 --quiet
```

### NVMe re-mount (after any restart/reboot)

```bash
# After reboot (RAID metadata intact):
sudo mdadm --assemble /dev/md0 && sudo mount /dev/md0 /mnt/local_storage

# After preemption (NVMe wiped — must recreate):
sudo apt-get install -y -qq mdadm
DRIVES=$(lsblk -d -n -o NAME,SIZE | grep nvme | grep 375G | awk '{print "/dev/" $1}' | tr '\n' ' ')
echo y | sudo mdadm --create /dev/md0 --level=0 --raid-devices=$(echo $DRIVES | wc -w) $DRIVES
sudo mkfs.ext4 -F /dev/md0
sudo mkdir -p /mnt/local_storage && sudo mount /dev/md0 /mnt/local_storage && sudo chmod 777 /mnt/local_storage
mkdir -p /mnt/local_storage/.cache
```

---

## Appendix: What Persists vs What's Lost

### Storage persistence matrix

| Storage | On Reboot | On Preemption | On VM Delete | On Zone Migration |
|---------|----------|--------------|-------------|-------------------|
| **Boot disk** (500GB) | ✅ | ✅ | ❌ Deleted | ✅ Via snapshot |
| **NVMe SSDs** (12TB) | ⚠️ Re-assemble | ❌ **Wiped** | ❌ Wiped | ❌ Wiped |
| **GCS bucket** | ✅ | ✅ | ✅ | ✅ |
| **Snapshots** | ✅ | ✅ | ✅ | ✅ |

### Recommended data placement

| Data | Where to store | Backup strategy |
|------|---------------|----------------|
| Source code | `~/` (boot disk) + GitHub | `git push` frequently |
| Python venvs / conda | `~/` (boot disk) | Survives preemption; snapshot for migration |
| Experiment results / trajectories | `~/` (boot disk) | `gcloud storage rsync` to GCS regularly |
| HF model weights | `~/.cache` → NVMe | Re-download after preemption (don't backup — too large) |
| Training checkpoints | NVMe then GCS | `gcloud storage rsync` to GCS after each checkpoint |
| SSH keys / configs | `~/` (boot disk) | Optional GCS backup |

### Disk type compatibility

The `a4-highgpu-8g` machine type **only accepts `hyperdisk-balanced`** for attached persistent disks. Attempting to attach `pd-standard` or `pd-ssd` will fail with:
```
ERROR: pd-standard disk type cannot be used by a4-highgpu-8g machine type.
```

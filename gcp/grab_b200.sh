#!/usr/bin/env bash
# Retry loop to grab a single B200 spot instance across all available zones.
# Usage: bash grab_b200.sh
# Stop with Ctrl+C once a VM is created.

set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

VM_NAME="wxz-b200"
PROJECT="camp-blue-431854084"
IMAGE_FAMILY="pytorch-2-9-cu129-ubuntu-2204-nvidia-580"
RETRY_INTERVAL=120  # seconds between full sweeps

# Zone -> RDMA network, RDMA subnet prefix, VPC-2 subnet
declare -A ZONES
ZONES=(
  ["us-west3-b"]="b200-rdma|b200-rdma-sub|b200-vpc-2-sub"
  ["us-south1-b"]="b200-rdma-us-south1-b|b200-rdma-us-south1-b-sub|b200-vpc-2-sub-south1"
  ["us-east1-b"]="b200-rdma-us-east1-b|b200-rdma-us-east1-b-sub|b200-vpc-2-east1"
  ["us-central1-b"]="b200-rdma-us-central1-b|b200-rdma-us-central1-b-sub|b200-vpc-2-sub-central1"
  ["us-east4-b"]="b200-rdma-us-east4-b|b200-rdma-us-east4-b-sub|b200-vpc-2-sub-us-east4"
  ["us-west2-c"]="b200-rdma-us-west2-c|b200-rdma-us-west2-c-sub|b200-vpc-2-sub-us-west2"
  ["us-west3-c"]="b200-rdma-us-west3-c|b200-rdma-us-west3-c-sub|b200-vpc-2-sub"
  ["europe-west4-b"]="b200-rdma-europe-west4-b|b200-rdma-europe-west4-b-sub|b200-vpc-2-sub-europe-west4"
  ["europe-north1-b"]="b200-rdma-europe-north1-b|b200-rdma-europe-north1-b-sub|b200-vpc-2-sub-europe-north1"
  ["asia-northeast1-b"]="b200-rdma-asia-northeast1-b|b200-rdma-asia-northeast1-b-sub|b200-vpc-2-sub-asia-northeast1"
  ["asia-southeast1-b"]="b200-rdma-asia-southeast1-b|b200-rdma-asia-southeast1-b-sub|b200-vpc-2-sub-asia-southeast1"
)

attempt=0
while true; do
  for ZONE in "${!ZONES[@]}"; do
    attempt=$((attempt + 1))
    IFS='|' read -r RDMA_NET RDMA_SUB VPC2_SUB <<< "${ZONES[$ZONE]}"

    echo ""
    echo "=========================================="
    echo "[Attempt $attempt] $(date '+%Y-%m-%d %H:%M:%S') — Trying $ZONE"
    echo "=========================================="

    if gcloud compute instances create "$VM_NAME" \
        --zone="$ZONE" \
        --machine-type=a4-highgpu-8g \
        --provisioning-model=SPOT \
        --maintenance-policy=TERMINATE \
        --scopes=cloud-platform \
        --image-project=deeplearning-platform-release \
        --image-family="$IMAGE_FAMILY" \
        --boot-disk-size=500GB \
        --tags=b200-train \
        --network-interface=nic-type=GVNIC,network=b200-vpc,subnet=b200-vpc \
        --network-interface=nic-type=GVNIC,network=b200-vpc-2,subnet="$VPC2_SUB",no-address \
        --network-interface=nic-type=MRDMA,network="$RDMA_NET",subnet="${RDMA_SUB}-0",no-address \
        --network-interface=nic-type=MRDMA,network="$RDMA_NET",subnet="${RDMA_SUB}-1",no-address \
        --network-interface=nic-type=MRDMA,network="$RDMA_NET",subnet="${RDMA_SUB}-2",no-address \
        --network-interface=nic-type=MRDMA,network="$RDMA_NET",subnet="${RDMA_SUB}-3",no-address \
        --network-interface=nic-type=MRDMA,network="$RDMA_NET",subnet="${RDMA_SUB}-4",no-address \
        --network-interface=nic-type=MRDMA,network="$RDMA_NET",subnet="${RDMA_SUB}-5",no-address \
        --network-interface=nic-type=MRDMA,network="$RDMA_NET",subnet="${RDMA_SUB}-6",no-address \
        --network-interface=nic-type=MRDMA,network="$RDMA_NET",subnet="${RDMA_SUB}-7",no-address \
        --metadata=startup-script='#!/bin/bash
  echo "DefaultLimitNOFILE=infinity" >> /etc/systemd/system.conf
  echo "DefaultLimitNOFILE=infinity" >> /etc/systemd/user.conf
  echo "*                soft    nofile          unlimited" >> /etc/security/limits.conf
  echo "*                hard    nofile          unlimited" >> /etc/security/limits.conf
  ' \
        --project="$PROJECT" 2>&1; then

      echo ""
      echo "============================================"
      echo "SUCCESS! VM '$VM_NAME' created in $ZONE"
      echo "============================================"
      echo ""
      echo "Next steps:"
      echo "  1. SSH in:  gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT"
      echo "  2. Install gIB:  sudo apt-get update && sudo apt-get install -y nccl-gib"
      echo "  3. Symlink:  sudo ln -sf /usr/local/gib/include/nccl.h /usr/local/cuda/include/nccl.h"
      echo "  4. Reboot:  sudo reboot"
      echo "  5. After reboot, mount NVMe and set NCCL_NET=Socket (single-node)"
      exit 0
    else
      echo "[STOCKOUT] $ZONE — trying next zone..."
      sleep 2
    fi
  done

  echo ""
  echo "All zones exhausted. Sleeping ${RETRY_INTERVAL}s before next sweep..."
  sleep "$RETRY_INTERVAL"
done

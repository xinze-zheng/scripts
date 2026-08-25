#### Initial setup
```
gcloud auth login
gcloud auth list

PROJECT=camp-blue-431854084
gcloud config set project "$PROJECT"
gcloud config list
```

#### Find instances
```
gcloud compute instances list \
  --filter="name~'wxz'" \
  --format="table(name,zone.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)"

VM=wxz-rl-dev-0
ZONE=$(gcloud compute instances list \
  --filter="name=$VM" \
  --format="value(zone.basename())" \
  --limit=1)

gcloud compute instances describe "$VM" \
  --zone="$ZONE" 
```

#### Login
```
gcloud compute ssh wxzheng"@$VM" --zone="$ZONE"
```

#### Migration
```
PROJECT=camp-blue-431854084
OLD_VM=wxz-rl-dev-1
OLD_ZONE=us-east1-b
SNAPSHOT=wxz-rl-dev-1-boot

gcloud compute snapshots create "$SNAPSHOT" \
  --source-disk="$OLD_VM" \
  --source-disk-zone="$OLD_ZONE" \
  --snapshot-type=STANDARD \
  --project="$PROJECT"
```
To confirm
```
gcloud compute snapshots describe "$SNAPSHOT" \
  --project="$PROJECT" \
  --format='table(name,status,diskSizeGb,creationTimestamp)'
```

Create and attach recovery disk
```
PROJECT=camp-blue-431854084
NEW_VM=wxz-rl-dev-1
NEW_ZONE=us-east1-b
SNAPSHOT=wxz-rl-dev-0-boot-20260820
RECOVERY_DISK=wxz-rl-dev-0-recovery
DEVICE_NAME=wxz-old-root

gcloud compute disks create "$RECOVERY_DISK" \
  --zone="$NEW_ZONE" \
  --source-snapshot="$SNAPSHOT" \
  --type=hyperdisk-balanced \
  --project="$PROJECT"

gcloud compute instances attach-disk "$NEW_VM" \
  --disk="$RECOVERY_DISK" \
  --device-name="$DEVICE_NAME" \
  --mode=rw \
  --zone="$NEW_ZONE" \
  --project="$PROJECT"
```

Mount in the new vm
```
gcloud compute ssh "$NEW_VM" \
  --zone="$NEW_ZONE" \
  --project="$PROJECT"
```
```
DEVICE_NAME=wxz-old-root

lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS
ls -l "/dev/disk/by-id/google-${DEVICE_NAME}"*

sudo mkdir -p /mnt/old-root
sudo mount -o ro \
  "/dev/disk/by-id/google-${DEVICE_NAME}-part1" \
  /mnt/old-root

OLD_USER=wxzheng

# Create the local account if it does not exist.
id "$OLD_USER" >/dev/null 2>&1 ||
  sudo useradd -m -s /bin/bash "$OLD_USER"

# Copy everything, including dotfiles and SSH configuration.
sudo rsync -aHAX --info=progress2 \
  "/mnt/old-root/home/${OLD_USER}/" \
  "/home/${OLD_USER}/"

sudo chown -R "${OLD_USER}:${OLD_USER}" "/home/${OLD_USER}"
```
Passwordless sudo
```
sudo usermod -aG sudo wxzheng

echo 'wxzheng ALL=(ALL) NOPASSWD:ALL' |
  sudo tee /etc/sudoers.d/wxzheng >/dev/null

sudo chmod 440 /etc/sudoers.d/wxzheng
sudo visudo -cf /etc/sudoers.d/wxzheng
```

Unmount and detach
```
sudo umount /mnt/old-root
```

Delete mounted disk
```
gcloud compute instances detach-disk "$NEW_VM" \
  --disk="$RECOVERY_DISK" \
  --zone="$NEW_ZONE" \
  --project="$PROJECT"
```
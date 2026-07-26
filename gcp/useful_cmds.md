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
  --zone="$ZONE" \
```

#### Login
```
gcloud compute ssh wxzheng"@$VM" --zone="$ZONE"
```

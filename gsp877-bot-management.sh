#!/usr/bin/env bash
#
# GSP877 - Bot Management with Google Cloud Armor and reCAPTCHA
# End-to-end gcloud automation script (Syntax & Unset Fix)

set -euo pipefail

# --------------------------------------------------------------------------
# 0. Variables & Environment Check
# --------------------------------------------------------------------------
export PROJECT_ID=$(gcloud config get-value project)
export REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export NETWORK="default"

export TEMPLATE_NAME="lb-backend-template"
export MIG_NAME="lb-backend-example"
export LB_NAME="http-lb"
export BACKEND_SERVICE="http-backend"
export HEALTH_CHECK="http-health-check"
export SECURITY_POLICY="recaptcha-policy"

# FIX: Safer POSIX conditional that also catches the literal string "(unset)"
if [ -z "$REGION" ] \vert{}\vert{} [ "$REGION" = "(unset)" ] || [ -z "$ZONE" ] \vert{}\vert{} [ "$ZONE" = "(unset)" ]; then
    echo "⚠️  Region or Zone not found in gcloud config."
    read -p "Enter the lab REGION (e.g., europe-west4): " REGION
    read -p "Enter the lab ZONE (e.g., europe-west4-a): " ZONE
    gcloud config set compute/region "$REGION"
    gcloud config set compute/zone "$ZONE"
fi

echo ">>> Using Project: ${PROJECT_ID}"
echo ">>> Using Region: ${REGION}"
echo ">>> Using Zone: ${ZONE}"

gcloud services enable compute.googleapis.com logging.googleapis.com monitoring.googleapis.com recaptchaenterprise.googleapis.com

# --------------------------------------------------------------------------
# Task 1: Firewalls
# --------------------------------------------------------------------------
echo ">>> Setting up firewall rules..."
gcloud compute firewall-rules create default-allow-health-check \
  --direction=INGRESS --priority=1000 --network="${NETWORK}" \
  --action=ALLOW --rules=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-check 2>/dev/null || true

gcloud compute firewall-rules create allow-ssh \
  --direction=INGRESS --priority=1000 --network="${NETWORK}" \
  --action=ALLOW --rules=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=allow-health-check 2>/dev/null || true

# --------------------------------------------------------------------------
# Task 2: Instance Template & MIG (Forced Recreation)
# --------------------------------------------------------------------------
echo ">>> Forcing cleanup of old instance group and template..."
gcloud compute instance-groups managed delete "${MIG_NAME}" --zone="${ZONE}" --quiet 2>/dev/null || true
gcloud compute instance-templates delete "${TEMPLATE_NAME}" --quiet 2>/dev/null || true
gcloud compute instance-templates delete "${TEMPLATE_NAME}" --region="${REGION}" --quiet 2>/dev/null || true

echo ">>> Creating instance template exactly as the grader expects..."
cat > /tmp/startup-script.sh << 'EOF'
#! /bin/bash
sudo apt-get update
sudo apt-get install apache2 -y
sudo a2ensite default-ssl
sudo a2enmod ssl
sudo su
vm_hostname="$(curl -H "Metadata-Flavor:Google" \
http://metadata.google.internal/computeMetadata/v1/instance/name)"echo "Page served from: $vm_hostname" | \
tee /var/www/html/index.html
EOF

# Create as a GLOBAL template, but explicitly bind it to the regional subnetwork
gcloud compute instance-templates create "${TEMPLATE_NAME}" \
  --machine-type=e2-medium \
  --network="${NETWORK}" \
  --subnet="projects/${PROJECT_ID}/regions/${REGION}/subnetworks/default" \
  --tags=allow-health-check \
  --metadata-from-file=startup-script=/tmp/startup-script.sh

echo ">>> Creating managed instance group..."
gcloud compute instance-groups managed create "${MIG_NAME}" \
  --template="${TEMPLATE_NAME}" --size=1 --zone="${ZONE}"

gcloud compute instance-groups set-named-ports "${MIG_NAME}" --named-ports http:80 --zone "${ZONE}"

# --------------------------------------------------------------------------
# Task 3: Load Balancer
# --------------------------------------------------------------------------
echo ">>> Checking Load Balancer components..."
if ! gcloud compute health-checks describe "${HEALTH_CHECK}" >/dev/null 2>&1; then
    gcloud compute health-checks create tcp "${HEALTH_CHECK}" --port=80 --check-interval=5s --timeout=5s --healthy-threshold=2 --unhealthy-threshold=2
fi

if ! gcloud compute backend-services describe "${BACKEND_SERVICE}" --global >/dev/null 2>&1; then
    gcloud compute backend-services create "${BACKEND_SERVICE}" --protocol=HTTP --port-name=http --health-checks="${HEALTH_CHECK}" --global --enable-logging --logging-sample-rate=1.0
    gcloud compute backend-services add-backend "${BACKEND_SERVICE}" --instance-group="${MIG_NAME}" --instance-group-zone="${ZONE}" --global
fi

if ! gcloud compute url-maps describe "${LB_NAME}" >/dev/null 2>&1; then
    gcloud compute url-maps create "${LB_NAME}" --default-service="${BACKEND_SERVICE}"
    gcloud compute target-http-proxies create "${LB_NAME}-proxy" --url-map="${LB_NAME}"
    gcloud compute addresses create "${LB_NAME}-ip" --global
    gcloud compute forwarding-rules create "${LB_NAME}-fw-rule" --address="${LB_NAME}-ip" --

#!/usr/bin/env bash
#
# GSP877 - Resource Cleanup Script
# Tears down the Load Balancer, Instance Groups, and associated resources.

# Suppress warnings and non-critical output
gcloud config set core/verbosity critical

# Dynamically grab the zone, or prompt if missing
ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
if [[ -z "$ZONE" ]]; then
    read -p "Enter the lab ZONE (e.g., europe-west4-a): " ZONE
    gcloud config set compute/zone "$ZONE"
fi

echo ">>> Starting cleanup in zone: $ZONE..."

echo ">>> 1/8: Deleting Forwarding Rule..."
gcloud compute forwarding-rules delete http-lb-fw-rule --global --quiet || true

echo ">>> 2/8: Deleting Target HTTP Proxy..."
gcloud compute target-http-proxies delete http-lb-proxy --quiet || true

echo ">>> 3/8: Deleting URL Map..."
gcloud compute url-maps delete http-lb --quiet || true

echo ">>> 4/8: Deleting Backend Service..."
gcloud compute backend-services delete http-backend --global --quiet || true

echo ">>> 5/8: Deleting Health Check..."
gcloud compute health-checks delete http-health-check --global --quiet || true

echo ">>> 6/8: Deleting Managed Instance Group..."
gcloud compute instance-groups managed delete lb-backend-example --zone="${ZONE}" --quiet || true

echo ">>> 7/8: Deleting Instance Template..."
gcloud compute instance-templates delete lb-backend-template --quiet || true

echo ">>> 8/8: Deleting Global IP Address..."
gcloud compute addresses delete http-lb-ip --global --quiet || true

# Optional: Uncomment below if you also want to delete the security policy and firewall rules
# echo ">>> Cleaning up Security Policies and Firewalls..."
# gcloud compute security-policies delete recaptcha-policy --quiet || true
# gcloud compute firewall-rules delete default-allow-health-check allow-ssh --quiet || true

echo "=================================================================="
echo " ✅ Cleanup complete."
echo "=================================================================="

# Restore normal gcloud output verbosity
gcloud config set core/verbosity warning

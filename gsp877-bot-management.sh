#!/usr/bin/env bash
#
# GSP877 - Bot Management with Google Cloud Armor and reCAPTCHA
# End-to-end gcloud automation script (v9 - fixed idempotency + startup script)

set -euo pipefail
trap 'echo "❌ Script failed at line ${LINENO} (exit code $?)"; exit 1' ERR

# --------------------------------------------------------------------------
# 0. Variables & Environment Check
# --------------------------------------------------------------------------
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null | tail -n 1)
export REGION=$(gcloud config get-value compute/region 2>/dev/null | tail -n 1)
export ZONE=$(gcloud config get-value compute/zone 2>/dev/null | tail -n 1)
export NETWORK="default"

export TEMPLATE_NAME="lb-backend-template"
export MIG_NAME="lb-backend-example"
export LB_NAME="http-lb"
export BACKEND_SERVICE="http-backend"
export HEALTH_CHECK="http-health-check"
export SECURITY_POLICY="recaptcha-policy"

if [[ -z "$REGION" || "$REGION" == *"(unset)"* || "$REGION" == *"error"* || -z "$ZONE" || "$ZONE" == *"(unset)"* || "$ZONE" == *"error"* ]]; then
    echo "⚠️  Region or Zone not found automatically."
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
  --target-tags=allow-health-check 2>/dev/null || echo "    (default-allow-health-check already exists)"

gcloud compute firewall-rules create allow-ssh \
  --direction=INGRESS --priority=1000 --network="${NETWORK}" \
  --action=ALLOW --rules=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=allow-health-check 2>/dev/null || echo "    (allow-ssh already exists)"

# --------------------------------------------------------------------------
# Task 2: Instance Template & MIG
# --------------------------------------------------------------------------
# NOTE: deliberately create-if-missing rather than delete-then-recreate.
# Once the backend service (Task 3) references this MIG, GCP will refuse to
# delete it — a forced delete silently fails, the "create" step below then
# hits "already exists" and (correctly) aborts the whole script under
# `set -e`, which is why Tasks 4-6 never ran previously.
echo ">>> Writing startup script..."
cat > /tmp/startup-script.sh << 'EOF'
#! /bin/bash
sudo apt-get update
sudo apt-get install apache2 -y
sudo a2ensite default-ssl
sudo a2enmod ssl
vm_hostname="$(curl -H "Metadata-Flavor:Google" http://metadata.google.internal/computeMetadata/v1/instance/name)"
echo "Page served from: $vm_hostname" | sudo tee /var/www/html/index.html
EOF

echo ">>> Checking instance template: ${TEMPLATE_NAME}"
if gcloud compute instance-templates describe "${TEMPLATE_NAME}" >/dev/null 2>&1; then
    echo "    Template already exists, skipping creation..."
else
    gcloud compute instance-templates create "${TEMPLATE_NAME}" \
      --machine-type=e2-medium \
      --network="${NETWORK}" \
      --subnet="projects/${PROJECT_ID}/regions/${REGION}/subnetworks/default" \
      --tags=allow-health-check \
      --metadata-from-file=startup-script=/tmp/startup-script.sh
fi

echo ">>> Checking managed instance group: ${MIG_NAME}"
if gcloud compute instance-groups managed describe "${MIG_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
    echo "    MIG already exists, skipping creation..."
else
    gcloud compute instance-groups managed create "${MIG_NAME}" \
      --template="${TEMPLATE_NAME}" --size=1 --zone="${ZONE}"
fi

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
    gcloud compute forwarding-rules create "${LB_NAME}-fw-rule" --address="${LB_NAME}-ip" --global --target-http-proxy="${LB_NAME}-proxy" --ports=80
fi

LB_IP=$(gcloud compute addresses describe "${LB_NAME}-ip" --global --format="get(address)")
echo ">>> Load balancer IPv4 address: ${LB_IP}"

# --------------------------------------------------------------------------
# Task 4: reCAPTCHA Keys
# --------------------------------------------------------------------------
echo ">>> Setting up reCAPTCHA keys..."
# NOTE: simple "field=value" filter — no nested quotes, which is the safer
# form and avoids gcloud filter-parsing edge cases.
EXISTING_SESSION=$(gcloud recaptcha keys list --format="value(name)" --filter="displayName=test-key-name" | head -n 1)
if [ -n "$EXISTING_SESSION" ]; then
    SESSION_TOKEN_SITE_KEY=$(basename "$EXISTING_SESSION")
else
    SESSION_KEY_OUTPUT=$(gcloud recaptcha keys create --display-name=test-key-name --web --allow-all-domains --integration-type=score --testing-score=0.5 --waf-feature=session-token --waf-service=ca --format="value(name)")
    SESSION_TOKEN_SITE_KEY=$(basename "${SESSION_KEY_OUTPUT}")
fi
echo "    SESSION_TOKEN_SITE_KEY = ${SESSION_TOKEN_SITE_KEY}"

EXISTING_CHALLENGE=$(gcloud recaptcha keys list --format="value(name)" --filter="displayName=challenge-page-key" | head -n 1)
if [ -n "$EXISTING_CHALLENGE" ]; then
    CHALLENGE_PAGE_KEY=$(basename "$EXISTING_CHALLENGE")
else
    CHALLENGE_KEY_OUTPUT=$(gcloud recaptcha keys create --display-name=challenge-page-key --web --allow-all-domains --integration-type=INVISIBLE --waf-feature=challenge-page --waf-service=ca --format="value(name)")
    CHALLENGE_PAGE_KEY=$(basename "${CHALLENGE_KEY_OUTPUT}")
fi
echo "    CHALLENGE_PAGE_KEY = ${CHALLENGE_PAGE_KEY}"

# --------------------------------------------------------------------------
# Task 4.2: Push HTML pages
# --------------------------------------------------------------------------
echo ">>> Waiting for the managed instance group to stabilize..."
gcloud compute instance-groups managed wait-until "${MIG_NAME}" \
  --zone "${ZONE}" --stable --timeout=300

INSTANCE_NAME=$(gcloud compute instance-groups managed list-instances "${MIG_NAME}" \
  --zone "${ZONE}" --format="value(instance)" | head -n1)

if [[ -z "${INSTANCE_NAME}" ]]; then
    echo "❌ No instance found in MIG ${MIG_NAME}. Aborting."
    exit 1
fi
echo "    Found VM: ${INSTANCE_NAME}"

echo ">>> Waiting for SSH to become available on ${INSTANCE_NAME}..."
MAX_RETRIES=15
RETRY_COUNT=0
until gcloud compute ssh "${INSTANCE_NAME}" --zone "${ZONE}" --quiet --command "echo 'SSH Ready'" >/dev/null 2>&1; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Failed to connect via SSH after $MAX_RETRIES attempts."
        exit 1
    fi
    echo "    Retrying SSH in 10 seconds... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 10
done

echo ">>> Deploying HTML pages via SSH..."
cat > /tmp/task4.sh <<EOF
cd /var/www/html/

echo '<!doctype html><html><head><title>ReCAPTCHA Session Token</title><script src="https://www.google.com/recaptcha/enterprise.js?render=${SESSION_TOKEN_SITE_KEY}&waf=session" async defer></script></head><body><h1>Main Page</h1><p><a href="/good-score.html">Visit allowed link</a></p><p><a href="/bad-score.html">Visit blocked link</a></p><p><a href="/median-score.html">Visit redirect link</a></p></body></html>' > index.html

echo '<!DOCTYPE html><html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head><body><h1>Congrats! You have a good score!!</h1></body></html>' > good-score.html

echo '<!DOCTYPE html><html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head><body><h1>Sorry, You have a bad score!</h1></body></html>' > bad-score.html

echo '<!DOCTYPE html><html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head><body><h1>You have a median score that we need a second verification.</h1></body></html>' > median-score.html
EOF

gcloud compute scp --quiet /tmp/task4.sh "${INSTANCE_NAME}:/tmp/task4.sh" --zone="${ZONE}"
gcloud compute ssh "${INSTANCE_NAME}" --zone="${ZONE}" --quiet --command="sudo bash /tmp/task4.sh"
echo "    HTML pages deployed successfully."

# --------------------------------------------------------------------------
# Task 5: Cloud Armor security policy
# --------------------------------------------------------------------------
echo ">>> Configuring Cloud Armor Security Policy..."
if ! gcloud compute security-policies describe "${SECURITY_POLICY}" >/dev/null 2>&1; then
    gcloud compute security-policies create "${SECURITY_POLICY}" --description "policy for bot management"
    gcloud compute security-policies update "${SECURITY_POLICY}" --recaptcha-redirect-site-key "${CHALLENGE_PAGE_KEY}"

    gcloud compute security-policies rules create 2000 --security-policy "${SECURITY_POLICY}" \
      --expression "request.path.matches('/good-score.html') && token.recaptcha_session.score > 0.4" --action allow

    gcloud compute security-policies rules create 3000 --security-policy "${SECURITY_POLICY}" \
      --expression "request.path.matches('/bad-score.html') && token.recaptcha_session.score < 0.6" --action "deny-403"

    gcloud compute security-policies rules create 1000 --security-policy "${SECURITY_POLICY}" \
      --expression "request.path.matches('/median-score.html') && token.recaptcha_session.score == 0.5" \
      --action redirect --redirect-type google-recaptcha

    gcloud compute backend-services update "${BACKEND_SERVICE}" --security-policy "${SECURITY_POLICY}" --global
else
    echo "    Policy ${SECURITY_POLICY} already exists."
fi

echo "=================================================================="
echo " ✅ Deployment complete."
echo " Load Balancer IP:          ${LB_IP}"
echo " Session token site key:    ${SESSION_TOKEN_SITE_KEY}"
echo " Challenge page site key:   ${CHALLENGE_PAGE_KEY}"
echo "=================================================================="

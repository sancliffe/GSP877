# GSP877: Bot Management with Google Cloud Armor and reCAPTCHA

An automated, end-to-end bash script solution for the Google Cloud Skills Boost lab **GSP877**. 

This repository provides scripts to rapidly deploy and tear down the infrastructure required for testing Cloud Armor bot management. It automates the configuration of an HTTP Load Balancer, deploys an Apache web server backend, provisions reCAPTCHA Enterprise session/challenge keys, and sets up Cloud Armor WAF rules to evaluate and act on traffic scores.

## Features

* **Idempotent Execution:** The deployment script checks for existing resources before creation. If a run fails due to a lab timeout or network hiccup, you can safely re-run the script without encountering "resource already exists" errors.
* **Dynamic Environment Detection:** Automatically pulls the active Project ID, Region, and Zone from your `gcloud` config. If they are missing, it will securely prompt you for them.
* **Robust SSH Injection:** Solves the "chicken-and-egg" problem of needing reCAPTCHA keys *before* generating the web server's HTML. The script uses a retry loop to ensure the VM is fully booted and accessible before pushing the final HTML files via SSH.
* **Complete Teardown:** Includes a dedicated cleanup script to systematically remove all load balancer components, instance groups, and templates to prevent unwanted billing.

## Repository Contents

* `gsp877-bot-management.sh` - The primary deployment automation script.
* `cleanup.sh` - The teardown script to remove all provisioned infrastructure.
* `LICENSE` - MIT License.

## Prerequisites

* Access to Google Cloud Shell or a local terminal authenticated with `gcloud`.
* An active Google Cloud Project with billing enabled (or a temporary lab environment).
* Necessary IAM permissions to create Compute Engine resources, Load Balancers, Cloud Armor Policies, and reCAPTCHA keys.

## Usage

### 1. Deployment

Clone this repository and make the deployment script executable. Run the script to provision the infrastructure:

```bash
chmod +x gsp877-bot-management.sh
./gsp877-bot-management.sh
```

Once the script completes, it will output the global IPv4 address of your Load Balancer. Note: You must wait approximately 5 minutes after completion for the global HTTP load balancer routing and health checks to fully propagate before testing the URLs.

2. Cleanup
When you are finished testing, use the cleanup script to delete the managed instance groups, load balancer, and associated networking components.

```Bash
chmod +x cleanup.sh
./cleanup.sh
```
Author
Stephen Ancliffe

GitHub: @sancliffe

License
This project is licensed under the MIT License - see the LICENSE file for details.

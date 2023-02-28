#!/usr/bin/env bash
set -e # Exit if error is detected during pipeline execution => terraform failing
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ -z "${API_DOMAIN}" ]]; then
  echo "API_DOMAIN env variable is not set. It should be set to either customized domain name or using a dummy name mydomain.com".
  exit
fi

if [[ -z "${PROJECT_ID}" ]]; then
  echo "PROJECT_ID variable is not set".
  exit
fi

source "${DIR}"/SET
gcloud config set project $PROJECT_ID

# Run following commands when executing from the local development machine (and not from Cloud Shell)
#gcloud auth login
#gcloud auth application-default login

export ORGANIZATION_ID=$(gcloud organizations list --format="value(name)")
export ADMIN_EMAIL=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
export TF_VAR_admin_email=${ADMIN_EMAIL}

# For Argolis Only
#gcloud resource-manager org-policies disable-enforce constraints/compute.requireOsLogin --organization=$ORGANIZATION_ID
#gcloud resource-manager org-policies delete constraints/compute.vmExternalIpAccess --organization=$ORGANIZATION_ID
#gcloud resource-manager org-policies delete constraints/compute.requireShieldedVm --organization=$ORGANIZATION_ID


bash "${DIR}"/setup/setup_terraform.sh

cd "${DIR}/terraform/environments/dev" || exit

# TODO skip if bucket already exists
terraform init -backend-config=bucket=$TF_BUCKET_NAME
terraform apply -target=module.project_services -target=module.service_accounts -target=module.project_services_docai -auto-approve
terraform apply -auto-approve


# Constructing the Global Config File
bash ../../../setup/update_config.sh

# Modify ACK deadline for the eventarc subscription (this could not be done via terraform API)
subscription=$(terraform output -json eventarc_subscription)
subscription_name=$(echo "$subscription" | tr -d '"' | sed 's:.*/::')
gcloud alpha pubsub subscriptions update "$subscription_name" --ack-deadline=120 --project $PROJECT_ID

#TODO fix in TF to perform this step
if [ -n "$DOCAI_PROJECT_ID"  ] && [ "$DOCAI_PROJECT_ID" != "$PROJECT_ID" ]; then
  gcloud projects add-iam-policy-binding $DOCAI_PROJECT_ID --member="serviceAccount:gke-sa@${PROJECT_ID}.iam.gserviceaccount.com"  --role="roles/documentai.viewer"
  PROJECT_DOCAI_NUMBER=$(gcloud projects describe "$DOCAI_PROJECT_ID" --format='get(projectNumber)')
  gcloud storage buckets add-iam-policy-binding  gs://${PROJECT_ID}-pa-forms --member="serviceAccount:service-${PROJECT_DOCAI_NUMBER}@gcp-sa-prod-dai-core.iam.gserviceaccount.com" --role="roles/storage.objectViewer"
  gcloud storage buckets add-iam-policy-binding  gs://${PROJECT_ID}-docai-output --member="serviceAccount:service-${PROJECT_DOCAI_NUMBER}@gcp-sa-prod-dai-core.iam.gserviceaccount.com" --role="roles/storage.admin"
fi

# TODO Add instructions on Cloud DNS Setup for API_DOMAIN
# Cloud DNS
# Enable Cloud DNS API
# https://docs.google.com/document/d/1oHpOwUfeIMKfe7b1UN7Vd1OoZzn9Gndxvmi-ANcxB_Q/preview?resourcekey=0-pAmIVo-ap-zCzd_HD-W5IQ
# gcloud dns --project=pa-document-ai managed-zones create pa-docai-demo --description="" --dns-name="evekhm.demo.altostrat.com." --visibility="public" --dnssec-state="off"

# REGISTRAR SETUP
#ns-cloud-e1.googledomains.com.
#ns-cloud-e2.googledomains.com.
#ns-cloud-e3.googledomains.com.
#ns-cloud-e4.googledomains.com.

# Submit a DNS delegation request

gcloud container clusters get-credentials main-cluster --region $REGION --project $PROJECT_ID


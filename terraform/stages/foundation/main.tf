/**
 * Copyright 2024 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

# project-specific locals
locals {
  env = var.env

  project_id         = var.project_id
  forms_gcs_path     = "${var.project_id}-pa-forms"
  config_bucket_name = var.config_bucket
  storage_location   = var.storage_location
  services = [
    "appengine.googleapis.com",            # AppEngine
    "artifactregistry.googleapis.com",     # Artifact Registry
    "bigquery.googleapis.com",             # BigQuery
    "bigquerydatatransfer.googleapis.com", # BigQuery Data Transfer
    "cloudbuild.googleapis.com",           # Cloud Build
    "compute.googleapis.com",              # Load Balancers, Cloud Armor
    "container.googleapis.com",            # Google Kubernetes Engine
    "containerregistry.googleapis.com",    # Google Container Registry
    "dataflow.googleapis.com",             # Cloud Dataflow
    "documentai.googleapis.com",           # Document AI
    "eventarc.googleapis.com",             # Event Arc
    "firebase.googleapis.com",             # Firebase
    "firestore.googleapis.com",            # Firestore
    "iam.googleapis.com",                  # Cloud IAM
    "logging.googleapis.com",              # Cloud Logging
    "monitoring.googleapis.com",           # Cloud Operations Suite
    "run.googleapis.com",                  # Cloud Run
    "secretmanager.googleapis.com",        # Secret Manager
    "storage.googleapis.com",              # Cloud Storage
    "certificatemanager.googleapis.com",   # Certificate Manager
    "serviceusage.googleapis.com",         # Service Usage
    "vpcaccess.googleapis.com",            # VPC Access Connector
    "dns.googleapis.com",                  # Cloud DNS
    "iap.googleapis.com",                  # IAP
    "secretmanager.googleapis.com",        # Secret Manager
  ]

  services_docai = [
    "documentai.googleapis.com", # Document AI
    "iam.googleapis.com",        # Cloud IAM
    "logging.googleapis.com",    # Cloud Logging
    "monitoring.googleapis.com", # Cloud Operations Suite
    "storage.googleapis.com",    # Cloud Storage
  ]

  shared_vpc_project = try(var.network_config.host_project, null)
  use_shared_vpc     = var.network_config != null
  region = (
    local.use_shared_vpc
    ? var.network_config.region
    : var.region
  )

  network_config = {
    host_project      = (local.use_shared_vpc ? var.network_config.host_project : var.project_id)
    network           = (local.use_shared_vpc ? var.network_config.network : var.vpc_network)
    subnet            = (local.use_shared_vpc ? var.network_config.subnet : var.vpc_subnetwork)
    serverless_subnet = (local.use_shared_vpc ? var.network_config.serverless_subnet : var.serverless_subnet)
    gke_secondary_ranges = {
      pods     = (local.use_shared_vpc ? var.network_config.gke_secondary_ranges.pods : var.secondary_ranges_pods.range_name)
      services = (local.use_shared_vpc ? var.network_config.gke_secondary_ranges.services : var.secondary_ranges_services.range_name)
    }
    region = (local.use_shared_vpc ? var.network_config.region : var.region)
  }


  //  INTERNAL
  //  adp_ui/.env must be HTTP
  //  cloudrun must be HTTP
  //
  //  EXTERNAL
  //  adp_ui/.env must be HTTPS
  //  cloudrun must be HTTPS
  cloud_run_protocol = (var.cda_external_ui == true ? "https" : "http")

}

data "google_project" "project" {}

module "project_services" {
  source     = "../../modules/project_services"
  project_id = var.project_id
  services   = local.services
}

module "project_services_docai" {
  count      = var.docai_project_id != var.project_id ? 1 : 0
  source     = "../../modules/project_services"
  project_id = var.docai_project_id
  services   = local.services_docai
}


module "service_accounts" {
  depends_on = [module.project_services]
  source     = "../../modules/service_accounts"
  project_id = var.project_id
  env        = var.env
}

resource "time_sleep" "wait_for_project_services" {
  depends_on = [
    module.project_services,
    module.service_accounts
  ]
  create_duration = "160s"
}

module "firebase" {
  depends_on          = [time_sleep.wait_for_project_services]
  source              = "../../modules/firebase"
  project_id          = var.project_id
  firestore_location  = var.firestore_location
  storage_location    = var.storage_location
}

module "vpc_network" {
  count                     = local.use_shared_vpc ? 0 : 1
  source                    = "../../modules/vpc_network"
  project_id                = var.project_id
  vpc_network               = var.vpc_network
  region                    = var.region
  subnetwork                = var.vpc_subnetwork
  serverless_subnet         = var.serverless_subnet
  secondary_ranges_pods     = var.secondary_ranges_pods
  secondary_ranges_services = var.secondary_ranges_services
  master_cidr_ranges        = [var.master_ipv4_cidr_block]
  node_pools_tags           = ["gke-${var.cluster_name}"]
}

module "vpc_serverless_connector" {
  depends_on = [module.project_services, module.vpc_network]

  source             = "../../modules/vpc_serverless_connector"
  vpc_connector_name = var.vpc_connector_name
  project_id         = var.project_id
  region             = var.region
  subnet_name        = local.network_config.serverless_subnet
  host_project_id    = local.shared_vpc_project
}

module "clouddns" {
  depends_on         = [module.project_services, module.vpc_network]
  count              = var.cda_external_ui == false ? 1 : 0
  source             = "../../modules/clouddns"
  project_id         = var.project_id
  region             = var.region
  api_domain         = var.api_domain
  internal_ip_name   = var.internal_ip_name
  vpc_network        = local.network_config.network
  vpc_subnetwork     = local.network_config.subnet
  network_project_id = local.network_config.host_project
}

module "gke" {
  depends_on = [module.project_services, module.vpc_network]

  source                    = "../../modules/gke"
  project_id                = var.project_id
  cluster_name              = var.cluster_name
  namespace                 = "default"
  vpc_network               = local.network_config.network
  vpc_subnetwork            = local.network_config.subnet
  network_project_id        = local.network_config.host_project
  secondary_ranges_pods     = local.network_config.gke_secondary_ranges.pods
  secondary_ranges_services = local.network_config.gke_secondary_ranges.services
  master_ipv4_cidr_block    = var.master_ipv4_cidr_block
  region                    = var.region
  min_node_count            = 1
  max_node_count            = 10
  machine_type              = "n1-standard-8"

  # This service account will be created in both GCP and GKE, and will be
  # used for workload federation in all microservices.
  # See microservices/sample_service/kustomize/base/deployment.yaml for example.
  service_account_name = var.service_account_name_gke

  # See latest stable version at https://cloud.google.com/kubernetes-engine/docs/release-notes-stable
  kubernetes_version = "latest"

}

module "cloudrun-queue" {
  depends_on = [
    time_sleep.wait_for_project_services,
    module.vpc_network,
    module.vpc_serverless_connector,
    google_artifact_registry_repository.docker_repository
  ]
  source             = "../../modules/cloudrun"
  project_id         = var.project_id
  name               = "queue"
  region             = local.region
  api_domain         = var.api_domain
  vpc_connector_name = var.vpc_connector_name
  protocol           = local.cloud_run_protocol
  iap_secret_name    = var.iap_secret_name
  repo_name          = var.repo_name
}

module "cloudrun-start-pipeline" {
  depends_on = [
    time_sleep.wait_for_project_services,
    module.vpc_network,
    module.vpc_serverless_connector,
    google_artifact_registry_repository.docker_repository
  ]
  source             = "../../modules/cloudrun"
  project_id         = var.project_id
  name               = "startpipeline"
  region             = local.region
  api_domain         = var.api_domain
  vpc_connector_name = var.vpc_connector_name
  protocol           = local.cloud_run_protocol
  iap_secret_name    = var.iap_secret_name
  repo_name          = var.repo_name

}


# Displaying the cloudrun endpoint
data "google_cloud_run_service" "queue-run" {
  depends_on = [
    time_sleep.wait_for_project_services,
    module.vpc_network,
    module.cloudrun-queue,
    google_artifact_registry_repository.docker_repository
  ]
  name     = "queue-cloudrun"
  location = local.region
}

data "google_cloud_run_service" "startpipeline-run" {
  depends_on = [
    time_sleep.wait_for_project_services,
    module.vpc_network,
    module.cloudrun-start-pipeline
  ]
  name     = "startpipeline-cloudrun"
  location = local.region
}

module "cloudrun-queue-pubsub" {
  depends_on = [
    time_sleep.wait_for_project_services,
    module.service_accounts,
    module.cloudrun-queue,
    data.google_cloud_run_service.queue-run
  ]
  source                = "../../modules/pubsub"
  topic                 = "queue-topic"
  project_id            = var.project_id
  region                = local.region
  cloudrun_name         = module.cloudrun-queue.name
  cloudrun_location     = module.cloudrun-queue.location
  cloudrun_endpoint     = module.cloudrun-queue.endpoint
  service_account_email = module.cloudrun-queue.service_account_email
}


data "google_storage_project_service_account" "gcs_account" {
}

# To use GCS CloudEvent triggers, the GCS service account requires the Pub/Sub Publisher(roles/pubsub.publisher) IAM role in the specified project.
# (See https://cloud.google.com/eventarc/docs/run/quickstart-storage#before-you-begin)
resource "google_project_iam_member" "gcs_pubsub_publishing" {
  project = data.google_project.project.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# Bucket to process batch documents on START_PIPELINE
resource "google_storage_bucket" "document-load" {
  name                        = local.forms_gcs_path
  location                    = local.storage_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels = {
    goog-packaged-solution = "prior-authorization"
  }
}


# give backup SA rights on bucket
resource "google_storage_bucket_iam_binding" "cloudrun_sa_storage_binding" {
  bucket = google_storage_bucket.document-load.name
  role   = "roles/storage.admin"
  members = [
    "serviceAccount:${module.cloudrun-start-pipeline.service_account_email}",
  ]
  depends_on = [
    module.cloudrun-start-pipeline,
    google_storage_bucket.document-load
  ]
}

resource "time_sleep" "wait_for_eventarc_service_agent_permissions" {
  depends_on = [
    google_storage_bucket_iam_binding.cloudrun_sa_storage_binding,
    google_project_iam_member.gcs_pubsub_publishing
  ]
  create_duration = "120s"
}

module "cloudrun-startspipeline-eventarc" {
  depends_on = [
    time_sleep.wait_for_project_services,
    module.service_accounts,
    module.cloudrun-start-pipeline,
    data.google_cloud_run_service.startpipeline-run,
    time_sleep.wait_for_eventarc_service_agent_permissions
  ]
  source                = "../../modules/eventarc"
  topic                 = "startpipeline-topic"
  project_id            = var.project_id
  location              = local.storage_location
  cloudrun_name         = module.cloudrun-start-pipeline.name
  cloudrun_location     = module.cloudrun-start-pipeline.location
  cloudrun_endpoint     = module.cloudrun-start-pipeline.endpoint
  service_account_email = module.cloudrun-start-pipeline.service_account_email
  gcs_bucket            = local.forms_gcs_path

}



# Need to update subscription created by eventarc and set acknoledgmenet deadline
//resource "google_pubsub_subscription" "startpipeline-eventarc-subscription" {
//  depends_on = [module.startpipeline-eventarc]
//  topic       = module.startpipeline-eventarc.event-topic
//  name = module.startpipeline-eventarc.event-subscription
//  ack_deadline_seconds = 60
//  labels = {
//    goog-packaged-solution = "prior-authorization"
//  }
//
//}

module "validation_bigquery" {
  depends_on = [
    time_sleep.wait_for_project_services
  ]
  source     = "../../modules/bigquery"
  dataset_id = var.dataset_id
  project_id = var.project_id
  location   = var.dataset_location
}

# Create Views.
resource "null_resource" "bigquery_views" {
  depends_on = [
    module.validation_bigquery
  ]
  provisioner "local-exec" {
    command = "../../../sql-scripts/create_views.sh"
  }
}

# ================= Document AI Parsers ====================

module "docai" {
  depends_on = [
    time_sleep.wait_for_project_services
  ]
  source     = "../../modules/docai"
  project_id = var.docai_project_id
  location   = var.docai_location

  # See modules/docai/README.md for available DocAI processor types.
  # Once applied Terraform changes, please run /setup/update_config.sh
  # to automatically update common/src/common/parser_config.json.
  processors = {
    claims_form_parser     = "FORM_PARSER_PROCESSOR"
    prior_auth_form_parser = "CUSTOM_EXTRACTION_PROCESSOR"
    //    classifier      = "CUSTOM_CLASSIFICATION_PROCESSOR" # Needs to become GA
  }
}

# ================= Setup Cross Project Access ====================
resource "google_project_iam_member" "project-gke-docai-access" {
  count   = var.docai_project_id != var.project_id ? 1 : 0
  project = var.docai_project_id
  member  = "serviceAccount:${module.gke.service_account_email}"
  role    = "roles/documentai.viewer"
  depends_on = [
    module.gke,
    module.docai
  ]
}

data "google_project" "docai_project" {
  project_id = var.docai_project_id
}

output "project_docai_number" {
  value = data.google_project.project.number
}


# give backup SA rights on bucket
resource "google_storage_bucket_iam_binding" "cda-docai_sa_storage_load_binding" {
  count  = var.docai_project_id != var.project_id ? 1 : 0
  bucket = google_storage_bucket.document-load.name
  role   = "roles/storage.objectViewer"
  members = [
    "serviceAccount:service-${data.google_project.docai_project.number}@gcp-sa-prod-dai-core.iam.gserviceaccount.com",
  ]
  depends_on = [
    google_storage_bucket.document-upload,
    module.docai
  ]
}

# TODO Use gke module to access sa
resource "google_storage_bucket_iam_binding" "cda-docai_sa_storage_output_binding" {
  count  = var.docai_project_id != var.project_id ? 1 : 0
  bucket = google_storage_bucket.docai-output.name
  role   = "roles/storage.admin"
  members = [
    "serviceAccount:service-${data.google_project.docai_project.number}@gcp-sa-prod-dai-core.iam.gserviceaccount.com",
  ]
  depends_on = [
    google_storage_bucket.docai-output,
    module.gke,
    module.docai
  ]
}

# ================= Storage buckets ====================

resource "google_storage_bucket" "default" {
  name                        = local.project_id
  location                    = local.storage_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels = {
    goog-packaged-solution = "prior-authorization"
  }
}

resource "google_storage_bucket" "document-upload" {
  name                        = "${local.project_id}-document-upload"
  location                    = local.storage_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels = {
    goog-packaged-solution = "prior-authorization"
  }
}


# Bucket to store config
resource "google_storage_bucket" "pa-config" {
  name                        = local.config_bucket_name
  location                    = local.storage_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  versioning {
    enabled = true
  }
  labels = {
    goog-packaged-solution = "prior-authorization"
  }
}


resource "google_storage_bucket" "docai-output" {
  name                        = "${local.project_id}-docai-output"
  location                    = local.storage_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels = {
    goog-packaged-solution = "prior-authorization"
  }
}


# ================= Validation Rules ====================

# Copying rules JSON files to GCS bucket.
resource "null_resource" "validation_rules" {
  depends_on = [
    google_storage_bucket.default
  ]
  provisioner "local-exec" {
    command = "gsutil -m cp ../../../common/src/common/validation_rules/* gs://${google_storage_bucket.default.name}/Validation"
  }
}


# Copying sample data into GCS bucket.
resource "null_resource" "sample-data" {
  depends_on = [
    google_storage_bucket.document-load
  ]
  provisioner "local-exec" {
    command = "gsutil -m  cp -r ../../../sample_data/demo gs://${google_storage_bucket.document-load.name}/demo"
  }
}

resource "google_artifact_registry_repository" "docker_repository" {
  location      = var.region
  repository_id = var.repo_name
  description   = "Docker repository for Microservices"
  format        = "DOCKER"
}



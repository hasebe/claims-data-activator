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

#Creating a cloud run service

resource "google_storage_bucket" "log-bucket" {
  name                        = "${var.project_id}-${var.name}-log"
  location                    = var.region
  storage_class               = "NEARLINE"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels = {
    goog-packaged-solution = "prior-authorization"
  }
}

# Creating a custom service account for cloud run
module "cloud-run-service-account" {
  source  = "terraform-google-modules/service-accounts/google"
  version = "~> 4.0"
  # fetched from previous module to explicitely express dependency
  project_id = var.project_id
  names         = ["cloudrun-${var.name}-sa"]
  display_name = "This is service account for cloud run ${var.name}"

  project_roles = [
    "${var.project_id}=>roles/eventarc.eventReceiver",
    "${var.project_id}=>roles/pubsub.publisher",
    "${var.project_id}=>roles/firebase.admin",
    "${var.project_id}=>roles/firestore.serviceAgent",
    "${var.project_id}=>roles/iam.serviceAccountUser",
    "${var.project_id}=>roles/iam.serviceAccountTokenCreator",
    "${var.project_id}=>roles/run.invoker",
    "${var.project_id}=>roles/pubsub.serviceAgent",
    "${var.project_id}=>roles/secretmanager.secretAccessor"
  ]

}

# Build Cloudrun image
data "archive_file" "common-zip" {
  type        = "zip"
  source_dir  = "../../../common"
  output_path = ".terraform/common.zip"
}
resource "null_resource" "build-common-image" {
  triggers = {
    src_hash = data.archive_file.common-zip.output_sha
  }

  provisioner "local-exec" {
    working_dir = "../../../common"
    command = join(" ", [
      "gcloud builds submit",
      "--config=cloudbuild.yaml",
      "--gcs-log-dir=gs://${var.project_id}-${var.name}-log",
      join("", [
        "--substitutions=",
        "_PROJECT_ID='${var.project_id}',",
        "_REPO_NAME='${var.repo_name}',",
        "_REGION='${var.region}',",
        "_IMAGE='common'",
      ])
    ])
  }
}

# Build Cloudrun image
data "archive_file" "cloudrun-queue-zip" {
  type        = "zip"
  source_dir  = "../../../cloudrun/${var.name}"
  output_path = ".terraform/cloudrun-${var.name}.zip"
}

resource "null_resource" "build-cloudrun-image" {
  depends_on = [
    null_resource.build-common-image,
  ]

  triggers = {
    src_hash = "${data.archive_file.cloudrun-queue-zip.output_sha}"
  }

  provisioner "local-exec" {
    working_dir = "../../../cloudrun/${var.name}"
    command = join(" ", [
      "gcloud builds submit",
      "--config=cloudbuild.yaml",
      "--gcs-log-dir=gs://${var.project_id}-${var.name}-log",
      join("", [
        "--substitutions=",
        "_PROJECT_ID='${var.project_id}',",
        "_REPO_NAME='${var.repo_name}',",
        "_REGION='${var.region}',",
        "_IMAGE='${var.name}-image'",
      ])
    ])
  }
}

resource "google_cloud_run_service" "cloudrun-service" {
  # Run the following to Re-deploy this CloudRun service.
  # terraform apply -replace=module.cloudrun.google_cloud_run_service.cloudrun-service -auto-approve

  depends_on = [
    # module.cloud-run-service-account,
    null_resource.build-common-image,
    null_resource.build-cloudrun-image,
  ]

  name     = "${var.name}-cloudrun"
  location = var.region

  metadata {
    annotations = {
      # internal traffic only
      "run.googleapis.com/ingress" = "internal"
    }
  }

  template {
    metadata {
      annotations = {
        # Limit scale up to prevent any cost blow outs!
        "autoscaling.knative.dev/maxScale" = "10"
        # Prevent Cold Start
        "autoscaling.knative.dev/minScale" = "1"
        # Use the VPC Connector
        "run.googleapis.com/vpc-access-connector" = var.vpc_connector_name
        # all egress from the service should go through the VPC Connector
        "run.googleapis.com/vpc-access-egress" = "all-traffic"
      }
      labels = {
        goog-packaged-solution = "prior-authorization"
      }
    }
    spec {
      timeout_seconds = 600
      containers {
        image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo_name}/${var.name}-image:latest" #Image to connect pubsub to cloud run to processtask API and fetch data from firestore
        ports {
          container_port = 8000
        }

        env {
          name  = "BATCH_PROCESS_QUOTA" # Concurrent Batch Process QUOTA
          value = "5"
        }
        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          # API endpoint domain
          name  = "API_DOMAIN"
          value = var.api_domain
        }
        env {
          # PROTOCOL
          name  = "PROTOCOL"
          value = var.protocol
        }
        env {
          name  = "IAP_SECRET_NAME"
          value = var.iap_secret_name
        }
      }
      service_account_name = module.cloud-run-service-account.email
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
    lifecycle {
    ignore_changes = [
      # Some common annotations which we don't care about.
      template[0].metadata[0].annotations["client.knative.dev/user-image"],
      template[0].metadata[0].annotations["run.googleapis.com/client-name"],
      template[0].metadata[0].annotations["run.googleapis.com/client-version"],
      metadata[0].annotations["run.googleapis.com/operation-id"],

      # These are only changed when "run.googleapis.com/launch-stage" is "BETA".
      # It's non-trivial to make ignore_changes dependent on input variables so
      # we always ignore these annotations even if, strictly speaking, we only
      # need to do so is var.enable_beta_launch_stage is true.
      metadata[0].annotations["serving.knative.dev/creator"],
      metadata[0].annotations["serving.knative.dev/lastModifier"],
    ]
  }
}

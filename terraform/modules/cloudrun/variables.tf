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

variable "project_id" {
  type        = string
  description = "project ID"
}

variable "repo_name" {
  type        = string
  description = "Artifacts Registry name"
}

variable "name" {
  type        = string
  description = "Service name"
}

variable "region" {
  type        = string
  description = "GCP region"
}

variable "api_domain" {
  type        = string
  description = "API domain"
}

variable "protocol" {
  type        = string
  description = "Protocol to be used for Cloud Run outbound requests"
}

variable "vpc_connector_name" {
  type        = string
  description = "VPC connector name"
}

variable "iap_secret_name" {
  type        = string
  description = "Secret to store CLinet id and client secret for IAP"
}
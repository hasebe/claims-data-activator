variable "project_id" {
  type        = string
  description = "GCP Project ID"

  validation {
    condition     = length(var.project_id) > 0
    error_message = "The project_id value must be an non-empty string."
  }
}

variable "region" {
  type        = string
  description = "GCP Region"
  default     = "us-central1"

  validation {
    condition     = length(var.region) > 0
    error_message = "The region value must be an non-empty string."
  }
}

variable "firestore_region" {
  type        = string
  description = "Firestore Region"
  default     = "us-central"
}

variable "dataset_location" {
  type        = string
  description = "BigQuery Dataset location"
  default     = "US"
}

variable "multiregion" {
  type    = string
  default = "us"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "cluster_name" {
  type    = string
  default = "adp-cluster"
}

variable "network" {
  type    = string
  default = "adp-vpc"
}

variable "subnetwork" {
  type    = string
  default = "adp-subnetwork"
}

#adding new variables for the updated scripts

variable "project_name" {
  type        = string
  default     = ""
  description = "This project name"
}

variable "org_id" {
  default     = ""
  description = "This project organization id"
}

variable "firebase_init" {
  default     = false
  description = "Whether to run Firebase init resource"
}

variable "cloudrun_deploy" {
  default     = false
  description = "Whether to deploy Queue cloudrun service resource"
}

variable "admin_email" {
  type        = string
  description = "email of the cert issuer"
}

variable "api_domain" {
  type        = string
  description = "api domain name"
}

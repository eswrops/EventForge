variable "tenancy_ocid" {
  type        = string
  description = "OCI tenancy OCID."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment containing EventForge resources."
}

variable "region" {
  type        = string
  description = "OCI region, such as ap-mumbai-1."
}

variable "object_storage_namespace" {
  type        = string
  description = "OCI Object Storage namespace for this tenancy."
}

variable "state_bucket_name" {
  type        = string
  default     = "eventforge-tfstate-prod"
  description = "Private, versioned bucket used only for Terraform state and locks."
}

variable "backup_bucket_name" {
  type        = string
  default     = "eventforge-backups"
  description = "Private bucket used by VM instance principals for backup artifacts."
}

variable "instance_ocids" {
  type        = set(string)
  description = "Exactly the two existing EventForge VM OCIDs."

  validation {
    condition     = length(var.instance_ocids) == 2
    error_message = "Provide the two existing EventForge VM OCIDs."
  }
}

variable "github_oidc_policy_statement" {
  type        = string
  sensitive   = false
  description = "A tenancy-specific, least-privilege OCI policy statement for the GitHub OIDC workload. It must constrain the production repository identity."

  validation {
    condition     = can(regex("request\\.principal", var.github_oidc_policy_statement))
    error_message = "The federation policy must constrain request.principal attributes."
  }
}

variable "notification_email" {
  type        = string
  description = "Email endpoint for initial OCI alert subscription."
}


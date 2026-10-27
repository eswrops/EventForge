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

variable "state_bucket_kms_key_id" {
  type        = string
  description = "OCI Vault key OCID used to encrypt Terraform state objects at rest."

  # The key must live in the same region as the buckets: Object Storage can
  # only use a CMK from its own region, so a mismatch would fail the apply.
  validation {
    condition     = startswith(var.state_bucket_kms_key_id, "ocid1.key.oc1.${var.region}.")
    error_message = "state_bucket_kms_key_id must be a Vault key OCID from the same region as the bootstrap buckets."
  }
}

variable "kms_key_compartment_ocid" {
  type        = string
  description = "Compartment containing the state-bucket master encryption key. The tenancy OCID names the root compartment (where the existing Vault lives); child compartments use their compartment OCID."

  validation {
    condition = (
      var.kms_key_compartment_ocid == var.tenancy_ocid ||
      can(regex("^ocid1\\.compartment\\.oc1\\.", var.kms_key_compartment_ocid))
    )
    error_message = "Provide the tenancy OCID (root compartment) or a valid child compartment OCID."
  }
}

variable "backup_bucket_name" {
  type        = string
  default     = "eventforge-backups"
  description = "Private bucket used by VM instance principals for backup artifacts."
}

variable "state_version_retention_days" {
  type        = number
  default     = 30
  description = "Days to retain noncurrent Terraform-state object versions."

  validation {
    condition     = var.state_version_retention_days >= 1 && var.state_version_retention_days <= 365
    error_message = "state_version_retention_days must be between 1 and 365."
  }
}

variable "instance_ocids" {
  type        = set(string)
  description = "Exactly the two existing EventForge VM OCIDs."

  validation {
    condition     = length(var.instance_ocids) == 2
    error_message = "Provide the two existing EventForge VM OCIDs."
  }
}

variable "github_plan_oidc_policy_statements" {
  type        = set(string)
  description = "Tenancy-specific OCI statements for the production-plan workload. Include only OCI reads and state/lock-object access, and constrain request.principal attributes."

  validation {
    condition     = length(var.github_plan_oidc_policy_statements) > 0 && alltrue([for statement in var.github_plan_oidc_policy_statements : can(regex("request\\.principal", statement))])
    error_message = "Every production-plan federation policy statement must constrain request.principal attributes."
  }
}

variable "github_apply_oidc_policy_statements" {
  type        = set(string)
  description = "Tenancy-specific OCI statements for the production apply workload. Restrict them to the EventForge compartment and constrain request.principal attributes."

  validation {
    condition     = length(var.github_apply_oidc_policy_statements) > 0 && alltrue([for statement in var.github_apply_oidc_policy_statements : can(regex("request\\.principal", statement))])
    error_message = "Every production apply federation policy statement must constrain request.principal attributes."
  }
}

variable "notification_email" {
  type        = string
  description = "Email endpoint for initial OCI alert subscription."
}


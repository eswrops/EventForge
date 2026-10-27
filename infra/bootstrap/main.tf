resource "oci_objectstorage_bucket" "terraform_state" {
  # Object Storage must be authorized to use the exact CMK before it creates
  # the encrypted bucket. This explicit ordering avoids a service-side race.
  depends_on = [oci_identity_policy.objectstorage_kms]

  compartment_id = var.compartment_ocid
  namespace      = var.object_storage_namespace
  name           = var.state_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"
  kms_key_id     = var.state_bucket_kms_key_id

  object_events_enabled = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_objectstorage_bucket" "backups" {
  compartment_id = var.compartment_ocid
  namespace      = var.object_storage_namespace
  name           = var.backup_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"

  object_events_enabled = false

  lifecycle {
    prevent_destroy = true
  }
}

# Terraform state contains sensitive values. Keep versioning enabled for
# recovery, while retaining old versions for a bounded, cost-conscious window.
resource "oci_objectstorage_object_lifecycle_policy" "terraform_state_versions" {
  bucket    = oci_objectstorage_bucket.terraform_state.name
  namespace = var.object_storage_namespace

  rules {
    action      = "DELETE"
    is_enabled  = true
    name        = "expire-noncurrent-state-versions"
    target      = "previous-object-versions"
    time_amount = var.state_version_retention_days
    time_unit   = "DAYS"
  }
}

# "tenancy" and "compartment id <ocid>" are distinct OCI policy locations:
# the root compartment is addressed by the tenancy OCID with the bare
# "tenancy" form, child compartments by "compartment id <ocid>".
locals {
  kms_policy_location = (
    var.kms_key_compartment_ocid == var.tenancy_ocid
    ? "tenancy"
    : "compartment id ${var.kms_key_compartment_ocid}"
  )
}

resource "oci_identity_policy" "objectstorage_kms" {
  compartment_id = var.tenancy_ocid
  name           = "eventforge-objectstorage-kms"
  description    = "Permits Object Storage to use the state-bucket key and execute its lifecycle policy."

  # The service subject is hyphenated (objectstorage-<region>) per the OCI
  # policy reference; without this statement, creating a bucket with
  # kms_key_id fails on the service side because Object Storage cannot use the
  # Vault key. Key permissions are scoped to the key's own compartment (which
  # may be the tenancy root) and pinned to the exact key OCID.
  # Lifecycle execution additionally needs object-family access, restricted to
  # the state bucket only, so noncurrent versions can expire as configured.
  statements = [
    "Allow service objectstorage-${var.region} to use keys in ${local.kms_policy_location} where target.key.id = '${var.state_bucket_kms_key_id}'",
    "Allow service objectstorage-${var.region} to manage object-family in compartment id ${var.compartment_ocid} where target.bucket.name = '${var.state_bucket_name}'",
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_identity_dynamic_group" "eventforge_instances" {
  compartment_id = var.tenancy_ocid
  name           = "eventforge-instances"
  description    = "Only the two EventForge application instances."
  matching_rule  = "Any {${join(", ", [for id in var.instance_ocids : "instance.id = '${id}'"])}}"
}

resource "oci_identity_policy" "eventforge_instance_backups" {
  compartment_id = var.tenancy_ocid
  name           = "eventforge-instance-backups"
  description    = "Permits EventForge instances to write only the backup bucket."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.eventforge_instances.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.eventforge_instances.name} to inspect buckets in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
  ]
}

# Stage 2 resources: both workload policies constrain the exchanged principal
# with draft claim keys (federation.md §C) that are only verified by the first
# live token exchange. Until then enable_workload_policies stays false so no
# unverified principal-claim mapping can reach an apply.
resource "oci_identity_policy" "github_oidc_plan" {
  count = var.enable_workload_policies ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "eventforge-github-oidc-plan"
  description    = "Read-only OCI access plus Terraform state locking for the constrained GitHub production-plan workload."
  statements     = tolist(var.github_plan_oidc_policy_statements)
}

resource "oci_identity_policy" "github_oidc_apply" {
  count          = var.enable_workload_policies ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "eventforge-github-oidc"
  description    = "Least-privilege apply authorization for the constrained GitHub production workload."
  statements     = tolist(var.github_apply_oidc_policy_statements)
}

# Preserve state for installations created before plan/apply identities were
# split. The existing policy becomes the apply policy; the plan policy is new.
moved {
  from = oci_identity_policy.github_oidc
  to   = oci_identity_policy.github_oidc_apply
}

resource "oci_ons_notification_topic" "operations" {
  compartment_id = var.compartment_ocid
  name           = "eventforge-operations"
  description    = "Infrastructure and budget alerts for EventForge."
}

resource "oci_ons_subscription" "operations_email" {
  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.operations.id
  protocol       = "EMAIL"
  endpoint       = var.notification_email
}


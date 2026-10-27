variable "region" {
  type = string
}

# Tenancy root compartment — owns the pre-existing VCN and the MySQL db subnet
# (import-safety.md §3). The VNIC-update policy MUST be attached here because a
# policy attached in a child compartment cannot grant access to parent resources.
variable "tenancy_ocid" {
  type = string

  validation {
    condition     = startswith(var.tenancy_ocid, "ocid1.tenancy.oc1.")
    error_message = "tenancy_ocid must be a tenancy OCID."
  }
}

# Test compartment — owns the MySQL DB system (rust-api-heatwave) and the
# eventforge-{db,app,lb}-nsg groups. request.resource.compartment.id below is
# this OCID: only DB systems living in this compartment may use these grants.
variable "db_compartment_ocid" {
  type = string

  validation {
    condition     = startswith(var.db_compartment_ocid, "ocid1.compartment.oc1.")
    error_message = "db_compartment_ocid must be a compartment OCID."
  }
}

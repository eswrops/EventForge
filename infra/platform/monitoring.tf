resource "oci_monitoring_alarm" "cpu" {
  compartment_id        = var.compartment_ocid
  display_name          = "eventforge-compute-cpu-high"
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_computeagent"
  query                 = "CpuUtilization[15m].mean() > 80"
  severity              = "WARNING"
  destinations          = [var.operations_topic_id]
  is_enabled            = true
  body                  = "EventForge compute CPU exceeded 80% for 15 minutes."
}

resource "oci_monitoring_alarm" "unhealthy_backends" {
  compartment_id        = var.compartment_ocid
  display_name          = "eventforge-unhealthy-backends"
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_lbaas"
  query                 = "UnHealthyBackendServers[5m].max() > 0"
  severity              = "CRITICAL"
  destinations          = [var.operations_topic_id]
  is_enabled            = true
  body                  = "At least one EventForge load-balancer backend is unhealthy."
}

resource "oci_budget_budget" "monthly" {
  compartment_id        = var.compartment_ocid
  target_compartment_id = var.compartment_ocid
  target_type           = "COMPARTMENT"
  display_name          = "eventforge-monthly"
  description           = "EventForge monthly OCI cost warning budget."
  amount                = var.monthly_budget_amount
  reset_period          = "MONTHLY"
}

resource "oci_budget_alert_rule" "actual_75" {
  budget_id      = oci_budget_budget.monthly.id
  type           = "ACTUAL"
  threshold      = 75
  threshold_type = "PERCENTAGE"
  recipients     = var.notification_email
  display_name   = "eventforge-actual-75"
}

resource "oci_budget_alert_rule" "actual_100" {
  budget_id      = oci_budget_budget.monthly.id
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.notification_email
  display_name   = "eventforge-actual-100"
}

resource "oci_budget_alert_rule" "forecast_100" {
  budget_id      = oci_budget_budget.monthly.id
  type           = "FORECAST"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.notification_email
  display_name   = "eventforge-forecast-100"
}


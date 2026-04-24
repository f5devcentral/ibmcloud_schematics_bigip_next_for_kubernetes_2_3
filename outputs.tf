# ============================================================
# Outputs — F5 BIG-IP Next for Kubernetes 2.3
#
# Workspaces with conditional count return null for all their
# outputs when the controlling variable is false:
#   ws2  install_cert_manager
#   ws3  deploy_bnk
#   ws4  deploy_bnk
#   ws5  deploy_bnk
# ws1 and ws6 are always present.
# ============================================================


# ============================================================
# WS1 — ROKS Cluster
# ============================================================

output "ws1_roks_cluster_id" {
  description = "ID of the OpenShift cluster"
  value       = try(local.ws1_outputs["roks_cluster_id"], null)
}

output "ws1_roks_cluster_name" {
  description = "Name of the OpenShift cluster"
  value       = try(local.ws1_outputs["roks_cluster_name"], null)
}

output "ws1_openshift_cluster_id" {
  description = "ID of the OpenShift cluster"
  value       = try(local.ws1_outputs["openshift_cluster_id"], null)
}

output "ws1_openshift_cluster_name" {
  description = "Name of the OpenShift cluster"
  value       = try(local.ws1_outputs["openshift_cluster_name"], null)
}

output "ws1_openshift_cluster_public_endpoint" {
  description = "Public endpoint URL for the OpenShift cluster"
  value       = try(local.ws1_outputs["openshift_cluster_public_endpoint"], null)
}

output "ws1_openshift_cluster_private_endpoint" {
  description = "Private endpoint URL for the OpenShift cluster"
  value       = try(local.ws1_outputs["openshift_cluster_private_endpoint"], null)
}

output "ws1_openshift_cluster_ingress_hostname" {
  description = "Ingress hostname for the OpenShift cluster"
  value       = try(local.ws1_outputs["openshift_cluster_ingress_hostname"], null)
}

output "ws1_openshift_cluster_state" {
  description = "State of the OpenShift cluster"
  value       = try(local.ws1_outputs["openshift_cluster_state"], null)
}

output "ws1_openshift_cluster_crn" {
  description = "CRN of the OpenShift cluster"
  value       = try(local.ws1_outputs["openshift_cluster_crn"], null)
}

output "ws1_openshift_version_used" {
  description = "OpenShift version used for the cluster"
  value       = try(local.ws1_outputs["openshift_version_used"], null)
}

output "ws1_available_openshift_versions" {
  description = "All available OpenShift versions in the cluster region"
  value       = try(local.ws1_outputs["available_openshift_versions"], null)
}

output "ws1_openshift_worker_zone1_ip" {
  description = "IP address of the worker node in zone 1"
  value       = try(local.ws1_outputs["openshift_worker_zone1_ip"], null)
}

output "ws1_openshift_worker_zone2_ip" {
  description = "IP address of the worker node in zone 2"
  value       = try(local.ws1_outputs["openshift_worker_zone2_ip"], null)
}

output "ws1_openshift_worker_zone3_ip" {
  description = "IP address of the worker node in zone 3"
  value       = try(local.ws1_outputs["openshift_worker_zone3_ip"], null)
}

output "ws1_roks_cluster_vpc_id" {
  description = "ID of the cluster VPC"
  value       = try(local.ws1_outputs["roks_cluster_vpc_id"], null)
}

output "ws1_roks_cluster_vpc_name" {
  description = "Name of the cluster VPC"
  value       = try(local.ws1_outputs["roks_cluster_vpc_name"], null)
}

output "ws1_roks_cluster_vpc_crn" {
  description = "CRN of the cluster VPC"
  value       = try(local.ws1_outputs["roks_cluster_vpc_crn"], null)
}

output "ws1_roks_transit_gateway_id" {
  description = "ID of the Transit Gateway"
  value       = try(local.ws1_outputs["roks_transit_gateway_id"], null)
}

output "ws1_roks_transit_gateway_name" {
  description = "Name of the Transit Gateway"
  value       = try(local.ws1_outputs["roks_transit_gateway_name"], null)
}

output "ws1_roks_transit_gateway_crn" {
  description = "CRN of the Transit Gateway"
  value       = try(local.ws1_outputs["roks_transit_gateway_crn"], null)
}

output "ws1_roks_transit_gateway_location" {
  description = "Location of the Transit Gateway"
  value       = try(local.ws1_outputs["roks_transit_gateway_location"], null)
}

output "ws1_roks_transit_gateway_global_routing" {
  description = "Global routing status of the Transit Gateway"
  value       = try(local.ws1_outputs["roks_transit_gateway_global_routing"], null)
}


# ============================================================
# WS2 — cert-manager (null when install_cert_manager = false)
# ============================================================

output "ws2_cert_manager_namespace" {
  description = "Namespace where cert-manager is deployed"
  value       = var.install_cert_manager ? try(local.ws2_outputs["cert_manager_namespace"], null) : null
}

output "ws2_cert_manager_version" {
  description = "Installed cert-manager Helm chart version"
  value       = var.install_cert_manager ? try(local.ws2_outputs["cert_manager_version"], null) : null
}


# ============================================================
# WS3 — FLO (null when deploy_bnk = false)
# ============================================================

output "ws3_flo_release_name" {
  description = "Name of the f5-lifecycle-operator Helm release"
  value       = var.deploy_bnk ? try(local.ws3_outputs["flo_release_name"], null) : null
}

output "ws3_flo_namespace" {
  description = "Namespace where f5-lifecycle-operator is installed"
  value       = var.deploy_bnk ? try(local.ws3_outputs["flo_namespace"], null) : null
}

output "ws3_flo_version" {
  description = "Installed f5-lifecycle-operator version"
  value       = var.deploy_bnk ? try(local.ws3_outputs["flo_version"], null) : null
}

output "ws3_flo_extracted_flo_version" {
  description = "FLO version extracted from f5-bigip-k8s-manifest"
  value       = var.deploy_bnk ? try(local.ws3_outputs["flo_extracted_flo_version"], null) : null
}

output "ws3_flo_trusted_profile_id" {
  description = "IBM IAM Trusted Profile ID created for the CNE controller service account"
  value       = var.deploy_bnk ? try(local.ws3_outputs["flo_trusted_profile_id"], null) : null
}

output "ws3_flo_pod_deployment_status" {
  description = "FLO pod deployment status"
  value       = var.deploy_bnk ? try(local.ws3_outputs["flo_pod_deployment_status"], null) : null
}

output "ws3_flo_cluster_issuer_name" {
  description = "mTLS certificate issuer name"
  value       = var.deploy_bnk ? try(local.ws3_outputs["flo_cluster_issuer_name"], null) : null
}

output "ws3_cneinstance_network_attachments" {
  description = "Network attachments configured for CNEInstance"
  value       = var.deploy_bnk ? try(local.ws3_outputs["cneinstance_network_attachments"], null) : null
}


# ============================================================
# WS4 — CNEInstance (null when deploy_bnk = false)
# ============================================================

output "ws4_cneinstance_id" {
  description = "Name of the CNEInstance resource"
  value       = var.deploy_bnk ? try(local.ws4_outputs["cneinstance_id"], null) : null
}

output "ws4_cneinstance_namespace" {
  description = "Namespace where CNEInstance is deployed"
  value       = var.deploy_bnk ? try(local.ws4_outputs["cneinstance_namespace"], null) : null
}

output "ws4_cneinstance_pod_deployment_status" {
  description = "Pod deployment status after CNEInstance readiness validation"
  value       = var.deploy_bnk ? try(local.ws4_outputs["cneinstance_pod_deployment_status"], null) : null
}


# ============================================================
# WS5 — License (null when deploy_bnk = false)
# ============================================================

output "ws5_license_id" {
  description = "Name of the License custom resource"
  value       = var.deploy_bnk ? try(local.ws5_outputs["license_id"], null) : null
}

output "ws5_license_namespace" {
  description = "Namespace where the License CR is deployed"
  value       = var.deploy_bnk ? try(local.ws5_outputs["license_namespace"], null) : null
}


# ============================================================
# WS6 — Testing Jumphosts
# ============================================================

output "ws6_testing_jumphost_shared_public_key" {
  description = "Public key installed on all jumphosts"
  value       = try(local.ws6_outputs["testing_jumphost_shared_public_key"], null)
}

output "ws6_testing_jumphost_shared_private_key" {
  description = "Private key shared across all jumphosts"
  value       = try(local.ws6_outputs["testing_jumphost_shared_private_key"], null)
  sensitive   = true
}

output "ws6_roks_cluster_id" {
  description = "ID of the referenced OpenShift cluster"
  value       = try(local.ws6_outputs["roks_cluster_id"], null)
}

output "ws6_roks_cluster_name" {
  description = "Name of the referenced OpenShift cluster"
  value       = try(local.ws6_outputs["roks_cluster_name"], null)
}

output "ws6_testing_tgw_jumphost_vpc_id" {
  description = "ID of the VPC containing the TGW jumphost"
  value       = try(local.ws6_outputs["testing_tgw_jumphost_vpc_id"], null)
}

output "ws6_testing_tgw_jumphost_vpc_name" {
  description = "Name of the VPC containing the TGW jumphost"
  value       = try(local.ws6_outputs["testing_tgw_jumphost_vpc_name"], null)
}

output "ws6_testing_tgw_jumphost_id" {
  description = "Instance ID of the TGW jumphost"
  value       = try(local.ws6_outputs["testing_tgw_jumphost_id"], null)
}

output "ws6_testing_tgw_jumphost_private_ip" {
  description = "Private IP of the TGW jumphost"
  value       = try(local.ws6_outputs["testing_tgw_jumphost_private_ip"], null)
}

output "ws6_testing_tgw_jumphost_public_ip" {
  description = "Floating (public) IP of the TGW jumphost"
  value       = try(local.ws6_outputs["testing_tgw_jumphost_public_ip"], null)
}

output "ws6_testing_tgw_jumphost_ssh_command" {
  description = "SSH command to connect to the TGW jumphost"
  value       = try(local.ws6_outputs["testing_tgw_jumphost_ssh_command"], null)
}

output "ws6_testing_tgw_jumphost_zone" {
  description = "Availability zone where the TGW jumphost was placed"
  value       = try(local.ws6_outputs["testing_tgw_jumphost_zone"], null)
}

output "ws6_testing_tgw_jumphost_profile_used" {
  description = "Instance profile selected for the TGW jumphost"
  value       = try(local.ws6_outputs["testing_tgw_jumphost_profile_used"], null)
}

output "ws6_testing_transit_gateway_connection_id" {
  description = "ID of the Transit Gateway VPC connection"
  value       = try(local.ws6_outputs["testing_transit_gateway_connection_id"], null)
}

output "ws6_testing_cluster_jumphost_ids" {
  description = "Map of zone to instance ID for cluster jumphosts"
  value       = try(local.ws6_outputs["testing_cluster_jumphost_ids"], null)
}

output "ws6_testing_cluster_jumphost_private_ips" {
  description = "Map of zone to private IP for cluster jumphosts"
  value       = try(local.ws6_outputs["testing_cluster_jumphost_private_ips"], null)
}

output "ws6_testing_cluster_jumphost_public_ips" {
  description = "Map of zone to floating IP for cluster jumphosts"
  value       = try(local.ws6_outputs["testing_cluster_jumphost_public_ips"], null)
}

output "ws6_testing_cluster_jumphost_ssh_commands" {
  description = "Map of zone to SSH command for cluster jumphosts"
  value       = try(local.ws6_outputs["testing_cluster_jumphost_ssh_commands"], null)
}

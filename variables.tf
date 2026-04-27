# ============================================================
# Root Terraform Variables
# F5 BIG-IP Next for Kubernetes 2.3 — Orchestration Workspace
#
# Variable sourcing per workspace:
#   ws1 - Build a ROKs cluster - ibmcloud_schematics_bigip_next_for_kubernetes_roks_cluster_4_18
#   ws2 - Install Community cert-manager in ROKs cluster - ibmcloud_schematics_bigip_next_for_kubernetes_2_3_cert_manager
#   ws3 - Install F5 Lifecycle Operator in ROKs cluster - ibmcloud_schematics_bigip_next_for_kubernetes_2_3_flo
#   ws4 - Create a BIG-IP Next for Kubernetes CNEInstance as a Gateway API Class provider - ibmcloud_schematics_bigip_next_for_kubernetes_2_3_cneinstance
#   ws5 - License BIG-IP Next for Kubernetes in the ROKs cluster - ibmcloud_schematics_bigip_next_for_kubernetes_2_3_license
#   ws6 - Install the testing VSI framework - ibmcloud_schematics_bigip_next_for_kubernetes_2_3_testing
#
# Variables omitted here are wired automatically from upstream outputs:
#   roks_cluster_name_or_id       ← ws1.openshift_cluster_name
#   cert_manager_namespace        ← ws2.cert_manager_namespace
#   flo_trusted_profile_id        ← ws3.flo_trusted_profile_id
#   flo_cluster_issuer_name       ← ws3.flo_cluster_issuer_name
#   flo_namespace (cneinstance)   ← ws3.flo_namespace
#   testing_transit_gateway_name  ← ws1.roks_transit_gateway_name
# ============================================================


# ============================================================
# Template Repo URLs (ws1–ws6)
# ============================================================

variable "roks_cluster_template_repo_url" {
  description = "GitHub URL for the ws1 ROKS cluster workspace template"
  type        = string
  default     = "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_roks_cluster_4_18"
}

variable "roks_cluster_template_repo_branch" {
  description = "GitHub branch for the ws1 ROKS cluster workspace template"
  type        = string
  default     = "main"
}

variable "cert_manager_template_repo_url" {
  description = "GitHub URL for the ws2 cert-manager workspace template"
  type        = string
  default     = "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_2_3_cert_manager"
}

variable "cert_manager_template_repo_branch" {
  description = "GitHub branch for the ws2 cert-manager workspace template"
  type        = string
  default     = "main"
}

variable "flo_template_repo_url" {
  description = "GitHub URL for the ws3 FLO workspace template"
  type        = string
  default     = "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_2_3_flo"
}

variable "flo_template_repo_branch" {
  description = "GitHub branch for the ws3 FLO workspace template"
  type        = string
  default     = "main"
}

variable "cneinstance_template_repo_url" {
  description = "GitHub URL for the ws4 CNEInstance workspace template"
  type        = string
  default     = "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_2_3_cneinstance"
}

variable "cneinstance_template_repo_branch" {
  description = "GitHub branch for the ws4 CNEInstance workspace template"
  type        = string
  default     = "main"
}

variable "license_template_repo_url" {
  description = "GitHub URL for the ws5 License workspace template"
  type        = string
  default     = "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_2_3_license"
}

variable "license_template_repo_branch" {
  description = "GitHub branch for the ws5 License workspace template"
  type        = string
  default     = "main"
}

variable "testing_template_repo_url" {
  description = "GitHub URL for the ws6 Testing workspace template"
  type        = string
  default     = "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_2_3_testing"
}

variable "testing_template_repo_branch" {
  description = "GitHub branch for the ws6 Testing workspace template"
  type        = string
  default     = "main"
}


# ============================================================
# IBM Cloud — Common (ws1–ws6)
# ============================================================

variable "ibmcloud_schematics_region" {
  description = "IBM Cloud region for the Schematics service (us-south, us-east, eu-gb, eu-de, ca-tor)"
  type        = string
  default     = "ca-tor"
}

variable "ibmcloud_api_key" {
  description = "IBM Cloud API Key"
  type        = string
  sensitive   = true
}

variable "ibmcloud_cluster_region" {
  description = "IBM Cloud region for all cluster resources"
  type        = string
  default     = "ca-tor"
}

variable "ibmcloud_resource_group" {
  description = "IBM Cloud Resource Group name (leave empty to use account default)"
  type        = string
  default     = "default"
}


# ============================================================
# ROKS Cluster (ws1)
# ============================================================

variable "create_roks_cluster" {
  description = "Create OpenShift ROKS cluster"
  type        = bool
  default     = true
}

variable "roks_cluster_id_or_name" {
  description = "ID or name of an existing ROKS cluster to use when create_roks_cluster is false"
  type        = string
  default     = ""
}

variable "create_roks_transit_gateway" {
  description = "Create Transit Gateway and VPC connections"
  type        = bool
  default     = true
}

variable "create_roks_registry_cos_instance" {
  description = "Create Cloud Object Storage instance for OpenShift registry"
  type        = bool
  default     = true
}

variable "roks_cluster_vpc_name" {
  description = "Name of the cluster VPC"
  type        = string
  default     = "tf-cluster-vpc"
}

variable "openshift_cluster_name" {
  description = "Name of the OpenShift cluster"
  type        = string
  default     = "tf-openshift-cluster"
}

variable "openshift_cluster_version" {
  description = "OpenShift cluster version (e.g. 4.18). Leave empty to use the latest available version."
  type        = string
  default     = "4.18"
}

variable "roks_workers_per_zone" {
  description = "Number of worker nodes per zone"
  type        = number
  default     = 1
}

variable "roks_min_worker_vcpu_count" {
  description = "Minimum vCPU count when auto-selecting the worker node flavor"
  type        = number
  default     = 16
}

variable "roks_min_worker_memory_gb" {
  description = "Minimum memory in GB when auto-selecting the worker node flavor"
  type        = number
  default     = 64
}

variable "roks_cos_instance_name" {
  description = "Name of the COS instance for the OpenShift image registry"
  type        = string
  default     = "tf-openshift-cos-instance"
}

# When create_roks_transit_gateway = true this name is passed to ws1 and the
# actual TGW name is wired through automatically from the ws1 output.
# When create_roks_transit_gateway = false AND testing_create_tgw_jumphost = true
# you MUST set this to the name of the existing Transit Gateway that is already
# connected to the cluster VPC — ws6 uses it to attach the client VPC.
variable "roks_transit_gateway_name" {
  description = "Name of the Transit Gateway. Must be set to an existing TGW name when create_roks_transit_gateway = false and testing_create_tgw_jumphost = true."
  type        = string
  default     = "tf-tgw"
}


# ============================================================
# cert-manager (ws2)
# ============================================================

variable "install_cert_manager" {
  description = "Install cert-manager via ws2. When false ws2 is skipped and cert_manager_namespace is passed directly to ws3."
  type        = bool
  default     = true
}

variable "cert_manager_namespace" {
  description = "Kubernetes namespace for cert-manager — passed to ws2 (if enabled) and ws3"
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.17.3"
}


# ============================================================
# COS Bucket — shared by FLO (ws3) and License (ws5)
# ============================================================

variable "ibmcloud_cos_bucket_region" {
  description = "IBM Cloud region where the COS bucket is located"
  type        = string
  default     = "us-south"
}

variable "ibmcloud_cos_instance_name" {
  description = "IBM Cloud COS instance name"
  type        = string
  default     = "bnk-orchestration"
}

variable "ibmcloud_resources_cos_bucket" {
  description = "IBM Cloud COS bucket containing FAR auth key and JWT files"
  type        = string
  default     = "bnk-schematics-resources"
}


# ============================================================
# FLO / CNEInstance / License (ws3–ws5)
# ============================================================

variable "deploy_bnk" {
  description = "Deploy BIG-IP Next for Kubernetes: FLO (ws3), CNEInstance (ws4), and License (ws5). When false all three workspaces are skipped."
  type        = bool
  default     = true
}

# ============================================================
# FLO — F5 Lifecycle Operator (ws3)
# ============================================================

variable "far_repo_url" {
  description = "FAR Repository URL for Docker and Helm registry"
  type        = string
  default     = "repo.f5.com"
}

variable "f5_bigip_k8s_manifest_version" {
  description = "Version of the f5-bigip-k8s-manifest chart (FLO/CIS versions are extracted from this)"
  type        = string
  default     = "2.3.0-bnpp-ehf-2-3.2598.3-0.0.17"
}


variable "f5_cne_far_auth_file" {
  description = "FAR auth key filename in the COS bucket (.tgz)"
  type        = string
  default     = "f5-far-auth-key.tgz"
}

variable "f5_cne_subscription_jwt_file" {
  description = "Subscription JWT filename in the COS bucket — used by FLO (ws3) and License (ws5)"
  type        = string
  default     = "trial.jwt"
}

variable "flo_namespace" {
  description = "Kubernetes namespace for the F5 Lifecycle Operator"
  type        = string
  default     = "f5-bnk"
}

variable "flo_utils_namespace" {
  description = "Kubernetes namespace for F5 utility components — used by FLO (ws3), CNEInstance (ws4), and License (ws5)"
  type        = string
  default     = "f5-utils"
}

variable "bigip_username" {
  description = "BIG-IP username for the CIS controller"
  type        = string
  default     = "admin"
}

variable "bigip_password" {
  description = "BIG-IP password for the CIS controller"
  type        = string
  default     = ""
  sensitive   = true
}

variable "bigip_url" {
  description = "BIG-IP URL for the CIS controller"
  type        = string
  default     = ""
}


# ============================================================
# CNEInstance (ws4)
# ============================================================

variable "cneinstance_deployment_size" {
  description = "Deployment size for CNEInstance (Small, Medium, Large)"
  type        = string
  default     = "Small"
}

variable "cneinstance_gslb_datacenter_name" {
  description = "GSLB datacenter name for CNEInstance (optional)"
  type        = string
  default     = ""
}


# ============================================================
# License (ws5)
# ============================================================

variable "license_mode" {
  description = "License operation mode (connected or disconnected)"
  type        = string
  default     = "connected"
}


# ============================================================
# Testing Jumphosts (ws6)
# ============================================================

variable "testing_create_tgw_jumphost" {
  description = "Create a jumphost in a client VPC and connect it to the cluster via the Transit Gateway"
  type        = bool
  default     = true
}

variable "testing_create_cluster_jumphosts" {
  description = "Create one jumphost per availability zone directly inside the cluster VPC"
  type        = bool
  default     = false
}

variable "testing_ssh_key_name" {
  description = "Name of the IBM Cloud SSH key to inject into all jumphosts"
  type        = string
  default     = ""
}

variable "testing_jumphost_profile" {
  description = "Instance profile for all jumphosts (leave empty to auto-select based on min_vcpu_count and min_memory_gb)"
  type        = string
  default     = ""
}

variable "testing_min_vcpu_count" {
  description = "Minimum vCPU count when auto-selecting the jumphost instance profile"
  type        = number
  default     = 4
}

variable "testing_min_memory_gb" {
  description = "Minimum memory in GB when auto-selecting the jumphost instance profile"
  type        = number
  default     = 8
}

variable "testing_create_client_vpc" {
  description = "Create a new client VPC for the TGW jumphost. When false, testing_client_vpc_name must reference an existing VPC"
  type        = bool
  default     = false
}

variable "testing_client_vpc_name" {
  description = "Name of the client VPC — created when testing_create_client_vpc = true, or looked up when false"
  type        = string
  default     = "tf-testing-vpc"
}

variable "testing_client_vpc_region" {
  description = "IBM Cloud region for the client VPC and TGW jumphost"
  type        = string
  default     = "ca-tor"
}

variable "testing_tgw_jumphost_name" {
  description = "Name of the TGW-connected jumphost instance"
  type        = string
  default     = "tf-testing-jumphost-tgw"
}

variable "testing_cluster_jumphost_name_prefix" {
  description = "Name prefix for cluster jumphosts — zone name is appended (<prefix>-<zone>)"
  type        = string
  default     = "tf-testing-jumphost-cluster"
}

variable "read_ws_outputs" {
  description = "Set to true after all sub-workspaces have been applied to propagate their outputs into downstream workspace configs. Defaults to false so the first apply succeeds before any sub-workspace has a statefile."
  type        = bool
  default     = false
}

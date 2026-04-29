# ============================================================
# F5 BIG-IP Next for Kubernetes 2.3 — Orchestration Workspace
#
# Execution order:
#   ws1  roks_cluster_4_18     — ROKS cluster + Transit Gateway
#   ws2  cert_manager          — cert-manager Helm install
#   ws3  flo                   — F5 Lifecycle Operator
#   ws4  cneinstance           — CNEInstance custom resource
#   ws5  license               — License custom resource
#   ws6  testing               — Jumphost infrastructure
#
# Plan  : workspaces planned ws1 → ws6
# Apply : workspaces applied ws1 → ws6
# Destroy: workspaces destroyed ws6 → ws1 (reverse depends_on order)
# ============================================================

# ============================================================
# Resource Group lookup
# ============================================================

data "ibm_resource_group" "rg" {
  name = var.ibmcloud_resource_group
}

# ============================================================
# WS1 — ROKS Cluster 4.18 + Transit Gateway
# ============================================================

resource "ibm_schematics_workspace" "ws1_roks_cluster" {
  name           = "bnk-23-roks-cluster${var.ws_name_suffix != "" ? "-${var.ws_name_suffix}" : ""}"
  description    = "ROKS 4.18 cluster and Transit Gateway"
  location       = var.ibmcloud_schematics_region
  resource_group = data.ibm_resource_group.rg.id
  template_type  = "terraform_v1.5"

  template_git_url    = var.roks_cluster_template_repo_url
  template_git_branch = var.roks_cluster_template_repo_branch
  template_git_folder = "."

  template_inputs {
    name   = "ibmcloud_api_key"
    value  = var.ibmcloud_api_key
    secure = true
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cluster_region"
    value  = var.ibmcloud_cluster_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_resource_group"
    value  = var.ibmcloud_resource_group
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "create_roks_cluster"
    value  = tostring(var.create_roks_cluster)
    secure = false
    type   = "bool"
  }
  template_inputs {
    name   = "create_roks_transit_gateway"
    value  = tostring(var.create_roks_transit_gateway)
    secure = false
    type   = "bool"
  }
  template_inputs {
    name   = "create_roks_registry_cos_instance"
    value  = tostring(var.create_roks_registry_cos_instance)
    secure = false
    type   = "bool"
  }
  template_inputs {
    name   = "roks_cluster_vpc_name"
    value  = var.roks_cluster_vpc_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "openshift_cluster_name"
    value  = var.openshift_cluster_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "openshift_cluster_version"
    value  = var.openshift_cluster_version
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "roks_workers_per_zone"
    value  = tostring(var.roks_workers_per_zone)
    secure = false
    type   = "number"
  }
  template_inputs {
    name   = "roks_min_worker_vcpu_count"
    value  = tostring(var.roks_min_worker_vcpu_count)
    secure = false
    type   = "number"
  }
  template_inputs {
    name   = "roks_min_worker_memory_gb"
    value  = tostring(var.roks_min_worker_memory_gb)
    secure = false
    type   = "number"
  }
  template_inputs {
    name   = "roks_cos_instance_name"
    value  = var.roks_cos_instance_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "roks_transit_gateway_name"
    value  = var.roks_transit_gateway_name
    secure = false
    type   = "string"
  }
}

data "ibm_schematics_output" "ws1_roks_cluster" {
  count        = var.read_ws_outputs ? 1 : 0
  workspace_id = ibm_schematics_workspace.ws1_roks_cluster.id
  template_id  = ibm_schematics_workspace.ws1_roks_cluster.runtime_data[0].id
  location     = var.ibmcloud_schematics_region
}

locals {
  ws1_outputs = var.read_ws_outputs ? try(data.ibm_schematics_output.ws1_roks_cluster[0].output_values, {}) : {}

  # Downstream wiring from ws1
  ws1_roks_cluster_name    = var.create_roks_cluster ? try(local.ws1_outputs["roks_cluster_name"], var.openshift_cluster_name) : var.roks_cluster_id_or_name
  ws1_transit_gateway_name = try(local.ws1_outputs["roks_transit_gateway_name"], var.roks_transit_gateway_name)
}

# ============================================================
# WS2 — cert-manager
# ============================================================

resource "ibm_schematics_workspace" "ws2_cert_manager" {
  count          = var.install_cert_manager ? 1 : 0
  name           = "bnk-23-cert-manager${var.ws_name_suffix != "" ? "-${var.ws_name_suffix}" : ""}"
  description    = "cert-manager Helm installation on ROKS cluster"
  location       = var.ibmcloud_schematics_region
  resource_group = data.ibm_resource_group.rg.id
  template_type  = "terraform_v1.5"

  template_git_url    = var.cert_manager_template_repo_url
  template_git_branch = var.cert_manager_template_repo_branch
  template_git_folder = "."

  template_inputs {
    name   = "ibmcloud_api_key"
    value  = var.ibmcloud_api_key
    secure = true
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cluster_region"
    value  = var.ibmcloud_cluster_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_resource_group"
    value  = var.ibmcloud_resource_group
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "roks_cluster_name_or_id"
    value  = local.ws1_roks_cluster_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "cert_manager_namespace"
    value  = var.cert_manager_namespace
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "cert_manager_version"
    value  = var.cert_manager_version
    secure = false
    type   = "string"
  }

  depends_on = [ibm_schematics_workspace.ws1_roks_cluster]
}

data "ibm_schematics_output" "ws2_cert_manager" {
  count        = (var.install_cert_manager && var.read_ws_outputs) ? 1 : 0
  workspace_id = ibm_schematics_workspace.ws2_cert_manager[0].id
  template_id  = ibm_schematics_workspace.ws2_cert_manager[0].runtime_data[0].id
  location     = var.ibmcloud_schematics_region
}

locals {
  ws2_outputs = (var.install_cert_manager && var.read_ws_outputs) ? try(data.ibm_schematics_output.ws2_cert_manager[0].output_values, {}) : {}
}

# ============================================================
# WS3 — F5 Lifecycle Operator (FLO)
# ============================================================

resource "ibm_schematics_workspace" "ws3_flo" {
  count          = var.deploy_bnk ? 1 : 0
  name           = "bnk-23-flo${var.ws_name_suffix != "" ? "-${var.ws_name_suffix}" : ""}"
  description    = "F5 Lifecycle Operator deployment"
  location       = var.ibmcloud_schematics_region
  resource_group = data.ibm_resource_group.rg.id
  template_type  = "terraform_v1.5"

  template_git_url    = var.flo_template_repo_url
  template_git_branch = var.flo_template_repo_branch
  template_git_folder = "."

  template_inputs {
    name   = "ibmcloud_api_key"
    value  = var.ibmcloud_api_key
    secure = true
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cluster_region"
    value  = var.ibmcloud_cluster_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_resource_group"
    value  = var.ibmcloud_resource_group
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "roks_cluster_name_or_id"
    value  = local.ws1_roks_cluster_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "cert_manager_namespace"
    value  = var.cert_manager_namespace
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "far_repo_url"
    value  = var.far_repo_url
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "f5_bigip_k8s_manifest_version"
    value  = var.f5_bigip_k8s_manifest_version
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "use_cos_bucket"
    value  = "true"
    secure = false
    type   = "bool"
  }
  template_inputs {
    name   = "ibmcloud_cos_bucket_region"
    value  = var.ibmcloud_cos_bucket_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cos_instance_name"
    value  = var.ibmcloud_cos_instance_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_resources_cos_bucket"
    value  = var.ibmcloud_resources_cos_bucket
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "f5_cne_far_auth_file"
    value  = var.f5_cne_far_auth_file
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "f5_cne_subscription_jwt_file"
    value  = var.f5_cne_subscription_jwt_file
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "flo_namespace"
    value  = var.flo_namespace
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "flo_utils_namespace"
    value  = var.flo_utils_namespace
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "bigip_username"
    value  = var.bigip_username
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "bigip_password"
    value  = var.bigip_password
    secure = true
    type   = "string"
  }
  template_inputs {
    name   = "bigip_url"
    value  = var.bigip_url
    secure = false
    type   = "string"
  }

  depends_on = [ibm_schematics_workspace.ws2_cert_manager]
}

data "ibm_schematics_output" "ws3_flo" {
  count        = (var.deploy_bnk && var.read_ws_outputs) ? 1 : 0
  workspace_id = ibm_schematics_workspace.ws3_flo[0].id
  template_id  = ibm_schematics_workspace.ws3_flo[0].runtime_data[0].id
  location     = var.ibmcloud_schematics_region
}

locals {
  ws3_outputs = (var.deploy_bnk && var.read_ws_outputs) ? try(data.ibm_schematics_output.ws3_flo[0].output_values, {}) : {}

  # Downstream wiring from ws3 — fall back to root variables when ws3 is skipped
  ws3_flo_namespace                   = try(local.ws3_outputs["flo_namespace"], var.flo_namespace)
  ws3_flo_trusted_profile_id          = try(local.ws3_outputs["flo_trusted_profile_id"], var.flo_trusted_profile_id)
  ws3_flo_cluster_issuer_name         = try(local.ws3_outputs["flo_cluster_issuer_name"], var.flo_cluster_issuer_name)
  ws3_cneinstance_network_attachments = try(
    jsondecode(local.ws3_outputs["cneinstance_network_attachments"]),
    var.cneinstance_network_attachments != "" ? jsondecode(var.cneinstance_network_attachments) : ["ens3-ipvlan-l2", "macvlan-conf"]
  )
}

# ============================================================
# WS4 — CNEInstance
# ============================================================

resource "ibm_schematics_workspace" "ws4_cneinstance" {
  count          = var.deploy_bnk ? 1 : 0
  name           = "bnk-23-cneinstance${var.ws_name_suffix != "" ? "-${var.ws_name_suffix}" : ""}"
  description    = "F5 CNEInstance custom resource deployment"
  location       = var.ibmcloud_schematics_region
  resource_group = data.ibm_resource_group.rg.id
  template_type  = "terraform_v1.5"

  template_git_url    = var.cneinstance_template_repo_url
  template_git_branch = var.cneinstance_template_repo_branch
  template_git_folder = "."

  template_inputs {
    name   = "ibmcloud_api_key"
    value  = var.ibmcloud_api_key
    secure = true
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cluster_region"
    value  = var.ibmcloud_cluster_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_resource_group"
    value  = var.ibmcloud_resource_group
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "roks_cluster_name_or_id"
    value  = local.ws1_roks_cluster_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "far_repo_url"
    value  = var.far_repo_url
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "flo_namespace"
    value  = local.ws3_flo_namespace
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "flo_utils_namespace"
    value  = var.flo_utils_namespace
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "f5_bigip_k8s_manifest_version"
    value  = var.f5_bigip_k8s_manifest_version
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "flo_trusted_profile_id"
    value  = local.ws3_flo_trusted_profile_id
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "flo_cluster_issuer_name"
    value  = local.ws3_flo_cluster_issuer_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "cneinstance_deployment_size"
    value  = var.cneinstance_deployment_size
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "cneinstance_gslb_datacenter_name"
    value  = var.cneinstance_gslb_datacenter_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "cneinstance_network_attachments"
    value  = jsonencode(local.ws3_cneinstance_network_attachments)
    secure = false
    type   = "list(string)"
  }

  depends_on = [ibm_schematics_workspace.ws3_flo]
}

data "ibm_schematics_output" "ws4_cneinstance" {
  count        = (var.deploy_bnk && var.read_ws_outputs) ? 1 : 0
  workspace_id = ibm_schematics_workspace.ws4_cneinstance[0].id
  template_id  = ibm_schematics_workspace.ws4_cneinstance[0].runtime_data[0].id
  location     = var.ibmcloud_schematics_region
}

locals {
  ws4_outputs = (var.deploy_bnk && var.read_ws_outputs) ? try(data.ibm_schematics_output.ws4_cneinstance[0].output_values, {}) : {}
}

# ============================================================
# WS5 — License
# ============================================================

resource "ibm_schematics_workspace" "ws5_license" {
  count          = var.deploy_bnk ? 1 : 0
  name           = "bnk-23-license${var.ws_name_suffix != "" ? "-${var.ws_name_suffix}" : ""}"
  description    = "F5 CNE License custom resource"
  location       = var.ibmcloud_schematics_region
  resource_group = data.ibm_resource_group.rg.id
  template_type  = "terraform_v1.5"

  template_git_url    = var.license_template_repo_url
  template_git_branch = var.license_template_repo_branch
  template_git_folder = "."

  template_inputs {
    name   = "ibmcloud_api_key"
    value  = var.ibmcloud_api_key
    secure = true
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cluster_region"
    value  = var.ibmcloud_cluster_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_resource_group"
    value  = var.ibmcloud_resource_group
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cos_bucket_region"
    value  = var.ibmcloud_cos_bucket_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cos_instance_name"
    value  = var.ibmcloud_cos_instance_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_resources_cos_bucket"
    value  = var.ibmcloud_resources_cos_bucket
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "roks_cluster_name_or_id"
    value  = local.ws1_roks_cluster_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "flo_utils_namespace"
    value  = var.flo_utils_namespace
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "f5_cne_subscription_jwt_file"
    value  = var.f5_cne_subscription_jwt_file
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "license_mode"
    value  = var.license_mode
    secure = false
    type   = "string"
  }

  depends_on = [ibm_schematics_workspace.ws4_cneinstance]
}

data "ibm_schematics_output" "ws5_license" {
  count        = (var.deploy_bnk && var.read_ws_outputs) ? 1 : 0
  workspace_id = ibm_schematics_workspace.ws5_license[0].id
  template_id  = ibm_schematics_workspace.ws5_license[0].runtime_data[0].id
  location     = var.ibmcloud_schematics_region
}

locals {
  ws5_outputs = (var.deploy_bnk && var.read_ws_outputs) ? try(data.ibm_schematics_output.ws5_license[0].output_values, {}) : {}
}

# ============================================================
# WS6 — Testing Jumphosts
# ============================================================

resource "ibm_schematics_workspace" "ws6_testing" {
  name           = "bnk-23-testing${var.ws_name_suffix != "" ? "-${var.ws_name_suffix}" : ""}"
  description    = "Jumphost infrastructure for BNK testing"
  location       = var.ibmcloud_schematics_region
  resource_group = data.ibm_resource_group.rg.id
  template_type  = "terraform_v1.5"

  template_git_url    = var.testing_template_repo_url
  template_git_branch = var.testing_template_repo_branch
  template_git_folder = "."

  template_inputs {
    name   = "ibmcloud_api_key"
    value  = var.ibmcloud_api_key
    secure = true
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_cluster_region"
    value  = var.ibmcloud_cluster_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "ibmcloud_resource_group"
    value  = var.ibmcloud_resource_group
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "roks_cluster_name_or_id"
    value  = local.ws1_roks_cluster_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "testing_transit_gateway_name"
    value  = local.ws1_transit_gateway_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "testing_create_tgw_jumphost"
    value  = tostring(var.testing_create_tgw_jumphost)
    secure = false
    type   = "bool"
  }
  template_inputs {
    name   = "testing_create_cluster_jumphosts"
    value  = tostring(var.testing_create_cluster_jumphosts)
    secure = false
    type   = "bool"
  }
  template_inputs {
    name   = "testing_ssh_key_name"
    value  = var.testing_ssh_key_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "testing_jumphost_profile"
    value  = var.testing_jumphost_profile
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "testing_min_vcpu_count"
    value  = tostring(var.testing_min_vcpu_count)
    secure = false
    type   = "number"
  }
  template_inputs {
    name   = "testing_min_memory_gb"
    value  = tostring(var.testing_min_memory_gb)
    secure = false
    type   = "number"
  }
  template_inputs {
    name   = "testing_create_client_vpc"
    value  = tostring(var.testing_create_client_vpc)
    secure = false
    type   = "bool"
  }
  template_inputs {
    name   = "testing_client_vpc_name"
    value  = var.testing_client_vpc_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "testing_client_vpc_region"
    value  = var.testing_client_vpc_region
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "testing_tgw_jumphost_name"
    value  = var.testing_tgw_jumphost_name
    secure = false
    type   = "string"
  }
  template_inputs {
    name   = "testing_cluster_jumphost_name_prefix"
    value  = var.testing_cluster_jumphost_name_prefix
    secure = false
    type   = "string"
  }

  depends_on = [ibm_schematics_workspace.ws5_license]
}

data "ibm_schematics_output" "ws6_testing" {
  count        = var.read_ws_outputs ? 1 : 0
  workspace_id = ibm_schematics_workspace.ws6_testing.id
  template_id  = ibm_schematics_workspace.ws6_testing.runtime_data[0].id
  location     = var.ibmcloud_schematics_region
}

locals {
  ws6_outputs = var.read_ws_outputs ? try(data.ibm_schematics_output.ws6_testing[0].output_values, {}) : {}
}

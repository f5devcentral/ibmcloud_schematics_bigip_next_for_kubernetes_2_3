# ============================================================
# Schematics Job Orchestration
#
# Plan jobs  : ws1 → ws2 → ws3 → ws4 → ws5 → ws6 (sequential)
# Apply jobs : ws1 → ws2 → ws3 → ws4 → ws5 → ws6 (sequential)
# Destroy    : driven by reverse depends_on order on workspace
#              resources — ws6 → ws5 → ws4 → ws3 → ws2 → ws1
#
# Each job resource has a lifecycle.replace_triggered_by pointing
# at its workspace so that re-applying the orchestrator re-runs
# the jobs even if the workspace resource itself did not change.
# ============================================================

# ============================================================
# Plan jobs — ws1 → ws6
# ============================================================

resource "ibm_schematics_job" "plan_ws1" {
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws1_roks_cluster.id
  command_name      = "workspace_plan"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_workspace.ws1_roks_cluster]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws1_roks_cluster]
  }
}

resource "ibm_schematics_job" "plan_ws2" {
  count             = var.install_cert_manager ? 1 : 0
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws2_cert_manager[0].id
  command_name      = "workspace_plan"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.plan_ws1]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws2_cert_manager[0]]
  }
}

resource "ibm_schematics_job" "plan_ws3" {
  count             = var.deploy_bnk ? 1 : 0
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws3_flo[0].id
  command_name      = "workspace_plan"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.plan_ws2]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws3_flo[0]]
  }
}

resource "ibm_schematics_job" "plan_ws4" {
  count             = var.deploy_bnk ? 1 : 0
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws4_cneinstance[0].id
  command_name      = "workspace_plan"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.plan_ws3]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws4_cneinstance[0]]
  }
}

resource "ibm_schematics_job" "plan_ws5" {
  count             = var.deploy_bnk ? 1 : 0
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws5_license[0].id
  command_name      = "workspace_plan"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.plan_ws4]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws5_license[0]]
  }
}

resource "ibm_schematics_job" "plan_ws6" {
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws6_testing.id
  command_name      = "workspace_plan"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.plan_ws5]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws6_testing]

    precondition {
      condition = (
        !var.testing_create_tgw_jumphost ||
        var.create_roks_transit_gateway ||
        var.roks_transit_gateway_name != "tf-tgw"
      )
      error_message = "roks_transit_gateway_name must be set to the name of an existing Transit Gateway when testing_create_tgw_jumphost = true and create_roks_transit_gateway = false."
    }
  }
}

# ============================================================
# Apply jobs — ws1 → ws6 (each waits for the previous apply)
# ============================================================

resource "ibm_schematics_job" "apply_ws1" {
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws1_roks_cluster.id
  command_name      = "workspace_apply"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.plan_ws6]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws1_roks_cluster]
  }
}

resource "ibm_schematics_job" "apply_ws2" {
  count             = var.install_cert_manager ? 1 : 0
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws2_cert_manager[0].id
  command_name      = "workspace_apply"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.apply_ws1]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws2_cert_manager[0]]
  }
}

resource "ibm_schematics_job" "apply_ws3" {
  count             = var.deploy_bnk ? 1 : 0
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws3_flo[0].id
  command_name      = "workspace_apply"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.apply_ws2]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws3_flo[0]]
  }
}

resource "ibm_schematics_job" "apply_ws4" {
  count             = var.deploy_bnk ? 1 : 0
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws4_cneinstance[0].id
  command_name      = "workspace_apply"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.apply_ws3]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws4_cneinstance[0]]
  }
}

resource "ibm_schematics_job" "apply_ws5" {
  count             = var.deploy_bnk ? 1 : 0
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws5_license[0].id
  command_name      = "workspace_apply"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.apply_ws4]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws5_license[0]]
  }
}

resource "ibm_schematics_job" "apply_ws6" {
  command_object    = "workspace"
  command_object_id = ibm_schematics_workspace.ws6_testing.id
  command_name      = "workspace_apply"
  location          = var.ibmcloud_schematics_region

  depends_on = [ibm_schematics_job.apply_ws5]

  lifecycle {
    replace_triggered_by = [ibm_schematics_workspace.ws6_testing]
  }
}

# ============================================================
# Destroy jobs — ws6 → ws1 (reverse order)
#
# These jobs run workspace_destroy on each sub-workspace before
# Terraform removes the ibm_schematics_workspace resource itself.
# The destroy provisioner fires when the null_resource is destroyed,
# which happens before the workspace resource it references because
# each null_resource depends_on its workspace.
# ============================================================

resource "null_resource" "destroy_ws6" {
  triggers = {
    workspace_id          = ibm_schematics_workspace.ws6_testing.id
    schematics_region     = var.ibmcloud_schematics_region
    ibmcloud_api_key      = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -sf -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}'
    EOT
  }

  depends_on = [ibm_schematics_workspace.ws6_testing]
}

resource "null_resource" "destroy_ws5" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws5_license[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -sf -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}'
    EOT
  }

  depends_on = [null_resource.destroy_ws6, ibm_schematics_workspace.ws5_license]
}

resource "null_resource" "destroy_ws4" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws4_cneinstance[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -sf -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}'
    EOT
  }

  depends_on = [null_resource.destroy_ws5, ibm_schematics_workspace.ws4_cneinstance]
}

resource "null_resource" "destroy_ws3" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws3_flo[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -sf -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}'
    EOT
  }

  depends_on = [null_resource.destroy_ws4, ibm_schematics_workspace.ws3_flo]
}

resource "null_resource" "destroy_ws2" {
  count = var.install_cert_manager ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws2_cert_manager[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -sf -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}'
    EOT
  }

  depends_on = [null_resource.destroy_ws3, ibm_schematics_workspace.ws2_cert_manager]
}

resource "null_resource" "destroy_ws1" {
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws1_roks_cluster.id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -sf -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}'
    EOT
  }

  depends_on = [null_resource.destroy_ws2, ibm_schematics_workspace.ws1_roks_cluster]
}

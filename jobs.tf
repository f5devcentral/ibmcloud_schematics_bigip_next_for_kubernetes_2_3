# ============================================================
# Schematics Job Orchestration
#
# Plan jobs  : ws1 → ws2 → ws3 → ws4 → ws5 → ws6 (sequential triggers)
# Apply jobs : ws1 → ws2 → ws3 → ws4 → ws5 → ws6 (sequential triggers)
# Destroy    : driven by reverse depends_on order — ws6 → ws5 → ws4 → ws3 → ws2 → ws1
#
# Plan and apply are triggered via the IBM Schematics workspace v1 API
# (POST /plan, PUT /apply) and fire-and-forget. Progress is visible in
# the IBM Cloud Schematics console for each sub-workspace.
# ============================================================

# ============================================================
# Plan jobs — ws1 → ws6
# ============================================================

resource "null_resource" "plan_ws1" {
  count = var.create_roks_cluster ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws1_roks_cluster[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X POST \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/plan" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [ibm_schematics_workspace.ws1_roks_cluster]
}

resource "null_resource" "plan_ws2" {
  count = var.install_cert_manager ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws2_cert_manager[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X POST \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/plan" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.plan_ws1]
}

resource "null_resource" "plan_ws3" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws3_flo[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X POST \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/plan" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.plan_ws2]
}

resource "null_resource" "plan_ws4" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws4_cneinstance[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X POST \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/plan" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.plan_ws3]
}

resource "null_resource" "plan_ws5" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws5_license[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X POST \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/plan" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.plan_ws4]
}

resource "null_resource" "plan_ws6" {
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws6_testing.id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X POST \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/plan" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.plan_ws5]

  lifecycle {
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
# Apply jobs — ws1 → ws6 (each waits for the previous apply trigger)
# ============================================================

resource "null_resource" "apply_ws1" {
  count = var.create_roks_cluster ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws1_roks_cluster[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/apply" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.plan_ws6]
}

resource "null_resource" "apply_ws2" {
  count = var.install_cert_manager ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws2_cert_manager[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/apply" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.apply_ws1]
}

resource "null_resource" "apply_ws3" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws3_flo[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/apply" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.apply_ws2]
}

resource "null_resource" "apply_ws4" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws4_cneinstance[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/apply" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.apply_ws3]
}

resource "null_resource" "apply_ws5" {
  count = var.deploy_bnk ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws5_license[0].id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/apply" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.apply_ws4]
}

resource "null_resource" "apply_ws6" {
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws6_testing.id
    schematics_region = var.ibmcloud_schematics_region
    ibmcloud_api_key  = var.ibmcloud_api_key
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(curl -sf -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${self.triggers.ibmcloud_api_key}" \
        | tr -d '\n' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/apply" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
    EOT
  }

  depends_on = [null_resource.apply_ws5]
}

# ============================================================
# Destroy jobs — ws6 → ws1 (reverse order)
#
# Destroy provisioners fire when the null_resource is destroyed,
# before Terraform removes the ibm_schematics_workspace resource.
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
      ws_poll() {
        curl -s \
          "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}" \
          -H "Authorization: Bearer $TOKEN"
      }
      ws_locked() { ws_poll | grep -A5 '"workspace_status"' | grep -c '"locked" *: *true' || true; }
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
      sleep 15
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
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
      ws_poll() {
        curl -s \
          "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}" \
          -H "Authorization: Bearer $TOKEN"
      }
      ws_locked() { ws_poll | grep -A5 '"workspace_status"' | grep -c '"locked" *: *true' || true; }
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
      sleep 15
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
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
      ws_poll() {
        curl -s \
          "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}" \
          -H "Authorization: Bearer $TOKEN"
      }
      ws_locked() { ws_poll | grep -A5 '"workspace_status"' | grep -c '"locked" *: *true' || true; }
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
      sleep 15
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
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
      ws_poll() {
        curl -s \
          "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}" \
          -H "Authorization: Bearer $TOKEN"
      }
      ws_locked() { ws_poll | grep -A5 '"workspace_status"' | grep -c '"locked" *: *true' || true; }
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
      sleep 15
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
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
      ws_poll() {
        curl -s \
          "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}" \
          -H "Authorization: Bearer $TOKEN"
      }
      ws_locked() { ws_poll | grep -A5 '"workspace_status"' | grep -c '"locked" *: *true' || true; }
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
      sleep 15
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
    EOT
  }

  depends_on = [null_resource.destroy_ws3, ibm_schematics_workspace.ws2_cert_manager]
}

resource "null_resource" "destroy_ws1" {
  count = var.create_roks_cluster ? 1 : 0
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws1_roks_cluster[0].id
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
      ws_poll() {
        curl -s \
          "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}" \
          -H "Authorization: Bearer $TOKEN"
      }
      ws_locked() { ws_poll | grep -A5 '"workspace_status"' | grep -c '"locked" *: *true' || true; }
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
      curl -s -X PUT \
        "https://${self.triggers.schematics_region}.schematics.cloud.ibm.com/v1/workspaces/${self.triggers.workspace_id}/destroy" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' || true
      sleep 15
      for i in $(seq 1 360); do
        [ "$(ws_locked)" = "0" ] && break
        sleep 10
      done
    EOT
  }

  depends_on = [null_resource.destroy_ws2, ibm_schematics_workspace.ws1_roks_cluster]
}

# ============================================================
# Schematics Sub-Workspace Destroy Hooks
#
# Reverse-order teardown: ws6 → ws5 → ws4 → ws3 → ws2 → ws1.
#
# Each null_resource.destroy_wsN carries a when=destroy provisioner that
# calls the IBM Schematics workspace v1 API (PUT /destroy) before Terraform
# removes the parent ibm_schematics_workspace resource. The provisioner
# polls the destroy job to completion so teardown is ordered correctly.
#
# Plan and apply of sub-workspaces are NOT driven from here — they are
# orchestrated externally (all_in_one.sh / schematics_runner.py) via the
# Schematics CLI, which interleaves plan→apply per workspace and waits
# for each to complete. Embedding plan/apply provisioners here would
# fire-and-forget and let downstream plans run before upstream applies
# finish — failing because data sources read live cluster state at plan time.
# ============================================================

resource "null_resource" "destroy_ws6" {
  triggers = {
    workspace_id      = ibm_schematics_workspace.ws6_testing.id
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

  depends_on = [null_resource.destroy_ws5, ibm_schematics_workspace.ws6_testing]
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

  depends_on = [null_resource.destroy_ws4, ibm_schematics_workspace.ws5_license]
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

  depends_on = [null_resource.destroy_ws3, ibm_schematics_workspace.ws4_cneinstance]
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

  depends_on = [null_resource.destroy_ws2, ibm_schematics_workspace.ws3_flo]
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

  depends_on = [null_resource.destroy_ws1, ibm_schematics_workspace.ws2_cert_manager]
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

  depends_on = [ibm_schematics_workspace.ws1_roks_cluster]
}

#!/usr/bin/env bash
# ============================================================
# deploy.sh — BIG-IP Next for Kubernetes 2.3
#
# Runs a full end-to-end deployment (or teardown) using the
# local Terraform application + ibmcloud Schematics CLI.
#
# What it does:
#   1.  terraform init
#   2.  terraform apply -target  (workspace records + destroy hooks only;
#       skips jobs.tf fire-and-forget plan/apply null_resources)
#   3.  Interleaved plan→apply for ws1→ws6 via ibmcloud schematics CLI,
#       polling each job to completion before starting the next
#   4.  After ws3 apply: patch ws4 variablestore with ws3 outputs
#       (flo_trusted_profile_id, flo_cluster_issuer_name,
#        cneinstance_network_attachments)
#   5.  terraform apply -target (data sources, read_ws_outputs=true)
#       so terraform output shows the final deployed values
#
# Why skip jobs.tf for plan/apply:
#   jobs.tf provisioners are fire-and-forget.  They POST to the Schematics
#   API to kick off each job but do not wait for completion, so downstream
#   workspaces get planned before upstream ones are applied — which fails
#   because data sources (e.g. ibm_container_cluster_config) read live
#   cluster state at plan time.
#
# Teardown:
#   ./deploy.sh --destroy        (runs terraform destroy)
#   The null_resource.destroy_wsN hooks created in step 2 fire the
#   Schematics destroy API for ws6→ws1 in the correct reverse order.
#
# Usage:
#   ./deploy.sh [terraform.tfvars] [--destroy]
#
# Prerequisites:
#   terraform >= 1.5,  ibmcloud CLI + schematics plugin,  python3
#   ibmcloud login --apikey $API_KEY -r $REGION
# ============================================================

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────
TFVARS="terraform.tfvars"
MODE="deploy"
for arg in "$@"; do
    case "$arg" in
        --destroy)   MODE="destroy" ;;
        --help|-h)   grep '^#' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
        *)           TFVARS="$arg" ;;
    esac
done

# ── Tunable constants ────────────────────────────────────────
readonly POLL_INTERVAL=30     # seconds between status polls
readonly JOB_TIMEOUT=18000    # 300 min — per sub-workspace job
readonly WS1_TIMEOUT=18000    # ROKS cluster can run close to 3 h
readonly PLAN_RETRIES=2       # extra plan attempts on failure
readonly PLAN_RETRY_WAIT=60   # seconds between plan retries
readonly DESTROY_RETRIES=2    # extra destroy attempts on failure
readonly READY_TIMEOUT=300    # seconds to wait for workspace to unlock
readonly WS4_PRE_PLAN_WAIT=180  # seconds after ws3 apply before planning ws4

# ── Log setup ────────────────────────────────────────────────
LOG_DIR="deploy-logs"
mkdir -p "$LOG_DIR"
TS=$(date -u +%Y%m%d_%H%M%S)
readonly LOG_FILE="$LOG_DIR/deploy_${TS}.log"

log() {
    printf '\n%s  %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"
}

section() {
    local bar; printf -v bar '%0.s─' {1..72}
    printf '\n%s\n  %s\n%s\n' "$bar" "$*" "$bar" | tee -a "$LOG_FILE"
}

die() {
    printf '\nFATAL: %s\n' "$*" | tee -a "$LOG_FILE" >&2
    printf '\nTo destroy partially-created resources:\n  terraform destroy -auto-approve\n' >&2
    exit 1
}

# ── Workspace status helpers ─────────────────────────────────

ws_status() {
    ibmcloud schematics workspace get --id "$1" --output json 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('status') or d.get('workspace_status_msg',{}).get('status_code','UNKNOWN'))
except Exception:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN"
}

ws_locked() {
    ibmcloud schematics workspace get --id "$1" --output json 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(str(d.get('workspace_status',{}).get('locked', True)).lower())
except Exception:
    print('true')
" 2>/dev/null || echo "true"
}

# Poll until workspace is unlocked and in a stable status.
wait_ready() {
    local ws_id="$1" label="$2" elapsed=0
    while (( elapsed < READY_TIMEOUT )); do
        local status locked
        status=$(ws_status "$ws_id")
        locked=$(ws_locked "$ws_id")
        # FAILED is always stable — stop waiting whether locked or not
        if [[ "$status" == "FAILED" ]]; then
            printf '\n'; return 0
        fi
        if [[ "$status" =~ ^(INACTIVE|ACTIVE|DRAFT)$ && "$locked" == "false" ]]; then
            printf '\n'; return 0
        fi
        printf '\r  [ready: %-20s] %3ds  status=%-10s  locked=%s    ' \
            "$label" "$elapsed" "$status" "$locked"
        sleep 10
        (( elapsed += 10 ))
    done
    printf '\n'
    log "WARNING: $label not ready after ${READY_TIMEOUT}s — proceeding anyway"
}

# Poll workspace status until it reaches a terminal state or times out.
# Prints the final status string to stdout.
poll_terminal() {
    local ws_id="$1" label="$2" timeout="${3:-$JOB_TIMEOUT}"
    local elapsed=0
    while (( elapsed < timeout )); do
        local status
        status=$(ws_status "$ws_id")
        if [[ "$status" =~ ^(INACTIVE|ACTIVE|FAILED|STOPPED|DRAFT)$ ]]; then
            printf '\n'
            echo "$status"
            return 0
        fi
        printf '\r  [%-22s] %5ds  status=%-10s    ' "$label" "$elapsed" "$status"
        sleep "$POLL_INTERVAL"
        (( elapsed += POLL_INTERVAL ))
    done
    printf '\n'
    echo "TIMEOUT"
}

# After submitting a job, wait up to 120 s for the workspace status to change
# away from pre_status before beginning terminal polling.  Without this,
# poll_terminal sees the pre-submission INACTIVE status on the first check,
# treats it as a completed job, and returns immediately — the job never ran.
wait_for_transition() {
    local ws_id="$1" pre_status="$2" label="$3"
    local elapsed=0
    while (( elapsed < 120 )); do
        local status
        status=$(ws_status "$ws_id")
        if [[ "$status" != "$pre_status" ]]; then
            printf '\n'; return 0
        fi
        printf '\r  [%-22s] %3ds  waiting for job to start (status=%s)    ' \
            "$label" "$elapsed" "$status"
        sleep 5
        (( elapsed += 5 ))
    done
    printf '\n'
    log "WARNING: $label status did not change from $pre_status after 120s — proceeding"
}

# ── Job runners ──────────────────────────────────────────────

# Submit a plan job; retry up to PLAN_RETRIES times on failure.
# Returns 0 on INACTIVE/ACTIVE, calls die on exhausted retries.
run_plan() {
    local ws_id="$1" label="$2"
    local attempt=0 status=""
    while (( attempt <= PLAN_RETRIES )); do
        if (( attempt > 0 )); then
            log "Plan $label FAILED — waiting ${PLAN_RETRY_WAIT}s then retrying (attempt $attempt/$PLAN_RETRIES)..."
            sleep "$PLAN_RETRY_WAIT"
            wait_ready "$ws_id" "$label"
        fi
        local pre_status
        pre_status=$(ws_status "$ws_id")
        log "Submitting plan: $label"
        ibmcloud schematics plan --id "$ws_id" --output json \
            >> "$LOG_FILE" 2>&1 \
            || { log "ERROR: plan submission failed for $label"; attempt=$(( attempt + 1 )); continue; }
        wait_for_transition "$ws_id" "$pre_status" "plan/$label"
        status=$(poll_terminal "$ws_id" "plan/$label")
        log "Plan $label: $status"
        [[ "$status" =~ ^(INACTIVE|ACTIVE)$ ]] && return 0
        attempt=$(( attempt + 1 ))
    done
    die "Plan $label failed after $((PLAN_RETRIES + 1)) attempts (last status: $status)"
}

# Submit an apply job and wait for completion.
# Calls die if the final status is not ACTIVE.
run_apply() {
    local ws_id="$1" label="$2" timeout="${3:-$JOB_TIMEOUT}"
    # Ensure the workspace is unlocked and stable before submitting the apply.
    # The plan may have just finished and the lock-release can lag the status.
    wait_ready "$ws_id" "$label"
    local pre_status
    pre_status=$(ws_status "$ws_id")
    log "Submitting apply: $label"
    ibmcloud schematics apply --id "$ws_id" --force --output json \
        >> "$LOG_FILE" 2>&1 \
        || die "Apply submission failed for $label"
    wait_for_transition "$ws_id" "$pre_status" "apply/$label"
    local status
    status=$(poll_terminal "$ws_id" "apply/$label" "$timeout")
    log "Apply $label: $status"
    [[ "$status" == "ACTIVE" ]] \
        || die "Apply $label ended with status '$status' (expected ACTIVE)"
}

# Submit a destroy job; retry up to DESTROY_RETRIES times on failure.
# Calls die on exhausted retries.
run_destroy() {
    local ws_id="$1" label="$2" timeout="${3:-$JOB_TIMEOUT}"
    local attempt=0 status=""
    while (( attempt <= DESTROY_RETRIES )); do
        if (( attempt > 0 )); then
            log "Destroy $label FAILED — waiting 30s then retrying (attempt $attempt/$DESTROY_RETRIES)..."
            sleep 30
            wait_ready "$ws_id" "$label"
        fi
        log "Submitting destroy: $label"
        local pre_status
        pre_status=$(ws_status "$ws_id")
        ibmcloud schematics destroy --id "$ws_id" --force --output json \
            >> "$LOG_FILE" 2>&1 \
            || { log "ERROR: destroy submission failed for $label"; attempt=$(( attempt + 1 )); continue; }
        wait_for_transition "$ws_id" "$pre_status" "destroy/$label"
        status=$(poll_terminal "$ws_id" "destroy/$label" "$timeout")
        log "Destroy $label: $status"
        [[ "$status" =~ ^(INACTIVE|DRAFT)$ ]] && return 0
        attempt=$(( attempt + 1 ))
    done
    die "Destroy $label failed after $((DESTROY_RETRIES + 1)) attempts (last status: $status)"
}

# ── Terraform state helpers ───────────────────────────────────

# Return the Schematics workspace ID for a given resource address.
# Prints empty string when the resource is not in state (disabled by count=0).
get_ws_id() {
    local address="$1"
    terraform show -json 2>/dev/null \
    | python3 -c "
import sys, json
try:
    for r in json.load(sys.stdin)['values']['root_module']['resources']:
        if r['address'] == '$address':
            print(r['values'].get('id',''))
            sys.exit(0)
except Exception:
    pass
" 2>/dev/null || true
}

# ── ws3 → ws4 output wiring ──────────────────────────────────

# Read ws3 (FLO) outputs and inject them into ws4 (CNEInstance) variablestore.
# flo_trusted_profile_id, flo_cluster_issuer_name, and
# cneinstance_network_attachments are empty when the orchestration workspace
# first creates ws4 (read_ws_outputs=false at that time).  We patch them
# directly via the Schematics workspace update API to avoid re-applying the
# orchestration workspace, which would fail because ws4/ws5/ws6 have no
# statefiles yet and their output data sources would error.
wire_ws3_to_ws4() {
    local ws3_id="$1" ws4_id="$2"

    section "Wiring ws3 (FLO) outputs into ws4 (CNEInstance) variablestore"

    # Write the Python logic to a temp file — avoids heredoc quoting issues
    # when ws3 output values contain characters that would confuse the shell.
    local py; py=$(mktemp /tmp/bnk_wire_XXXXXX.py)
    cat > "$py" << 'PYEOF'
#!/usr/bin/env python3
"""
Reads ws3 outputs via ibmcloud CLI, patches ws4 variablestore, and prints
the JSON update payload to stdout.

Required env vars: WS3_ID, WS4_ID, TFVARS
"""
import ast, json, os, re, subprocess, sys

def ibmcloud_json(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"command failed: {cmd}\n{(r.stderr or r.stdout).strip()}")
    return json.loads(r.stdout)

def fetch_outputs(ws_id):
    """Fetch workspace outputs; handles both API response formats."""
    data  = ibmcloud_json(f"ibmcloud schematics output --id {ws_id} --output json")
    items = data if isinstance(data, list) else [data]
    out   = {}
    for tmpl in items:
        for v in tmpl.get("output_values", []):
            if not isinstance(v, dict):
                continue
            if "name" in v:
                out[v["name"]] = v.get("value", "")
            else:
                for name, val in v.items():
                    if isinstance(val, dict):
                        out[name] = val.get("value", "")
                    elif isinstance(val, list):
                        out[name] = json.dumps(val)
                    else:
                        out[name] = str(val) if val is not None else ""
    return out

def parse_tfvars(path):
    """Return {name: value} from a tfvars file (plaintext only, for secure vars)."""
    result = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                m = re.match(r'^(\w+)\s*=\s*(.+)$', line)
                if m:
                    result[m.group(1)] = m.group(2).strip().strip('"')
    except Exception:
        pass
    return result

ws3_id = os.environ["WS3_ID"]
ws4_id = os.environ["WS4_ID"]
tfvars = parse_tfvars(os.environ.get("TFVARS", "terraform.tfvars"))

# Read the three values FLO produces that CNEInstance needs.
ws3_out = fetch_outputs(ws3_id)
flo_trusted_profile_id  = ws3_out.get("flo_trusted_profile_id", "")
flo_cluster_issuer_name = ws3_out.get("flo_cluster_issuer_name", "")

if not flo_trusted_profile_id:
    raise RuntimeError(
        "ws3 output flo_trusted_profile_id is empty — FLO may not have applied successfully"
    )
print(f"  flo_trusted_profile_id  : {flo_trusted_profile_id}", file=sys.stderr)
print(f"  flo_cluster_issuer_name : {flo_cluster_issuer_name}", file=sys.stderr)

# Normalise cneinstance_network_attachments to a JSON string.
raw_na = ws3_out.get("cneinstance_network_attachments")
if raw_na is None:
    cneinstance_network_attachments = None
elif isinstance(raw_na, list):
    cneinstance_network_attachments = json.dumps(raw_na)
else:
    try:
        cneinstance_network_attachments = json.dumps(json.loads(raw_na))
    except (json.JSONDecodeError, TypeError):
        try:
            cneinstance_network_attachments = json.dumps(ast.literal_eval(raw_na))
        except Exception:
            cneinstance_network_attachments = raw_na  # keep as-is; best effort

patch = {
    "flo_trusted_profile_id":  flo_trusted_profile_id,
    "flo_cluster_issuer_name": flo_cluster_issuer_name,
}
if cneinstance_network_attachments is not None:
    patch["cneinstance_network_attachments"] = cneinstance_network_attachments

# Fetch ws4's current workspace definition so we can rebuild its variablestore.
ws4_data    = ibmcloud_json(f"ibmcloud schematics workspace get --id {ws4_id} --output json")
td          = ws4_data.get("template_data", [{}])[0]
template_id = td.get("id", "")
folder      = td.get("folder", ".")
tf_type     = td.get("type", "terraform_v1.5")

# Rebuild variablestore: patch ws3-sourced values, preserve secure variable
# plaintext from tfvars (Schematics GET never returns plaintext — only a mask).
# Only forward name/value/type/secure — extra fields returned by GET (e.g.
# "description") cause the CLI update call to fail with HTTP 400.
remaining = dict(patch)
updated   = []
for v in (td.get("variablestore") or []):
    name      = v.get("name", "")
    is_secure = v.get("secure", False)
    if name in remaining:
        clean = {k: v[k] for k in ("name", "type", "secure") if k in v}
        clean["value"] = remaining.pop(name)
    elif is_secure:
        # Omit "value" to keep the existing server-side secret unless we have
        # the plaintext available from the original tfvars.
        clean = {k: v[k] for k in ("name", "type", "secure") if k in v}
        if name in tfvars:
            clean["value"] = tfvars[name]
    else:
        clean = {k: v[k] for k in ("name", "value", "type", "secure") if k in v}
    updated.append(clean)
# Append any patch keys that were not already in the variablestore
for name, value in remaining.items():
    updated.append({"name": name, "value": value})

entry = {"folder": folder, "type": tf_type, "variablestore": updated}
if template_id:
    entry["id"] = template_id

print(json.dumps({"template_data": [entry]}, indent=2))
PYEOF

    local update_json
    update_json=$(WS3_ID="$ws3_id" WS4_ID="$ws4_id" TFVARS="$TFVARS" \
        python3 "$py" 2> >(tee -a "$LOG_FILE" >&2)) \
        || { rm -f "$py"; die "ws3→ws4 wiring script failed"; }
    rm -f "$py"

    local update_file; update_file=$(mktemp /tmp/bnk_ws4_update_XXXXXX.json)
    printf '%s\n' "$update_json" > "$update_file"

    log "Updating ws4 variablestore..."
    ibmcloud schematics workspace update \
        --id "$ws4_id" --file "$update_file" --output json \
        >> "$LOG_FILE" 2>&1 \
        || { rm -f "$update_file"; die "ws4 variablestore update failed"; }
    rm -f "$update_file"
    log "ws4 variablestore patched"
}

# ── Deploy ────────────────────────────────────────────────────

do_deploy() {
    section "BIG-IP Next for Kubernetes 2.3 — Deployment"
    log "tfvars   : $TFVARS"
    log "log file : $LOG_FILE"

    # Pre-flight: confirm ibmcloud CLI is authenticated before spending time
    # creating resources, since every Schematics call would fail with 401 otherwise.
    section "PRE-FLIGHT — ibmcloud CLI login check"
    ibmcloud iam oauth-tokens > /dev/null 2>&1 \
        || die "Not logged in. Run: ibmcloud login --apikey YOUR_API_KEY -r REGION"
    log "ibmcloud CLI authenticated"

    [[ -f "$TFVARS" ]] || die "$TFVARS not found"

    # Determine which workspaces are enabled by reading tfvars booleans.
    # Variables default to true (matching the Terraform variable defaults).
    local ws1_enabled ws2_enabled ws3_enabled ws4_enabled ws5_enabled
    eval "$(python3 - "$TFVARS" << 'PYEOF'
import re, sys

vals = {}
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^(\w+)\s*=\s*(.+)$', line)
        if m:
            vals[m.group(1)] = m.group(2).strip().strip('"').lower()

def enabled(name, default="true"):
    return "true" if vals.get(name, default) not in ("false", "0", "no") else "false"

print(f"ws1_enabled={enabled('create_roks_cluster')}")
print(f"ws2_enabled={enabled('install_cert_manager')}")
print(f"ws3_enabled={enabled('deploy_bnk')}")
print(f"ws4_enabled={enabled('deploy_bnk')}")
print(f"ws5_enabled={enabled('deploy_bnk')}")
PYEOF
)"

    log "ws1 roks-cluster  : $ws1_enabled"
    log "ws2 cert-manager  : $ws2_enabled"
    log "ws3 flo           : $ws3_enabled"
    log "ws4 cneinstance   : $ws4_enabled"
    log "ws5 license       : $ws5_enabled"
    log "ws6 testing       : true (always)"

    # ── Step 1: terraform init ────────────────────────────────
    section "TERRAFORM INIT"
    terraform init -input=false 2>&1 | tee -a "$LOG_FILE"

    # ── Step 2: Create workspace records and destroy hooks ────
    #
    # Target only ibm_schematics_workspace resources and null_resource.destroy_wsN.
    # The null_resource.plan_wsN / apply_wsN resources (jobs.tf) are excluded:
    # their local-exec provisioners fire-and-forget to the Schematics API and
    # cannot enforce the interleaved plan→apply ordering needed by downstream
    # data sources.  We drive plan/apply manually below.
    #
    # The destroy_wsN resources have only when=destroy provisioners, so creating
    # them now has no side-effect but registers them in state so that
    # `terraform destroy` will correctly call the Schematics destroy API for
    # each workspace in reverse order (ws6→ws1).
    section "TERRAFORM APPLY — Create workspace records + register destroy hooks"

    local targets=(
        -target "data.ibm_resource_group.rg"
        -target "ibm_schematics_workspace.ws6_testing"
        -target "null_resource.destroy_ws6"
    )
    [[ "$ws1_enabled" == "true" ]] && targets+=(
        -target "ibm_schematics_workspace.ws1_roks_cluster[0]"
        -target "null_resource.destroy_ws1[0]"
    )
    [[ "$ws2_enabled" == "true" ]] && targets+=(
        -target "ibm_schematics_workspace.ws2_cert_manager[0]"
        -target "null_resource.destroy_ws2[0]"
    )
    [[ "$ws3_enabled" == "true" ]] && targets+=(
        -target "ibm_schematics_workspace.ws3_flo[0]"
        -target "null_resource.destroy_ws3[0]"
    )
    [[ "$ws4_enabled" == "true" ]] && targets+=(
        -target "ibm_schematics_workspace.ws4_cneinstance[0]"
        -target "null_resource.destroy_ws4[0]"
    )
    [[ "$ws5_enabled" == "true" ]] && targets+=(
        -target "ibm_schematics_workspace.ws5_license[0]"
        -target "null_resource.destroy_ws5[0]"
    )

    terraform apply -auto-approve -input=false \
        -var "read_ws_outputs=false" \
        "${targets[@]}" \
        2>&1 | tee -a "$LOG_FILE"

    # ── Step 3: Resolve workspace IDs from Terraform state ────
    section "Resolving workspace IDs from Terraform state"

    local ws1_id ws2_id ws3_id ws4_id ws5_id ws6_id
    ws1_id=$(get_ws_id "ibm_schematics_workspace.ws1_roks_cluster[0]")
    ws2_id=$(get_ws_id "ibm_schematics_workspace.ws2_cert_manager[0]")
    ws3_id=$(get_ws_id "ibm_schematics_workspace.ws3_flo[0]")
    ws4_id=$(get_ws_id "ibm_schematics_workspace.ws4_cneinstance[0]")
    ws5_id=$(get_ws_id "ibm_schematics_workspace.ws5_license[0]")
    ws6_id=$(get_ws_id "ibm_schematics_workspace.ws6_testing")

    log "ws1 : ${ws1_id:-(disabled)}"
    log "ws2 : ${ws2_id:-(disabled)}"
    log "ws3 : ${ws3_id:-(disabled)}"
    log "ws4 : ${ws4_id:-(disabled)}"
    log "ws5 : ${ws5_id:-(disabled)}"
    log "ws6 : $ws6_id"

    [[ -n "$ws6_id" ]] || die "ws6 ID not found in Terraform state — apply may have failed"

    # Wait for all new workspace records to leave CONNECTING and reach INACTIVE.
    local id_pair
    for id_pair in \
        "${ws1_id:-}:ws1" "${ws2_id:-}:ws2" "${ws3_id:-}:ws3" \
        "${ws4_id:-}:ws4" "${ws5_id:-}:ws5" "${ws6_id}:ws6"
    do
        local id="${id_pair%%:*}" label="${id_pair##*:}"
        [[ -n "$id" ]] && wait_ready "$id" "$label"
    done

    # ── Step 4: Interleaved plan → apply, ws1 → ws6 ──────────
    #
    # Each workspace is planned and fully applied before the next is planned.
    # Downstream workspaces have data sources that query live cluster state at
    # plan time, so the ROKS cluster (ws1) must exist before ws2 is planned,
    # and so on up the chain.

    if [[ "$ws1_enabled" == "true" ]]; then
        section "WS1 — ROKS Cluster 4.18"
        [[ -n "$ws1_id" ]] || die "ws1 ID missing — cannot proceed"
        run_plan  "$ws1_id" "ws1-roks-cluster"
        run_apply "$ws1_id" "ws1-roks-cluster" "$WS1_TIMEOUT"
    fi

    if [[ "$ws2_enabled" == "true" ]]; then
        section "WS2 — cert-manager"
        [[ -n "$ws2_id" ]] || die "ws2 ID missing — cannot proceed"
        run_plan  "$ws2_id" "ws2-cert-manager"
        run_apply "$ws2_id" "ws2-cert-manager"
    fi

    if [[ "$ws3_enabled" == "true" ]]; then
        section "WS3 — F5 Lifecycle Operator (FLO)"
        [[ -n "$ws3_id" ]] || die "ws3 ID missing — cannot proceed"
        run_plan  "$ws3_id" "ws3-flo"
        run_apply "$ws3_id" "ws3-flo"
    fi

    # After ws3 applies, wire its outputs into ws4 before planning ws4.
    # FLO also installs Multus network attachments and reconfigures the cluster,
    # which temporarily causes ibm_container_cluster_config reads to fail (HTTP
    # 400 from the IBM Container Service API).  Wait for the cluster to settle.
    if [[ "$ws3_enabled" == "true" && "$ws4_enabled" == "true" && -n "$ws4_id" ]]; then
        wire_ws3_to_ws4 "$ws3_id" "$ws4_id"
        log "Waiting ${WS4_PRE_PLAN_WAIT}s for cluster to stabilise after FLO changes..."
        sleep "$WS4_PRE_PLAN_WAIT"
        wait_ready "$ws4_id" "ws4-cneinstance"
    fi

    if [[ "$ws4_enabled" == "true" ]]; then
        section "WS4 — CNEInstance"
        [[ -n "$ws4_id" ]] || die "ws4 ID missing — cannot proceed"
        run_plan  "$ws4_id" "ws4-cneinstance"
        run_apply "$ws4_id" "ws4-cneinstance"
    fi

    if [[ "$ws5_enabled" == "true" ]]; then
        section "WS5 — License"
        [[ -n "$ws5_id" ]] || die "ws5 ID missing — cannot proceed"
        run_plan  "$ws5_id" "ws5-license"
        run_apply "$ws5_id" "ws5-license"
    fi

    section "WS6 — Testing Jumphosts"
    [[ -n "$ws6_id" ]] || die "ws6 ID missing — cannot proceed"
    run_plan  "$ws6_id" "ws6-testing"
    run_apply "$ws6_id" "ws6-testing"

    # ── Step 5: Pull outputs into Terraform state ─────────────
    #
    # Re-apply the workspace records with read_ws_outputs=true.  This causes
    # the ibm_schematics_output data sources in main.tf to read each
    # sub-workspace's outputs and wire them (cluster name, FLO profile ID, etc.)
    # into the downstream workspace template_inputs and into outputs.tf.
    # After this apply, `terraform output` returns the full set of deployed values.
    #
    # Only workspace records and data sources are targeted — the null_resource
    # plan/apply jobs are excluded to prevent re-triggering live Schematics jobs.
    section "TERRAFORM APPLY — Pull sub-workspace outputs (read_ws_outputs=true)"

    local output_targets=(
        -target "data.ibm_resource_group.rg"
        -target "ibm_schematics_workspace.ws6_testing"
        -target "data.ibm_schematics_output.ws6_testing[0]"
    )
    [[ "$ws1_enabled" == "true" ]] && output_targets+=(
        -target "ibm_schematics_workspace.ws1_roks_cluster[0]"
        -target "data.ibm_schematics_output.ws1_roks_cluster[0]"
    )
    [[ "$ws2_enabled" == "true" ]] && output_targets+=(
        -target "ibm_schematics_workspace.ws2_cert_manager[0]"
        -target "data.ibm_schematics_output.ws2_cert_manager[0]"
    )
    [[ "$ws3_enabled" == "true" ]] && output_targets+=(
        -target "ibm_schematics_workspace.ws3_flo[0]"
        -target "data.ibm_schematics_output.ws3_flo[0]"
    )
    [[ "$ws4_enabled" == "true" ]] && output_targets+=(
        -target "ibm_schematics_workspace.ws4_cneinstance[0]"
        -target "data.ibm_schematics_output.ws4_cneinstance[0]"
    )
    [[ "$ws5_enabled" == "true" ]] && output_targets+=(
        -target "ibm_schematics_workspace.ws5_license[0]"
        -target "data.ibm_schematics_output.ws5_license[0]"
    )

    terraform apply -auto-approve -input=false \
        -var "read_ws_outputs=true" \
        "${output_targets[@]}" \
        2>&1 | tee -a "$LOG_FILE"

    # ── Step 6: Display outputs ───────────────────────────────
    section "DEPLOYMENT OUTPUTS"
    terraform output 2>&1 | tee -a "$LOG_FILE"

    section "DEPLOYMENT COMPLETE"
    log "All workspaces applied successfully."
    log ""
    log "To tear down:"
    log "  terraform destroy -auto-approve"
    log ""
    log "Log: $LOG_FILE"
}

# ── Destroy ───────────────────────────────────────────────────

do_destroy() {
    section "BIG-IP Next for Kubernetes 2.3 — Teardown"
    log "log file : $LOG_FILE"
    log ""
    log "terraform destroy will fire the null_resource.destroy_wsN provisioners"
    log "registered in state, calling the Schematics destroy API for each"
    log "sub-workspace in reverse order (ws6→ws1) and polling for completion"
    log "before moving to the next."

    terraform destroy -auto-approve 2>&1 | tee -a "$LOG_FILE"

    section "TEARDOWN COMPLETE"
    log "Log: $LOG_FILE"
}

# ── Entry point ───────────────────────────────────────────────

case "$MODE" in
    deploy)  do_deploy  ;;
    destroy) do_destroy ;;
esac

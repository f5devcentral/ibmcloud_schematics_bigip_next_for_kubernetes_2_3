#!/usr/bin/env bash
# ============================================================
# run_tests.sh — BIG-IP Next for Kubernetes 2.3 test suite
#
# Runs plan / apply / destroy for four all_in_one.sh scenarios
# and reports PASS / FAIL per phase.  Each scenario runs in its
# own subdirectory; Terraform state files do not conflict.
#
# Scenarios:
#   1  full
#        create_roks_cluster=true   create_roks_transit_gateway=true
#        install_cert_manager=true  deploy_bnk=true
#
#   2  existing-cluster-create-tgw
#        create_roks_cluster=false  create_roks_transit_gateway=true
#        install_cert_manager=false deploy_bnk=true
#
#   3  existing-cluster-existing-tgw
#        create_roks_cluster=false  create_roks_transit_gateway=false
#        install_cert_manager=false deploy_bnk=true
#
#   4  existing-cluster-create-tgw-existing-cert-manager
#        create_roks_cluster=false  create_roks_transit_gateway=true
#        install_cert_manager=false deploy_bnk=true
#
# Scenarios 2–4 share a prereqs workspace that creates the ROKS
# cluster, Transit Gateway, and cert-manager once before those
# tests run and tears them down after all three complete.  Because
# the prereqs already installs cert-manager into the shared cluster,
# all three scenarios pass install_cert_manager=false (a second
# install would collide on the same Helm release).
#
# Usage:
#   ./run_tests.sh [OPTIONS] [TESTS...]
#
# TESTS (one or more; default: all):
#   1 | full
#   2 | existing-cluster-create-tgw
#   3 | existing-cluster-existing-tgw
#   4 | existing-cluster-create-tgw-existing-cert-manager
#   all
#
# OPTIONS:
#   --no-destroy     Skip all destroy phases (leave resources up)
#   --run-dir DIR    Override test run output directory
#   --cleanup DIR    Destroy all Schematics workspaces left over in a prior
#                    run directory (use after a crash or stalled test run)
#   -h, --help
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_TFVARS="$SCRIPT_DIR/terraform.tfvars"
RUN_TS=$(date -u +%Y%m%d_%H%M%S)
TF_FILES=(main.tf variables.tf outputs.tf providers.tf versions.tf jobs.tf)
DIVIDER='══════════════════════════════════════════════════════════════'

# ── Arg parsing ─────────────────────────────────────────────
SKIP_DESTROY=false
RUN_DIR=""
CLEANUP_DIR=""
SELECTED_IDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-destroy)   SKIP_DESTROY=true ;;
        --run-dir)      shift; RUN_DIR="$1" ;;
        --run-dir=*)    RUN_DIR="${1#*=}" ;;
        --cleanup)      shift; CLEANUP_DIR="$1" ;;
        --cleanup=*)    CLEANUP_DIR="${1#*=}" ;;
        -h|--help)      sed -n '2,/^[^#]/{/^#/!q; s/^# \{0,2\}//p}' "$0"; exit 0 ;;
        all)            SELECTED_IDS=(1 2 3 4) ;;
        1|full)                                          SELECTED_IDS+=(1) ;;
        2|existing-cluster-create-tgw)                  SELECTED_IDS+=(2) ;;
        3|existing-cluster-existing-tgw)                SELECTED_IDS+=(3) ;;
        4|existing-cluster-create-tgw-existing-cert-manager) SELECTED_IDS+=(4) ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done
[[ ${#SELECTED_IDS[@]} -eq 0 ]] && SELECTED_IDS=(1 2 3 4)

# De-duplicate preserving order
declare -A _SEEN; DEDUPED=()
for _x in "${SELECTED_IDS[@]}"; do
    [[ -z "${_SEEN[$_x]:-}" ]] && DEDUPED+=("$_x") && _SEEN[$_x]=1
done
SELECTED_IDS=("${DEDUPED[@]}"); unset _SEEN _x DEDUPED

# ── Run directory ────────────────────────────────────────────
[[ -z "$RUN_DIR" ]] && RUN_DIR="$SCRIPT_DIR/test-runs/$RUN_TS"
mkdir -p "$RUN_DIR"
SUMMARY_LOG="$RUN_DIR/summary.log"

# Share provider cache across all scenario inits
export TF_PLUGIN_CACHE_DIR="$SCRIPT_DIR/.terraform/providers"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

# ── Pending-destroy tracker ───────────────────────────────────
# Written just before phase_apply; removed after a successful phase_destroy.
# emergency_cleanup processes whatever is still here on EXIT (Ctrl+C, set -e).
PENDING_DESTROY_FILE=$(mktemp)

register_pending_destroy()   { echo "$1|$2" >> "$PENDING_DESTROY_FILE"; }

unregister_pending_destroy() {
    local tmp; tmp=$(mktemp)
    grep -vxF "$1|$2" "$PENDING_DESTROY_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$PENDING_DESTROY_FILE"
}

# ── Result store ─────────────────────────────────────────────
declare -A RESULTS   # "ID:phase" → PASS | FAIL | SKIP | —

# ── Scenario properties ──────────────────────────────────────
scenario_label() {
    case $1 in
        1) echo "full" ;;
        2) echo "existing-cluster-create-tgw" ;;
        3) echo "existing-cluster-existing-tgw" ;;
        4) echo "existing-cluster-create-tgw-existing-cert-manager" ;;
    esac
}

scenario_tfvars_file() {
    case $1 in
        1) echo "terraform_full.tfvars" ;;
        2) echo "terraform_existing_cluster_create_tgw.tfvars" ;;
        3) echo "terraform_existing_cluster_existing_tgw.tfvars" ;;
        4) echo "terraform_existing_cluster_create_tgw_existing_cert_manager.tfvars" ;;
    esac
}

# ── tfvars generator ─────────────────────────────────────────
# gen_tfvars BASE_FILE OUT_FILE KEY=VALUE [KEY=VALUE ...]
# Copies BASE_FILE to OUT_FILE, replacing or appending each KEY.
gen_tfvars() {
    local base="$1" out="$2"; shift 2
    python3 - "$base" "$out" "$@" << 'PY'
import sys, re

base, out = sys.argv[1], sys.argv[2]
overrides = {}
for kv in sys.argv[3:]:
    k, _, v = kv.partition('=')
    overrides[k] = v

def fmt(key, val):
    if val.lower() in ('true', 'false') or re.fullmatch(r'-?\d+', val):
        return f'{key} = {val}\n'
    return f'{key} = "{val}"\n'

with open(base) as f:
    lines = f.readlines()

output = []
seen = set()
for line in lines:
    m = re.match(r'^(\w+)\s*=', line)
    if m and m.group(1) in overrides:
        key = m.group(1)
        output.append(fmt(key, overrides[key]))
        seen.add(key)
    else:
        output.append(line)
for k, v in overrides.items():
    if k not in seen:
        output.append(fmt(k, v))
with open(out, 'w') as f:
    f.writelines(output)
PY
}

# ── Single-value tfvars reader ───────────────────────────────
# get_tfvar KEY FILE  →  prints the value, or empty string on miss
get_tfvar() {
    python3 - "$2" "$1" << 'PY'
import re, sys
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r'^' + re.escape(sys.argv[2]) + r'\s*=\s*"?([^"#\n]+)"?', line)
        if m:
            print(m.group(1).strip().strip('"'))
            break
PY
}

# ── Scenario directory ───────────────────────────────────────
make_scenario_dir() {
    local dir="$1"
    mkdir -p "$dir/deploy-logs"
    for f in "${TF_FILES[@]}"; do
        ln -sf "$SCRIPT_DIR/$f" "$dir/$f"
    done
    ln -sf "$SCRIPT_DIR/all_in_one.sh" "$dir/all_in_one.sh"
}

# ── Logging ──────────────────────────────────────────────────
ts()    { date -u +%H:%M:%S; }
tlog()  { printf '%s\n'       "$*"          | tee -a "$SUMMARY_LOG"; }
tslog() { printf '[%s]  %s\n' "$(ts)" "$*"  | tee -a "$SUMMARY_LOG"; }

# ── Phase runners ────────────────────────────────────────────
# Each returns 0 on success, 1 on failure.

phase_plan() {
    local dir="$1" tfvars="$2" log="$dir/phase-plan.log"
    (
        cd "$dir"
        terraform init -input=false                          >> "$log" 2>&1 || exit 1
        terraform plan -input=false                          \
            -var-file="$tfvars"                              \
            -var 'read_ws_outputs=false'                     \
            >> "$log" 2>&1
    )
}

phase_apply() {
    local dir="$1" tfvars="$2" log="$dir/phase-apply.log"
    (cd "$dir" && ./all_in_one.sh "$tfvars" >> "$log" 2>&1)
}

phase_destroy() {
    local dir="$1" tfvars="$2" log="$dir/phase-destroy.log"
    (cd "$dir" && ./all_in_one.sh --destroy "$tfvars" >> "$log" 2>&1)
}

# ── Schematics log capture ────────────────────────────────────
# capture_schematics_logs DIR PHASE_LOG
# Parses workspace IDs logged by all_in_one.sh in PHASE_LOG and saves
# the most recent Schematics job log for each workspace to DIR/schematics-logs/.
capture_schematics_logs() {
    local dir="$1" phase_log="$2"
    local log_dir="$dir/schematics-logs"

    [[ -f "$phase_log" ]] || return 0

    # Extract "wsN : <workspace-id>" lines emitted by all_in_one.sh
    local ws_map
    ws_map=$(python3 - "$phase_log" << 'PY'
import re, sys
seen = {}
with open(sys.argv[1]) as f:
    for line in f:
        m = re.search(r'\b(ws\d+)\s*:\s*(\S+\.workspace\.\S+)', line)
        if m and m.group(1) not in seen:
            seen[m.group(1)] = m.group(2)
for ws in sorted(seen):
    print(ws, seen[ws])
PY
)

    if [[ -z "$ws_map" ]]; then
        tslog "  LOGS   No workspace IDs found in $(basename "$phase_log")"
        return 0
    fi

    mkdir -p "$log_dir"
    tslog "  LOGS   Capturing Schematics workspace logs → $log_dir"

    while IFS=' ' read -r ws ws_id; do
        [[ -n "$ws_id" ]] || continue
        local out_file="$log_dir/${ws}.log"
        local act_id=""
        act_id=$(ibmcloud schematics workspace action --id "$ws_id" --output json 2>/dev/null | \
            python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    acts = data if isinstance(data, list) else data.get('actions', [])
    if acts:
        a = acts[0]
        print(a.get('action_id', '') or a.get('id', ''))
except:
    pass
" 2>/dev/null)
        if [[ -n "$act_id" ]]; then
            ibmcloud schematics logs --id "$ws_id" --act-id "$act_id" \
                > "$out_file" 2>&1
            tslog "         $ws ($ws_id)  →  $(basename "$out_file")"
        else
            tslog "         $ws ($ws_id)  no recent activity (workspace may be gone)"
        fi
    done <<< "$ws_map"
}

# ── Single test ──────────────────────────────────────────────
run_test() {
    local id="$1" dir="$2" tfvars="$3"
    local label; label=$(scenario_label "$id")
    local start end elapsed mins secs

    RESULTS["$id:plan"]="—"
    RESULTS["$id:apply"]="—"
    RESULTS["$id:destroy"]="—"

    # PLAN ────────────────────────────────────────────────────
    tslog "TEST   $label / PLAN"
    start=$(date +%s)
    if phase_plan "$dir" "$tfvars"; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:plan"]="PASS"
        tslog "PASS   $label / PLAN  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:plan"]="FAIL"
        RESULTS["$id:apply"]="SKIP"
        RESULTS["$id:destroy"]="SKIP"
        tslog "FAIL   $label / PLAN  (${mins}m${secs}s)  →  $dir/phase-plan.log"
        return
    fi

    # APPLY ───────────────────────────────────────────────────
    tslog "TEST   $label / APPLY"
    start=$(date +%s)
    if phase_apply "$dir" "$tfvars"; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:apply"]="PASS"
        tslog "PASS   $label / APPLY  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:apply"]="FAIL"
        tslog "FAIL   $label / APPLY  (${mins}m${secs}s)  →  $dir/phase-apply.log"
        capture_schematics_logs "$dir" "$dir/phase-apply.log"
        # Attempt cleanup even after a partial apply
        if [[ "$SKIP_DESTROY" == false ]]; then
            tslog "TEST   $label / DESTROY (cleanup after failed apply)"
            start=$(date +%s)
            if phase_destroy "$dir" "$tfvars"; then
                elapsed=$(( $(date +%s) - start ))
                mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
                RESULTS["$id:destroy"]="PASS"
                tslog "PASS   $label / DESTROY  (${mins}m${secs}s)"
            else
                elapsed=$(( $(date +%s) - start ))
                mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
                RESULTS["$id:destroy"]="FAIL"
                tslog "FAIL   $label / DESTROY  (${mins}m${secs}s)  →  $dir/phase-destroy.log"
                tslog "  !! MANUAL CLEANUP MAY BE REQUIRED"
                capture_schematics_logs "$dir" "$dir/phase-destroy.log"
            fi
        else
            RESULTS["$id:destroy"]="SKIP"
        fi
        return
    fi

    # DESTROY ─────────────────────────────────────────────────
    if [[ "$SKIP_DESTROY" == true ]]; then
        RESULTS["$id:destroy"]="SKIP"
        tslog "SKIP   $label / DESTROY  (--no-destroy)"
        return
    fi

    tslog "TEST   $label / DESTROY"
    start=$(date +%s)
    if phase_destroy "$dir" "$tfvars"; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:destroy"]="PASS"
        tslog "PASS   $label / DESTROY  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:destroy"]="FAIL"
        tslog "FAIL   $label / DESTROY  (${mins}m${secs}s)  →  $dir/phase-destroy.log"
        tslog "  !! MANUAL CLEANUP MAY BE REQUIRED"
        capture_schematics_logs "$dir" "$dir/phase-destroy.log"
    fi
}

# ── Shared prerequisites (for scenarios 2 / 3 / 4) ──────────
# Creates ROKS cluster + Transit Gateway + cert-manager once.
# deploy_bnk=false so ws3–ws5 are skipped; ws6 runs as a no-op.
PREREQS_DIR="$RUN_DIR/prereqs"
PREREQS_TFVARS="terraform_prereqs.tfvars"

run_prereqs_setup() {
    local cluster_name="$1" vpc_name="$2" cos_name="$3" tgw_name="$4"
    tslog "SETUP  shared prerequisites (cluster + TGW + cert-manager) for scenarios 2/3/4"
    tslog "       cluster=${cluster_name}  tgw=${tgw_name}"
    make_scenario_dir "$PREREQS_DIR"
    gen_tfvars "$BASE_TFVARS" "$PREREQS_DIR/$PREREQS_TFVARS" \
        "ws_name_suffix=setup-$RUN_TS"              \
        "openshift_cluster_name=${cluster_name}"    \
        "roks_cluster_vpc_name=${vpc_name}"         \
        "roks_cos_instance_name=${cos_name}"        \
        "roks_transit_gateway_name=${tgw_name}"     \
        "create_roks_cluster=true"                  \
        "create_roks_transit_gateway=true"           \
        "install_cert_manager=true"                 \
        "deploy_bnk=false"                          \
        "testing_create_tgw_jumphost=false"         \
        "testing_create_cluster_jumphosts=false"
    ln -sf "$PREREQS_TFVARS" "$PREREQS_DIR/terraform.tfvars"

    local start end elapsed mins secs
    start=$(date +%s)
    if (cd "$PREREQS_DIR" && ./all_in_one.sh "$PREREQS_TFVARS" \
            >> "$PREREQS_DIR/phase-setup.log" 2>&1); then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "READY  shared prerequisites  (${mins}m${secs}s)"
        return 0
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "FAIL   shared prerequisites setup  (${mins}m${secs}s)  →  $PREREQS_DIR/phase-setup.log"
        capture_schematics_logs "$PREREQS_DIR" "$PREREQS_DIR/phase-setup.log"
        return 1
    fi
}

run_prereqs_teardown() {
    if [[ "$SKIP_DESTROY" == true ]]; then
        tslog "SKIP   shared prerequisites teardown  (--no-destroy)"
        return
    fi
    tslog "TEARDOWN  shared prerequisites"
    local start end elapsed mins secs
    start=$(date +%s)
    if (cd "$PREREQS_DIR" && ./all_in_one.sh --destroy "$PREREQS_TFVARS" \
            >> "$PREREQS_DIR/phase-teardown.log" 2>&1); then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "PASS   shared prerequisites teardown  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "FAIL   shared prerequisites teardown  (${mins}m${secs}s)  →  $PREREQS_DIR/phase-teardown.log"
        tslog "  !! MANUAL CLEANUP REQUIRED"
        capture_schematics_logs "$PREREQS_DIR" "$PREREQS_DIR/phase-teardown.log"
    fi
}

# ── Summary ──────────────────────────────────────────────────
print_summary() {
    local total=0 passed=0
    tlog ""
    tlog "$DIVIDER"
    tlog "SUMMARY"
    tlog "$DIVIDER"
    tlog "$(printf '  %-50s  %-6s  %-6s  %-7s' 'SCENARIO' 'PLAN' 'APPLY' 'DESTROY')"
    tlog "$(printf '  %-50s  %-6s  %-6s  %-7s' \
        '────────────────────────────────────────────────────' '──────' '──────' '───────')"

    for id in 1 2 3 4; do
        local is_selected=false
        for s in "${SELECTED_IDS[@]}"; do [[ $s == "$id" ]] && is_selected=true && break; done
        [[ $is_selected == false ]] && continue

        local label plan apply destroy
        label=$(scenario_label "$id")
        plan="${RESULTS[$id:plan]:-—}"
        apply="${RESULTS[$id:apply]:-—}"
        destroy="${RESULTS[$id:destroy]:-—}"
        tlog "$(printf '  %-50s  %-6s  %-6s  %-7s' "$label" "$plan" "$apply" "$destroy")"

        (( total++ )) || true
        if [[ "$plan" == "PASS" && "$apply" == "PASS" \
              && ( "$destroy" == "PASS" || "$destroy" == "SKIP" ) ]]; then
            (( passed++ )) || true
        fi
    done

    tlog "$DIVIDER"
    tlog ""
    tlog "Result: $passed / $total scenarios fully passed"
    tlog "Logs:   $RUN_DIR"
    tlog ""
}

# ── Main ─────────────────────────────────────────────────────
main() {
    tlog "$DIVIDER"
    tlog "  BIG-IP Next for Kubernetes 2.3 — Schematics Test Suite"
    tlog "  Run timestamp : $RUN_TS"
    tlog "  Run directory : $RUN_DIR"
    tlog "  Tests         : ${SELECTED_IDS[*]}"
    tlog "  Skip destroy  : $SKIP_DESTROY"
    tlog "$DIVIDER"
    tlog ""

    [[ -f "$BASE_TFVARS" ]] || { tslog "FATAL: $BASE_TFVARS not found"; exit 1; }

    # ── Derive unique resource names from base tfvars ─────────
    # Append a short per-test suffix (tN-HHMM or s-HHMM for prereqs) to every
    # IBM Cloud resource name so concurrent or back-to-back runs never collide.
    local hhmm="${RUN_TS:9:4}"   # e.g. "0652" from 20260504_065205
    local base_cluster base_vpc base_cos base_tgw
    base_cluster=$(get_tfvar "openshift_cluster_name"   "$BASE_TFVARS")
    base_vpc=$(get_tfvar     "roks_cluster_vpc_name"    "$BASE_TFVARS")
    base_cos=$(get_tfvar     "roks_cos_instance_name"   "$BASE_TFVARS")
    base_tgw=$(get_tfvar     "roks_transit_gateway_name" "$BASE_TFVARS")

    # Prereqs names — shared by scenarios 2, 3, 4
    local p_cluster="${base_cluster}-s${hhmm}"
    local p_vpc="${base_vpc}-s${hhmm}"
    local p_cos="${base_cos}-s${hhmm}"
    local p_tgw="${base_tgw}-s${hhmm}"

    tlog "  Resource suffix : -tN-${hhmm}  (prereqs: -s${hhmm})"
    tlog ""

    # Pre-initialise results so summary shows — for any unrun test
    for id in "${SELECTED_IDS[@]}"; do
        RESULTS["$id:plan"]="—"; RESULTS["$id:apply"]="—"; RESULTS["$id:destroy"]="—"
    done

    # ── Scenario 1 (full) — independent ──────────────────────
    local id dir tfvars
    for id in "${SELECTED_IDS[@]}"; do
        [[ "$id" == "1" ]] || continue
        tlog ""; tlog "──── Scenario 1: full ────"
        dir="$RUN_DIR/scenario-1-full"
        tfvars=$(scenario_tfvars_file 1)
        make_scenario_dir "$dir"
        gen_tfvars "$BASE_TFVARS" "$dir/$tfvars" \
            "ws_name_suffix=t1-$RUN_TS"                        \
            "openshift_cluster_name=${base_cluster}-t1-${hhmm}" \
            "roks_cluster_vpc_name=${base_vpc}-t1-${hhmm}"     \
            "roks_cos_instance_name=${base_cos}-t1-${hhmm}"    \
            "roks_transit_gateway_name=${base_tgw}-t1-${hhmm}" \
            "create_roks_cluster=true"                          \
            "create_roks_transit_gateway=true"                  \
            "install_cert_manager=true"                         \
            "deploy_bnk=true"                                   \
            "testing_create_tgw_jumphost=false"                 \
            "testing_create_cluster_jumphosts=false"
        ln -sf "$tfvars" "$dir/terraform.tfvars"
        run_test 1 "$dir" "$tfvars"
    done

    # ── Scenarios 2, 3, 4 — share prereqs ────────────────────
    local needs_prereqs=false
    for id in "${SELECTED_IDS[@]}"; do
        [[ "$id" != "1" ]] && needs_prereqs=true && break
    done

    if [[ "$needs_prereqs" == true ]]; then
        tlog ""; tlog "──── Shared prerequisites ────"
        local prereqs_ok=true
        if ! run_prereqs_setup "$p_cluster" "$p_vpc" "$p_cos" "$p_tgw"; then
            prereqs_ok=false
            for id in "${SELECTED_IDS[@]}"; do
                [[ "$id" == "1" ]] && continue
                RESULTS["$id:plan"]="SKIP"
                RESULTS["$id:apply"]="SKIP"
                RESULTS["$id:destroy"]="SKIP"
            done
        fi

        if [[ "$prereqs_ok" == true ]]; then
            for id in "${SELECTED_IDS[@]}"; do
                [[ "$id" == "1" ]] && continue
                local label; label=$(scenario_label "$id")
                tlog ""; tlog "──── Scenario $id: $label ────"
                dir="$RUN_DIR/scenario-$id-$label"
                tfvars=$(scenario_tfvars_file "$id")
                make_scenario_dir "$dir"

                case $id in
                    2) gen_tfvars "$BASE_TFVARS" "$dir/$tfvars" \
                           "ws_name_suffix=t2-$RUN_TS"                        \
                           "roks_cluster_id_or_name=${p_cluster}"             \
                           "roks_transit_gateway_name=${base_tgw}-t2-${hhmm}" \
                           "create_roks_cluster=false"                        \
                           "create_roks_transit_gateway=true"                 \
                           "install_cert_manager=false"                       \
                           "deploy_bnk=true"                                  \
                           "testing_create_tgw_jumphost=false"                \
                           "testing_create_cluster_jumphosts=false"           ;;
                    3) gen_tfvars "$BASE_TFVARS" "$dir/$tfvars" \
                           "ws_name_suffix=t3-$RUN_TS"              \
                           "roks_cluster_id_or_name=${p_cluster}"   \
                           "roks_transit_gateway_name=${p_tgw}"     \
                           "create_roks_cluster=false"              \
                           "create_roks_transit_gateway=false"      \
                           "install_cert_manager=false"             \
                           "deploy_bnk=true"                        \
                           "testing_create_tgw_jumphost=false"      \
                           "testing_create_cluster_jumphosts=false" ;;
                    4) gen_tfvars "$BASE_TFVARS" "$dir/$tfvars" \
                           "ws_name_suffix=t4-$RUN_TS"                        \
                           "roks_cluster_id_or_name=${p_cluster}"             \
                           "roks_transit_gateway_name=${base_tgw}-t4-${hhmm}" \
                           "create_roks_cluster=false"                        \
                           "create_roks_transit_gateway=true"                 \
                           "install_cert_manager=false"                       \
                           "deploy_bnk=true"                                  \
                           "testing_create_tgw_jumphost=false"                \
                           "testing_create_cluster_jumphosts=false"           ;;
                esac
                ln -sf "$tfvars" "$dir/terraform.tfvars"

                run_test "$id" "$dir" "$tfvars"
            done

            run_prereqs_teardown
        fi
    fi

    print_summary
}

main

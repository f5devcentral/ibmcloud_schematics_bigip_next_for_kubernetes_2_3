#!/usr/bin/env python3
"""
BIG-IP Next for Kubernetes 2.3 — Schematics Lifecycle Test Runner

Full lifecycle test:
  1. Create orchestration workspace
  2. Plan orchestration workspace  (validate HCL)
  3. Apply orchestration workspace (create ws1–ws6 sub-workspaces)
  4. For each sub-workspace ws1 → ws6 (interleaved, stop chain on first failure):
       a. Plan  wsN  — downstream workspaces depend on upstream applied resources
       b. Apply wsN
  5. Destroy ws6 → ws1 (reverse, skips workspaces never applied)
  6. Destroy orchestration workspace (runs when=destroy provisioners)
  7. Delete  orchestration workspace

Note on interleaved plan→apply ordering:
  Downstream workspaces (ws2 cert-manager, ws3 FLO, etc.) have data sources that
  look up the ROKS cluster by name.  Those data sources are evaluated during plan,
  so ws2 plan can only succeed AFTER ws1 apply has created the cluster.  Running all
  plans before any apply (plan-all → apply-all) would cause ws2–ws6 plans to fail
  with "cluster not found".  The interleaved order ensures each workspace's
  dependencies exist before its plan runs.

Usage:
    python3 test_lifecycle.py [path/to/terraform.tfvars] [--branch BRANCH]

    --branch BRANCH   GitHub branch to test (default: main)

Prerequisites:
    ibmcloud CLI installed and logged in:
        ibmcloud login --apikey YOUR_API_KEY -r REGION
    Schematics plugin installed:
        ibmcloud plugin install schematics
"""

import json
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ── Configuration ─────────────────────────────────────────────────────────────

TFVARS_DEFAULT = "terraform.tfvars"
WS_JSON_PATH   = "workspace.json"
REPORT_DIR     = Path("test-reports")

POLL_INTERVAL   = 30      # seconds between status polls
JOB_TIMEOUT     = 18000   # 300 min max per sub-workspace phase
ORCH_TIMEOUT    = 10800   # 3 h max for orchestration workspace operations
READY_TIMEOUT   = 300     # seconds to wait for workspace to leave CONNECTING
DESTROY_RETRIES   = 2     # extra attempts on destroy FAILED (e.g. transient provider init errors)
PLAN_RETRIES      = 2     # extra attempts on plan FAILED
PLAN_RETRY_WAIT   = 60    # seconds to wait between plan retry attempts

SECURE_VARS = {"ibmcloud_api_key", "bigip_password"}

# Workspace status values that mean a job finished
TERMINAL_STATUSES = {"INACTIVE", "ACTIVE", "FAILED", "STOPPED", "DRAFT"}

# Ordered list of selectable lifecycle phases (also the default run order)
VALID_PHASES = [
    "create",        # create orchestration workspace
    "plan-orch",     # plan orchestration workspace
    "apply-orch",    # apply orchestration workspace (creates sub-workspaces)
    "sub-ws",        # plan then apply each sub-workspace ws1→ws6
    "destroy-sub",   # destroy sub-workspaces ws6→ws1
    "destroy-orch",  # destroy orchestration workspace
    "delete",        # delete orchestration workspace record
]

# Sub-workspace definitions: (slot, fixed-name-in-main.tf, controlling-tfvar-or-None)
SUB_WORKSPACE_DEFS = [
    (1, "bnk-23-roks-cluster", "create_roks_cluster"),
    (2, "bnk-23-cert-manager",  "install_cert_manager"),
    (3, "bnk-23-flo",           "deploy_bnk"),
    (4, "bnk-23-cneinstance",   "deploy_bnk"),
    (5, "bnk-23-license",       "deploy_bnk"),
    (6, "bnk-23-testing",       None),
]

# Outputs printed in the report (from orchestration workspace)
KEY_OUTPUTS = [
    "roks_openshift_cluster_name",
    "roks_openshift_cluster_public_endpoint",
    "roks_transit_gateway_name",
    "ibmcloud_trusted_profile_id",
    "flo_deloyment_status",
    "cneinstance_deployment_status",
    "bnk_license_id",
    "test_jumphost_public_ip",
    "test_jumphost_ssh_command",
    "cluster_vpc_jumphosts_ssh_commands",
]


# ── Low-level helpers ─────────────────────────────────────────────────────────

def tee(msg, lf=None):
    print(msg, flush=True)
    if lf:
        print(msg, file=lf, flush=True)


def run_cmd(cmd, lf=None, stream=False):
    if not stream:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return r.returncode, r.stdout, r.stderr

    proc = subprocess.Popen(
        cmd, shell=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )
    buf = []
    for line in proc.stdout:
        print(line, end="", flush=True)
        if lf:
            print(line, end="", file=lf, flush=True)
        buf.append(line)
    proc.wait()
    return proc.returncode, "".join(buf), ""


def ibmcloud_json(cmd, lf=None):
    rc, out, err = run_cmd(f"{cmd} --output json")
    if lf and out.strip():
        print(out, file=lf, flush=True)
    if rc != 0:
        raise RuntimeError(f"Command failed: {cmd}\n{(err or out).strip()}")
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Non-JSON output from: {cmd}\n{out}") from exc


# ── tfvars / workspace.json ───────────────────────────────────────────────────

def parse_tfvars(path):
    variables = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r'^(\w+)\s*=\s*(.+)$', line)
            if not m:
                continue
            name, raw = m.group(1), m.group(2).strip()
            if raw in ("true", "false"):
                entry = {"name": name, "value": raw, "type": "bool"}
            elif re.match(r'^-?\d+(\.\d+)?$', raw):
                entry = {"name": name, "value": raw, "type": "number"}
            else:
                entry = {"name": name, "value": raw.strip('"'), "type": "string"}
            if name in SECURE_VARS:
                entry["secure"] = True
            variables.append(entry)
    return variables


def build_workspace_json(variables, ts_label, branch="main"):
    location       = next((v["value"] for v in variables if v["name"] == "ibmcloud_schematics_region"), "ca-tor")
    resource_group = next((v["value"] for v in variables if v["name"] == "ibmcloud_resource_group"), "default")
    ws = {
        "name": f"bnk-23-test-{ts_label}",
        "type": ["terraform_v1.5"],
        "location": location,
        "description": f"Lifecycle test — {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        "resource_group": resource_group,
        "template_repo": {
            "url": "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_2_3",
            "branch": branch,
        },
        "template_data": [{
            "folder": ".",
            "type": "terraform_v1.5",
            "variablestore": variables,
        }],
    }
    Path(WS_JSON_PATH).write_text(json.dumps(ws, indent=2))
    return ws


# ── Schematics polling ────────────────────────────────────────────────────────

def get_ws_info(ws_id):
    try:
        data   = ibmcloud_json(f"ibmcloud schematics workspace get --id {ws_id}")
        status = data.get("status") or data.get("workspace_status_msg", {}).get("status_code") or "UNKNOWN"
        locked = data.get("workspace_status", {}).get("locked", False)
        return status, locked
    except Exception:
        return "UNKNOWN", True


def get_ws_status(ws_id):
    status, _ = get_ws_info(ws_id)
    return status


def wait_for_workspace_ready(ws_id, lf, timeout=READY_TIMEOUT):
    start = time.time()
    while True:
        elapsed = int(time.time() - start)
        if elapsed > timeout:
            tee(f"\n  WARNING: workspace not ready after {timeout}s — proceeding anyway", lf)
            return get_ws_status(ws_id)
        status, locked = get_ws_info(ws_id)
        if status in {"INACTIVE", "ACTIVE", "FAILED"} and not locked:
            print()
            return status
        if status == "FAILED":
            print()
            return status
        msg = f"  [ready] {elapsed}s  status={status}  locked={locked}"
        print(f"\r{msg:<76}", end="", flush=True)
        print(msg, file=lf, flush=True)
        time.sleep(10)


def poll_until_terminal(ws_id, label, lf, timeout=JOB_TIMEOUT):
    start = time.time()
    while True:
        elapsed = int(time.time() - start)
        if elapsed > timeout:
            return "TIMEOUT", elapsed
        status = get_ws_status(ws_id)
        if status in TERMINAL_STATUSES:
            print()
            return status, elapsed
        msg = f"  [{label}] {elapsed}s elapsed  status={status}"
        print(f"\r{msg:<76}", end="", flush=True)
        print(msg, file=lf, flush=True)
        time.sleep(POLL_INTERVAL)


def stream_logs(ws_id, act_id, lf):
    run_cmd(
        f"ibmcloud schematics logs --id {ws_id} --act-id {act_id}",
        lf=lf, stream=True,
    )


def run_job(cmd, ws_id, label, lf, success_statuses, timeout=JOB_TIMEOUT):
    """
    Submit a Schematics job (plan / apply / destroy), wait for completion,
    stream the final logs, and return (passed, final_status, elapsed_seconds).
    Retries on 409 workspace-locked responses for up to `timeout` seconds
    (the same budget used for polling), so a long-running prior job (e.g.
    a 60-minute roks_cluster apply) does not cause the submission to give up.
    """
    pre_status = get_ws_status(ws_id)
    lock_deadline = time.time() + timeout
    attempt = 0

    while True:
        attempt += 1
        rc, out, err = run_cmd(f"{cmd} --output json")
        combined = (out + err).lower()
        if rc == 0:
            break
        if ("409" in combined or "temporarily locked" in combined) and time.time() < lock_deadline:
            remaining = int(lock_deadline - time.time())
            tee(f"  Workspace locked (409) — retrying in 30s "
                f"(attempt {attempt}, {remaining}s remaining in budget)", lf)
            time.sleep(30)
            continue
        if out.strip():
            print(out, file=lf, flush=True)
        raise RuntimeError((err or out).strip())

    if out.strip():
        print(out, file=lf, flush=True)
    if rc != 0:
        raise RuntimeError((err or out).strip())

    try:
        act_id = json.loads(out).get("activityid")
    except (json.JSONDecodeError, AttributeError):
        act_id = None

    tee(f"  Activity ID : {act_id or '(unavailable)'}", lf)

    t0 = time.time()
    if act_id:
        tee("  Waiting for activity to start...", lf)
        t_transition = time.time()
        while time.time() - t_transition < 120:
            if get_ws_status(ws_id) != pre_status:
                break
            time.sleep(5)

        tee("  Polling until activity completes...", lf)
        final_status, _ = poll_until_terminal(ws_id, label, lf, timeout=timeout)

        tee("  Fetching final logs...", lf)
        stream_logs(ws_id, act_id, lf)
        tee("", lf)
    else:
        tee("  No activity ID returned — polling workspace status...", lf)
        final_status, _ = poll_until_terminal(ws_id, label, lf, timeout=timeout)

    elapsed = int(time.time() - t0)
    passed  = final_status in success_statuses
    return passed, final_status, elapsed


def find_subworkspace_ids(sub_workspaces, lf):
    """List all Schematics workspaces and match by name into sub_workspaces[].id."""
    try:
        data    = ibmcloud_json("ibmcloud schematics workspace list", lf)
        ws_list = data.get("workspaces", []) if isinstance(data, dict) else (data or [])
        name_to_id = {w.get("name"): w.get("id") for w in ws_list if w.get("name")}
        for sw in sub_workspaces:
            if sw["enabled"]:
                sw["id"] = name_to_id.get(sw["name"])
                found = sw["id"] or "NOT FOUND"
                tee(f"  ws{sw['slot']} {sw['name']}: {found}", lf)
    except Exception as exc:
        tee(f"  WARNING: workspace list failed: {exc}", lf)


def fetch_outputs(ws_id, lf):
    try:
        data  = ibmcloud_json(f"ibmcloud schematics output --id {ws_id}", lf)
        items = data if isinstance(data, list) else [data]
        out   = {}
        for template in items:
            for vals in template.get("output_values", []):
                if not isinstance(vals, dict):
                    continue
                if "name" in vals:
                    # format: [{"name": "var", "value": "..."}]
                    out[vals["name"]] = vals.get("value", "")
                else:
                    # format: [{"var_name": value, ...}] — one dict maps all outputs
                    for name, v in vals.items():
                        if isinstance(v, dict):
                            out[name] = v.get("value", "")
                        elif isinstance(v, list):
                            out[name] = json.dumps(v)
                        else:
                            out[name] = str(v) if v is not None else ""
        return out
    except Exception as exc:
        tee(f"  WARNING: could not fetch outputs: {exc}", lf)
        return {}


def reapply_orch_with_ws_outputs(orch_ws_id, variables, lf):
    """
    Switch read_ws_outputs → true in the orchestration workspace and re-apply it.
    This causes Terraform to read ws3 outputs and wire flo_trusted_profile_id /
    flo_cluster_issuer_name into ws4 and ws5 template_inputs before those
    workspaces run their own plan/apply.
    """
    # Build variablestore with read_ws_outputs forced to true
    patched = False
    updated = []
    for v in variables:
        if v["name"] == "read_ws_outputs":
            updated.append({**v, "value": "true"})
            patched = True
        else:
            updated.append(v)
    if not patched:
        updated.append({"name": "read_ws_outputs", "value": "true", "type": "bool"})

    # Fetch the existing workspace template id/folder/type so the update payload
    # targets the existing template (preserving the state file association).
    # Without the template id, Schematics creates a new template entry and the
    # subsequent apply fails with "statefile cannot be located".
    try:
        ws_data     = ibmcloud_json(f"ibmcloud schematics workspace get --id {orch_ws_id}", lf)
        td          = ws_data.get("template_data", [{}])[0]
        template_id = td.get("id", "")
        folder      = td.get("folder", ".")
        tf_type     = td.get("type", "terraform_v1.5")
    except Exception:
        template_id, folder, tf_type = "", ".", "terraform_v1.5"

    template_entry = {
        "folder":        folder,
        "type":          tf_type,
        "variablestore": updated,
    }
    if template_id:
        template_entry["id"] = template_id

    update_payload = {"template_data": [template_entry]}
    update_file = Path("workspace_reapply_update.json")
    update_file.write_text(json.dumps(update_payload, indent=2))

    tee("  Updating orchestration workspace (read_ws_outputs → true) ...", lf)
    rc, out, err = run_cmd(
        f"ibmcloud schematics workspace update --id {orch_ws_id} --file {update_file} --output json",
        lf=lf,
    )
    update_file.unlink(missing_ok=True)
    if rc != 0:
        raise RuntimeError(f"workspace update failed: {(err or out).strip()}")

    tee("  Waiting for workspace to settle after update ...", lf)
    wait_for_workspace_ready(orch_ws_id, lf)

    return run_job(
        cmd             = f"ibmcloud schematics apply --id {orch_ws_id} --force",
        ws_id           = orch_ws_id,
        label           = "reapply-orch",
        lf              = lf,
        success_statuses= {"ACTIVE"},
        timeout         = ORCH_TIMEOUT,
    )


def wire_ws3_outputs_into_ws4(ws3_id, ws4_id, lf):
    """
    Read ws3 (FLO) outputs and inject them directly into ws4 (CNEInstance)
    variablestore. This avoids re-applying the orchestration workspace (which
    would fail because it tries to read outputs from ws4/ws5/ws6 that have no
    statefiles yet at this point in the lifecycle).
    """
    tee("  Fetching ws3 (FLO) outputs ...", lf)
    ws3_outputs = fetch_outputs(ws3_id, lf)

    flo_trusted_profile_id  = ws3_outputs.get("flo_trusted_profile_id", "")
    flo_cluster_issuer_name = ws3_outputs.get("flo_cluster_issuer_name", "")

    # cneinstance_network_attachments may come back as a list (JSON array) or
    # a string.  Normalise to a JSON string either way.
    raw_na = ws3_outputs.get("cneinstance_network_attachments", None)
    if raw_na is None:
        cneinstance_network_attachments = None          # don't overwrite ws4
    elif isinstance(raw_na, list):
        cneinstance_network_attachments = json.dumps(raw_na)
    else:
        # It's a string — validate it is JSON; if not try ast.literal_eval
        try:
            parsed = json.loads(raw_na)
            cneinstance_network_attachments = json.dumps(parsed)
        except (json.JSONDecodeError, TypeError):
            import ast as _ast
            try:
                parsed = _ast.literal_eval(raw_na)
                cneinstance_network_attachments = json.dumps(parsed)
            except Exception:
                cneinstance_network_attachments = raw_na   # keep as-is

    if not flo_trusted_profile_id:
        raise RuntimeError("ws3 output flo_trusted_profile_id is empty — FLO may not have applied successfully")

    tee(f"  flo_trusted_profile_id    : {flo_trusted_profile_id}", lf)
    tee(f"  flo_cluster_issuer_name   : {flo_cluster_issuer_name}", lf)
    if cneinstance_network_attachments is not None:
        tee(f"  cneinstance_network_attachments: {cneinstance_network_attachments[:80]}...", lf)

    ws3_patch: dict = {
        "flo_trusted_profile_id":  flo_trusted_profile_id,
        "flo_cluster_issuer_name": flo_cluster_issuer_name,
    }
    if cneinstance_network_attachments is not None:
        ws3_patch["cneinstance_network_attachments"] = cneinstance_network_attachments

    tee("  Fetching ws4 (CNEInstance) workspace config ...", lf)
    ws4_data    = ibmcloud_json(f"ibmcloud schematics workspace get --id {ws4_id}", lf)
    td          = ws4_data.get("template_data", [{}])[0]
    template_id = td.get("id", "")
    folder      = td.get("folder", ".")
    tf_type     = td.get("type", "terraform_v1.5")

    # Rebuild variablestore patching the ws3-sourced variables.
    # Only keep name/value/type/secure — the IBM Cloud CLI rejects payloads
    # that include extra fields (e.g. description) returned by workspace GET.
    # For secure variables with masked values (empty string returned by GET),
    # omit the "value" key entirely so IBM Cloud preserves the existing secret.
    # Sending "value": "" for a secure variable clears it.
    remaining = dict(ws3_patch)
    updated   = []
    for v in (td.get("variablestore") or []):
        name      = v.get("name", "")
        is_secure = v.get("secure", False)
        raw_val   = v.get("value", "")
        if name in remaining:
            # Explicitly updating this variable — always include value
            clean = {k: v[k] for k in ("name", "type", "secure") if k in v}
            clean["value"] = remaining.pop(name)
        elif is_secure and not raw_val:
            # Secure variable with masked value — omit "value" to preserve secret
            clean = {k: v[k] for k in ("name", "type", "secure") if k in v}
        else:
            clean = {k: v[k] for k in ("name", "value", "type", "secure") if k in v}
        updated.append(clean)
    for name, value in remaining.items():
        updated.append({"name": name, "value": value})

    template_entry = {"folder": folder, "type": tf_type, "variablestore": updated}
    if template_id:
        template_entry["id"] = template_id

    update_payload = {"template_data": [template_entry]}
    update_file    = Path("ws4_wire_update.json")
    update_file.write_text(json.dumps(update_payload, indent=2))

    tee("  Updating ws4 variablestore with ws3 outputs ...", lf)
    rc, out, err = run_cmd(
        f"ibmcloud schematics workspace update --id {ws4_id} --file {update_file} --output json",
        lf=lf,
    )
    update_file.unlink(missing_ok=True)
    if rc != 0:
        raise RuntimeError(
            f"ws4 variablestore update failed: {(err or out).strip()[:300]}"
        )

    tee("  ws4 variablestore updated successfully", lf)
    wait_for_workspace_ready(ws4_id, lf)


# ── Report rendering ──────────────────────────────────────────────────────────

class Phase:
    __slots__ = ("name", "status", "duration", "error")

    def __init__(self, name):
        self.name     = name
        self.status   = "SKIP"
        self.duration = 0
        self.error    = None


def render_report(started_at, ws_id, ws_name, phases, outputs, overall):
    elapsed = int((datetime.now(timezone.utc) - started_at).total_seconds())
    W   = 72
    sep = "=" * W
    thn = "-" * W
    lines = [
        "",
        sep,
        "  BIG-IP Next for Kubernetes 2.3 — Schematics Lifecycle Test Report",
        sep,
        f"  Started              {started_at.strftime('%Y-%m-%d %H:%M:%S UTC')}",
        f"  Orchestration WS     {ws_name or 'not created'}",
        f"  Orchestration WS ID  {ws_id   or 'not created'}",
        f"  Result               {overall}",
        f"  Total time           {elapsed}s  ({elapsed / 60:.1f} min)",
        thn,
        f"  {'Phase':<28} {'Result':<8} {'Duration':>10}",
        thn,
    ]
    for p in phases:
        lines.append(f"  {p.name:<28} {p.status:<8} {p.duration:>8}s")
        if p.error:
            lines.append(f"    !! {p.error}")

    if outputs:
        lines += [thn, "  Key Outputs", thn]
        printed = set()
        for key in KEY_OUTPUTS:
            val = outputs.get(key)
            if val is not None:
                lines.append(f"  {key}")
                lines.append(f"    {val}")
                printed.add(key)
        extras = {k: v for k, v in outputs.items() if k not in printed}
        if extras:
            lines.append(thn)
            for k, v in extras.items():
                lines.append(f"  {k}")
                lines.append(f"    {v}")

    lines += [sep, ""]
    return "\n".join(lines)


# ── Workspace tree ────────────────────────────────────────────────────────────

def show_workspace_tree(tfvars_path):
    """Print orchestration and sub-workspace IDs / statuses from the account."""
    W   = 72
    sep = "=" * W
    thn = "─" * (W - 4)

    try:
        variables = parse_tfvars(tfvars_path)
    except Exception as exc:
        print(f"ERROR: could not parse {tfvars_path}: {exc}")
        return 1

    var_map = {v["name"]: v["value"] for v in variables}
    region  = var_map.get("ibmcloud_schematics_region", "us-south")

    def _enabled(ctrl_var):
        if not ctrl_var:
            return True
        v = var_map.get(ctrl_var, "true")
        return v.lower() not in ("false", "0", "no")

    print(f"\n{sep}")
    print(f"  BIG-IP Next for Kubernetes 2.3 — Workspace Tree")
    print(f"  Schematics region : {region}")
    print(f"  tfvars            : {tfvars_path}")
    print(sep)

    rc, out, err = run_cmd("ibmcloud schematics workspace list --output json")
    if rc != 0:
        print(f"\n  ERROR: workspace list failed:\n  {(err or out).strip()}\n{sep}\n")
        return 1
    try:
        data    = json.loads(out)
        ws_list = data.get("workspaces", []) if isinstance(data, dict) else (data or [])
    except json.JSONDecodeError as exc:
        print(f"\n  ERROR: could not parse workspace list JSON: {exc}\n{sep}\n")
        return 1

    # Build name → [{id, status}, ...] — multiple runs can leave duplicate names
    by_name: dict = {}
    for w in ws_list:
        name = w.get("name") or ""
        if not name:
            continue
        status = (
            w.get("status")
            or w.get("workspace_status_msg", {}).get("status_code")
            or "UNKNOWN"
        )
        by_name.setdefault(name, []).append({"id": w.get("id", ""), "status": status})

    # ── Orchestration workspaces ───────────────────────────────────────────
    orch_prefix = "bnk-23-test-"
    orch_rows   = sorted(
        [
            (name, entry)
            for name, entries in by_name.items()
            for entry in entries
            if name.startswith(orch_prefix)
        ],
        key=lambda x: x[0],
        reverse=True,   # newest timestamp first
    )

    print(f"\n  Orchestration workspaces  (prefix: {orch_prefix}*)")
    print(f"  {thn}")
    if orch_rows:
        for name, entry in orch_rows:
            print(f"  {entry['status']:<10}  {name:<42}  {entry['id']}")
    else:
        print("  (none found)")

    # ── Sub-workspaces ─────────────────────────────────────────────────────
    print(f"\n  Sub-workspaces  (matched by prefix; newest run first)")
    print(f"  {thn}")
    for slot, ws_base_name, ctrl_var in SUB_WORKSPACE_DEFS:
        tag     = "" if _enabled(ctrl_var) else "  [disabled in tfvars]"
        # Match exact name (manual runs) or any timestamped variant (test runner)
        matches = sorted(
            [
                (name, entry)
                for name, entries in by_name.items()
                for entry in entries
                if name == ws_base_name or name.startswith(ws_base_name + "-")
            ],
            key=lambda x: x[0],
            reverse=True,
        )
        label = f"  ws{slot}  {ws_base_name:<28}"
        if matches:
            first_name, first = matches[0]
            print(f"{label}  {first['status']:<10}  {first['id']}  [{first_name}]{tag}")
            for name, dup in matches[1:]:
                print(f"  {'':>3}  {name:<28}  {dup['status']:<10}  {dup['id']}")
        else:
            print(f"{label}  (not found){tag}")

    print(f"\n{sep}\n")
    return 0


def show_outputs(ws_id):
    """Print all output variables for the given orchestration workspace."""
    W   = 72
    sep = "=" * W
    thn = "-" * W
    print(f"\n{sep}")
    print(f"  BIG-IP Next for Kubernetes 2.3 — Orchestration Workspace Outputs")
    print(f"  WS ID : {ws_id}")
    print(sep)

    try:
        data  = ibmcloud_json(f"ibmcloud schematics output --id {ws_id}")
        items = data if isinstance(data, list) else [data]
        outputs = {}
        for template in items:
            for item in template.get("output_values", []):
                outputs[item["name"]] = item.get("value", "")
    except Exception as exc:
        print(f"\n  ERROR: could not fetch outputs: {exc}\n{sep}\n")
        return 1

    if not outputs:
        print("\n  (no outputs — workspace may not be applied yet)")
        print(f"\n{sep}\n")
        return 0

    # Print KEY_OUTPUTS first, then any extras
    print(f"\n  {thn}")
    printed = set()
    for key in KEY_OUTPUTS:
        val = outputs.get(key)
        if val is not None:
            print(f"  {key}")
            print(f"    {val}")
            printed.add(key)
    extras = {k: v for k, v in outputs.items() if k not in printed}
    if extras:
        if printed:
            print(f"  {thn}")
        for k, v in extras.items():
            print(f"  {k}")
            print(f"    {v}")
    print(f"\n{sep}\n")
    return 0


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    import argparse
    parser = argparse.ArgumentParser(
        description="Schematics lifecycle test runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "phases (in execution order):\n"
            "  create       create orchestration workspace\n"
            "  plan-orch    plan orchestration workspace\n"
            "  apply-orch   apply orchestration workspace (creates sub-workspaces)\n"
            "  sub-ws       plan then apply each sub-workspace ws1→ws6\n"
            "  destroy-sub  destroy sub-workspaces ws6→ws1\n"
            "  destroy-orch destroy orchestration workspace\n"
            "  delete       delete orchestration workspace record\n"
            "\nexamples:\n"
            "  # full lifecycle (default)\n"
            "  python3 test_lifecycle.py ./terraform.tfvars\n"
            "\n"
            "  # create + plan + apply only, no destroy\n"
            "  python3 test_lifecycle.py ./terraform.tfvars \\\n"
            "      --phases create plan-orch apply-orch sub-ws\n"
            "\n"
            "  # destroy an already-applied workspace by ID\n"
            "  python3 test_lifecycle.py ./terraform.tfvars \\\n"
            "      --ws-id us-south.workspace.bnk-23-test-xxx.abc123 \\\n"
            "      --phases destroy-sub destroy-orch delete\n"
        ),
    )
    parser.add_argument("tfvars", nargs="?", default=TFVARS_DEFAULT,
                        help="Path to terraform.tfvars (default: %(default)s)")
    parser.add_argument("--branch", default="main",
                        help="GitHub branch to test (default: %(default)s)")
    parser.add_argument(
        "--phases", nargs="+", default=VALID_PHASES,
        choices=VALID_PHASES, metavar="PHASE",
        help=(
            "One or more phases to run (default: all). "
            "Choices: " + " ".join(VALID_PHASES)
        ),
    )
    parser.add_argument(
        "--ws-id", default=None, dest="ws_id", metavar="WS_ID",
        help="Existing orchestration workspace ID — required when 'create' is not in --phases",
    )
    parser.add_argument(
        "--list", action="store_true",
        help="Display workspace tree (orchestration + sub-workspaces) and exit",
    )
    parser.add_argument(
        "--outputs", action="store_true",
        help="Print orchestration workspace output variables and exit (requires --ws-id)",
    )
    args = parser.parse_args()

    if args.list:
        return show_workspace_tree(args.tfvars)

    if args.outputs:
        if not args.ws_id:
            print(
                "ERROR: --ws-id is required with --outputs\n"
                "       Use --list to find the orchestration workspace ID."
            )
            return 1
        return show_outputs(args.ws_id)

    tfvars_path = args.tfvars
    branch      = args.branch
    run         = set(args.phases)
    REPORT_DIR.mkdir(exist_ok=True)

    # Validate: --ws-id required when 'create' is skipped but later phases need the workspace
    needs_ws = run & {"plan-orch", "apply-orch", "sub-ws", "destroy-sub", "destroy-orch", "delete"}
    if "create" not in run and needs_ws and not args.ws_id:
        print(
            "ERROR: --ws-id is required when 'create' is not in --phases\n"
            "       e.g. --ws-id us-south.workspace.bnk-23-test-xxx.abc123"
        )
        return 1

    ts_label    = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    report_path = REPORT_DIR / f"lifecycle_{ts_label}.txt"
    log_path    = REPORT_DIR / f"lifecycle_{ts_label}_logs.txt"

    started_at     = datetime.now(timezone.utc)
    orch_ws_id     = args.ws_id or None
    orch_ws_name   = None
    sub_workspaces = []   # [{slot, name, label, id, enabled}, ...]
    phases         = []
    outputs        = {}
    overall        = "FAIL"

    W = 72

    # Sentinel phases used for dependency checks when a phase is not in `run`.
    # Status "SKIP" means "not selected — do not treat as failure".
    p_plan_orch  = Phase("plan orch");  p_plan_orch.status  = "SKIP"
    p_apply_orch = Phase("apply orch"); p_apply_orch.status = "SKIP"

    with open(log_path, "w") as lf:

        def section(title):
            bar = "─" * W
            tee(f"\n{bar}\n  {title}\n{bar}", lf)

        def cleanup():
            if not orch_ws_id:
                return
            tee(f"\n  Cleanup: destroying orchestration workspace {orch_ws_id} ...", lf)
            run_cmd(f"ibmcloud schematics destroy --id {orch_ws_id} --force",
                    lf=lf, stream=True)
            poll_until_terminal(orch_ws_id, "cleanup-destroy", lf, timeout=ORCH_TIMEOUT)
            tee(f"  Cleanup: deleting orchestration workspace {orch_ws_id} ...", lf)
            run_cmd(f"ibmcloud schematics workspace delete --id {orch_ws_id} --force", lf=lf)

        def _sigint(sig, frame):
            tee("\n\nInterrupted by user — running cleanup...", lf)
            cleanup()
            report = render_report(started_at, orch_ws_id, orch_ws_name,
                                   phases, outputs, "INTERRUPTED")
            tee(report, lf)
            report_path.write_text(report)
            sys.exit(130)

        signal.signal(signal.SIGINT, _sigint)

        # ── Pre-flight (always) ───────────────────────────────────────────
        section("PRE-FLIGHT — Check ibmcloud CLI login")
        p = Phase("preflight")
        t0 = time.time()
        try:
            rc, out, err = run_cmd("ibmcloud iam oauth-tokens")
            if rc != 0:
                raise RuntimeError(
                    "Not logged in. Run: ibmcloud login --apikey YOUR_API_KEY -r REGION"
                )
            tee("  ibmcloud CLI authenticated", lf)
            p.status = "PASS"
        except Exception as exc:
            p.status = "FAIL"
            p.error  = str(exc)
            tee(f"  ERROR: {exc}", lf)
        p.duration = int(time.time() - t0)
        phases.append(p)
        if p.status != "PASS":
            report = render_report(started_at, orch_ws_id, orch_ws_name, phases, outputs, "FAIL")
            tee(report, lf); report_path.write_text(report)
            return 1

        # ── Setup (always) ────────────────────────────────────────────────
        section("SETUP — Parse terraform.tfvars → workspace.json")
        p = Phase("setup")
        t0 = time.time()
        try:
            if not Path(tfvars_path).exists():
                raise FileNotFoundError(
                    f"{tfvars_path} not found — "
                    "copy terraform.tfvars.example and fill in your values"
                )
            variables    = parse_tfvars(tfvars_path)
            # Inject ws_name_suffix so sub-workspaces share this run's timestamp
            variables = [v for v in variables if v["name"] != "ws_name_suffix"]
            variables.append({"name": "ws_name_suffix", "value": ts_label, "type": "string"})
            ws           = build_workspace_json(variables, ts_label, branch=branch)
            orch_ws_name = ws["name"]

            # If an existing workspace ID was supplied, resolve its name for the report
            if orch_ws_id:
                try:
                    d = ibmcloud_json(f"ibmcloud schematics workspace get --id {orch_ws_id}", lf)
                    orch_ws_name = d.get("name", orch_ws_id)
                except Exception:
                    orch_ws_name = orch_ws_id

            var_map = {v["name"]: v["value"] for v in variables}

            def bool_var(name, default=True):
                v = var_map.get(name, "true" if default else "false")
                return v.lower() not in ("false", "0", "no")

            for slot, ws_base_name, ctrl_var in SUB_WORKSPACE_DEFS:
                enabled  = bool_var(ctrl_var) if ctrl_var else True
                ws_name  = f"{ws_base_name}-{ts_label}"
                short    = ws_base_name.replace("bnk-23-", "")
                sub_workspaces.append({
                    "slot":    slot,
                    "name":    ws_name,
                    "label":   f"ws{slot} {short}",
                    "id":      None,
                    "enabled": enabled,
                })

            tee(f"  {len(variables)} variables parsed from {tfvars_path}", lf)
            tee(f"  Orchestration workspace : {orch_ws_name}", lf)
            tee(f"  Branch                  : {branch}", lf)
            tee(f"  Location                : {ws['location']}", lf)
            tee(f"  Phases selected         : {' '.join(p for p in VALID_PHASES if p in run)}", lf)
            if orch_ws_id:
                tee(f"  Workspace ID (--ws-id)  : {orch_ws_id}", lf)
            for sw in sub_workspaces:
                state = "enabled" if sw["enabled"] else "disabled"
                tee(f"  ws{sw['slot']} {sw['name']:<26} {state}", lf)
            p.status = "PASS"
        except Exception as exc:
            p.status = "FAIL"
            p.error  = str(exc)
            tee(f"  ERROR: {exc}", lf)
        p.duration = int(time.time() - t0)
        phases.append(p)
        if p.status != "PASS":
            report = render_report(started_at, orch_ws_id, orch_ws_name, phases, outputs, "FAIL")
            tee(report, lf); report_path.write_text(report)
            return 1

        # ── Phase: create ─────────────────────────────────────────────────
        if "create" in run:
            section("PHASE — Create orchestration workspace")
            p = Phase("create")
            t0 = time.time()
            try:
                rc, out, err = run_cmd(
                    f"ibmcloud schematics workspace new --file {WS_JSON_PATH} --output json"
                )
                if out.strip():
                    print(out, file=lf, flush=True)
                if rc != 0:
                    raise RuntimeError((err or out).strip())
                data = json.loads(out)
                orch_ws_id = data.get("id") or data.get("workspace_id")
                if not orch_ws_id:
                    raise RuntimeError(f"workspace ID not in response: {out[:300]}")
                tee(f"  Workspace ID : {orch_ws_id}", lf)
                tee("  Waiting for workspace to become ready...", lf)
                status = wait_for_workspace_ready(orch_ws_id, lf)
                tee(f"  Ready status : {status}", lf)
                p.status = "PASS"
            except Exception as exc:
                p.status = "FAIL"
                p.error  = str(exc)
                tee(f"  ERROR: {exc}", lf)
            p.duration = int(time.time() - t0)
            phases.append(p)
            if p.status != "PASS":
                report = render_report(started_at, orch_ws_id, orch_ws_name, phases, outputs, "FAIL")
                tee(report, lf); report_path.write_text(report)
                return 1

        # ── Phase: plan-orch ──────────────────────────────────────────────
        if "plan-orch" in run:
            section("PHASE — Plan orchestration workspace")
            t0 = time.time()
            try:
                passed, final_status, elapsed = run_job(
                    cmd             = f"ibmcloud schematics plan --id {orch_ws_id}",
                    ws_id           = orch_ws_id,
                    label           = "plan-orch",
                    lf              = lf,
                    success_statuses= {"INACTIVE", "ACTIVE"},
                    timeout         = ORCH_TIMEOUT,
                )
                tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
                p_plan_orch.status = "PASS" if passed else "FAIL"
                if not passed:
                    p_plan_orch.error = f"status after plan: {final_status}"
            except Exception as exc:
                p_plan_orch.status = "FAIL"
                p_plan_orch.error  = str(exc)
                tee(f"  ERROR: {exc}", lf)
            p_plan_orch.duration = int(time.time() - t0)
            phases.append(p_plan_orch)

        # ── Phase: apply-orch ─────────────────────────────────────────────
        if "apply-orch" in run:
            if p_plan_orch.status == "FAIL":
                p_apply_orch.status = "SKIP"
                p_apply_orch.error  = "skipped — orchestration plan failed"
                phases.append(p_apply_orch)
            else:
                section("PHASE — Apply orchestration workspace (create sub-workspaces)")
                t0 = time.time()
                try:
                    passed, final_status, elapsed = run_job(
                        cmd             = f"ibmcloud schematics apply --id {orch_ws_id} --force",
                        ws_id           = orch_ws_id,
                        label           = "apply-orch",
                        lf              = lf,
                        success_statuses= {"ACTIVE"},
                        timeout         = ORCH_TIMEOUT,
                    )
                    tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
                    p_apply_orch.status = "PASS" if passed else "FAIL"
                    if not passed:
                        p_apply_orch.error = f"status after apply: {final_status}"
                except Exception as exc:
                    p_apply_orch.status = "FAIL"
                    p_apply_orch.error  = str(exc)
                    tee(f"  ERROR: {exc}", lf)
                p_apply_orch.duration = int(time.time() - t0)
                phases.append(p_apply_orch)

        # ── Discover sub-workspace IDs ────────────────────────────────────
        if run & {"sub-ws", "destroy-sub"}:
            section("Discover sub-workspace IDs")
            find_subworkspace_ids(sub_workspaces, lf)

        # ── Phase: sub-ws (plan→apply ws1→ws6, interleaved) ──────────────
        # Downstream workspaces have data sources that look up the ROKS cluster
        # by name; those are evaluated at plan time, so each workspace must be
        # fully applied before the next workspace is planned.
        if "sub-ws" in run:
            # SKIP means the phase was not selected — not a failure; allow sub-ws to proceed.
            proceed = p_apply_orch.status in {"PASS", "SKIP"}

            for sw in sub_workspaces:
                enabled = sw["enabled"]
                ws_id   = sw["id"]

                # ── Plan ──────────────────────────────────────────────────
                p_plan = Phase(f"plan {sw['label']}")

                if not enabled:
                    p_plan.status = "SKIP"
                    p_plan.error  = "disabled (controlling variable is false)"
                elif not proceed:
                    p_plan.status = "SKIP"
                    p_plan.error  = "skipped — previous workspace failed"
                elif not ws_id:
                    p_plan.status = "FAIL"
                    p_plan.error  = f"{sw['name']} not found after orchestration apply"
                    proceed = False
                else:
                    section(f"PLAN — ws{sw['slot']} {sw['name']}")
                    t0           = time.time()
                    passed       = False
                    final_status = "FAILED"
                    # ws3 FLO installs operators and network attachments that temporarily
                    # put the ROKS cluster in a reconfiguring state. The IBM Container Service
                    # API returns 400 on ibm_container_cluster_config reads during this window.
                    # Wait before attempting ws4 plan to let the cluster stabilize.
                    if sw["slot"] == 4:
                        pre_plan_wait = 180
                        tee(f"  Waiting {pre_plan_wait}s for cluster to stabilize "
                            f"after ws3 FLO changes ...", lf)
                        time.sleep(pre_plan_wait)
                    for attempt in range(PLAN_RETRIES + 1):
                        if attempt > 0:
                            tee(f"  Plan FAILED — waiting {PLAN_RETRY_WAIT}s then retrying "
                                f"(attempt {attempt}/{PLAN_RETRIES}) ...", lf)
                            time.sleep(PLAN_RETRY_WAIT)
                            try:
                                wait_for_workspace_ready(ws_id, lf)
                            except Exception:
                                pass
                        try:
                            passed, final_status, elapsed = run_job(
                                cmd             = f"ibmcloud schematics plan --id {ws_id}",
                                ws_id           = ws_id,
                                label           = f"plan-ws{sw['slot']}",
                                lf              = lf,
                                success_statuses= {"INACTIVE", "ACTIVE"},
                                timeout         = JOB_TIMEOUT,
                            )
                            tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
                            if passed:
                                break
                        except Exception as exc:
                            tee(f"  ERROR: {exc}", lf)
                            if attempt >= PLAN_RETRIES:
                                p_plan.status = "FAIL"
                                p_plan.error  = str(exc)
                                proceed = False
                            continue
                    p_plan.status = "PASS" if passed else "FAIL"
                    if not passed and not p_plan.error:
                        p_plan.error = f"status after plan: {final_status}"
                        proceed = False
                    p_plan.duration = int(time.time() - t0)

                phases.append(p_plan)

                # ── Apply ──────────────────────────────────────────────────
                p_apply = Phase(f"apply {sw['label']}")

                if not enabled:
                    p_apply.status = "SKIP"
                    p_apply.error  = "disabled"
                elif p_plan.status != "PASS":
                    p_apply.status = "SKIP"
                    p_apply.error  = "skipped — plan did not pass"
                elif not proceed:
                    p_apply.status = "SKIP"
                    p_apply.error  = "skipped — previous workspace failed"
                else:
                    section(f"APPLY — ws{sw['slot']} {sw['name']}")
                    t0 = time.time()
                    try:
                        passed, final_status, elapsed = run_job(
                            cmd             = f"ibmcloud schematics apply --id {ws_id} --force",
                            ws_id           = ws_id,
                            label           = f"apply-ws{sw['slot']}",
                            lf              = lf,
                            success_statuses= {"ACTIVE"},
                            timeout         = JOB_TIMEOUT,
                        )
                        tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
                        p_apply.status = "PASS" if passed else "FAIL"
                        if not passed:
                            p_apply.error = f"status after apply: {final_status}"
                            proceed = False
                    except Exception as exc:
                        p_apply.status = "FAIL"
                        p_apply.error  = str(exc)
                        proceed = False
                        tee(f"  ERROR: {exc}", lf)
                    p_apply.duration = int(time.time() - t0)

                phases.append(p_apply)

                # Track whether an apply actually ran (vs. being skipped because plan failed).
                # Used in destroy-sub to avoid triggering Terraform refresh on workspaces
                # whose plan failed and therefore have no managed state.
                sw["apply_attempted"] = p_apply.status in {"PASS", "FAIL"}

                # ── After ws3 apply: inject ws3 outputs directly into ws4 variablestore ──
                # flo_trusted_profile_id / flo_cluster_issuer_name /
                # cneinstance_network_attachments are empty when the orchestration
                # workspace first creates ws4 (read_ws_outputs=false at that time).
                # We read them from ws3 and patch ws4 directly rather than reapplying
                # the orchestration workspace, which would fail because it also tries
                # to read ws4/ws5/ws6 outputs (those workspaces have no statefiles yet).
                if sw["slot"] == 3 and p_apply.status == "PASS" and proceed:
                    section("Wiring ws3 outputs into ws4 (CNEInstance) variablestore")
                    p_reapply = Phase("reapply orch (ws3→ws4 wire)")
                    t0 = time.time()
                    try:
                        ws4 = next((s for s in sub_workspaces if s["slot"] == 4), None)
                        if not ws4 or not ws4.get("id"):
                            raise RuntimeError("ws4 ID not found — cannot wire ws3 outputs")
                        wire_ws3_outputs_into_ws4(sw["id"], ws4["id"], lf)
                        p_reapply.status = "PASS"
                    except Exception as exc:
                        p_reapply.status = "FAIL"
                        p_reapply.error  = str(exc)
                        proceed = False
                        tee(f"  ERROR: {exc}", lf)
                    p_reapply.duration = int(time.time() - t0)
                    phases.append(p_reapply)

        # ── Phase: destroy-sub (ws6→ws1) ──────────────────────────────────
        # Skip workspaces that are INACTIVE/DRAFT — they were never applied
        # and have no managed state.  Also skip workspaces that are FAILED
        # but never had an apply attempted (plan-only failure): Terraform
        # refresh will fail on data sources (e.g. cluster kubeconfig lookup)
        # even though the state is empty.
        if "destroy-sub" in run:
            for sw in reversed(sub_workspaces):
                p = Phase(f"destroy {sw['label']}")

                if not sw["enabled"]:
                    p.status = "SKIP"
                    p.error  = "disabled"
                    phases.append(p)
                    continue

                if not sw["id"]:
                    p.status = "SKIP"
                    p.error  = f"{sw['name']} not found — nothing to destroy"
                    phases.append(p)
                    continue

                pre_status     = get_ws_status(sw["id"])
                # apply_attempted is set by the sub-ws phase; True if apply ran (pass or fail).
                # Default True (conservative) when the sub-ws phase was not part of this run.
                apply_attempted = sw.get("apply_attempted", True)
                if pre_status in {"INACTIVE", "DRAFT"} or (pre_status == "FAILED" and not apply_attempted):
                    tee(f"  Skipping destroy of ws{sw['slot']} — status={pre_status} (no managed state)", lf)
                    p.status = "SKIP"
                    p.error  = f"no managed state (status={pre_status})"
                    phases.append(p)
                    continue

                section(f"DESTROY — ws{sw['slot']} {sw['name']}")
                t0 = time.time()
                passed      = False
                final_status = "FAILED"
                for attempt in range(DESTROY_RETRIES + 1):
                    if attempt > 0:
                        tee(f"  Destroy FAILED — waiting 30s then retrying "
                            f"(attempt {attempt}/{DESTROY_RETRIES}) ...", lf)
                        time.sleep(30)
                        try:
                            wait_for_workspace_ready(sw["id"], lf)
                        except Exception:
                            pass
                    try:
                        passed, final_status, elapsed = run_job(
                            cmd             = f"ibmcloud schematics destroy --id {sw['id']} --force",
                            ws_id           = sw["id"],
                            label           = f"destroy-ws{sw['slot']}",
                            lf              = lf,
                            success_statuses= {"INACTIVE", "DRAFT"},
                            timeout         = JOB_TIMEOUT,
                        )
                        tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
                        if passed:
                            break
                    except Exception as exc:
                        tee(f"  ERROR: {exc}", lf)
                        if attempt >= DESTROY_RETRIES:
                            p.status = "FAIL"
                            p.error  = str(exc)
                            break
                        continue
                p.status = "PASS" if passed else "FAIL"
                if not passed and not p.error:
                    p.error = f"status after destroy: {final_status}"
                p.duration = int(time.time() - t0)
                phases.append(p)

        # ── Phase: destroy-orch ───────────────────────────────────────────
        if "destroy-orch" in run:
            section("PHASE — Destroy orchestration workspace")
            p = Phase("destroy orch")
            t0 = time.time()
            passed      = False
            final_status = "FAILED"
            for attempt in range(DESTROY_RETRIES + 1):
                if attempt > 0:
                    tee(f"  Destroy-orch FAILED — waiting 30s then retrying "
                        f"(attempt {attempt}/{DESTROY_RETRIES}) ...", lf)
                    time.sleep(30)
                    try:
                        wait_for_workspace_ready(orch_ws_id, lf)
                    except Exception:
                        pass
                try:
                    passed, final_status, elapsed = run_job(
                        cmd             = f"ibmcloud schematics destroy --id {orch_ws_id} --force",
                        ws_id           = orch_ws_id,
                        label           = "destroy-orch",
                        lf              = lf,
                        success_statuses= {"INACTIVE", "DRAFT"},
                        timeout         = ORCH_TIMEOUT,
                    )
                    tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
                    if passed:
                        break
                except Exception as exc:
                    tee(f"  ERROR: {exc}", lf)
                    if attempt >= DESTROY_RETRIES:
                        p.status = "FAIL"
                        p.error  = str(exc)
                        break
                    continue
            p.status = "PASS" if passed else "FAIL"
            if not passed and not p.error:
                p.error = f"status after destroy: {final_status}"
            p.duration = int(time.time() - t0)
            phases.append(p)

        # ── Phase: delete ─────────────────────────────────────────────────
        if "delete" in run:
            section("PHASE — Delete orchestration workspace")
            p = Phase("delete")
            t0 = time.time()
            try:
                rc, out, err = run_cmd(
                    f"ibmcloud schematics workspace delete --id {orch_ws_id} --force",
                    lf=lf,
                )
                if out.strip():
                    print(out, file=lf, flush=True)
                if rc != 0:
                    raise RuntimeError((err or out).strip())
                tee(f"  Workspace {orch_ws_id} deleted", lf)
                p.status = "PASS"
            except Exception as exc:
                p.status = "FAIL"
                p.error  = str(exc)
                tee(
                    f"  Manual cleanup required:\n"
                    f"    ibmcloud schematics workspace delete --id {orch_ws_id} --force",
                    lf,
                )
            p.duration = int(time.time() - t0)
            phases.append(p)

        # ── Final result ──────────────────────────────────────────────────
        failed  = [ph for ph in phases if ph.status == "FAIL"]
        overall = "PASS" if not failed else "FAIL"

    report = render_report(started_at, orch_ws_id, orch_ws_name, phases, outputs, overall)
    print(report)
    report_path.write_text(report)
    print(f"  Report : {report_path}")
    print(f"  Logs   : {log_path}")

    return 0 if overall == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())

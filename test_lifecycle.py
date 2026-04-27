#!/usr/bin/env python3
"""
BIG-IP Next for Kubernetes 2.3 — Schematics Lifecycle Test Runner

Reads terraform.tfvars, creates a timestamped orchestration workspace,
runs plan → apply → destroy → delete, captures logs and outputs, and
writes a report to both the console and ./test-reports/.

Usage:
    python3 test_lifecycle.py [path/to/terraform.tfvars] [--branch BRANCH]

    --branch BRANCH   GitHub branch to test (default: main)

Examples:
    python3 test_lifecycle.py
    python3 test_lifecycle.py terraform.tfvars --branch my-feature-branch

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

POLL_INTERVAL = 30     # seconds between status polls when no log stream
JOB_TIMEOUT   = 10800  # 3 h max per phase (ROKS cluster creation is slow)
READY_TIMEOUT = 180    # seconds to wait for workspace to leave CONNECTING

SECURE_VARS = {"ibmcloud_api_key", "bigip_password"}

# Workspace status values that mean a job finished
TERMINAL_STATUSES = {"INACTIVE", "ACTIVE", "FAILED", "STOPPED", "DRAFT"}

# Outputs printed in the report (in order)
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
    """Print to console and optionally to an open log file."""
    print(msg, flush=True)
    if lf:
        print(msg, file=lf, flush=True)


def run_cmd(cmd, lf=None, stream=False):
    """
    Run a shell command.

    stream=False (default): capture stdout/stderr, return (rc, stdout, stderr).
    stream=True:            stream stdout+stderr live to console and lf,
                            return (rc, combined_output, "").
    """
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
    """Run an ibmcloud command, append --output json, return parsed dict/list."""
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
    """Return (status, locked) for the workspace, or ('UNKNOWN', True) on error."""
    try:
        data   = ibmcloud_json(f"ibmcloud schematics workspace get --id {ws_id}")
        status = data.get("status") or data.get("workspace_status_msg", {}).get("status_code") or "UNKNOWN"
        locked = data.get("workspace_status", {}).get("locked", False)
        return status, locked
    except Exception:
        return "UNKNOWN", True


def get_ws_status(ws_id):
    """Return current workspace status string."""
    status, _ = get_ws_info(ws_id)
    return status


def wait_for_workspace_ready(ws_id, lf, timeout=READY_TIMEOUT):
    """
    After workspace creation Schematics locks the workspace while it scans
    the template repo.  Poll until status is INACTIVE (scan done) and the
    workspace is no longer locked.  Returns the final status string.
    """
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
    """
    Poll workspace status every POLL_INTERVAL seconds until it reaches a
    terminal state.  Used when log streaming is unavailable.
    Returns (final_status, elapsed_seconds).
    """
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


def settle_status(ws_id, lf, timeout=120):
    """
    Short poll used immediately after log streaming ends, to let the
    workspace status catch up.  Returns final status string.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = get_ws_status(ws_id)
        if status in TERMINAL_STATUSES:
            return status
        time.sleep(10)
    return get_ws_status(ws_id)


def stream_logs(ws_id, act_id, lf):
    """Stream Schematics activity logs; blocks until the activity ends."""
    run_cmd(
        f"ibmcloud schematics logs --id {ws_id} --act-id {act_id}",
        lf=lf, stream=True,
    )


def run_job(cmd, ws_id, label, lf, success_statuses, max_lock_retries=6):
    """
    Execute a Schematics job command (plan / apply / destroy), wait for
    completion, fetch the final logs, and return (pass_bool, final_status,
    duration).

    `ibmcloud schematics logs` exits as soon as the current log buffer is
    drained — it does NOT tail/follow.  We therefore:
      1. Snapshot the workspace status before submitting the job so we can
         detect when the new activity has actually changed the state.
      2. After submitting, wait up to 120 s for the workspace status to
         diverge from the pre-job snapshot (proving the activity started).
      3. Poll until a new terminal status is reached.
      4. Fetch the complete logs once the activity is done.

    Retries up to max_lock_retries times on 409 workspace-locked responses,
    waiting 30 s longer each attempt.
    """
    # Snapshot status before the job so we can detect real state changes later.
    pre_status = get_ws_status(ws_id)

    for attempt in range(1, max_lock_retries + 1):
        rc, out, err = run_cmd(f"{cmd} --output json")
        combined = (out + err).lower()
        if rc == 0:
            break
        if "409" in combined or "temporarily locked" in combined:
            wait = attempt * 30
            tee(f"  Workspace locked (409) — retrying in {wait}s "
                f"(attempt {attempt}/{max_lock_retries})", lf)
            time.sleep(wait)
            continue
        # Non-retriable error
        if out.strip():
            print(out, file=lf, flush=True)
        raise RuntimeError((err or out).strip())
    else:
        raise RuntimeError(f"Workspace still locked after {max_lock_retries} retries: {cmd}")

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
        # Wait for the workspace status to leave the pre-job state, confirming
        # the activity has been picked up and is changing workspace state.
        tee("  Waiting for activity to start...", lf)
        t_transition = time.time()
        while time.time() - t_transition < 120:
            if get_ws_status(ws_id) != pre_status:
                break
            time.sleep(5)

        tee("  Polling until activity completes...", lf)
        final_status, _ = poll_until_terminal(ws_id, label, lf)

        # Fetch complete logs now that the activity is finished.
        tee("  Fetching final logs...", lf)
        stream_logs(ws_id, act_id, lf)
        tee("", lf)
    else:
        tee("  No activity ID returned — polling workspace status...", lf)
        final_status, _ = poll_until_terminal(ws_id, label, lf)

    elapsed = int(time.time() - t0)
    passed  = final_status in success_statuses
    return passed, final_status, elapsed


def fetch_outputs(ws_id, lf):
    """Return workspace outputs as {name: value}."""
    try:
        data  = ibmcloud_json(f"ibmcloud schematics output --id {ws_id}", lf)
        items = data if isinstance(data, list) else [data]
        out   = {}
        for template in items:
            for item in template.get("output_values", []):
                out[item["name"]] = item.get("value", "")
        return out
    except Exception as exc:
        tee(f"  WARNING: could not fetch outputs: {exc}", lf)
        return {}


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
        f"  Started        {started_at.strftime('%Y-%m-%d %H:%M:%S UTC')}",
        f"  Workspace      {ws_name or 'not created'}",
        f"  Workspace ID   {ws_id   or 'not created'}",
        f"  Result         {overall}",
        f"  Total time     {elapsed}s  ({elapsed / 60:.1f} min)",
        thn,
        f"  {'Phase':<24} {'Result':<10} {'Duration':>10}",
        thn,
    ]
    for p in phases:
        lines.append(f"  {p.name:<24} {p.status:<10} {p.duration:>8}s")
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


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Schematics lifecycle test runner")
    parser.add_argument("tfvars", nargs="?", default=TFVARS_DEFAULT,
                        help="Path to terraform.tfvars (default: %(default)s)")
    parser.add_argument("--branch", default="main",
                        help="GitHub branch to test (default: %(default)s)")
    args = parser.parse_args()

    tfvars_path = args.tfvars
    branch      = args.branch
    REPORT_DIR.mkdir(exist_ok=True)

    ts_label    = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    report_path = REPORT_DIR / f"lifecycle_{ts_label}.txt"
    log_path    = REPORT_DIR / f"lifecycle_{ts_label}_logs.txt"

    started_at = datetime.now(timezone.utc)
    ws_id      = None
    ws_name    = None
    phases     = []
    outputs    = {}
    overall    = "FAIL"

    W = 72

    def section(title):
        bar = "─" * W
        msg = f"\n{bar}\n  {title}\n{bar}"
        tee(msg, lf)

    def cleanup():
        """Best-effort destroy + delete on interrupt or early exit."""
        if not ws_id:
            return
        tee(f"\n  Cleanup: destroying workspace {ws_id} ...", lf)
        run_cmd(f"ibmcloud schematics destroy --id {ws_id} --force", lf=lf, stream=True)
        poll_until_terminal(ws_id, "cleanup-destroy", lf, timeout=3600)
        tee(f"  Cleanup: deleting workspace {ws_id} ...", lf)
        run_cmd(f"ibmcloud schematics workspace delete --id {ws_id} --force", lf=lf)

    with open(log_path, "w") as lf:

        # Register Ctrl-C handler after lf is open
        def _sigint(sig, frame):
            tee("\n\nInterrupted by user — running cleanup...", lf)
            cleanup()
            report = render_report(started_at, ws_id, ws_name, phases, outputs, "INTERRUPTED")
            tee(report, lf)
            report_path.write_text(report)
            sys.exit(130)

        signal.signal(signal.SIGINT, _sigint)

        # ── Pre-flight ────────────────────────────────────────────────
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
            report = render_report(started_at, ws_id, ws_name, phases, outputs, "FAIL")
            tee(report, lf)
            report_path.write_text(report)
            return 1

        # ── Setup ─────────────────────────────────────────────────────
        section("SETUP — Parse terraform.tfvars → workspace.json")
        p = Phase("setup")
        t0 = time.time()
        try:
            if not Path(tfvars_path).exists():
                raise FileNotFoundError(
                    f"{tfvars_path} not found — "
                    "copy terraform.tfvars.example and fill in your values"
                )
            variables = parse_tfvars(tfvars_path)
            ws        = build_workspace_json(variables, ts_label, branch=branch)
            ws_name   = ws["name"]
            tee(f"  {len(variables)} variables parsed from {tfvars_path}", lf)
            tee(f"  workspace name  : {ws['name']}", lf)
            tee(f"  branch          : {branch}", lf)
            tee(f"  location        : {ws['location']}", lf)
            tee(f"  resource_group  : {ws['resource_group']}", lf)
            tee(f"  workspace.json  : written", lf)
            p.status = "PASS"
        except Exception as exc:
            p.status = "FAIL"
            p.error  = str(exc)
            tee(f"  ERROR: {exc}", lf)
        p.duration = int(time.time() - t0)
        phases.append(p)

        if p.status != "PASS":
            report = render_report(started_at, ws_id, ws_name, phases, outputs, "FAIL")
            tee(report, lf)
            report_path.write_text(report)
            return 1

        # ── Phase 1: Create ───────────────────────────────────────────
        section("PHASE 1 — Create workspace")
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
            data  = json.loads(out)
            ws_id = data.get("id") or data.get("workspace_id")
            if not ws_id:
                raise RuntimeError(f"workspace ID not in response: {out[:300]}")
            tee(f"  Workspace ID : {ws_id}", lf)

            # Wait for Schematics to finish scanning the repo and release the lock
            tee("  Waiting for workspace to become ready...", lf)
            status = wait_for_workspace_ready(ws_id, lf)
            tee(f"  Ready status : {status}", lf)
            p.status = "PASS"
        except Exception as exc:
            p.status = "FAIL"
            p.error  = str(exc)
            tee(f"  ERROR: {exc}", lf)
        p.duration = int(time.time() - t0)
        phases.append(p)

        if p.status != "PASS":
            report = render_report(started_at, ws_id, ws_name, phases, outputs, "FAIL")
            tee(report, lf)
            report_path.write_text(report)
            return 1

        # ── Phase 2: Plan ─────────────────────────────────────────────
        section("PHASE 2 — Plan")
        p = Phase("plan")
        t0 = time.time()
        try:
            passed, final_status, elapsed = run_job(
                cmd             = f"ibmcloud schematics plan --id {ws_id}",
                ws_id           = ws_id,
                label           = "plan",
                lf              = lf,
                success_statuses= {"INACTIVE", "ACTIVE"},
            )
            tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
            p.status = "PASS" if passed else "FAIL"
            if not passed:
                p.error = f"workspace status after plan: {final_status}"
        except Exception as exc:
            p.status = "FAIL"
            p.error  = str(exc)
            tee(f"  ERROR: {exc}", lf)
        p.duration = int(time.time() - t0)
        phases.append(p)

        # ── Phase 3: Apply ────────────────────────────────────────────
        p_apply = Phase("apply")
        if p.status == "PASS":
            section("PHASE 3 — Apply")
            t0 = time.time()
            try:
                passed, final_status, elapsed = run_job(
                    cmd             = f"ibmcloud schematics apply --id {ws_id} --force",
                    ws_id           = ws_id,
                    label           = "apply",
                    lf              = lf,
                    success_statuses= {"ACTIVE"},
                )
                tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
                p_apply.status = "PASS" if passed else "FAIL"
                if not passed:
                    p_apply.error = f"workspace status after apply: {final_status}"
            except Exception as exc:
                p_apply.status = "FAIL"
                p_apply.error  = str(exc)
                tee(f"  ERROR: {exc}", lf)
            p_apply.duration = int(time.time() - t0)

            if p_apply.status == "PASS":
                section("Outputs")
                outputs = fetch_outputs(ws_id, lf)
                if outputs:
                    for key in KEY_OUTPUTS:
                        val = outputs.get(key)
                        if val is not None:
                            tee(f"  {key}", lf)
                            tee(f"    {val}", lf)
                else:
                    tee("  (no outputs returned)", lf)
        else:
            p_apply.status = "SKIP"
            p_apply.error  = "skipped — plan failed"
        phases.append(p_apply)

        # ── Phase 4: Destroy ──────────────────────────────────────────
        section("PHASE 4 — Destroy")
        p = Phase("destroy")
        t0 = time.time()
        try:
            passed, final_status, elapsed = run_job(
                cmd             = f"ibmcloud schematics destroy --id {ws_id} --force",
                ws_id           = ws_id,
                label           = "destroy",
                lf              = lf,
                success_statuses= {"INACTIVE", "DRAFT"},
            )
            tee(f"  Final status : {final_status}  ({elapsed}s)", lf)
            p.status = "PASS" if passed else "FAIL"
            if not passed:
                p.error = f"workspace status after destroy: {final_status}"
        except Exception as exc:
            p.status = "FAIL"
            p.error  = str(exc)
            tee(f"  ERROR: {exc}", lf)
        p.duration = int(time.time() - t0)
        phases.append(p)

        # ── Phase 5: Delete workspace ─────────────────────────────────
        section("PHASE 5 — Delete workspace")
        p = Phase("delete")
        t0 = time.time()
        try:
            rc, out, err = run_cmd(
                f"ibmcloud schematics workspace delete --id {ws_id} --force",
                lf=lf,
            )
            if out.strip():
                print(out, file=lf, flush=True)
            if rc != 0:
                raise RuntimeError((err or out).strip())
            tee(f"  Workspace {ws_id} deleted", lf)
            p.status = "PASS"
        except Exception as exc:
            p.status = "FAIL"
            p.error  = str(exc)
            tee(f"  ERROR: {exc}", lf)
            tee(
                f"  Manual cleanup required:\n"
                f"    ibmcloud schematics workspace delete --id {ws_id} --force",
                lf,
            )
        p.duration = int(time.time() - t0)
        phases.append(p)

        # ── Final result ──────────────────────────────────────────────
        failed  = [ph for ph in phases if ph.status == "FAIL"]
        overall = "PASS" if not failed else "FAIL"

    report = render_report(started_at, ws_id, ws_name, phases, outputs, overall)
    print(report)
    report_path.write_text(report)
    print(f"  Report : {report_path}")
    print(f"  Logs   : {log_path}")

    return 0 if overall == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
import json, re, sys

SECURE_VARS = {"ibmcloud_api_key", "bigip_password"}

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
            # Determine type and value
            if raw in ("true", "false"):
                entry = {"name": name, "value": raw, "type": "bool"}
            elif re.match(r'^-?\d+(\.\d+)?$', raw):
                entry = {"name": name, "value": raw, "type": "number"}
            else:
                entry = {"name": name, "value": raw.strip('"')}
            if name in SECURE_VARS:
                entry["secure"] = True
            variables.append(entry)
    return variables

workspace = {
    "name": "bnk-23-orchestration",
    "type": ["terraform_v1.5"],
    "location": "ca-tor",
    "resource_group": "default",
    "template_repo": {
        "url": "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_2_3",
        "branch": "main"
    },
    "template_data": [{
        "folder": ".",
        "type": "terraform_v1.5",
        "variablestore": parse_tfvars("terraform.tfvars")
    }]
}

with open("workspace.json", "w") as f:
    json.dump(workspace, f, indent=2)
print("workspace.json written")

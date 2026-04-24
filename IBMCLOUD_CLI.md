# IBM Cloud CLI — Schematics Workspace Operations

This guide covers creating the orchestration workspace, supplying variables from
`ibmcloud_cli_input_variables.json`, and triggering plan, apply, and destroy
using the IBM Cloud CLI.

---

## Prerequisites

### 1. Install the IBM Cloud CLI

```bash
curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
```

### 2. Install the Schematics and Container Service plugins

```bash
ibmcloud plugin install schematics
```

### 3. Log in

```bash
ibmcloud login --apikey YOUR_IBMCLOUD_API_KEY -r ca-tor
```

---

## Workspace setup

### Prepare your variables

Copy the Terraform variables example and fill in your values:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — at minimum set `ibmcloud_api_key` and
`testing_ssh_key_name`.

### Generate workspace.json from terraform.tfvars

`tfvars_to_schematics_input_json.py` reads `terraform.tfvars` and writes a
complete `workspace.json` in the format expected by `ibmcloud schematics
workspace new`. It automatically detects variable types (string, bool, number)
and marks `ibmcloud_api_key` and `bigip_password` as secure.

```bash
python3 tfvars_to_schematics_input_json.py
```

Output:

```
workspace.json written
```

> **Alternative — JSON variables file**: if you prefer to manage variables
> directly in JSON rather than via `terraform.tfvars`, copy
> `ibmcloud_cli_input_variables.json.example` to
> `ibmcloud_cli_input_variables.json`, fill in your values, then use `jq` to
> assemble `workspace.json`:
>
> ```bash
> cp ibmcloud_cli_input_variables.json.example ibmcloud_cli_input_variables.json
> # edit ibmcloud_cli_input_variables.json
>
> jq -n \
>   --argjson vars "$(cat ibmcloud_cli_input_variables.json)" \
>   '{
>     name: "bnk-23-orchestration",
>     type: ["terraform_v1.5"],
>     location: "ca-tor",
>     resource_group: "default",
>     template_repo: {
>       url: "https://github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_2_3",
>       branch: "main"
>     },
>     template_data: [{
>       folder: ".",
>       type: "terraform_v1.5",
>       variablestore: $vars.variablestore
>     }]
>   }' > workspace.json
> ```

### Create the workspace

```bash
ibmcloud schematics workspace new --file workspace.json
```

Note the workspace ID from the output — it looks like
`ca-tor.workspace.bnk-23-orchestration.xxxxxxxx`. Export it for use in
subsequent commands:

```bash
export WS_ID="<workspace-id>"
```

---

## Plan

```bash
ibmcloud schematics plan --id $WS_ID
```

The command returns an activity ID. Stream the logs:

```bash
ibmcloud schematics logs --id $WS_ID --act-id <activity-id>
```

Or poll the workspace status until the plan completes:

```bash
watch -n 10 ibmcloud schematics workspace get --id $WS_ID --output json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'])"
```

---

## Apply

```bash
ibmcloud schematics apply --id $WS_ID --force
```

Stream logs the same way:

```bash
ibmcloud schematics logs --id $WS_ID --act-id <activity-id>
```

After the apply completes, retrieve workspace outputs:

```bash
ibmcloud schematics output --id $WS_ID
```

---

## Updating variables

Edit `ibmcloud_cli_input_variables.json` with the new values, then push the
update to the workspace:

```bash
ibmcloud schematics workspace update --id $WS_ID --file ibmcloud_cli_input_variables.json
```

Then re-run plan and apply as above.

---

## Destroy

Destroy runs in reverse order (ws6 → ws1) via the `null_resource` destroy
provisioners in `jobs.tf`. Trigger it with:

```bash
ibmcloud schematics destroy --id $WS_ID --force
```

Stream logs:

```bash
ibmcloud schematics logs --id $WS_ID --act-id <activity-id>
```

Once all sub-workspaces are destroyed, delete the orchestration workspace itself:

```bash
ibmcloud schematics workspace delete --id $WS_ID --force
```

---

## Quick-reference

| Action               | Command                                                                    |
|----------------------|----------------------------------------------------------------------------|
| Create workspace     | `ibmcloud schematics workspace new --file workspace.json`                  |
| Get workspace status | `ibmcloud schematics workspace get --id $WS_ID`                            |
| Plan                 | `ibmcloud schematics plan --id $WS_ID`                                     |
| Apply                | `ibmcloud schematics apply --id $WS_ID --force`                            |
| Destroy              | `ibmcloud schematics destroy --id $WS_ID --force`                          |
| Delete workspace     | `ibmcloud schematics workspace delete --id $WS_ID --force`                 |
| Update variables     | `ibmcloud schematics workspace update --id $WS_ID --file <variables.json>` |
| Stream logs          | `ibmcloud schematics logs --id $WS_ID --act-id <activity-id>`              |
| List workspaces      | `ibmcloud schematics workspace list`                                       |
| View outputs         | `ibmcloud schematics output --id $WS_ID`                                   |

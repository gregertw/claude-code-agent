# Implementation Plan: Remote Agent Trigger via Lambda Function URL

**Date:** 2026-03-27
**Status:** Implemented
**Branch:** main

## Update Log

- **2026-03-27**: Extract Lambda code to separate template file (per feedback: no inline heredocs in deploy scripts). Add Phase 4 for documentation in aws-setup.md and ARCHITECTURE.md. Remote trigger is an optional add-on, not part of default installation.

## Overview

Add a Lambda Function URL that allows the user to remotely trigger an agent run from any device (e.g., iPhone via iOS Shortcuts). The Lambda calls `ec2:StartInstances`, which boots the instance and triggers the orchestrator via the existing `agent-boot-runner.service` systemd unit. A 256-bit Bearer token prevents unauthorized access.

## Decisions Made

- **Scope**: Start run only — Lambda just calls `ec2:StartInstances`. No custom messages, no status endpoint.
- **Integration**: New `deploy-trigger.sh` script (standalone, following `deploy-scheduler.sh` pattern). Stores Lambda ARN, Function URL, and token in `deploy-state.json`. [Updated 2026-03-28] Default invocation shows status; `--deploy` flag required to create resources.
- **Auth**: Bearer token (auto-generated 256-bit `secrets.token_urlsafe(32)`), verified with `hmac.compare_digest` in Lambda code.
- **Mode support**: Scheduled mode only — relies on `agent-boot-runner.service` triggering orchestrator on boot. Documented as not applicable for always-on mode. [Updated 2026-03-28] Boot-runner and resume-check both pass `--force` to orchestrator, bypassing the active-hours guard. Works for both cold boot and hibernate resume.
- **Additional hardening**: Token alone is sufficient. No rate limiting, no IP filtering, no token rotation command.

## What We're NOT Doing

- SSM integration (not installed on the instance, not needed)
- Always-on mode support (cron handles runs; starting an already-running instance is a no-op)
- Custom message/prompt passthrough to agent
- Status check endpoint
- CloudFront/WAF layer
- Token rotation command (can be added later if needed)

---

## Phase 1: Lambda Function + deploy-trigger.sh

Create the deployment script and Lambda function.

### Changes

- `deploy-trigger.sh` (new) — Standalone script that:
  - Reads `deploy-state.json` for instance_id and region (errors if missing)
  - Creates IAM role `agent-server-trigger-role` (trust: `lambda.amazonaws.com`)
  - Attaches inline policy with `ec2:StartInstances` and `ec2:DescribeInstances` scoped to the specific instance ARN
  - Attaches `AWSLambdaBasicExecutionRole` managed policy for CloudWatch Logs
  - Generates Bearer token via `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`
  - Creates Lambda function `agent-server-trigger` (Python 3.12, inline zip) with env vars: `SHARED_SECRET`, `INSTANCE_ID`, `REGION`
  - Creates Function URL (auth-type NONE)
  - Adds public invoke permission
  - Updates `deploy-state.json` with: `trigger_function_name`, `trigger_function_url`, `trigger_token`, `trigger_role_name`
  - Supports `--remove` flag to delete all trigger resources and remove keys from state
  - Supports `--show` flag to display current URL and token
  - Uses create-or-update semantics (idempotent re-runs)
  - Follows existing script conventions: header banner, color/log functions (`[TRIGGER]` prefix), completion banner with copy-friendly URL/token output

- `templates/trigger-lambda.py` (new) — Lambda function code as a separate template file:
  ```python
  import json, hashlib, hmac, os, boto3

  SHARED_SECRET = os.environ["SHARED_SECRET"]
  INSTANCE_ID = os.environ["INSTANCE_ID"]
  REGION = os.environ.get("REGION", "eu-north-1")

  def lambda_handler(event, context):
      # Verify Bearer token
      headers = event.get("headers", {})
      token = headers.get("authorization", "")
      if not hmac.compare_digest(token, f"Bearer {SHARED_SECRET}"):
          return {"statusCode": 401, "body": json.dumps({"error": "unauthorized"})}

      # Check current instance state
      ec2 = boto3.client("ec2", region_name=REGION)
      resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
      state = resp["Reservations"][0]["Instances"][0]["State"]["Name"]

      if state == "running":
          return {"statusCode": 200, "body": json.dumps({"status": "already_running"})}
      if state in ("shutting-down", "terminated"):
          return {"statusCode": 409, "body": json.dumps({"status": "error", "message": f"Instance is {state}"})}

      # Start instance
      ec2.start_instances(InstanceIds=[INSTANCE_ID])
      return {"statusCode": 200, "body": json.dumps({"status": "starting"})}
  ```

- `deploy-trigger.sh` reads this file and zips it for Lambda deployment (no inline code)

### Key patterns to follow from existing scripts

- `deploy-scheduler.sh:1-20` — header banner format
- `deploy-scheduler.sh:110-128` — `--remove` flag pattern
- `deploy-scheduler.sh:156-179` — IAM role creation with create-or-reuse
- `deploy-scheduler.sh:203-205` — IAM propagation sleep
- `deploy-scheduler.sh:244-261` — completion banner
- `deploy.sh:264-278` — writing to `deploy-state.json` (use `python3` to merge keys into existing JSON)
- Colors: `GREEN`, `YELLOW`, `RED`, `NC` with `log()`, `warn()`, `err()` functions

### Completion banner format (copy-friendly for iOS Shortcuts)

```
============================================================
 REMOTE TRIGGER DEPLOYED
============================================================

  Function URL:
    https://xxxxxxxxxx.lambda-url.eu-north-1.on.aws/

  Bearer Token:
    xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

  Test:
    curl -s -X POST '<url>' \
      -H 'Authorization: Bearer <token>' | python3 -m json.tool

  iOS Shortcuts:
    Action:  Get Contents of URL
    URL:     <Function URL above>
    Method:  POST
    Headers: Authorization = Bearer <token above>

============================================================
```

### New Tests

- Manual: Run `./deploy-trigger.sh` and verify Lambda is created in AWS
- Manual: `curl` the Function URL with correct token → 200 `{"status": "starting"}` or `{"status": "already_running"}`
- Manual: `curl` without token → 401
- Manual: `curl` with wrong token → 401
- Manual: `./deploy-trigger.sh --show` displays URL and token
- Manual: `./deploy-trigger.sh --remove` cleans up all resources
- Manual: `./deploy-trigger.sh` again after remove → re-creates cleanly

### Verification

- [ ] `./deploy-trigger.sh` completes without errors
- [ ] Lambda function exists: `aws lambda get-function --function-name agent-server-trigger --region eu-north-1`
- [ ] Function URL exists: `aws lambda get-function-url-config --function-name agent-server-trigger --region eu-north-1`
- [ ] `deploy-state.json` contains `trigger_function_name`, `trigger_function_url`, `trigger_token`
- [ ] `curl` with valid token returns 200
- [ ] `curl` without/wrong token returns 401
- [ ] `./deploy-trigger.sh --show` displays stored URL and token
- [ ] `./deploy-trigger.sh --remove` removes Lambda, IAM role, and state keys
- [ ] Re-running `./deploy-trigger.sh` after remove works (clean re-create)

### Implementation Status: Complete

- Created `templates/trigger-lambda.py` as separate template file
- Created `deploy-trigger.sh` with create/show/remove modes, idempotent create-or-update semantics
- Added second IAM policy statement with `ec2:DescribeInstances` on `Resource: "*"` (required by EC2 API — DescribeInstances doesn't support resource-level ARN filtering)
- Reuses existing token on re-runs to avoid invalidating iOS Shortcuts

---

## Phase 2: Teardown Integration

Update `teardown.sh` to clean up Lambda trigger resources.

### Changes

- `teardown.sh` — Add cleanup section between the existing EventBridge removal (step 1, line 115) and scheduler IAM deletion (step 2, line 127):
  - Read `trigger_function_name` and `trigger_role_name` from `deploy-state.json` via `json_get()`
  - If present: delete Function URL config, delete Lambda function, detach managed policy, delete inline policy, delete IAM role
  - Use existing `aws_ignore_missing` helper for all calls
  - Add Lambda to the "what will be destroyed" display (lines 82-84) — conditionally show only if trigger exists in state
  - Follow pattern of existing teardown steps (log prefix, error handling)

### Specific changes in teardown.sh

After line 125 (end of EventBridge removal), add:

```bash
# --- 1b. Remove Lambda Trigger -----------------------------------------------
TRIGGER_FUNCTION="$(json_get trigger_function_name)"
TRIGGER_ROLE="$(json_get trigger_role_name)"
if [[ -n "${TRIGGER_FUNCTION}" ]]; then
  log "Removing Lambda trigger function..."
  aws_ignore_missing aws lambda delete-function-url-config \
    --function-name "${TRIGGER_FUNCTION}" --region "${REGION}"
  aws_ignore_missing aws lambda delete-function \
    --function-name "${TRIGGER_FUNCTION}" --region "${REGION}"
fi
if [[ -n "${TRIGGER_ROLE}" ]]; then
  log "Removing Lambda trigger IAM role..."
  aws_ignore_missing aws iam detach-role-policy \
    --role-name "${TRIGGER_ROLE}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  aws_ignore_missing aws iam delete-role-policy \
    --role-name "${TRIGGER_ROLE}" --policy-name "ec2-trigger"
  aws_ignore_missing aws iam delete-role \
    --role-name "${TRIGGER_ROLE}"
fi
```

In the "what will be destroyed" display (around line 82), add:

```bash
TRIGGER_FUNCTION="$(json_get trigger_function_name)"
[[ -n "${TRIGGER_FUNCTION}" ]] && echo "  Lambda Trigger:     ${TRIGGER_FUNCTION}"
```

### New Tests

- Manual: Run `./teardown.sh` (on a test deployment) and verify Lambda + IAM role are cleaned up
- Manual: Run `./teardown.sh` when no trigger was deployed — no errors, skip cleanly

### Verification

- [ ] `./teardown.sh` shows Lambda trigger in the "will be destroyed" list (when trigger exists)
- [ ] `./teardown.sh` does not error when no trigger was deployed
- [ ] After teardown, Lambda function is gone: `aws lambda get-function` returns ResourceNotFoundException
- [ ] After teardown, IAM role is gone: `aws iam get-role` returns NoSuchEntity

### Implementation Status: Complete

- Added `TRIGGER_FUNCTION` to "will be destroyed" display (conditional)
- Added cleanup section 1b between EventBridge removal and scheduler IAM deletion
- Follows existing `aws_ignore_missing` pattern for all calls

---

## Phase 3: agent-manager.sh Integration

Add `--trigger` command to display the remote trigger URL and token.

### Changes

- `agent-manager.sh` — Add `cmd_trigger()` function and update dispatch:

  **New function `cmd_trigger()`** (add before `cmd_help`):
  - Read `trigger_function_url` and `trigger_token` from `deploy-state.json`
  - If not present: print message directing user to `./deploy-trigger.sh` and exit
  - If present: display URL and token in same copy-friendly format as deploy-trigger.sh completion banner
  - Include the `curl` test command and iOS Shortcuts setup instructions

  **Update `cmd_help()`** (line 942):
  - Add `--trigger` entry: `./agent-manager.sh --trigger   Show remote trigger URL and token`

  **Update dispatch table** (line 968):
  - Add `--trigger|trigger) cmd_trigger ;;`

  **Update hints line** (line 269):
  - Add `--trigger` to the dim hints: `Commands: --wakeup, --sleep, --run-agent, --trigger, --log, --history, --scheduled, --ssh`

### New Tests

- Manual: `./agent-manager.sh --trigger` when trigger is deployed → shows URL + token
- Manual: `./agent-manager.sh --trigger` when trigger is not deployed → shows setup instructions
- Manual: `./agent-manager.sh --help` includes `--trigger` entry

### Verification

- [ ] `./agent-manager.sh --trigger` displays URL and token from deploy-state.json
- [ ] `./agent-manager.sh --trigger` handles missing trigger gracefully
- [ ] `./agent-manager.sh --help` lists `--trigger`
- [ ] Hints line at bottom of `--status` includes `--trigger`

### Implementation Status: Complete

- Added `cmd_trigger()` function with copy-friendly URL/token display
- Updated help text, hints line, dispatch table, and header comment

---

## Phase 4: Documentation

Update `docs/aws-setup.md` and `ARCHITECTURE.md` to document the remote trigger as an optional add-on.

### Changes

- `docs/aws-setup.md` — Add new section **"Optional: Remote Trigger"** after the "Manual Wakeup" subsection (after line 337), at the same heading level as "Manual Wakeup". Content:
  - Brief description: trigger agent runs from any device (phone, tablet, shortcut) by calling a Lambda Function URL
  - Explain it's for scheduled mode (starting a stopped instance)
  - Deployment: `./deploy-trigger.sh`
  - Management: `./agent-manager.sh --trigger` to view URL and token
  - Removal: `./deploy-trigger.sh --remove`
  - iOS Shortcuts setup (same content as the completion banner: Action, URL, Method, Headers)
  - Note: `./teardown.sh` automatically cleans up trigger resources if deployed
  - Keep it concise — ~30 lines, matching the style of surrounding sections

- `ARCHITECTURE.md` — Two additions:
  1. In the **Repository Structure** tree (line 10-51): add `deploy-trigger.sh` after `deploy-scheduler.sh` (line 44) with comment `# Optional: Lambda remote trigger`
  2. Add `templates/trigger-lambda.py` in the templates tree with comment `#     Lambda code for remote trigger`
  3. In the **"What each script does"** table (line 55-64): add row for `deploy-trigger.sh`: "Local machine | Optional. Creates Lambda Function URL for remote agent triggering. Standalone — not called by deploy.sh."
  4. In the **AWS infrastructure** table (line 219-226): add row: "Lambda Function URL | (Optional) Remote trigger — starts the instance via Bearer-token-authenticated HTTPS endpoint"

### Key patterns to follow

- `aws-setup.md:261-278` — "Web Terminal (ttyd)" section style: brief intro, code block, security notes. Good model for an optional feature section.
- `aws-setup.md:306-337` — "Manual Wakeup" section: shows command examples with comments. Follow this for the trigger commands.
- `ARCHITECTURE.md:44` — `deploy-scheduler.sh` line: follow same format for `deploy-trigger.sh`

### New Tests

- Manual: Review rendered markdown for correct formatting
- Manual: Verify all referenced commands (`deploy-trigger.sh`, `--trigger`, `--remove`, `--show`) match Phase 1 and Phase 3

### Verification

- [ ] `docs/aws-setup.md` has "Optional: Remote Trigger" section
- [ ] Section clearly states this is optional and not part of default deployment
- [ ] Section includes deploy, show, and remove commands
- [ ] Section includes iOS Shortcuts setup instructions
- [ ] `ARCHITECTURE.md` repo tree includes `deploy-trigger.sh` and `templates/trigger-lambda.py`
- [ ] `ARCHITECTURE.md` script table includes `deploy-trigger.sh`
- [ ] `ARCHITECTURE.md` AWS infrastructure table includes Lambda Function URL

### Implementation Status: Complete

- Added "Optional: Remote Trigger" section to aws-setup.md after Manual Wakeup
- Updated ARCHITECTURE.md: repo tree (deploy-trigger.sh + trigger-lambda.py), script table, AWS infrastructure table

---

## Evaluation Notes

### Architecture
- Fits existing patterns well. `deploy-trigger.sh` follows `deploy-scheduler.sh` structure (standalone, IAM role + AWS resource creation, `--remove` flag).
- No IAM conflicts — new role `agent-server-trigger-role` is independent of existing `agent-server-role` and `agent-server-scheduler-role`.
- Flow (Lambda → StartInstances → systemd boot-runner → orchestrator) is sound for scheduled mode. The orchestrator's `flock` at `agent-orchestrator.sh:41-44` prevents concurrent runs.
- In always-on mode, `StartInstances` on a running instance is a no-op (by AWS API design) — harmless but does not trigger a run. Documented as scheduled-mode-only feature.

### Security
- Bearer token (256-bit) with `hmac.compare_digest` is appropriate for this use case.
- Blast radius if token leaks: attacker can only start one EC2 instance. No data access, no command execution, no privilege escalation.
- Token stored in `deploy-state.json` which is gitignored (`.gitignore:2`). Note: this file gets SCP'd to the server at `deploy.sh:348` — the token will exist on the EC2 instance too. Acceptable given the low blast radius.
- Function URL with auth-type NONE is necessary for iOS Shortcuts compatibility. The unguessable URL + mandatory token provide defense in depth.

### Scalability
- Rapid repeated triggers are safe: four idempotency layers (Lambda/EC2 API, systemd oneshot, flock, heartbeat check).
- Lambda cold start (~300-600ms) is negligible compared to 30-60s EC2 boot time.
- Cost: effectively zero. Lambda free tier (1M requests, 400K GB-seconds) will never be approached.

### Usability
- Completion banner designed for easy copy-paste to iOS Shortcuts (plain text lines, no ANSI codes on URL/token values).
- `agent-manager.sh --trigger` provides on-demand retrieval of URL/token without re-running the deploy script.
- Error responses from Lambda use clear HTTP status codes: 401 (unauthorized), 200 (starting/already_running), 409 (terminated).

---

## Post-Verification Changes (2026-03-28)

After the initial implementation was verified, the following changes were made during live AWS testing and iteration.

### 1. Fix: AWS dual-permission requirement for Function URLs (Oct 2025)

**Category**: Bug fix

**What changed**: Added a second `lambda:InvokeFunction` permission alongside `lambda:InvokeFunctionUrl` when creating the Function URL. AWS changed their requirements in October 2025 — both permissions are now mandatory.

**Files affected**:
- `deploy-trigger.sh` — Added second `aws lambda add-permission` call with `lambda:InvokeFunction`

**Rationale**: Without this, the Function URL returns `403 Forbidden` even though the policy and AuthType look correct. Direct Lambda invoke works, but the Function URL path requires both permissions.

### 2. Fix: Wait for Lambda to become Active before creating Function URL

**Category**: Bug fix

**What changed**: Added `aws lambda wait function-active-v2` after creating/updating the Lambda and before creating the Function URL.

**Files affected**:
- `deploy-trigger.sh` — Added wait step between Lambda creation and Function URL creation

**Rationale**: Lambda is in `Pending` state immediately after creation. Creating a Function URL on a Pending function led to the URL not being properly accessible.

### 3. Fix: Handle `stopping` instance state in Lambda

**Category**: Bug fix

**What changed**: Added `"stopping"` to the rejected-states tuple in the Lambda handler.

**Files affected**:
- `templates/trigger-lambda.py` — `stopping` added to the 409-response states

**Rationale**: If the instance is in `stopping` state, `ec2.start_instances()` raises an unhandled exception, returning a raw 500. Now returns a clean `409 {"status": "error", "message": "Instance is stopping"}`.

### 4. Fix: Remove unused `hashlib` import

**Category**: Bug fix (dead code)

**What changed**: Removed unused `import hashlib` from the Lambda template.

**Files affected**:
- `templates/trigger-lambda.py` — Removed line 2

### 5. UX: Default to `--show`, require `--deploy` for creation

**Category**: UX refinement

**What changed**: Running `./deploy-trigger.sh` with no arguments now shows the current trigger URL and token (like `--show`). Deploying requires the explicit `--deploy` flag. Unknown arguments show usage help.

**Files affected**:
- `deploy-trigger.sh` — Refactored dispatch: bare invocation and `--show` both call `show_trigger()`, create mode gated behind `--deploy`, added usage help for unknown args
- `agent-manager.sh` — Updated `cmd_trigger()` "not deployed" message to reference `--deploy`
- `docs/aws-setup.md` — Updated commands to use `--deploy`

**Rationale**: Safer default — accidental bare invocation shows info rather than creating AWS resources. Consistent with how `agent-manager.sh` defaults to `--status`.

### 6. Suppress noisy AWS JSON output

**Category**: UX refinement

**What changed**: Redirected stdout from `aws iam create-role`, `aws lambda create-function`, and `aws lambda delete-function-url-config` to `/dev/null` so the deploy/remove output is clean log lines only.

**Files affected**:
- `deploy-trigger.sh` — Changed `2>/dev/null` to `> /dev/null 2>&1` on three AWS commands

**Rationale**: During testing, the full JSON output from role/function creation cluttered the deployment output. The `[TRIGGER]` log lines provide sufficient feedback.

### 7. Feature: Force-run — bypass active-hours guard for all wake paths

**Category**: New functionality

**What changed**: Added `--force` flag to the orchestrator that bypasses the active-hours guard while still allowing self-stop. All wake paths (boot-runner, resume-check, `--run-agent`) now pass `--force`. Removed the redundant hours check from `agent-resume-check.sh`.

The hours check in boot-runner and resume-check was redundant because:
- EventBridge already constrains its cron expression to active hours
- All other wakes (remote trigger, `--wakeup`, `--run-agent`) are intentional manual actions
- The orchestrator's own hours check remains as a last-resort safeguard (bypassed by `--force`)

The heartbeat interval check in resume-check is preserved — it prevents duplicate runs if woken too soon after the last run.

An EC2 tag-based signaling approach was initially attempted but abandoned because AWS Describe actions don't support resource-level IAM conditions, making the tag unreadable from the instance. The simpler `--force` approach requires no IAM changes or cross-boundary signaling.

**Files affected**:
- `scripts/agent-orchestrator.sh` — New `--force` flag (bypasses hours, still self-stops), refactored flag handling (`NO_STOP` and `FORCE_RUN` as separate booleans)
- `scripts/agent-resume-check.sh` — Removed hours check, passes `--force` to orchestrator
- `setup.sh` — Boot-runner service passes `--force` to orchestrator
- `agent-manager.sh` — `--run-agent` passes `--force` instead of `--no-stop`

**Rationale**: Remote trigger and `--run-agent` were blocked by the active-hours guard outside working hours. Both are explicit manual actions that should always run. Tested end-to-end: Lambda trigger at 13:02 (outside weekend hours 8,17) → orchestrator ran → self-stopped.

### 8. Docs: Update documentation for --force behavior

**Category**: Documentation

**What changed**: Updated docs to reflect that boot/resume/trigger/run-agent paths bypass the active-hours guard, while cron runs still respect it.

**Files affected**:
- `docs/aws-setup.md` — Manual Wakeup section: clarified boot-runner bypasses hours guard. Remote Trigger section: noted it works at any time, even outside active hours.
- `ARCHITECTURE.md` — Runtime diagram: distinguished boot/resume (`--force`, bypasses hours) from cron (no flag, hours apply). Added remote trigger to the wake sources.
- `agent-manager.sh` — Status output: changed "self-stops immediately if woken outside active hours" to accurately describe that only cron respects the guard.

**Rationale**: Docs and status output described the old behavior where the hours guard applied to all paths. After the `--force` changes, only cron-initiated runs are subject to the guard.

### 9. Fix: --run-agent should not set .keep-running

**Category**: Bug fix

**What changed**: `cmd_run_agent` no longer calls `cmd_wakeup` (which sets `.keep-running`). Instead it has its own minimal wake logic that starts the instance and waits for SSH without creating the lock file. This ensures the orchestrator self-stops after the run.

**Files affected**:
- `agent-manager.sh` — `cmd_run_agent` replaced `cmd_wakeup` call with inline start+wait logic

**Rationale**: `cmd_wakeup` sets `.keep-running` to prevent self-stop (for interactive SSH). But `--run-agent` wants a single run followed by self-stop. With `.keep-running` set, the orchestrator's in-memory `NO_STOP` flag was set at startup and couldn't be cleared by removing the file later.

### 10. Docs: Wake/run behavior table in ARCHITECTURE.md

**Category**: Documentation

**What changed**: Added comprehensive tables documenting all trigger sources and their behavior in scheduled and always-on modes, plus a safeguards table.

**Files affected**:
- `ARCHITECTURE.md` — New "Wake/run behavior by trigger source" subsection under "Schedule modes"

**Rationale**: The interaction between trigger sources, hours guard, and self-stop is non-obvious. A reference table makes the behavioral contract clear.

---

## Implementation Summary

**Completed:** 2026-03-28
**All phases:** Complete
**Test status:** All syntax checks passing (bash -n, python3 ast.parse)

### Files Created
- `templates/trigger-lambda.py` — Lambda function code
- `deploy-trigger.sh` — Standalone deploy/show/remove script

### Files Modified
- `teardown.sh` — Added Lambda trigger cleanup (section 1b)
- `agent-manager.sh` — Added `--trigger` command, updated help/hints/dispatch
- `docs/aws-setup.md` — Added "Optional: Remote Trigger" section
- `ARCHITECTURE.md` — Updated repo tree, script table, AWS infrastructure table

### Deviations from Plan
- Added a second IAM policy statement with `ec2:DescribeInstances` on `Resource: "*"` — the EC2 DescribeInstances API does not support resource-level ARN filtering, so a wildcard is required for the state check
- Token is reused on idempotent re-runs to avoid invalidating existing iOS Shortcuts setups
- Added `aws lambda wait function-updated` between code update and config update to avoid ConflictException

### Learnings
- AWS changed Lambda Function URL permissions in Oct 2025 — now requires both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`
- Lambda functions need to be Active (not Pending) before Function URL creation works reliably
- `ec2:DescribeInstances` does not support resource-level ARN filtering — requires `Resource: "*"`
- The `stopping` EC2 state rejects `StartInstances` with an exception, unlike `stopped`/`pending` which accept it
- AWS Describe/List actions (DescribeTags, DescribeInstances) ignore resource-level IAM conditions — they need `Resource: "*"` in a separate statement
- EC2 tag-based signaling across Lambda→instance boundary looked clean but failed due to IAM condition limitations; passing flags via systemd service config is simpler and more reliable
- The active-hours check in boot-runner and resume-check is redundant when EventBridge already constrains its schedule to active hours — all non-EventBridge wakes are intentional

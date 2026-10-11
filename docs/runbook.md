# backup-dr — Operations runbook

How to run the four scripts, read their output and exit codes, carry out a DR failover and
failback, and set up the simulators used for testing and demos.

Every script imports the `BackupDR` module from `src/BackupDR`, resolves its default paths
relative to the repository (not the current directory), and accepts `-Now <datetime>` so that
schedule and age decisions can be replayed for a given moment. `-Now` defaults to the current
time.

## 1. Before you start

| Variable | Values | Effect |
|---|---|---|
| `BACKUPDR_PROVIDER` | `veeam` (default on Windows), `simulator` (default elsewhere), `none` | Where the vendor commands come from. `veeam` loads `VeeamPSSnapin`, `AzureRM.RecoveryServices`, `AzureRM.RecoveryServices.SiteRecovery` and `DnsServer`; `simulator` loads the modules under `sim/`; `none` loads nothing (unit tests). |
| `BACKUPDR_SIM_STATE` | directory | Simulator state files (`veeam.json`, `azure.json`, `dns.json`). Unset: the samples are copied to a new temp directory on first use. |
| `BACKUPDR_SIM_NOW` | ISO 8601 time | Clock the simulators stamp new sessions, restore points and jobs with. Unset: current time. |
| `BACKUPDR_POLL_SECONDS` | integer | Default seconds between job/ASR status polls (an explicit `-PollSeconds` wins). Default 60 for backup jobs, 30 for ASR jobs. |
| `BACKUPDR_SMTP_SERVER`, `BACKUPDR_SMTP_PORT` | host, port | Override `alerting.smtpServer` / `smtpPort` from the policy. |

On a Veeam server, run the scripts from Windows PowerShell 5.1 under an account that can use
the Veeam console, the Azure Recovery Services vault and the DNS server. If the snap-in or a
module is missing, the script stops with a message naming it.

Configuration files:

- `config/backup_policy.json` — backup jobs, alerting and health thresholds. Validated by
  `Get-BackupPolicy`; every problem is listed in one error.
- `config/dr_plan.json` — the DR plan (vault, recovery plan, RPO threshold, ordered steps).
  Validated by `Get-DRPlan`.

Review changes to either file in version control before they reach the backup server.

Log files are written under `logs/` in the repository, one per script
(`backup_scheduler.log`, `health_check.log`, `azure_replication.log`, `disaster_recovery.log`).
Each line is `[yyyy-MM-dd HH:mm:ss] [INFO|WARN|ERROR] message`, and the same lines go to the
console.

## 2. Exit codes

| Script | 0 | 1 | 2 |
|---|---|---|---|
| `scripts/backup_scheduler.ps1` | every job that ran succeeded, or nothing was due | a job ended Failed or Timeout, was not found, raised an error, or the policy could not be loaded | — |
| `scripts/health_check.ps1` | OK | WARNING | CRITICAL (also when the policy cannot be loaded) |
| `scripts/azure_replication.ps1` | OK | WARNING | CRITICAL (also when the DR plan cannot be loaded) |
| `scripts/disaster_recovery.ps1` | the plan succeeded | a step failed, the plan or policy could not be loaded, or the action was not confirmed | — |

`health_check.ps1` and `azure_replication.ps1` follow the Nagios convention, so a monitoring
agent can run them directly and use the exit code as the service state. The worst check wins.

## 3. Backup scheduler

```
pwsh scripts/backup_scheduler.ps1 [-ConfigPath config/backup_policy.json] [-DryRun] [-Now <datetime>]
                                  [-PollSeconds <int>] [-ReportPath out/report.html]
                                  [-LogPath logs/backup_scheduler.log]
```

What it does, in order:

1. Loads and validates `config/backup_policy.json`. An invalid policy is logged as ERROR and
   the script exits 1 without starting anything.
2. For each job, decides whether it is due at `-Now`: the weekday must be in `schedule` (or the
   schedule is `Daily`), and for jobs with `intervalMinutes` at least that many minutes must
   have passed since the job's newest session. A job that is not due is logged as `Skipping`.
3. Starts each due job unless it does not exist (`NotFound`) or is already running
   (`AlreadyRunning`), then polls its session every `-PollSeconds` until it finishes or
   `timeoutHours` passes (`Timeout`).
4. Sends an alert mail for a Failed result (`alerting.alertOnFailure`) or a Warning result
   (`alerting.alertOnWarning`).
5. Verifies the jobs with `verifyAfterBackup: true` from their latest session; a status other
   than Success is logged as WARN.
6. Writes the HTML daily report to `-ReportPath` and mails it when `alerting.dailyReport` is
   true.

`-DryRun` logs which jobs would start and still writes the report, but starts nothing and sends
no mail. Use it after every policy change.

### Scheduling it

The toolkit does not install a scheduled task. On the Veeam server, an hourly task covers the
`Daily`, weekday and `intervalMinutes` jobs (a job is only started when it is due):

```
schtasks /Create /TN "BackupDR\Scheduler" /SC HOURLY /RU SYSTEM ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\backup-dr\scripts\backup_scheduler.ps1"
```

Adjust the path to where the repository is checked out. If Veeam's own job scheduling is also
enabled for the same jobs, disable one of the two so jobs are not started twice; a job that is
already running is skipped, not started again.

### Reading the daily report

`out/report.html` (and the mail, titled `Daily Backup Report yyyy-MM-dd`) has one row per job
in policy order:

| Column | Meaning |
|---|---|
| JobName | Job name from the policy |
| Status | Result of the newest session: Success (green), Warning (yellow), Failed / Timeout / Error (red), NoSession (grey, the job has never run) |
| StartTime / EndTime | Start and end of that session |
| DataSize | Data processed by the session |
| DedupRatio | Deduplication ratio reported by Veeam |

What to do:

- **Failed** — open the session in the Veeam console for the per-VM error, fix it and rerun the
  job from the console or wait for the next scheduled run. Check `health_check.ps1` afterwards.
- **Warning** — usually a VM skipped or a snapshot problem; read the session log. Repeated
  warnings on the same job need the same attention as a failure.
- **NoSession** — the job exists in the policy but has never run in Veeam: check the job name
  matches exactly and that the job is enabled.

## 4. Health check

```
pwsh scripts/health_check.ps1 [-ConfigPath config/backup_policy.json] [-Now <datetime>]
```

Prints one line per check, then a summary line:

```
<OK|WARNING|CRITICAL> <Type> <Name>: <message>
<STATE> - <n> checks, <m> warnings, <k> critical[; retention: <job>: <issues> ...]
```

| Check type | WARNING when | CRITICAL when |
|---|---|---|
| Repository | free space below `health.repositoryMinFreePercent`, capacity reported as 0, or no repository found | repositories cannot be read |
| LastResult | newest session ended with Warning, has an unexpected result, or the job never ran | newest session ended Failed, or sessions cannot be read |
| Schedule | the job has not run within the time its schedule allows ("overdue"), or never ran | sessions cannot be read |
| Retention | restore points kept past `retentionDays`, no restore point recent enough for the schedule, or no backup at all | the retention audit itself fails |

Retention issues are repeated at the end of the summary line so they reach a monitoring system
that shows only the first or last line.

What to do:

- **Repository WARNING** — free space before the next full backup: remove retired backups from
  the console, extend the repository, or lower retention after review.
- **LastResult CRITICAL** — as for a Failed row in the daily report.
- **Schedule WARNING (overdue)** — check the scheduled task ran (`logs/backup_scheduler.log`)
  and that the job was due; a job left disabled in Veeam shows up here.
- **Retention WARNING, points older than retention** — Veeam's retention for that job does not
  match `retentionDays`. The toolkit only reports this; it never deletes restore points. Align
  the job's retention setting in Veeam with the policy (or change the policy after review).
- **Retention WARNING, no recent restore point** — the job ran but produced no usable restore
  point; treat it as a failed backup.

## 5. Azure replication status

```
pwsh scripts/azure_replication.ps1 [-PlanPath config/dr_plan.json] [-Now <datetime>]
```

Reads the Recovery Services vault named in `config/dr_plan.json` (`azure.vaultName`) and lists
the Azure Site Recovery protected items of `azure.recoveryPlan` (every item in the vault when
the plan names no recovery plan):

```
AZURE REPLICATION <STATE> - <summary>
<OK|WARNING|CRITICAL> <item> health=<ReplicationHealth> rpo=<minutes> min
```

An item's RPO is the value ASR last reported plus the time since ASR calculated it, measured at
`-Now`, so an RPO that has stopped being refreshed keeps growing. An item is WARNING when its
replication health is not Normal, its RPO exceeds `rpoThresholdMinutes`, or ASR reported no RPO
(`rpo=unknown`). The run is CRITICAL when an item's health is Critical, the vault has no
protected items, or the vault cannot be read.

Run it before every DR test and failover. A WARNING or CRITICAL item would be failed over with
older data than the plan allows, or not at all: fix replication in the Azure portal first, or
record the accepted data loss before continuing.

## 6. Disaster recovery

```
pwsh scripts/disaster_recovery.ps1 -Action failover|failback|test [-PlanPath config/dr_plan.json]
                                   [-ConfigPath config/backup_policy.json]
                                   [-RunLogPath out/dr-run.json] [-Now <datetime>] [-Force]
```

The plan in `config/dr_plan.json` lists the steps in failover order. Step types:

| Type | failover | failback | test |
|---|---|---|---|
| `veeam_replica` | `Start-VBRViReplicaFailover` on the replica's newest restore point | `Start-VBRViReplicaFailback` | replica and restore point exist |
| `azure_failover` | unplanned ASR failover of the recovery plan, PrimaryToRecovery | planned ASR failover, RecoveryToPrimary | vault and recovery plan exist |
| `dns_update` | A record moves from `primaryIp` to `failoverIp` | A record moves back to `primaryIp` | DNS zone exists |
| `notification` | mail with the step results | mail with the step results | alerting settings present |

- **failover** runs the steps in plan order. The first failed step stops the run; the rest are
  reported as `NotRun`, unless the failed step has `continueOnError: true`.
- **failback** runs the `veeam_replica`, `azure_failover` and `dns_update` steps in reverse
  order, then the notification steps.
- **test** runs every step's pre-flight check, reports all problems (it does not stop at the
  first) and changes nothing.

`failover` and `failback` ask for confirmation. `-Force` skips the prompt and is required for
unattended runs; a non-interactive session without `-Force` is refused with exit code 1.

Every run prints one line per step (`<Status> <step name> (<type>) <message>`, status
Succeeded, Failed or NotRun) and writes the run log to `out/dr-run.json`: plan name, action,
time, overall `Success` and each step with its status, message and start/finish times. Keep a
copy of the run log with the incident record.

### 6.1 Pre-checks (before declaring a failover)

1. Confirm the primary site is really unavailable, or that the failover is planned and approved.
2. Run `pwsh scripts/azure_replication.ps1` and note any item above the RPO threshold.
3. Run `pwsh scripts/disaster_recovery.ps1 -Action test`. Every step must show `Succeeded`;
   fix any `Failed` pre-flight check before going further.
4. Check that the replica named in each `veeam_replica` step has a recent restore point (the
   test output shows the newest one) and accept the possible data loss.
5. Tell users and application owners that a failover is starting.

### 6.2 Failover

1. Run `pwsh scripts/disaster_recovery.ps1 -Action failover` and confirm the prompt
   (or add `-Force` when running from an automation account).
2. Watch the step lines. If a step fails, the run stops and the later steps are marked NotRun.
   Do not simply run the failover again: only the `dns_update` step is safe to repeat (it
   changes the record only when needed). The `veeam_replica` and `azure_failover` steps do not
   check the current state first, so a rerun after a partial failover stops at the first of
   them that already succeeded (Veeam refuses a replica that is not Ready; Azure refuses a
   recovery plan already at the recovery site) and nothing after it runs. Instead:
   - Read `out/dr-run.json` to see which steps succeeded and which failed or did not run.
   - Fix the cause of the failure, then finish the remaining steps by hand: the replica
     failover in the Veeam console, the recovery plan failover in the Azure portal and the
     A record in DNS Manager (or with a temporary copy of `config/dr_plan.json` that holds
     only the remaining steps, passed with `-PlanPath`).
   - `pwsh scripts/disaster_recovery.ps1 -Action test` changes nothing and shows the replica's
     current state and the recovery plan's current site, which helps confirm where each
     component stands.
3. Exit code 0 means every step succeeded and the notification was sent.

### 6.3 Verification after failover

1. Resolve the application name (e.g. `app.example.local` from the sample plan) and confirm it
   returns the `failoverIp`. Clients may hold the old address until the record's TTL expires.
2. In the Veeam console, the replica VM is in the Failover state and powered on.
3. In the Azure portal, the recovery plan's failover job succeeded and the VMs are running.
4. Log in to the application, check recent data is present and record the time of the newest
   data seen.
5. Keep `out/dr-run.json` and the console output with the incident record.

### 6.4 Failback

Fail back only when the primary site is healthy again and a maintenance window is agreed.

1. Confirm the primary hosts, storage and network are up and that replication from the DR side
   back to the primary site is possible.
2. Run `pwsh scripts/disaster_recovery.ps1 -Action test` again to confirm the replica, recovery
   plan and DNS zone are still reachable.
3. Run `pwsh scripts/disaster_recovery.ps1 -Action failback` and confirm the prompt. The DNS
   record is moved back first, then the Azure recovery plan is failed back
   (planned failover RecoveryToPrimary) and the Veeam replica is failed back.
4. Verify as in 6.3, now expecting the `primaryIp` and the production VMs running on the
   primary site.
5. In the Veeam console, commit the failback once the production VMs are confirmed working;
   in the Azure portal, commit the failover and re-protect the items so replication to Azure
   resumes. The toolkit does not perform these two steps.
6. Run `pwsh scripts/health_check.ps1` and `pwsh scripts/azure_replication.ps1` and confirm both
   return to OK after the next backup and replication cycle.

## 7. Simulator setup

Veeam, Azure Site Recovery and Windows DNS are not available outside a Windows site, so the
repository ships simulators with the same cmdlet names: `sim/VeeamSim`, `sim/AzureSim` and
`sim/DnsSim`. They keep their state in JSON files and are loaded when
`BACKUPDR_PROVIDER=simulator` (the default in the Docker image). Mail goes to a local MailHog
container.

Sample state lives in `sim/state/*.sample.json` with times written as offsets such as `"-26h"`.
`New-SimState` rewrites them relative to an anchor time:

```powershell
. ./tests/TestHelpers/New-SimState.ps1
$now = [datetime]'2019-02-17T02:00:00'
New-SimState -Anchor $now -Path out/sim      # sets $env:BACKUPDR_SIM_STATE
$env:BACKUPDR_SIM_NOW = $now.ToString('o')
./scripts/health_check.ps1 -Now $now
./scripts/disaster_recovery.ps1 -Action test -Now $now
```

Edit the JSON files under the state directory to stage a scenario (a failed session, a full
repository, a stale replica, an unhealthy ASR item) and rerun the scripts.

With Docker:

| Command | What it does |
|---|---|
| `make build` | Builds the `backup-dr:dev` image (PowerShell Core, Pester, PSScriptAnalyzer). |
| `docker compose up -d mailhog` | Starts MailHog; its web UI is at http://localhost:21025. |
| `make demo` | Seeds `out/sim` at the current time, runs the scheduler as a dry run and then for real; the report lands in `out/report.html` and the mail in MailHog. |
| `make shell` | Opens `pwsh` in the container with the simulator provider set. |
| `make test` / `make test-unit` / `make lint` | Full suite (starts MailHog), unit tests only, PSScriptAnalyzer only. |
| `make clean` | Stops the containers and removes `out/` and `logs/`. |

The simulators complete backup jobs and failovers immediately and model only the properties the
toolkit reads; results from them say nothing about real job durations or vendor behaviour.

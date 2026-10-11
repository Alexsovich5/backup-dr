# backup-dr — Specification

Rebuild target: a working PowerShell toolkit that drives Veeam Backup & Replication 9.5 backup
jobs from a JSON policy, audits the results, and runs a JSON-described disaster-recovery plan
(Veeam replica failover, Azure Site Recovery failover, DNS cut-over, notification).
Period: October 2018 – February 2019. Every external system (Veeam, vSphere, Azure, Windows DNS)
is simulated; only SMTP is exercised against a real (local) server.

## 1. Problem

A small Windows/VMware shop runs Veeam B&R 9.5 and wants its backup and DR procedures to be
scripted instead of clicked:

- Start the right Veeam jobs on the right days from one reviewed policy file, wait for them,
  and alert on anything that is not `Success`.
- Produce a daily report of what ran, and check that restore points actually respect the
  policy's retention.
- Check the health of the backup server (repositories, last results) and of Azure replication.
- Execute a written DR plan (failover, failback, dry-run test) in a fixed, logged order.

## 2. In scope

1. **Backup policy file** — `config/backup_policy.json` loaded and validated by
   `Get-BackupPolicy` (required fields, allowed values, clear errors).
2. **Policy-driven scheduler** — decides which jobs are due for a given time
   (`schedule` weekday list / `Daily`, and `intervalMinutes` for sub-daily jobs) and starts them.
3. **Job execution with wait/timeout** — skips missing and already-running jobs, starts the job,
   polls the last session until it finishes or `timeoutHours` passes, records the result.
   `-DryRun` logs intent only.
4. **Post-backup verification** — for jobs with `verifyAfterBackup`, reads the latest backup
   session and records status, start/end time, data size and dedup ratio (port of the existing
   `Test-BackupIntegrity`). Jobs with `verifyAfterBackup: false` are not verified.
5. **Alerting** — e-mail on failure/warning according to `alerting.alertOnFailure` /
   `alertOnWarning`, sent over SMTP.
6. **Daily report** — HTML report (ConvertTo-Html) of every job's last result, e-mailed when
   `alerting.dailyReport` is true and also written to disk.
7. **Retention compliance audit** — per job, compares restore-point ages against
   `retentionDays`: flags points kept past retention and jobs with no restore point newer than
   their schedule allows. Reached by users through `scripts/health_check.ps1` (item 8).
8. **Backup-server health check** — `scripts/health_check.ps1`: repository free-space
   threshold, jobs whose last result is Failed, jobs not run within their window, and the
   retention audit of item 7 (a non-compliant job is a WARNING and its issues are listed in the
   summary); exits 0/1/2 (OK/WARNING/CRITICAL, Nagios convention) so it can be scheduled or
   monitored.
9. **Azure replication status** — `scripts/azure_replication.ps1`: lists Azure Site Recovery
   protected items, flags unhealthy items and items whose RPO exceeds the threshold configured in
   `dr_plan.json`; same exit-code convention.
10. **DR plan file** — `config/dr_plan.json` (ordered steps, typed) loaded and validated by
    `Get-DRPlan`.
11. **DR execution** — `scripts/disaster_recovery.ps1 -Action failover|failback|test`:
    failover runs steps in order; failback runs the reversible steps in reverse order; test
    validates the plan and runs pre-flight checks (replicas exist, recovery plan exists, DNS
    zone exists via `Get-DnsServerZone`) without changing anything. Step types: `veeam_replica`,
    `azure_failover`, `dns_update`, `notification`. Stops on the first failed step unless the
    step has `continueOnError: true`. Writes a JSON run log.
12. **Configurable logging** — `Write-BackupLog` to console and a log file whose path comes from
    a parameter/environment via `Set-BackupLogPath` (no hard-coded `C:\Logs`).
13. **Runbook** — `docs/runbook.md`: how to run each script, how to read the report and exit
    codes, manual steps around a failover.
14. **Pester test suite** — unit tests with Pester mocks for every public function, integration
    tests running the real scripts against the simulators and a local SMTP server
    (replaces the README's `tests/test_backup.ps1`).

## 3. Out of scope

| Original README item | Reason |
|---|---|
| Real Veeam B&R 9.5 server | Proprietary, Windows-only, licensed; replaced by the `VeeamSim` simulator module and Pester mocks. |
| Real VMware vSphere 6.5 environment | Veeam is the only component that talks to vSphere; the toolkit never calls vSphere directly, so it is represented only through simulated Veeam replicas/VM names. |
| Real Azure Site Recovery / Azure subscription | Paid cloud service; replaced by the `AzureSim` simulator exposing the subset of AzureRM ASR cmdlets used. |
| Azure authentication (`Connect-AzureRmAccount`, service principals) | Nothing to authenticate against; simulator accepts any context. |
| Retention *enforcement* (deleting restore points) | Veeam enforces retention natively per job; the toolkit audits drift (in-scope item 7) rather than deleting backups from a script. |
| "RPO < 15 minutes", "RTO < 1 hour", "100% Backup Success Rate", "Compliance Ready" | Business-impact claims not measured by any code; dropped. The RPO *threshold check* (item 9) is kept as a configurable number. |
| Near-real-time replication itself | Performed by Veeam/ASR, not by scripts; the toolkit only reports its status. |
| Running under Windows PowerShell 5.1 in CI | No Linux container for Windows PowerShell; code is written to the 5.1 language subset and tested on PowerShell Core 6.1 (see Limitations). |
| Scheduling via Windows Task Scheduler / Veeam's own scheduler | Host-level setup; the runbook documents the `schtasks` line, but it is not automated. |
| Organization / role / timeline / "Status: Complete" badges | Fabricated portfolio claims; removed. |

## 4. Architecture

```
                 config/backup_policy.json        config/dr_plan.json
                            |                              |
   scripts/backup_scheduler.ps1   scripts/health_check.ps1  scripts/disaster_recovery.ps1
   scripts/azure_replication.ps1        |                   |
            \____________________ Import-Module src/BackupDR ___________________/
                                        |
                     BackupDR module (Public/*.ps1, Private/*.ps1)
         Get-BackupPolicy  Test-BackupJobDue  Start-BackupJob  Get-BackupJobReport
         Test-RetentionCompliance  Get-BackupServerHealth  Get-AzureReplicationStatus
         Get-DRPlan  Invoke-DRPlan  Send-BackupAlert  Set-BackupLogPath  Write-BackupLog
                                        |
                           Import-BackupDRProvider (Private)
             veeam (Windows):  Add-PSSnapin VeeamPSSnapin, Import-Module AzureRM, DnsServer
             simulator:        Import-Module sim/VeeamSim, sim/AzureSim, sim/DnsSim
             none:             load nothing (unit tests supply stubs + mocks)
                                        |
          +------------------+----------+---------+----------------------+
          | VeeamSim         | AzureSim           | DnsSim               |  SMTP
          | Get-VBRJob ...   | Get-AzureRm...Asr* | Get-DnsServerZone,   |  Send-MailMessage
          | state: JSON file | state: JSON file   | *-DnsServerResource* |     |
          +------------------+--------------------+----------------------+     v
                                                                        MailHog (container)
```

Data flow (scheduler): policy → `Test-BackupJobDue(job, now, lastSession)` → `Start-BackupJob`
→ Veeam cmdlets → session result → `Send-BackupAlert` (on warning/failure) →
`Get-BackupJobReport` → HTML report → file + e-mail.

Data flow (health): policy → `Get-BackupServerHealth -Now` → repository check + last-result
check + overdue check + `Test-RetentionCompliance -Now` → worst state → summary line + exit code.

Data flow (DR): plan → `Get-DRPlan` (validate) → `Invoke-DRPlan -Action` → per step handler
(`Invoke-VeeamReplicaStep`, `Invoke-AzureFailoverStep`, `Invoke-DnsUpdateStep`,
`Invoke-NotificationStep`) → run log JSON.

Simulators are ordinary PowerShell modules that define functions with the **same names and
parameter names** as the vendor cmdlets and return objects with the properties/methods the
toolkit reads (`GetLastState()`, `FindLastSession()`, `Result`, `CreationTime`, ...). State lives
in a JSON file (`$env:BACKUPDR_SIM_STATE`, default `sim/state/*.sample.json` copied to a temp
path) so integration tests can seed scenarios (failed job, full repository, stale replica,
over-retained restore point).

Clock: nothing reads the wall clock directly for decisions. Module functions take `-Now`;
scripts take `-Now` (default `Get-Date`) and pass it down. The simulators stamp new sessions,
restore points and failover jobs with `$env:BACKUPDR_SIM_NOW` when it is set (ISO 8601), else
`Get-Date`. Sample state files store timestamps as relative offsets (e.g. `"-26h"`, `"-15d"`)
that `New-SimState -Anchor <datetime>` rewrites to absolute times relative to the anchor, so
seeded scenarios do not go stale as real time passes.

Compatibility rule: all code under `src/`, `scripts/` and `sim/` uses only PowerShell
5.1-compatible syntax and cmdlets (no `?.`, no `??`, no ternary, no `-Parallel`, no
`ConvertFrom-Json -AsHashtable`). Enforcement is described in §10 and §11.

## 5. Data model & interfaces

### 5.1 `config/backup_policy.json`
```json
{
  "organization": "Example Org",
  "version": "1.1",
  "jobs": [
    { "name": "Database-Servers-Hourly", "type": "incremental|full",
      "schedule": ["Daily"] | ["Sunday", "Wednesday"], "intervalMinutes": 60,
      "timeoutHours": 1, "retentionDays": 14, "targets": ["prod-db-*"],
      "verifyAfterBackup": false, "compression": "optimal", "replicateToAzure": false }
  ],
  "alerting": { "email": "it-admin@example.local", "from": "backup@example.local",
                "smtpServer": "smtp.example.local", "smtpPort": 25,
                "alertOnFailure": true, "alertOnWarning": true, "dailyReport": true },
  "health": { "repositoryMinFreePercent": 15 }
}
```
Validation: `name` unique & non-empty; `type` in {incremental, full}; `schedule` values in
weekday names or `Daily`; `timeoutHours` > 0; `retentionDays` >= 1; `intervalMinutes` optional
>= 15. `alerting.smtpServer`/`smtpPort` may be overridden by `BACKUPDR_SMTP_SERVER`/`_PORT`.

### 5.2 `config/dr_plan.json`
```json
{
  "name": "Primary-Site-To-Azure",
  "rpoThresholdMinutes": 15,
  "azure": { "vaultName": "rsv-dr", "recoveryPlan": "rp-primary" },
  "failoverSteps": [
    { "name": "Fail over DB replica", "type": "veeam_replica", "target": "prod-db-01_replica" },
    { "name": "Fail over app tier to Azure", "type": "azure_failover", "recoveryPlan": "rp-primary" },
    { "name": "Point app DNS at DR", "type": "dns_update", "zone": "example.local",
      "record": "app", "failoverIp": "10.20.0.10", "primaryIp": "10.10.0.10" },
    { "name": "Notify IT", "type": "notification", "to": "it-admin@example.local",
      "continueOnError": true }
  ]
}
```
The `azure_failover` step has no `direction` field: the action decides it (failover →
unplanned failover `PrimaryToRecovery`; failback → planned failover `RecoveryToPrimary`, see §5.5).

### 5.3 Public functions (module `BackupDR`)
| Function | Signature | Returns |
|---|---|---|
| `Get-BackupPolicy` | `-Path <string>` | validated policy object; throws `PolicyValidationException`-style error listing all problems |
| `Test-BackupJobDue` | `-Job <psobject> -Now <datetime> [-LastRun <datetime>]` | `[bool]`. If `LastRun` > `Now` (clock skew or seeded future session) an interval job is **not due** and a WARN is logged. |
| `Start-BackupJob` | `-Job <psobject> [-DryRun] [-PollSeconds <int>] [-Alerting <psobject>]` | `[pscustomobject]@{JobName; Outcome = Started/Skipped/NotFound/AlreadyRunning/DryRun/Error; Result; Duration; Message}` (`Message` carries the log text, e.g. the exception message for `Error`). `-PollSeconds` defaults to `$env:BACKUPDR_POLL_SECONDS`, else 60; `0` is allowed. After `Start-VBRJob` it checks the session state **before** the first sleep (no sleep when already finished), then polls at most `maxPolls = ceil(timeoutHours*3600 / max(PollSeconds,1))` times; when the budget is exhausted `Result='Timeout'`. No Stopwatch. |
| `Get-BackupJobReport` | `-JobName <string[]>` | objects `{JobName, Status, StartTime, EndTime, DataSize, DedupRatio}` |
| `ConvertTo-BackupReportHtml` | `-Report <object[]> -Title <string>` | HTML string |
| `Test-RetentionCompliance` | `-Policy <psobject> [-Now <datetime>]` | objects `{JobName, OldestPointAge, ExpiredPoints, NewestPointAge, Compliant, Issues[]}` |
| `Get-BackupServerHealth` | `-Policy <psobject> [-Now <datetime>]` | `{State = OK/WARNING/CRITICAL; ExitCode; Checks[]}`; `Checks` includes one `Retention` entry per job from `Test-RetentionCompliance` (non-compliant → WARNING with its `Issues`) |
| `Get-AzureReplicationStatus` | `-Plan <psobject> [-Now <datetime>]` | `{State; ExitCode; Items[{Name, Health, RpoMinutes, Ok}]}` |
| `Get-DRPlan` | `-Path <string>` | validated plan |
| `Invoke-DRPlan` | `-Plan <psobject> -Action failover|failback|test [-Alerting] [-RunLogPath] [-Now]` | `{Action; Success; Steps[{Name, Type, Status, Message, Started, Finished}]}` |
| `Send-BackupAlert` | `-Alerting <psobject> -Subject <string> -Body <string> [-BodyAsHtml]` | nothing; wraps `Send-MailMessage` |
| `Set-BackupLogPath` | `-Path <string>` | nothing; sets `$script:LogPath` and creates the parent directory; default `logs/backupdr.log` under the repo |
| `Write-BackupLog` (private) | `-Message -Level INFO/WARN/ERROR` | writes to host + `$script:LogPath` |

### 5.4 Scripts (CLI)
```
pwsh scripts/backup_scheduler.ps1  [-ConfigPath config/backup_policy.json] [-DryRun] [-Now <datetime>] [-PollSeconds <int>] [-ReportPath out/report.html] [-LogPath logs/backup_scheduler.log]
pwsh scripts/disaster_recovery.ps1 -Action failover|failback|test [-PlanPath config/dr_plan.json] [-ConfigPath config/backup_policy.json] [-RunLogPath out/dr-run.json] [-Now <datetime>] [-Force]
pwsh scripts/health_check.ps1      [-ConfigPath ...] [-Now <datetime>]   # exit 0/1/2; includes retention audit
pwsh scripts/azure_replication.ps1 [-PlanPath ...] [-Now <datetime>]     # exit 0/1/2
```
`-Now` defaults to `Get-Date` in every script and is passed to every age/schedule decision.
`disaster_recovery.ps1` asks for confirmation (`$PSCmdlet.ShouldContinue`) before `failover` or
`failback`; `-Force` skips the prompt (unattended runs and tests). `test` never prompts.

Default paths are resolved relative to `$PSScriptRoot` (the old `..\config` relative to CWD is
a bug). Environment: `BACKUPDR_PROVIDER` = `veeam` (default on Windows) | `simulator` | `none`
(load no vendor commands; used by unit tests); `BACKUPDR_SIM_STATE` = directory of simulator
state files; `BACKUPDR_SIM_NOW` = simulator clock (§4); `BACKUPDR_POLL_SECONDS` = default for
`-PollSeconds` (an explicit parameter wins); `BACKUPDR_SMTP_SERVER/PORT`.

### 5.5 Vendor cmdlets used (and therefore simulated)
- Veeam 9.5 (`VeeamPSSnapin`): `Get-VBRJob -Name`, `Start-VBRJob -Job [-RunAsync]`,
  job methods `GetLastState()`, `FindLastSession()`, `Get-VBRBackupSession`, `Get-VBRBackup -Name`,
  `Get-VBRRestorePoint -Backup`, `Get-VBRReplica -Name`, `Start-VBRViReplicaFailover -RestorePoint`,
  `Start-VBRViReplicaFailback -RestorePoint`, `Get-VBRBackupRepository` (+ `GetContainer()`
  → `CachedTotalSpace`, `CachedFreeSpace`).
- AzureRM 6.x (`AzureRM.RecoveryServices.SiteRecovery`): `Get-AzureRmRecoveryServicesVault`,
  `Set-AzureRmRecoveryServicesAsrVaultContext`, `Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name`,
  `Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan -Direction PrimaryToRecovery`
  (failover; for VMware VMs replicated to Azure, ASR in 2018 supported only unplanned failover
  to Azure), `Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -RecoveryPlan -Direction
  RecoveryToPrimary` (failback only), `Get-AzureRmRecoveryServicesAsrJob`,
  `Get-AzureRmRecoveryServicesAsrReplicationProtectedItem`.
- Windows `DnsServer` module: `Get-DnsServerZone -Name` (pre-flight),
  `Add-DnsServerResourceRecordA -ZoneName -Name -IPv4Address`,
  `Remove-DnsServerResourceRecord -ZoneName -Name -RRType A -Force`,
  `Get-DnsServerResourceRecord -ZoneName -Name`.
- Windows PowerShell host: `Add-PSSnapin -Name VeeamPSSnapin` (provider `veeam` only). It does
  not exist in PowerShell Core, so VendorStubs defines it for unit tests.

## 6. Stack & pinned versions

| Component | Version | Released | Why it was the choice then |
|---|---|---|---|
| Windows PowerShell (target runtime) | 5.1 | 2016-08 (WMF 5.1) | Shipped with Server 2016 / Win10; what a Veeam 9.5 server ran. Code restricted to its syntax. |
| PowerShell Core (container runtime) | 6.1.2 | 2019-01-15 | Current stable PowerShell Core in the period; the only PowerShell with official Linux images. |
| Pester | 4.6.0 | 2019-01-21 (PSGallery) | De-facto PowerShell test framework; 4.x was current (5.0 came in 2020). Verified via PSGallery API. |
| PSScriptAnalyzer | 1.17.1 | 2018-06-05 (PSGallery) | Standard PowerShell linter; 1.18.0 arrived 2019-03-21, after the period. Verified via PSGallery API. |
| Veeam Backup & Replication PowerShell snap-in | 9.5 Update 3a/4 API surface | U4: 2019-01-22 | Current Veeam release; cmdlet names follow 9.5 docs. Simulated only. |
| AzureRM PowerShell (ASR cmdlets) | 6.x API surface | 6.13.1 on 2018-11 | Az module only reached 1.0 in Dec 2018; AzureRM was still what scripts used. Simulated only, not installed. |
| MailHog (local SMTP sink) | v1.0.0 | 2017-04-16 | Most common dev SMTP catcher of the time; has an HTTP API for asserting mail in tests. |
| Docker Compose file format | 3.7 | 2018-07 (Engine 18.06.0-ce / docker-compose 1.22.0) | Current compose format in the period. |
| docker-compose CLI (period invocation) | 1.23.2 | 2018-11-28 (PyPI) | Standalone Python CLI of the period; optional on the host (see §7). Verified with `check_period.py`. |

Pin verification: `check_period.py` checks the docker-compose pin via a `requirements.txt`
manifest (exit 0). It has no PowerShell Gallery support, so the two PSGallery modules were
verified directly against `https://www.powershellgallery.com/api/v2/FindPackagesById()`
published dates (both before 2019-02-28). Pins live in `build/requirements.psd1` and are
installed with `Install-Module -RequiredVersion`.

## 7. Docker images (tags verified)

| Image | Tag | Verified | Use |
|---|---|---|---|
| `mcr.microsoft.com/powershell` | `6.1.2-ubuntu-18.04` | MCR manifest HTTP 200; listed in `mcr.microsoft.com/v2/powershell/tags/list` | build/test/run image (Pester + PSScriptAnalyzer baked in) |
| `mailhog/mailhog` | `v1.0.0` | Docker Hub API HTTP 200 | SMTP sink for alert/report integration tests |

Note: `microsoft/powershell:6.1.x-ubuntu-18.04` on Docker Hub returns 404 (images moved to MCR),
so the MCR name is used. `6.1.3` (released 2019-02-19) also exists but 6.1.2 is chosen as
the version that was current for most of the period.

Host-side compose CLI: the Makefile default `COMPOSE ?= docker compose` is the Compose v2
plugin, a modern host tool that did not exist in the period; it is the default only because it
is what current Docker installs ship. The compose *file* stays at format 3.7, and the
period-accurate invocation works unchanged with `make COMPOSE=docker-compose`
(docker-compose 1.23.x).

## 8. Simulated / mocked integrations

| Real system | Replacement | Where |
|---|---|---|
| Veeam B&R 9.5 server + `VeeamPSSnapin` | **VeeamSim** — PowerShell module with same-named cmdlets, state in `veeam.json` (jobs, sessions, backups, restore points, replicas, repositories); `Start-VBRJob` completes a session immediately with the result seeded in state, stamped with the simulator clock | `sim/VeeamSim/` |
| VMware vSphere 6.5 VMs | Named VM/replica entries inside VeeamSim state | `sim/state/veeam.sample.json` |
| Azure Site Recovery (AzureRM) | **AzureSim** — same-named AzureRM ASR cmdlets over `azure.json` (vault, recovery plans, protected items with health and RPO); unplanned failover to recovery, planned failover only for failback | `sim/AzureSim/` |
| Windows DNS Server (`DnsServer` module) | **DnsSim** — zone lookup and A-record add/remove/get over `dns.json` | `sim/DnsSim/` |
| Corporate SMTP relay | **MailHog** container (real SMTP, fake mailbox) | `docker-compose.yml` |
| All of the above in unit tests | **VendorStubs** global module (`tests/TestHelpers/VendorStubs.ps1`) + **Pester 4 `Mock -ModuleName BackupDR`** against the same command names | `tests/unit/` |

The final README must state that Veeam, vSphere, Azure and Windows DNS are simulated and that the
toolkit has never been run against a real Veeam server.

## 9. Existing code inventory (`git ls-files`)

| File | Decision | Reason |
|---|---|---|
| `README.md` | refactor | Regenerated from `tools/readme_template.md` in the last task with an honest Status and generated Layout. |
| `config/backup_policy.json` | refactor | Job list is good and kept verbatim; add `alerting.from/smtpServer/smtpPort`, `health` section, bump `version`. |
| `scripts/backup_scheduler.ps1` | refactor | Logic (policy load, already-running check, wait loop, integrity report, alert mail) is sound and is moved into module functions; script becomes a thin entrypoint. Fixes: hard-coded `C:\Logs`, CWD-relative config path, ignored `intervalMinutes`, unused report, alert settings ignoring the policy, `Send-AlertEmail` defined after use in call order, sleep-before-first-poll. |
| `scripts/disaster_recovery.ps1` | refactor | Step-type switch is the right design and is kept as `Invoke-DRPlan`; commented-out cmdlet calls become real (simulated) calls; `failback` is currently accepted but does nothing; `dr_plan.json` it reads does not exist. |

No file is deleted. `docs/SPEC.md` and `docs/IMPLEMENTATION_PLAN.md` are currently untracked and
are committed in T1.

## 10. Test strategy

- **Runner**: `build/Invoke-Tests.ps1` runs PSScriptAnalyzer (settings in
  `build/PSScriptAnalyzerSettings.psd1`, default rules) and fails on any Error-severity finding.
  It does not use `PSUseCompatibleCmdlets`: in PSScriptAnalyzer 1.17.1 that rule flags a command
  only when it exists in the reference platform and is missing from the target, the reference is
  hard-coded to `desktop-5.1.14393.206-windows` (the `reference` setting is honoured only in
  `#if DEBUG` builds), so targeting desktop-5.1 can never flag anything. The 5.1 cmdlet check is
  done by `Compatibility.Tests.ps1` instead (below). It then runs
  `Invoke-Pester` with `-EnableExit`, NUnit XML to `out/testresults.xml`, and
  `-CodeCoverage (Get-ChildItem src -Recurse -Include *.ps1)` (coverage is reported; there is
  no threshold gate). Before `Integration`-tagged tests run, it waits for MailHog by retrying
  `Invoke-RestMethod http://mailhog:8025/api/v2/messages` for up to ~10 s.
- **`make test`** = `$(COMPOSE) run --rm app pwsh -File build/Invoke-Tests.ps1`
  (compose starts MailHog via `depends_on`). `make test-unit` and `make lint` use
  `$(COMPOSE) run --rm --no-deps app ...`, so MailHog is not started.
- **Unit (`tests/unit/*.Tests.ps1`, tag `Unit`)**: every public function. Each file sets
  `$env:BACKUPDR_PROVIDER = 'none'` before `Import-Module src/BackupDR -Force`, so the simulators
  are never loaded in unit runs. `tests/TestHelpers/VendorStubs.ps1` defines every §5.5 command
  (plus `Add-PSSnapin`) as a **global** module
  (`New-Module -Name VendorStubs { ... } | Import-Module -Global -Force`), so code inside
  `BackupDR` can resolve them. Every mock of a command called from module code is written
  `Mock -ModuleName BackupDR <cmd>` and asserted with `Assert-MockCalled -ModuleName BackupDR`;
  this includes `Start-Sleep` and `Send-MailMessage`. Time is injected via `-Now`.
  `Send-MailMessage` is asserted on subject and recipient.
- **Simulator tests (`tests/sim/*.Tests.ps1`, tag `Unit`)**: the simulators behave like the
  cmdlets they stand in for (state round-trip, failover changes replica state, simulator clock
  honoured, `New-SimState -Anchor` rewrites offsets).
- **Integration (`tests/integration/*.Tests.ps1`, tag `Integration`)**: run each script as a child
  `pwsh` process with `BACKUPDR_PROVIDER=simulator`, a seeded temp state directory
  (`New-SimState -Anchor $now`), `BACKUPDR_SIM_NOW=$now` and the same `-Now $now` passed to the
  script; the scheduler also gets `-PollSeconds 0`. Assert exit codes, log lines, report file,
  DR run log, DNS state after failover/failback, retention warnings from `health_check.ps1`,
  and that MailHog received the expected messages (`GET http://mailhog:8025/api/v2/messages`,
  cleared with `DELETE /api/v1/messages` before each test).
- **Compatibility (`tests/unit/Compatibility.Tests.ps1`, tag `Unit`)**: for every `.ps1` /
  `.psm1` under `src/`, `scripts/`, `sim/`:
  1. parses it with `[System.Management.Automation.Language.Parser]::ParseFile` and fails on any
     parse error (this is what catches ternary, `?.` and `??` on PowerShell 6.1);
  2. collects `GetCommandName()` of every `CommandAst` (dynamic invocations such as `& $cmd`
     return `$null` and are skipped) and fails on any name that is not (a) in the
     `ExportedCommands` of PSScriptAnalyzer's shipped
     `Settings/desktop-5.1.14393.206-windows.json` (under the installed module's `ModuleBase`),
     (b) a function defined by a `FunctionDefinitionAst` anywhere in those three directories, or
     (c) on an explicit allowlist of the §5.5 vendor commands (the DnsServer, Veeam and AzureRM
     cmdlets are not in that client profile). Aliases are not resolved, so code in these
     directories uses full cmdlet names;
  3. fails on a case-insensitive regex match of `ConvertFrom-Json[^|]*-AsHashtable` or
     `ForEach-Object[^|]*-Parallel` (parameters 5.1 lacks on cmdlets it has); `Group-Object
     -AsHashTable`, valid in 5.1, does not match.
  Self-tests feed `TestDrive:` files through the same helpers: a call to `Get-Uptime` or
  `Test-Json` (6.x-only) must be flagged, `ConvertFrom-Json -AsHashtable` must be flagged, and
  `Group-Object -AsHashTable` must pass.
- Coverage goal: every in-scope feature has at least one unit and one integration assertion.

## 11. Known limitations that will remain

- Never run against a real Veeam, vSphere, Azure or Windows DNS server; simulators model only the
  properties and cmdlets listed in 5.5, and vendor object shapes are approximations.
- CI runs on PowerShell Core 6.1 on Linux, not Windows PowerShell 5.1. 5.1 compatibility is
  enforced by `Compatibility.Tests.ps1` (§10), not by execution: it checks command **names**
  against PSScriptAnalyzer 1.17.1's shipped `desktop-5.1.14393.206-windows` command list, fails
  on parse errors (ternary, `?.`, `??` do not parse on 6.1) and regex-matches two known 6.x-only
  parameters (`ConvertFrom-Json -AsHashtable`, `ForEach-Object -Parallel`). Other 6.x-only
  parameters are not detected and remain held by convention and review. PSScriptAnalyzer's
  own `PSUseCompatibleCmdlets` is not used because in 1.17.1 its reference platform is fixed to
  desktop-5.1, so targeting desktop-5.1 flags nothing; `PSUseCompatibleSyntax` only arrived in
  1.18. The profile is a Windows 10 client profile, so server-only modules are covered only by
  the §5.5 allowlist.
- Simulated `Start-VBRJob` completes instantly; real job durations/timeouts are exercised only
  through mocked sessions in unit tests.
- No retention enforcement, no scheduling installation, no authentication.
- Alert e-mail uses unauthenticated SMTP without TLS (as `Send-MailMessage` to an internal relay).

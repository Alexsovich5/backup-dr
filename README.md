# backup-dr

A PowerShell toolkit that drives Veeam Backup & Replication 9.5 backup jobs from a JSON policy
file, audits the results, and runs a JSON-described disaster-recovery plan. The scheduler
decides which jobs are due, starts them, waits for them with a timeout, verifies the latest
sessions, e-mails alerts and an HTML daily report. A health check reports repository space,
failed and overdue jobs and retention drift; a replication check reports Azure Site Recovery
health against an RPO threshold; the DR script runs failover, failback or a no-change test of
the plan (Veeam replica failover, Azure Site Recovery failover, DNS cut-over, notification) in a
fixed, logged order.

Personal project built on the 2018-era stack (Windows PowerShell 5.1 syntax tested on
PowerShell Core 6.1.2, Pester 4, Veeam 9.5 and AzureRM 6.x cmdlet surfaces).

## Status

**Implemented**

- Backup policy loading and validation, listing every problem in one error —
  `src/BackupDR/Public/Get-BackupPolicy.ps1`, `config/backup_policy.json`;
  tests in `tests/unit/Get-BackupPolicy.Tests.ps1`.
- Schedule evaluation for weekday/`Daily` jobs and `intervalMinutes` sub-daily jobs —
  `Test-BackupJobDue.ps1`; `tests/unit/Test-BackupJobDue.Tests.ps1`.
- Job execution that skips missing and already-running jobs, polls until the new session (not
  the previous run's) has stopped or `timeoutHours` passes, reports a missing session or an
  unrecognised result as `Unknown` (alerted, scheduler exits 1), and supports `-DryRun` —
  `Start-BackupJob.ps1`; `tests/unit/Start-BackupJob.Tests.ps1`.
- Exact-name lookups of Veeam jobs, backups and replicas and of ASR vaults and recovery plans:
  wildcard names are refused, prefix matches are ignored and a name matching more than one
  object is an error, so a job start, failover or audit never acts on the wrong object —
  `Private/Resolve-ExactVendorObject.ps1`; `tests/unit/Resolve-ExactVendorObject.Tests.ps1`,
  `tests/unit/Start-BackupJob.Tests.ps1`, `tests/unit/DRSteps.Tests.ps1`,
  `tests/unit/Test-RetentionCompliance.Tests.ps1`.
- Post-backup verification (status, times, data size, dedup ratio) and an HTML daily report —
  `Get-BackupJobReport.ps1`, `ConvertTo-BackupReportHtml.ps1`;
  `tests/unit/Get-BackupJobReport.Tests.ps1`, `tests/unit/ConvertTo-BackupReportHtml.Tests.ps1`.
- E-mail alerts on failure/warning and the daily report, sent over SMTP using the policy's
  alerting settings — `Send-BackupAlert.ps1`; `tests/unit/Send-BackupAlert.Tests.ps1`,
  `tests/integration/Smtp.Tests.ps1`.
- Scheduler entrypoint tying these together — `scripts/backup_scheduler.ps1`;
  `tests/integration/BackupScheduler.Tests.ps1`.
- Retention compliance audit (restore points kept past `retentionDays`, jobs with no recent
  restore point) — `Test-RetentionCompliance.ps1`; `tests/unit/Test-RetentionCompliance.Tests.ps1`.
- Backup server health check with Nagios-style exit codes 0/1/2, including the retention audit —
  `Get-BackupServerHealth.ps1`, `scripts/health_check.ps1`;
  `tests/unit/Get-BackupServerHealth.Tests.ps1`, `tests/integration/HealthCheck.Tests.ps1`.
- Azure Site Recovery replication status against the plan's RPO threshold —
  `Get-AzureReplicationStatus.ps1`, `scripts/azure_replication.ps1`;
  `tests/unit/Get-AzureReplicationStatus.Tests.ps1`, `tests/integration/AzureReplication.Tests.ps1`.
- DR plan loading and validation — `Get-DRPlan.ps1`, `config/dr_plan.json`;
  `tests/unit/Get-DRPlan.Tests.ps1`.
- DR execution: failover in order, failback of reversible steps in reverse order, and a
  pre-flight `test` that changes nothing; stops on the first failed step unless
  `continueOnError` is set; a notification that could not be mailed and a DNS record that cannot
  be read fail their step instead of passing silently; writes a JSON run log —
  `Invoke-DRPlan.ps1`, `Private/Invoke-*Step.ps1`,
  `scripts/disaster_recovery.ps1`; `tests/unit/Invoke-DRPlan.Tests.ps1`,
  `tests/unit/DRSteps.Tests.ps1`, `tests/integration/DisasterRecovery.Tests.ps1`.
- Logging to console and a configurable log file — `Private/Write-BackupLog.ps1`,
  `Set-BackupLogPath.ps1`; `tests/unit/Write-BackupLog.Tests.ps1`.
- Simulators for the vendor cmdlets, with state in JSON files — `sim/`; `tests/sim/`.
- Container checks: every port published by `docker-compose.yml` (as written and as rendered by
  `docker compose config`) is bound to 127.0.0.1, and no Dockerfile turns off apt signature
  checks — `tests/unit/Container.Tests.ps1`.
- Operations runbook — `docs/runbook.md`; `tests/unit/Docs.Tests.ps1` checks the files it names.

Function files above are under `src/BackupDR/Public/` unless a path is given.

**Not implemented / known limitations**

- Veeam Backup & Replication, VMware vSphere, Azure Site Recovery and Windows DNS are simulated
  by the VeeamSim, AzureSim and DnsSim modules (integration tests, demo) and by Pester mocks
  (unit tests). The toolkit has never been run against a real Veeam server, vSphere
  environment, Azure subscription or Windows DNS server; the simulators model only the cmdlets
  and properties the toolkit uses, and vendor object shapes are approximations.
- vSphere is never called directly; it appears only as VM and replica names in VeeamSim state.
- No Azure authentication (`Connect-AzureRmAccount`, service principals).
- No retention enforcement: restore points are audited, never deleted.
- Replication itself is done by Veeam/ASR; the toolkit only reports its status.
- Scheduling is not installed automatically; the runbook documents a `schtasks` line.
- Tests run on PowerShell Core 6.1.2 on Linux, not Windows PowerShell 5.1. 5.1 compatibility is
  checked statically (parse errors, command names against PSScriptAnalyzer's 5.1 profile, two
  known 6.x-only parameters); other 6.x-only parameters are not detected.
- Simulated `Start-VBRJob` completes instantly; long-running jobs and timeouts are covered only by
  mocked sessions in unit tests.
- Alert e-mail uses unauthenticated SMTP without TLS. Only SMTP runs against a real server
  (MailHog in a container).
- MailHog is lab software without authentication; its web UI/API is published on
  127.0.0.1:21025 only and its SMTP port is reachable only inside the compose network.
- A `veeam_replica` step fails over one VM: a replica whose restore points belong to more than
  one VM is refused rather than failing over an arbitrary one.
- Pester and PSScriptAnalyzer are installed from the PowerShell Gallery pinned by version, not
  by file hash.
- No RPO/RTO or backup success-rate figures are claimed; the RPO check is a configurable
  threshold in `config/dr_plan.json`.

## Built with

- **PowerShell** — Windows PowerShell 5.1 syntax, run on PowerShell Core 6.1.2
  (`mcr.microsoft.com/powershell:6.1.2-ubuntu-18.04`)
- **Pester 4.6.0** and **PSScriptAnalyzer 1.17.1** (pinned in `build/requirements.psd1`)
- **MailHog v1.0.0** as the local SMTP server

## Running it

Everything runs in Docker images from the project's era, so nothing needs installing locally beyond Docker.

```bash
docker compose up -d mailhog   # start the SMTP sink (web UI on http://localhost:21025)
make demo                      # seed simulator state, run the scheduler dry and for real
```

`make demo` writes the HTML report to `out/report.html` and the alert and report e-mails land
in MailHog. `make shell` opens PowerShell in the same image to run the other scripts; see
`docs/runbook.md`.

## Tests

```bash
make test                # runs the suite inside the period image
```

`make test` runs PSScriptAnalyzer, unit tests with Pester mocks for every public function,
simulator tests, a PowerShell 5.1 compatibility check, and integration tests that run each
script against the simulators and MailHog (`make test-unit` skips the integration tests); they
do not exercise real Veeam, Azure, vSphere or DNS servers, or Windows PowerShell itself.

## Layout

```
.gitignore
Dockerfile
Makefile
README.md
build/
  Invoke-Tests.ps1
  PSScriptAnalyzerSettings.psd1
  requirements.psd1
config/
  backup_policy.json
  dr_plan.json
docker-compose.yml
docs/
  IMPLEMENTATION_PLAN.md
  SPEC.md
  runbook.md
requirements.txt
scripts/
  azure_replication.ps1
  backup_scheduler.ps1
  disaster_recovery.ps1
  health_check.ps1
sim/
  AzureSim/
    AzureSim.psd1
    AzureSim.psm1
  DnsSim/
    DnsSim.psd1
    DnsSim.psm1
  VeeamSim/
    VeeamSim.psd1
    VeeamSim.psm1
  state/
    azure.sample.json
    dns.sample.json
    veeam.sample.json
src/
  BackupDR/
    BackupDR.psd1
    BackupDR.psm1
    Private/
      Get-RetentionExpectedGap.ps1
      Import-BackupDRProvider.ps1
      Invoke-AzureFailoverStep.ps1
      Invoke-DnsUpdateStep.ps1
      Invoke-NotificationStep.ps1
      Invoke-VeeamReplicaStep.ps1
      Resolve-ExactVendorObject.ps1
      Test-PolicyNumber.ps1
      Write-BackupLog.ps1
    Public/
      ConvertTo-BackupReportHtml.ps1
      Get-AzureReplicationStatus.ps1
      Get-BackupJobReport.ps1
      Get-BackupPolicy.ps1
      Get-BackupServerHealth.ps1
      Get-DRPlan.ps1
      Invoke-DRPlan.ps1
      Send-BackupAlert.ps1
      Set-BackupLogPath.ps1
      Start-BackupJob.ps1
      Test-BackupJobDue.ps1
      Test-RetentionCompliance.ps1
tests/
  TestHelpers/
    MailHog.ps1
    New-SimState.ps1
    VendorStubs.ps1
  fixtures/
    dr-plan-invalid.json
    policy-invalid.json
  integration/
    AzureReplication.Tests.ps1
    BackupScheduler.Tests.ps1
    DisasterRecovery.Tests.ps1
    HealthCheck.Tests.ps1
    Smtp.Tests.ps1
  sim/
    AzureSim.Tests.ps1
    DnsSim.Tests.ps1
    VeeamSim.Tests.ps1
  unit/
    Compatibility.Tests.ps1
    Container.Tests.ps1
    ConvertTo-BackupReportHtml.Tests.ps1
    DRSteps.Tests.ps1
    Docs.Tests.ps1
    Get-AzureReplicationStatus.Tests.ps1
    Get-BackupJobReport.Tests.ps1
    Get-BackupPolicy.Tests.ps1
    Get-BackupServerHealth.Tests.ps1
    Get-DRPlan.Tests.ps1
    Harness.Tests.ps1
    Import-BackupDRProvider.Tests.ps1
    Invoke-DRPlan.Tests.ps1
    Resolve-ExactVendorObject.Tests.ps1
    Send-BackupAlert.Tests.ps1
    Start-BackupJob.Tests.ps1
    Test-BackupJobDue.Tests.ps1
    Test-RetentionCompliance.Tests.ps1
    Write-BackupLog.Tests.ps1
```

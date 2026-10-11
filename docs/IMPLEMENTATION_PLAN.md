# backup-dr — Implementation Plan

Each task is one commit and leaves `make test` green. Tasks are ordered by dependency.
All commands run from the repo root on a host with Docker; nothing else is installed locally.
Conventions used below:

- `make test`       → `$(COMPOSE) run --rm app pwsh -NoProfile -File build/Invoke-Tests.ps1` (starts MailHog via `depends_on`)
- `make test-unit`  → `$(COMPOSE) run --rm --no-deps app pwsh -NoProfile -File build/Invoke-Tests.ps1 -Tag Unit` (MailHog not started)
- `make lint`       → `$(COMPOSE) run --rm --no-deps app ...` PSScriptAnalyzer only
- `COMPOSE ?= docker compose`; the period-accurate `make COMPOSE=docker-compose` (1.23.x) also works (SPEC §7).
- Code under `src/`, `scripts/`, `sim/` must stay Windows PowerShell 5.1-compatible (SPEC §4, §11).
- Unit-test pattern (SPEC §10), used by every `tests/unit/*.Tests.ps1` from T3 on:
  ```powershell
  $env:BACKUPDR_PROVIDER = 'none'
  . $PSScriptRoot/../TestHelpers/VendorStubs.ps1      # builds a GLOBAL module of stubs
  Import-Module $PSScriptRoot/../../src/BackupDR -Force
  Mock -ModuleName BackupDR Get-VBRJob { ... }
  Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 0 -Exactly
  ```
- Integration-test pattern: `$now = [datetime]'2019-02-17T02:00:00'` (a Sunday);
  `New-SimState -Anchor $now`; `$env:BACKUPDR_SIM_NOW = $now.ToString('o')`; every script gets
  `-Now $now`; the scheduler also gets `-PollSeconds 0`.

---

## T1 — Scaffold Docker image, Makefile and Pester harness

**Goal:** `make test` runs Pester 4.6.0 + PSScriptAnalyzer 1.17.1 inside the period image from the first commit, with the 5.1 compatibility gate active.

**Files**
- add `docs/SPEC.md`, `docs/IMPLEMENTATION_PLAN.md` (currently untracked; committed here so they are part of `git ls-files` from the start)
- create `Dockerfile` (`FROM mcr.microsoft.com/powershell:6.1.2-ubuntu-18.04`; `apt-get install -y git` (bionic archive, needed by the README layout test in T17); `Set-PSRepository PSGallery -InstallationPolicy Trusted`; install modules from `build/requirements.psd1` with `-RequiredVersion`, `-Scope AllUsers`, `-SkipPublisherCheck`; `WORKDIR /src`)
- create `build/requirements.psd1` (`@{ Pester = '4.6.0'; PSScriptAnalyzer = '1.17.1' }`)
- create `docker-compose.yml` (format `3.7`; service `app` builds `.`, mounts `.:/src`, env `BACKUPDR_PROVIDER=simulator`, `BACKUPDR_SMTP_SERVER=mailhog`, `BACKUPDR_SMTP_PORT=1025`, `depends_on: [mailhog]`; service `mailhog` image `mailhog/mailhog:v1.0.0`, host port `21025:8025` (the web UI/API; in-network clients use `mailhog:8025`); app image named `backup-dr:dev`; default network pinned to subnet `172.60.0.0/24` so the stack stays off other projects' address ranges on a shared Docker host)
- create `Makefile` (`COMPOSE ?= docker compose`; targets `build`, `test`, `test-unit`, `lint`, `shell`, `clean`; `test-unit` and `lint` use `run --rm --no-deps`; `lint` runs `Invoke-Tests.ps1 -LintOnly`; the Makefile exports `COMPOSE_PROJECT_NAME ?= backup-dr`. No `demo` target yet — it is added in T9 when the scripts exist.)
- create `build/Invoke-Tests.ps1`:
  - params `-Tag`, `-ExcludeTag`, `-LintOnly` (stop after PSScriptAnalyzer; used by `make lint`)
  - `Invoke-ScriptAnalyzer -Recurse -Settings build/PSScriptAnalyzerSettings.psd1` over `src scripts sim` (skip dirs that do not exist yet); fail if any finding has `Severity -eq 'Error'`. `PSUseCompatibleCmdlets` is deliberately not used (in 1.17.1 its reference platform is hard-coded to desktop-5.1, so targeting desktop-5.1 flags nothing; see SPEC §10); the 5.1 gate is `Compatibility.Tests.ps1`
  - if the run includes `Integration` tests: retry `Invoke-RestMethod http://mailhog:8025/api/v2/messages` every 500 ms for up to 10 s, fail with a clear message if MailHog never answers
  - `Invoke-Pester -Script tests -Tag ... -EnableExit -OutputFormat NUnitXml -OutputFile out/testresults.xml -CodeCoverage (Get-ChildItem src -Recurse -Include *.ps1)` (omit `-CodeCoverage` while `src/` is empty)
- create `build/PSScriptAnalyzerSettings.psd1` (default rules only)
- create `tests/unit/Harness.Tests.ps1`, `tests/unit/Compatibility.Tests.ps1`
- create `.gitignore` (`out/`, `logs/`, `*.log`)
- create `requirements.txt` (`docker-compose==1.23.2`, the optional period host CLI from SPEC §6, so `check_period.py` has a manifest to verify)

**Tests to write first:** `Harness.Tests.ps1` (tag `Unit`): `$PSVersionTable.PSVersion` is `6.1.2`; `(Get-Module Pester).Version` is `4.6.0`; `Get-Module -ListAvailable PSScriptAnalyzer` version `1.17.1`. `Compatibility.Tests.ps1` (tag `Unit`), per SPEC §10, for every `.ps1`/`.psm1` under `src/`, `scripts/`, `sim/` (existing dirs only): `[System.Management.Automation.Language.Parser]::ParseFile` reports no parse errors; every `CommandAst.GetCommandName()` (non-null) is in the `ExportedCommands` of `Join-Path (Get-Module -ListAvailable PSScriptAnalyzer).ModuleBase 'Settings/desktop-5.1.14393.206-windows.json'`, or is a function defined in those dirs, or is on the SPEC §5.5 vendor allowlist (held in the test file); no case-insensitive regex match of `ConvertFrom-Json[^|]*-AsHashtable` or `ForEach-Object[^|]*-Parallel`. Self-checks through the same helpers on `TestDrive:` files: `Get-Uptime` and `Test-Json` are flagged; `ConvertFrom-Json -AsHashtable` is flagged; `Group-Object -AsHashTable` and a call to `Get-VBRJob` (allowlisted) pass.

**Acceptance:** `make build && make test`

**Commit:** 
```
Add Docker test harness with Pester 4 and PSScriptAnalyzer

Build a PowerShell Core 6.1 image with pinned test modules and a Makefile
so the suite runs in a container. A parser-based test fails on commands
and syntax that Windows PowerShell 5.1 lacks. Commits the spec and
implementation plan.
```

---

## T2 — Create BackupDR module with logging and policy loading

**Goal:** Module skeleton; port `Write-Log` and `Get-BackupPolicy` from `scripts/backup_scheduler.ps1` into it with validation and a configurable log path.

**Files**
- create `src/BackupDR/BackupDR.psd1` (`PowerShellVersion = '5.1'`, `CompatiblePSEditions = 'Desktop','Core'`, explicit `FunctionsToExport` incl. `Set-BackupLogPath`)
- create `src/BackupDR/BackupDR.psm1` (dot-sources `Private/*.ps1`, `Public/*.ps1`)
- create `src/BackupDR/Private/Write-BackupLog.ps1`
- create `src/BackupDR/Public/Set-BackupLogPath.ps1` (SPEC §5.3; default `logs/backupdr.log` under repo; creates parent dir)
- create `src/BackupDR/Public/Get-BackupPolicy.ps1` (validation rules from SPEC §5.1; collects all errors; applies `BACKUPDR_SMTP_*` overrides)
- modify `config/backup_policy.json` (add `alerting.from`, `smtpServer`, `smtpPort`, `health.repositoryMinFreePercent`, version `1.1`; jobs unchanged)
- modify `build/Invoke-Tests.ps1` (enable `-CodeCoverage` now that `src/` exists)
- create `tests/unit/Get-BackupPolicy.Tests.ps1`, `tests/unit/Write-BackupLog.Tests.ps1`, `tests/fixtures/policy-invalid.json`

**Tests to write first:** valid shipped policy loads with 4 jobs; duplicate job names, bad `type`, bad weekday, `timeoutHours: 0`, `intervalMinutes: 5` each produce a named error, and all errors are reported together; env override replaces `smtpServer`; `Set-BackupLogPath TestDrive:\x\y.log` creates `x\`; log line format `[yyyy-MM-dd HH:mm:ss] [LEVEL] msg` written to that path (private function tested via `InModuleScope BackupDR`).

**Acceptance:** `make test`

**Commit:**
```
Move policy loading and logging into a BackupDR module

Validate backup_policy.json up front and report every problem at once.
Log path is now configurable instead of hard-coded to C:\Logs.
```

---

## T3 — Add vendor cmdlet stubs and the VeeamSim simulator

**Goal:** Make Veeam cmdlet names exist on Linux: global stubs for Pester mocking, and a stateful simulator for integration runs; provider loader chooses between real snap-in, simulator, or nothing.

**Files**
- create `tests/TestHelpers/VendorStubs.ps1`: `New-Module -Name VendorStubs -ScriptBlock { function Get-VBRJob { param($Name) throw 'stub' } ... ; Export-ModuleMember -Function * } | Import-Module -Global -Force`. One stub per Veeam cmdlet in SPEC §5.5 with the real parameter names, plus `Add-PSSnapin -Name` (absent on PowerShell Core). Global scope is required: code inside `BackupDR` resolves commands through module scope then global scope and never sees functions defined in the Pester test scope.
- create `sim/VeeamSim/VeeamSim.psm1`, `sim/VeeamSim/VeeamSim.psd1` (`Get-VBRJob`, `Start-VBRJob`, `Get-VBRBackupSession`, `Get-VBRBackup`, `Get-VBRRestorePoint`, `Get-VBRReplica`, `Start-VBRViReplicaFailover`, `Start-VBRViReplicaFailback`, `Get-VBRBackupRepository`; objects expose `GetLastState()`, `FindLastSession()`, `GetContainer()` as ScriptMethods; state in `$env:BACKUPDR_SIM_STATE/veeam.json`; new sessions stamped with `$env:BACKUPDR_SIM_NOW` if set, else `Get-Date`)
- create `sim/state/veeam.sample.json` (the 4 policy jobs, sessions, restore points, one replica `prod-db-01_replica`, one repository; all timestamps as relative offsets such as `"-26h"`)
- create `src/BackupDR/Private/Import-BackupDRProvider.ps1` (`BACKUPDR_PROVIDER`: `veeam` → `Add-PSSnapin -Name VeeamPSSnapin` wrapped in try/catch that rethrows `"Veeam PowerShell snap-in (VeeamPSSnapin) not found; install the Veeam console or set BACKUPDR_PROVIDER=simulator"`; `simulator` → import `sim/*`; `none` → load nothing; anything else throws)
- create `tests/TestHelpers/New-SimState.ps1` (`New-SimState -Anchor <datetime> [-Path TestDrive:]`: copies sample state, rewrites every offset string to `Anchor + offset` in ISO 8601, sets `$env:BACKUPDR_SIM_STATE`)
- create `tests/sim/VeeamSim.Tests.ps1`, `tests/unit/Import-BackupDRProvider.Tests.ps1`

**Tests to write first:** `Get-VBRJob -Name` returns a job whose `GetLastState()` is `Stopped`; `Start-VBRJob` appends a session with the seeded result, stamped with `BACKUPDR_SIM_NOW`, and `FindLastSession()` returns it; failover on replica sets its state to `Failover` and persists to JSON; `New-SimState -Anchor 2019-02-17T02:00` turns `"-26h"` into `2019-02-16T00:00:00`. Provider (unit, `InModuleScope BackupDR`): unknown provider throws; `none` loads nothing; `simulator` makes `Get-VBRJob` available; `veeam` calls `Add-PSSnapin` with `-Name VeeamPSSnapin` (`Mock -ModuleName BackupDR Add-PSSnapin {}` + `Assert-MockCalled -ModuleName BackupDR Add-PSSnapin -ParameterFilter { $Name -eq 'VeeamPSSnapin' }`); `veeam` with `Add-PSSnapin` mocked to throw → error message names the snap-in.

**Acceptance:** `make test`

**Commit:**
```
Add Veeam cmdlet simulator and provider loader

VeeamSim implements the Veeam 9.5 cmdlets the toolkit uses over a JSON
state file so scripts can run end to end without a Veeam server.
```

---

## T4 — Decide which jobs are due, including interval jobs

**Goal:** Pure scheduling logic; fixes the ignored `intervalMinutes`.

**Files**
- create `src/BackupDR/Public/Test-BackupJobDue.ps1`
- create `tests/unit/Test-BackupJobDue.Tests.ps1`

**Tests to write first:** `Daily` due any day; `["Sunday"]` due on Sunday only (TestCases for all 7 days); `intervalMinutes: 60` due when `LastRun` is null or ≥ 60 min ago, not due at 59 min; `LastRun` 5 min **after** `Now` → not due and a WARN log line (`Mock -ModuleName BackupDR Write-BackupLog`, assert `Level -eq 'WARN'`); day names compared case-insensitively.

**Acceptance:** `make test-unit`

**Commit:**
```
Add schedule evaluation for backup jobs

Weekday and Daily schedules are evaluated against an injected time and
intervalMinutes is honoured for sub-daily jobs.
```

---

## T5 — Port Start-BackupJob with wait, timeout and outcomes

**Goal:** Move the job start/poll loop into the module, returning a result object instead of only logging. The loop checks the session before sleeping and counts polls instead of reading a Stopwatch.

**Files**
- create `src/BackupDR/Public/Start-BackupJob.ps1` (`-PollSeconds` default `$env:BACKUPDR_POLL_SECONDS` else 60, `0` allowed; after `Start-VBRJob` check `FindLastSession().State` first; loop `for ($i = 0; $i -lt $maxPolls; $i++) { Start-Sleep -Seconds $PollSeconds; check }` with `maxPolls = [math]::Ceiling(timeoutHours*3600 / [math]::Max(PollSeconds,1))`; outcomes per SPEC §5.3)
- create `tests/unit/Start-BackupJob.Tests.ps1`

**Tests to write first (all mocks `-ModuleName BackupDR`: `Get-VBRJob`, `Start-VBRJob`, `Start-Sleep`):** job not found → `NotFound`, `Start-VBRJob` not called; `GetLastState()='Working'` → `AlreadyRunning`; `-DryRun` → `DryRun`, nothing started; session already `Stopped/Success` right after start → `Started`/`Success` and `Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 0 -Exactly`; session goes Working→Success on the 2nd check → `Start-Sleep` called exactly 1 time; session stays Working with `timeoutHours = 0.01`, `-PollSeconds 12` (`maxPolls = 3`) → `Result='Timeout'` and `Start-Sleep -Times 3 -Exactly`; `BACKUPDR_POLL_SECONDS=5` used when `-PollSeconds` omitted (assert `Start-Sleep` `-ParameterFilter { $Seconds -eq 5 }`); `Start-VBRJob` throws → `Error` with message.

**Acceptance:** `make test-unit`

**Commit:**
```
Move backup job execution into the module

Start-BackupJob returns a structured outcome, checks the session before
sleeping, polls a bounded number of times and reports a timeout instead
of looping on a stale session.
```

---

## T6 — Send alerts over SMTP from policy settings

**Goal:** `Send-BackupAlert` using policy `alerting` (replacing hard-coded addresses); hook into `Start-BackupJob` for warning/failure per `alertOnWarning`/`alertOnFailure`.

**Files**
- create `src/BackupDR/Public/Send-BackupAlert.ps1` (wraps `Send-MailMessage -SmtpServer -Port -From -To -Subject -Body [-BodyAsHtml]`; SMTP errors logged, not rethrown)
- modify `src/BackupDR/Public/Start-BackupJob.ps1` (`-Alerting` param)
- create `tests/unit/Send-BackupAlert.Tests.ps1`
- create `tests/integration/Smtp.Tests.ps1`, `tests/TestHelpers/MailHog.ps1` (`Wait-MailHog` (retry up to ~10 s), `Clear-MailHog`, `Get-MailHogMessages` via `Invoke-RestMethod http://mailhog:8025`)

**Tests to write first:** unit (`Mock -ModuleName BackupDR Send-MailMessage`) — failure alert sent when `alertOnFailure`, suppressed when false; `Warning` result obeys `alertOnWarning`; SMTP exception does not propagate. Integration (tag `Integration`, `BeforeAll { Wait-MailHog }`) — real `Send-BackupAlert` to `mailhog:1025` produces one message with expected subject and recipient.

**Acceptance:** `make test`

**Commit:**
```
Send backup alerts through configurable SMTP

Recipients, sender and relay come from the policy's alerting block.
Adds a MailHog-backed integration test for delivery.
```

---

## T7 — Verification report and HTML daily report

**Goal:** Port `Test-BackupIntegrity` as `Get-BackupJobReport`; render and send the daily report. Verification only covers jobs with `verifyAfterBackup: true`.

**Files**
- create `src/BackupDR/Public/Get-BackupJobReport.ps1` (`-JobName <string[]>`, or `-Policy` which selects the jobs with `verifyAfterBackup: true`; calls `Get-VBRBackupSession -Name <job>` per job)
- create `src/BackupDR/Public/ConvertTo-BackupReportHtml.ps1` (ConvertTo-Html with inline CSS, status column highlighted)
- create `tests/unit/Get-BackupJobReport.Tests.ps1`, `tests/unit/ConvertTo-BackupReportHtml.Tests.ps1`

**Tests to write first (mocks `-ModuleName BackupDR`):** latest session per job selected by `CreationTime` (not first in pipeline order, fixing the old `Select-Object -First 1`); job with no session → `Status='NoSession'`; DataSize/DedupRatio mapped; given the shipped policy, only jobs with `verifyAfterBackup: true` are passed to `Get-BackupJobReport` for verification and a `verifyAfterBackup: false` job produces no verification call (`Assert-MockCalled -ModuleName BackupDR Get-VBRBackupSession -Times 0 -ParameterFilter` for that job); HTML contains one row per job and escapes job names.

**Acceptance:** `make test-unit`

**Commit:**
```
Add backup verification and HTML daily report

Report picks the newest session per job and renders an HTML summary
that can be saved or mailed. Only jobs marked verifyAfterBackup are
verified.
```

---

## T8 — Audit restore points against retention policy

**Goal:** `Test-RetentionCompliance` (SPEC in-scope 7). Its user-facing entrypoint is `scripts/health_check.ps1` (T15).

**Files**
- create `src/BackupDR/Public/Test-RetentionCompliance.ps1`
- modify `sim/state/veeam.sample.json` (restore points with a spread of relative ages; one point on `Production-Servers-Weekly-Full` at `"-92d"` (retentionDays 90 + 2), i.e. over-retained — used by the T15 integration test)
- create `tests/unit/Test-RetentionCompliance.Tests.ps1`

**Tests to write first (mocks `-ModuleName BackupDR`: `Get-VBRBackup`, `Get-VBRRestorePoint`):** all points within `retentionDays` → compliant; point at retentionDays+1 → `ExpiredPoints=1`, non-compliant; `Daily` job with newest point 2 days old → issue "no recent restore point"; missing backup → issue "no backup found"; ages computed from `-Now`, not the wall clock.

**Acceptance:** `make test-unit`

**Commit:**
```
Add retention compliance audit

Flag restore points kept past the policy's retentionDays and jobs with
no recent restore point.
```

---

## T9 — Turn backup_scheduler.ps1 into a thin entrypoint

**Goal:** Script wires policy → due check → start → report → mail, using module functions.

**Files**
- modify `scripts/backup_scheduler.ps1` (params per SPEC §5.4 including `-Now` and `-PollSeconds`; paths relative to `$PSScriptRoot`; exit 1 if any job ended in Error/Failed)
- create `tests/integration/BackupScheduler.Tests.ps1`
- modify `Makefile` (add `demo` target: `BACKUPDR_POLL_SECONDS=1`, seeds sim state into `out/sim`, runs the scheduler `-DryRun` then for real against the simulator)

**Tests to write first (Integration, child `pwsh` process, integration-test pattern from the conventions: `New-SimState -Anchor $now`, `BACKUPDR_SIM_NOW=$now`, `-Now $now`, `-PollSeconds 0`):** `-Now` a Sunday runs the weekly-full job, a Monday (anchor + 1 day, re-seeded) does not; the hourly job's last seeded session is anchor −2 h so it is due, and after the run its new session is stamped at `$now`; `-DryRun` leaves session count unchanged; seeded failed job → exit code 1 and a "Backup FAILED" mail in MailHog; report file written with 4 rows; daily report mail received; whole file completes in under 60 s (`Measure-Command`).

**Acceptance:** `make test`

**Commit:**
```
Rewrite backup scheduler as a thin script over the module

Resolve config relative to the script, accept an injected time and poll
interval, write the daily report and exit non-zero when a job fails.
```

---

## T10 — Add DR plan file and validation

**Goal:** Create the missing `config/dr_plan.json` and `Get-DRPlan`.

**Files**
- create `config/dr_plan.json` (SPEC §5.2)
- create `src/BackupDR/Public/Get-DRPlan.ps1` (step `type` in the 4 known types; per-type required fields; unique step names; `rpoThresholdMinutes` > 0)
- create `tests/unit/Get-DRPlan.Tests.ps1`, `tests/fixtures/dr-plan-invalid.json`

**Tests to write first:** shipped plan loads with 4 steps; unknown step type, `dns_update` missing `failoverIp`, `veeam_replica` missing `target` each rejected with a named error.

**Acceptance:** `make test-unit`

**Commit:**
```
Add DR plan configuration and validation

dr_plan.json describes the ordered failover steps; Get-DRPlan checks
each step has the fields its type requires.
```

---

## T11 — Add AzureSim and DnsSim simulators

**Goal:** Simulated AzureRM ASR and Windows DNS cmdlets for DR steps and replication checks.

**Files**
- create `sim/AzureSim/AzureSim.psm1`, `.psd1` (cmdlets in SPEC §5.5: `Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob` accepts only `-Direction PrimaryToRecovery` and flips the recovery plan `CurrentSite` to recovery; `Start-AzureRmRecoveryServicesAsrPlannedFailoverJob` accepts only `-Direction RecoveryToPrimary` (failback) and flips it back, throwing for `PrimaryToRecovery` as real ASR does for VMware-to-Azure; jobs complete immediately, stamped with the simulator clock; as with real ASR, every ASR cmdlet except `Get-AzureRmRecoveryServicesVault` throws until `Set-AzureRmRecoveryServicesAsrVaultContext -Vault` has been called)
- create `sim/DnsSim/DnsSim.psm1`, `.psd1` (`Get-DnsServerZone -Name` (throws when the zone is absent, like the real cmdlet), `Add-DnsServerResourceRecordA`, `Remove-DnsServerResourceRecord`, `Get-DnsServerResourceRecord`)
- create `sim/state/azure.sample.json`, `sim/state/dns.sample.json` (zone `example.local`, record `app` → `10.10.0.10`)
- modify `src/BackupDR/Private/Import-BackupDRProvider.ps1` (`veeam`: also `Import-Module AzureRM.RecoveryServices` (home of `Get-AzureRmRecoveryServicesVault`), `AzureRM.RecoveryServices.SiteRecovery`, `DnsServer`; `simulator`: load the new sims)
- modify `tests/TestHelpers/VendorStubs.ps1` (AzureRM ASR stubs incl. both failover cmdlets, `Get-DnsServerZone` and the DNS record stubs, `Import-Module` is not stubbed — provider tests mock it with `-ModuleName BackupDR -ParameterFilter { $Name -like 'AzureRM*' -or $Name -eq 'DnsServer' }`)
- modify `tests/TestHelpers/New-SimState.ps1` (copy and anchor azure/dns samples)
- modify `tests/unit/Import-BackupDRProvider.Tests.ps1`
- create `tests/sim/AzureSim.Tests.ps1`, `tests/sim/DnsSim.Tests.ps1`

**Tests to write first:** unplanned failover job `PrimaryToRecovery` returns `State='Succeeded'` and plan site changes to recovery; planned failover `RecoveryToPrimary` returns it to primary; planned failover `PrimaryToRecovery` throws; protected items expose `ReplicationHealth` and `RpoInSeconds`; `Get-DnsServerZone -Name example.local` returns the zone and a missing zone throws; DNS add/remove/get round-trip through JSON; removing a missing record throws like the real cmdlet; provider `veeam` imports the AzureRM ASR and DnsServer modules (mocked `Import-Module`).

**Acceptance:** `make test`

**Commit:**
```
Add Azure Site Recovery and DNS simulators

Stand-ins for the AzureRM ASR and DnsServer cmdlets used by the DR plan,
backed by JSON state files. Failover uses unplanned failover and
failback uses planned failover, as ASR requires for VMware to Azure.
```

---

## T12 — Execute DR plans: failover, failback and test

**Goal:** Port the step switch from `disaster_recovery.ps1` into `Invoke-DRPlan` with real (simulated) calls, stop-on-error, failback in reverse, and test-mode pre-flight.

**Files**
- create `src/BackupDR/Public/Invoke-DRPlan.ps1`
- create `src/BackupDR/Private/Invoke-VeeamReplicaStep.ps1`, `Invoke-AzureFailoverStep.ps1` (failover → `Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -Direction PrimaryToRecovery`; failback → `Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -Direction RecoveryToPrimary`), `Invoke-DnsUpdateStep.ps1`, `Invoke-NotificationStep.ps1` (each takes `-Step -Action`)
- create `tests/unit/Invoke-DRPlan.Tests.ps1`, `tests/unit/DRSteps.Tests.ps1`

**Tests to write first (all mocks `-ModuleName BackupDR`):** failover calls handlers in plan order; failback calls reversible steps in reverse order (`notification` runs last in both); a throwing step marks `Failed`, later steps `NotRun`, `Success=$false`; `continueOnError` step failure does not stop the run; `test` action calls no mutating cmdlet (`Assert-MockCalled -ModuleName BackupDR Start-VBRViReplicaFailover -Times 0 -Exactly`, same for both ASR failover cmdlets and `Add-DnsServerResourceRecordA`) and reports missing replica, missing recovery plan and missing DNS zone (`Get-DnsServerZone` mocked to throw) as pre-flight failures; Azure step on failover calls the unplanned cmdlet with `PrimaryToRecovery` and never the planned one, on failback calls the planned cmdlet with `RecoveryToPrimary`; DNS step swaps primary→failover IP and back; run log JSON written.

**Acceptance:** `make test-unit`

**Commit:**
```
Implement DR plan execution with failback and test modes

Steps run in order and stop on the first failure; failback reverses the
plan and test mode only runs pre-flight checks.
```

---

## T13 — Turn disaster_recovery.ps1 into a thin entrypoint

**Goal:** Script loads plan + policy alerting and calls `Invoke-DRPlan`; exit code reflects success.

**Files**
- modify `scripts/disaster_recovery.ps1` (params per SPEC §5.4 incl. `-Now` and `-Force`; `$PSScriptRoot`-relative defaults; `[CmdletBinding()]` + `$PSCmdlet.ShouldContinue` prompt for failover/failback unless `-Force`)
- create `tests/integration/DisasterRecovery.Tests.ps1`

**Tests to write first (Integration, conventions pattern):** `-Action test` exits 0 and leaves all state files byte-identical; `-Action failover -Force` sets replica state `Failover`, ASR plan site to recovery (via the unplanned failover job recorded in `azure.json`), DNS `app` → `10.20.0.10`, MailHog gets the notification; subsequent `failback -Force` restores DNS to `10.10.0.10` and records a planned `RecoveryToPrimary` job; missing replica in state → exit 1 and run log shows later steps `NotRun`; `-Action test` with the zone removed from `dns.json` → exit 1, pre-flight names the zone.

**Acceptance:** `make test`

**Commit:**
```
Rewrite disaster recovery script over Invoke-DRPlan

Adds working failback, confirmation for destructive actions and a JSON
run log; exit code reports whether the plan succeeded.
```

---

## T14 — Report Azure replication health against RPO threshold

**Goal:** `Get-AzureReplicationStatus` and `scripts/azure_replication.ps1`.

**Files**
- create `src/BackupDR/Public/Get-AzureReplicationStatus.ps1`
- create `scripts/azure_replication.ps1` (`-PlanPath`, `-Now`)
- create `tests/unit/Get-AzureReplicationStatus.Tests.ps1`, `tests/integration/AzureReplication.Tests.ps1`

**Tests to write first:** all Normal + RPO under threshold → OK/0; one item RPO over `rpoThresholdMinutes` → WARNING/1; any `ReplicationHealth='Critical'` → CRITICAL/2; no protected items → CRITICAL/2. Integration (conventions pattern): script prints one line per item and exits with the expected code for seeded states.

**Acceptance:** `make test`

**Commit:**
```
Add Azure replication status check

Lists Site Recovery protected items and grades them against the plan's
RPO threshold with Nagios-style exit codes.
```

---

## T15 — Add backup server health check with retention audit

**Goal:** `Get-BackupServerHealth` and `scripts/health_check.ps1`, the user-facing entrypoint for the retention audit (SPEC in-scope 7 and 8).

**Files**
- create `src/BackupDR/Public/Get-BackupServerHealth.ps1` (`-Now`; repository free % vs `health.repositoryMinFreePercent`; last result Failed → CRITICAL; Warning or overdue by schedule → WARNING; calls `Test-RetentionCompliance -Now` and adds one `Retention` check per job, non-compliant → WARNING with its issues)
- create `scripts/health_check.ps1` (`-ConfigPath`, `-Now`; prints one line per check plus a summary line `STATE - n checks, m warnings, k critical`, retention issues included; exits with `ExitCode`)
- create `tests/unit/Get-BackupServerHealth.Tests.ps1`, `tests/integration/HealthCheck.Tests.ps1`

**Tests to write first:** unit (mocks `-ModuleName BackupDR`, `-Now` fixed) — healthy fixture → OK/0; repository at 10% free with 15% threshold → WARNING; a Failed last session → CRITICAL/2 (worst state wins); daily job last run 3 days before `-Now` → WARNING "overdue"; `Test-RetentionCompliance` mocked to return one non-compliant job → WARNING and the issue text in `Checks`. Integration (conventions pattern) — seeded state with the over-retained restore point from T8 → exit 1 and the summary lists `Production-Servers-Weekly-Full` retention; same state with that point removed → exit 0; running the same seeded state with `-Now` = anchor gives the same result regardless of the real date.

**Acceptance:** `make test`

**Commit:**
```
Add backup server health check script

Checks repository free space, last job results and retention compliance
and exits 0/1/2 so it can be run from Task Scheduler or a monitoring
agent.
```

---

## T16 — Write the operations runbook

**Goal:** `docs/runbook.md` covering every script, exit codes, report reading, DR procedure (pre-checks, `test`, failover, verification, failback), and the simulator setup; plus a doc test so referenced files stay real.

**Files**
- create `docs/runbook.md`
- create `tests/unit/Docs.Tests.ps1`

**Tests to write first:** every `scripts/*.ps1` and `config/*.json` path mentioned in `docs/runbook.md` exists; every script in `scripts/` is mentioned in the runbook.

**Acceptance:** `make test-unit`

**Commit:**
```
Add backup and DR operations runbook

Documents running each script, interpreting exit codes and reports, and
the manual checks around a failover and failback.
```

---

## T17 — Regenerate README from the template

**Goal:** Honest README per `tools/readme_template.md`: description, Status (implemented features each mapped to code + tests; limitations incl. SPEC Out-of-scope; explicit statement that Veeam, vSphere, Azure Site Recovery and Windows DNS are simulated by VeeamSim/AzureSim/DnsSim and Pester mocks and never run against real systems), Built with (PowerShell Core 6.1.2 / Windows PowerShell 5.1 syntax, Pester 4.6.0, PSScriptAnalyzer 1.17.1, MailHog v1.0.0), Running it (`docker compose up -d mailhog` + `make demo`), Tests, Layout generated from the repository file list. No badges, employer, role, dates or metrics.

**Files**
- modify `README.md`
- modify `tests/unit/Docs.Tests.ps1`

**Tests to write first:** extend `Docs.Tests.ps1`:
- README: every path in Layout exists.
- Banned strings, case-insensitive `-Match`: `Zambaiti|Career Portfolio|Efrem|img\.shields\.io|Status-Complete|Developed during|RPO <|RTO <|100% Backup`.
- Banned labels, case-sensitive `-CMatch`: `\*\*Organization\*\*|Organization:|\*\*Role\*\*|Role:` (so a lower-case mention of the policy's `organization` field is allowed).
- Layout block equals the file list from `git ls-files --cached --others --exclude-standard` rendered as a tree (generated by a small helper in the test, compared literally), so new files count before they are staged.

**Acceptance:** `git add -A && make test && git ls-files | wc -l`

**Commit:**
```
Rewrite README with honest status and generated layout

Describe what is implemented, what is simulated and what is out of
scope; layout reflects the tracked files.
```

---

## T18 — Security and hygiene hardening

**Goal:** Review the whole repository for unsafe lookups, fail-open results, exposed services and
hygiene problems; fix each with a failing test first.

**Found and changed**
- *Ambiguous vendor lookups (blocker).* `Start-BackupJob`, `Invoke-VeeamReplicaStep`,
  `Invoke-AzureFailoverStep`, `Test-RetentionCompliance` and `Get-AzureReplicationStatus` took
  `Select-Object -First 1` of `Get-VBRJob` / `Get-VBRReplica` / `Get-VBRBackup` /
  `Get-AzureRmRecoveryServicesVault` / `Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name`, which
  treat the name as a wildcard. A wildcard or shared name could start, fail over or audit an
  arbitrary object. New private `Resolve-ExactVendorObject` rejects wildcard names before the
  lookup, filters to `Name` equal to the requested name (case-insensitive) and requires exactly
  one match. The replica step also refuses restore points of more than one VM and two newest
  points with the same time. `Get-BackupPolicy` and `Get-DRPlan` reject wildcard characters in
  job names, replica targets, recovery plans and the ASR vault name.
  Tests: `tests/unit/Resolve-ExactVendorObject.Tests.ps1`; new cases in `Start-BackupJob`,
  `DRSteps`, `Test-RetentionCompliance`, `Get-BackupPolicy` and `Get-DRPlan` tests.
- *MailHog published on every interface (major).* `docker-compose.yml` now publishes
  `127.0.0.1:21025:8025`. `make test` / `make test-unit` render `$(COMPOSE) config` to
  `out/compose.config.yml` (new `compose-config` target) and `tests/unit/Container.Tests.ps1`
  fails if any published port in it or in `docker-compose.yml` lacks the 127.0.0.1 prefix. The
  same test file fails if a Dockerfile or apt file disables signature checks
  (`--allow-unauthenticated`, `--force-yes`, `[trusted=yes]`, `AllowUnauthenticated`,
  `--no-check-gpg`, insecure repositories) or uses `http://`.
- *Previous session reported as this run's result (major).* After `Start-VBRJob -RunAsync`,
  `FindLastSession()` can still return the previous run, and only `Working` was treated as
  running (`Starting`, `Postprocessing` ... ended the wait with result `None`, which was neither
  alerted nor counted as a failure). `Start-BackupJob` now notes the previous session, waits for
  a different session in state `Stopped`, and reports `Unknown` when none appears or its result
  is not Success/Warning/Failed. `backup_scheduler.ps1` counts `Unknown` as a failure (exit 1).
  Tests: new cases in `Start-BackupJob.Tests.ps1` and `tests/integration/BackupScheduler.Tests.ps1`.
- *DNS read errors treated as "no record" (major).* `Invoke-DnsUpdateStep` swallowed every
  `Get-DnsServerResourceRecord` error, so an access-denied read would add the failover address
  next to the primary one. Only `ObjectNotFound` (what the real cmdlet reports for a name without
  records) now counts as empty; anything else fails the step before it changes the record.
  DnsSim raises `ObjectNotFound` like the real cmdlet. Tests: `DRSteps.Tests.ps1`,
  `tests/sim/DnsSim.Tests.ps1`.
- *Undelivered DR notification reported as Succeeded (minor).* `Send-BackupAlert -PassThru`
  returns whether the relay accepted the mail; `Invoke-NotificationStep` fails when it did not.
- *Replica failover with no session or result `None` passed (minor).* `Invoke-VeeamReplicaStep`
  now requires a Success or Warning session result.
- *DNS addresses not validated (minor).* `Get-DRPlan` requires dotted IPv4 `failoverIp` /
  `primaryIp`.
- *Audited, no change needed:* the toolkit handles no credentials (SMTP is unauthenticated, no
  Azure login), so no secret reaches logs, exceptions or reports; the HTML report encodes every
  value; no dated comments, fabricated claims, author tags or debug leftovers were
  found.

**Acceptance:** `make test`

**Commit:**
```
Harden vendor lookups, job results and exposed ports
```

# Enterprise Backup and Disaster Recovery

Enterprise backup and disaster recovery solution using Veeam for VMware vSphere environments with Azure cloud replication and automated failover procedures.

Personal project, built to explore scripting Veeam backup scheduling and failover in PowerShell. It is not production software — see **Status** below for exactly what is and isn't implemented.

## Status

**Implemented**

- Backup scheduler script driven by `config/backup_policy.json`
- Disaster-recovery failover script

**Not implemented / known limitations**

- No Azure replication or health-check scripts (the earlier README claimed these; they did not exist)
- Requires Veeam PowerShell snap-ins; never run against a real Veeam installation
- No Pester tests

## Layout

```
config/
  backup_policy.json
scripts/
  backup_scheduler.ps1
  disaster_recovery.ps1
```


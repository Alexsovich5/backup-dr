COMPOSE ?= docker compose
export COMPOSE_PROJECT_NAME ?= backup-dr

PESTER = pwsh -NoProfile -File build/Invoke-Tests.ps1

.PHONY: build test test-unit lint demo shell clean

build:
	$(COMPOSE) build

test:
	$(COMPOSE) run --rm app $(PESTER)

test-unit:
	$(COMPOSE) run --rm --no-deps app $(PESTER) -Tag Unit

lint:
	$(COMPOSE) run --rm --no-deps app $(PESTER) -LintOnly

# Seeds simulator state in out/sim (anchored at the current time), then runs the
# scheduler as a dry run and for real; the report lands in out/report.html and mail in MailHog.
DEMO_SCRIPT = . ./tests/TestHelpers/New-SimState.ps1; \
	New-SimState -Anchor (Get-Date) -Path out/sim | Out-Null; \
	./scripts/backup_scheduler.ps1 -DryRun; \
	./scripts/backup_scheduler.ps1; \
	exit $$LASTEXITCODE

demo:
	$(COMPOSE) run --rm -e BACKUPDR_POLL_SECONDS=1 app pwsh -NoProfile -Command "$(DEMO_SCRIPT)"

shell:
	$(COMPOSE) run --rm app pwsh

clean:
	$(COMPOSE) down --remove-orphans
	rm -rf out logs

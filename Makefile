COMPOSE ?= docker compose
export COMPOSE_PROJECT_NAME ?= backup-dr

PESTER = pwsh -NoProfile -File build/Invoke-Tests.ps1

.PHONY: build test test-unit lint demo shell clean compose-config

build:
	$(COMPOSE) build

# Renders the compose file as Docker sees it; tests/unit/Container.Tests.ps1 checks that every
# published port in it is bound to 127.0.0.1.
compose-config:
	@mkdir -p out
	$(COMPOSE) config > out/compose.config.yml

test: compose-config
	$(COMPOSE) run --rm app $(PESTER)

test-unit: compose-config
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

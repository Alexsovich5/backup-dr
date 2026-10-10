COMPOSE ?= docker compose
export COMPOSE_PROJECT_NAME ?= backup-dr

PESTER = pwsh -NoProfile -File build/Invoke-Tests.ps1

.PHONY: build test test-unit lint shell clean

build:
	$(COMPOSE) build

test:
	$(COMPOSE) run --rm app $(PESTER)

test-unit:
	$(COMPOSE) run --rm --no-deps app $(PESTER) -Tag Unit

lint:
	$(COMPOSE) run --rm --no-deps app $(PESTER) -LintOnly

shell:
	$(COMPOSE) run --rm app pwsh

clean:
	$(COMPOSE) down --remove-orphans
	rm -rf out logs

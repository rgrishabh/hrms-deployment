# Commands for one installation. They assume only docker compose, make, sh and openssl, so they work
# on a laptop as well as on a Linux host.
.DEFAULT_GOAL := help
.PHONY: help init up down logs ps config migrate migrate-status migrate-down rotate-keys seed backup restore test

help: ## Show this list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/^([a-z-]+):.*## /  \1\t/'

init: ## Create .env (with secrets) and .brandenv from the examples, keeping existing files
	@[ -f .env ] || cp .env.example .env
	@[ -f .brandenv ] || cp .brandenv.example .brandenv
	@bin/init-env

up: ## Start everything in order: postgres, provision, migrate, bootstrap, then the app
	@bin/stack-up

down: ## Stop the stack. Volumes are kept
	@bin/dc down

logs: ## Follow logs, or one service with S=backend
	@bin/dc logs -f --tail 100 $(S)

ps: ## Show service state and health
	@bin/dc ps

config: ## Validate the Compose file against .env, versions.env and .brandenv
	@bin/check-brandenv
	@bin/dc config --quiet && echo "compose config ok"

migrate: ## Apply pending migrations without restarting the app
	@bin/dc run --rm --no-deps migrate

migrate-status: ## Applied, pending and unknown migrations. Exit 2 when pending, 3 when the database is ahead
	@bin/dc run --rm --no-deps -T migrate migrate-status

migrate-down: ## Undo migrations with the image in versions.env, BEFORE moving to an older one: make migrate-down ARGS="--steps 1"
	@[ -n "$(ARGS)" ] || { echo 'usage: make migrate-down ARGS="--steps N" (or --to NAME, or --all)' >&2; exit 2; }
	@bin/dc run --rm --no-deps -T migrate migrate-down $(ARGS)

rotate-keys: ## Re-encrypt with the active key. Needs the old key in DATA_ENCRYPTION_KEY_PREVIOUS
	@bin/dc run --rm --no-deps -T migrate rotate-keys

seed: ## Load synthetic demo data. Dev and demo only; the backend refuses if real employees exist
	@bin/demo-data

backup: ## Take a backup now. Exits non-zero if it fails
	@bin/backup

restore: ## Replace this installation's data: make restore SET=path/to/hrms-<ts> CONFIRM=hrms-dev
	@[ -n "$(SET)" ] || { echo "usage: make restore SET=path/to/hrms-<ts> CONFIRM=hrms-dev" >&2; exit 2; }
	@bin/restore "$(SET)" --confirm "$(CONFIRM)"

test: ## Run the stack's offline tests. They need no Docker daemon
	@tests/backup-loop.test.sh bin/backup-loop.sh
	@tests/check-brandenv.test.sh
	@tests/deploy-order.test.sh

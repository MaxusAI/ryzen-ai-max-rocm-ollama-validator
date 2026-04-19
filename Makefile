.DEFAULT_GOAL := help

COMPOSE        ?= docker compose
SERVICE        ?= ollama
MODEL          ?= gemma4:31b-it-q4_K_M
CTX            ?= 262144
HOST_PORT      ?= 11434

.PHONY: help submodules build up down restart logs shell gpu-check ps test-fa rocm-smi clean-image \
        validate validate-full validate-logged mes-check install-mes-firmware \
        stress-test stress-test-quick run-history

help: ## Show this help.
	@awk 'BEGIN { FS = ":.*?## "; printf "Targets:\n" } \
		/^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)

submodules: ## Init/update the external/ollama git submodule (idempotent).
	git submodule update --init --recursive

build: submodules ## Build the docker image (multi-stage; ROCm 7.2.2 + Go 1.24.1).
	$(COMPOSE) build

up: ## Start the ollama-rocm container in the background.
	$(COMPOSE) up --detach
	@echo
	@echo "ollama listening on http://localhost:$(HOST_PORT)"
	@echo "tail logs with: make logs"

down: ## Stop and remove the container.
	$(COMPOSE) down

restart: ## Restart the container without rebuilding.
	$(COMPOSE) restart $(SERVICE)

logs: ## Tail the ollama server logs (ctrl-c to stop tailing).
	$(COMPOSE) logs --follow --tail 200 $(SERVICE)

shell: ## Open a bash shell inside the running container.
	$(COMPOSE) exec $(SERVICE) bash

gpu-check: ## Confirm rocminfo reports gfx1151 inside the container.
	@$(COMPOSE) exec $(SERVICE) bash -c \
		'echo "--- rocminfo (gfx lines) ---"; \
		 rocminfo | grep --extended-regexp "Marketing Name|Name:[[:space:]]+gfx|Compute Unit"; \
		 echo "--- rocm-smi ---"; \
		 rocm-smi --showid --showproductname --showmeminfo vram --showuse'

ps: ## Show ollama loaded-models table.
	$(COMPOSE) exec $(SERVICE) ollama ps

rocm-smi: ## Run rocm-smi inside the container.
	$(COMPOSE) exec $(SERVICE) rocm-smi

test-fa: ## Fire one short generation at $(CTX) ctx, then classify the FA branch.
	@echo "--- POST /api/generate model=$(MODEL) num_ctx=$(CTX) num_predict=4 ---"
	@curl --silent --show-error --fail \
		--request POST \
		--header 'content-type: application/json' \
		--data '{"model":"$(MODEL)","prompt":"hello","stream":false,"options":{"num_ctx":$(CTX),"num_predict":4}}' \
		http://localhost:$(HOST_PORT)/api/generate \
		| sed 's/^/  /' || echo "  (request failed; check 'make logs')"
	@echo
	@echo "--- FA classification (last 300 server log lines) ---"
	@$(COMPOSE) logs --tail 300 $(SERVICE) 2>&1 \
		| grep --extended-regexp \
			--ignore-case \
			'flash attention|enabling flash|kv cache type|not supported by gpu' \
		|| echo "  (no flash-attention or kv-cache lines found)"
	@echo
	@echo "Branch (a) FA works:        expect 'enabling flash attention' + 'kv cache type: q8_0'"
	@echo "Branch (b) FA disabled:     expect 'flash attention enabled but not supported' + 'kv cache type: f16'"
	@echo "Branch (c) runner crashed:  no FA/kv lines AND 'docker compose ps' shows unhealthy"

clean-image: ## Remove the built image (forces a full rebuild next time).
	docker image rm amd-rocm-ollama:7.2.2 || true

validate: ## Run the 9-layer validation ladder, skipping the slow Layer 8.
	./scripts/validate.sh --skip-long-ctx

validate-full: ## Run the full 9-layer validation including ~200K-token Layer 8 (slow).
	./scripts/validate.sh

mes-check: ## Quick check: is the running MES firmware safe (NOT the 0x83 regression)?
	./scripts/install-mes-firmware.sh --check

install-mes-firmware: ## Install the pre-regression MES firmware override (requires sudo, then reboot).
	sudo ./scripts/install-mes-firmware.sh

validate-logged: ## Run the full validator and append a JSONL record to logs/run-history.jsonl.
	./scripts/log-run.sh -- ./scripts/validate.sh

stress-test: ## VRAM/GTT/MES stress test: largest model, 4 parallel reqs at full ctx, logged.
	./scripts/log-run.sh -- ./scripts/stress-test.sh

stress-test-quick: ## Quick stress test: smaller model + smaller ctx (~5min, safe to run often).
	./scripts/log-run.sh -- ./scripts/stress-test.sh \
		--model $(MODEL) --num-ctx 32768 --concurrency 2 --requests 4

run-history: ## Show the last 10 entries from the run-history log (jq required for pretty output).
	@./scripts/log-run.sh show --last 10

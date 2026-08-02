.PHONY: test check

test: ## Run bats tests
	@if [ -d tests ] && ls tests/*.bats >/dev/null 2>&1; then \
		bats tests/; \
	else \
		echo "no tests yet"; \
	fi

test-integration: ## Prove the egress policy in a throwaway container (needs docker)
	bash tests/integration/egress_container.sh

check: lint test ## Lint and test

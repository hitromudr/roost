.PHONY: test check

test: ## Run bats tests
	@if [ -d tests ] && ls tests/*.bats >/dev/null 2>&1; then \
		bats tests/; \
	else \
		echo "no tests yet"; \
	fi

test-integration: ## Apply the roles in a throwaway container and check them (needs docker)
	bash tests/integration/egress_container.sh

check: lint test ## Lint and test

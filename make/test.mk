.PHONY: test check

test: ## Run bats tests
	@if [ -d tests ] && ls tests/*.bats >/dev/null 2>&1; then \
		bats tests/; \
	else \
		echo "no tests yet"; \
	fi

check: lint test ## Lint and test

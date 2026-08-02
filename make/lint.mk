.PHONY: lint lint-sh lint-ansible

# Shell sources: the CLI wrapper plus anything under scripts/ and the
# templates roles render. Globs are guarded so an empty match is not an error
# while the tree is still filling up.
# Role scripts have no extension on purpose — they are commands, not
# libraries — so they are listed by location as well as by suffix.
SH_FILES = $(shell find . -name '*.sh' -not -path './.git/*' 2>/dev/null) \
           $(shell find ansible -path '*/files/*' -type f 2>/dev/null) \
           $(wildcard roost)

lint: lint-sh lint-ansible ## Run all linters

lint-sh: ## shellcheck over shell sources
	@if [ -n "$(strip $(SH_FILES))" ]; then \
		shellcheck $(SH_FILES); \
	else \
		echo "no shell files yet"; \
	fi

lint-ansible: ## ansible-lint over the roles
	@if [ -d ansible ]; then \
		ansible-lint ansible; \
	else \
		echo "no ansible tree yet"; \
	fi

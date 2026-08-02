.PHONY: lint lint-sh lint-ansible

# Shell sources: the CLI wrapper plus anything under scripts/ and the
# templates roles render. Globs are guarded so an empty match is not an error
# while the tree is still filling up.
SH_FILES = $(shell find . -name '*.sh' -not -path './.git/*' 2>/dev/null) \
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

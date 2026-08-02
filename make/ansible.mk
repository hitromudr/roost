.PHONY: deps stand gate stand-check gate-check

INVENTORY ?= ansible/inventory

# Installed into the user path explicitly: distributions ship collections in
# a system directory that tools installed separately (ansible-lint from pipx,
# for one) do not read, and then the modules "do not exist" during linting.
# --force is needed, not paranoia: when a distribution ships these collections
# inside the ansible package, galaxy sees them, reports "nothing to do", and
# leaves the user path empty — where separately installed tools look.
deps: ## Install the ansible collections the roles need
	ansible-galaxy collection install -r ansible/requirements.yml --force \
		-p "$${ANSIBLE_COLLECTIONS_PATH:-$$HOME/.ansible/collections}"

stand-check: ## Dry-run the stand playbook
	ansible-playbook -i $(INVENTORY) ansible/playbooks/stand.yml --check --diff

stand: ## Configure the stand
	ansible-playbook -i $(INVENTORY) ansible/playbooks/stand.yml

gate-check: ## Dry-run the gate playbook
	ansible-playbook -i $(INVENTORY) ansible/playbooks/gate.yml --check --diff

gate: ## Configure the gate
	ansible-playbook -i $(INVENTORY) ansible/playbooks/gate.yml

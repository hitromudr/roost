.PHONY: stand stand-check projects projects-check

INVENTORY ?= ansible/inventory

# No `deps` target: the roles use ansible-builtin modules only. That is a
# constraint worth keeping — a stand is often a machine running whatever
# ansible its distribution ships, and every collection is one more thing to
# install before anything works.

stand-check: ## Dry-run the stand playbook
	ansible-playbook -i $(INVENTORY) ansible/playbooks/stand.yml --check --diff

stand: ## Configure the stand
	ansible-playbook -i $(INVENTORY) ansible/playbooks/stand.yml

projects-check: ## Dry-run the projects playbook
	ansible-playbook -i $(INVENTORY) ansible/playbooks/projects.yml --check --diff

projects: ## Check out the projects listed in projects.conf
	ansible-playbook -i $(INVENTORY) ansible/playbooks/projects.yml

TF := terraform -chdir=terraform

.PHONY: init plan apply destroy validate rotate-plan rotate-apply seats ssh fmt check

init:
	$(TF) init

plan:
	$(TF) plan

apply:
	$(TF) apply

# The data volume has prevent_destroy; to really tear down, remove that lifecycle
# block first (and snapshot the volume if you care about the worlds).
destroy:
	$(TF) destroy

validate:
	scripts/validate.sh

rotate-plan:
	python3 access/rotate.py plan

rotate-apply:
	python3 access/rotate.py apply

seats:
	python3 access/rotate.py seats

ssh:
	tailscale ssh ubuntu@tt-host

fmt:
	$(TF) fmt -recursive

# Offline checks that need no cloud credentials.
check:
	bash -n host/bootstrap.sh host/tabletop.sh scripts/validate.sh
	python3 -c "import json; json.load(open('host/serve.json'))"
	python3 -m py_compile access/rotate.py
	cd host && docker compose config --quiet 2>/dev/null || echo "(compose needs a .env to render; see README)"

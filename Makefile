.DEFAULT_GOAL := help

VERBOSE_ORIGINS := "command line" "environment"
ifdef V
  ifeq ($(filter $(VERBOSE_ORIGINS),$(origin V)),)
    BUILD_VERBOSE := $(V)
  endif
endif

ifndef BUILD_VERBOSE
  BUILD_VERBOSE := 0
endif

ifeq ($(BUILD_VERBOSE),1)
  Q :=
else
  Q := @
endif

CURDIR := $(shell pwd)
BIN_DIR ?= $(CURDIR)/bin
DIRS := $(BIN_DIR)
PATH := $(BIN_DIR):$(PATH)

SHELL := env PATH=$(PATH) /bin/bash

$(DIRS):
	$(Q)mkdir -p $@

define download-tool
%/$(strip $(notdir $(1))):
	@echo 'Installing $(strip $(notdir $(1)))'
	$$(Q)curl -sLo $$@ $(strip $(2))
	$$(Q)chmod +x $$@
	@echo "'$$(notdir $$@)' installed"
endef

define download-zip-tool
%/$(strip $(notdir $(1))):
	@echo 'Installing $(strip $(notdir $(1)))'
	$$(eval tmp_dir := $$(shell mktemp -d))
	$$(eval file := $$(tmp_dir)/$$(notdir $(1)).zip)
	$(Q)curl -sLo $$(file) $(strip $(2)) && unzip -qq -d $$(dir $$@) $$(file) $(1)
ifneq ($(strip $(findstring /,$(1))),)
	$(Q)mv $$(dir $$@)$$(strip $(1)) $$(dir $$@)$$(notdir $(1))
	$(Q)rm -r $$(dir $$@)$$(dir $(1))
endif
	$(Q)chmod +x $$@
	$(Q)rm -fr $$(tmp_dir)
	@echo "'$$(notdir $$@)' installed"
endef

define download-gzip-tool
%/$(strip $(notdir $(1))):
	@echo 'Installing $(strip $(notdir $(1)))'
	$(Q)curl -fsSL $(strip $(2)) | tar -C $$(dir $$@) -xz $(1)
ifneq ($(strip $(findstring /,$(1))),)
	$(Q)mv $$(dir $$@)$$(strip $(1)) $$(dir $$@)$$(notdir $(1))
	$(Q)rm -r $$(dir $$@)$$(dir $(1))
endif
	$(Q)chmod +x $$@
	@echo "'$$(notdir $$@)' installed"
endef

# ----------
OS := $(shell uname | tr A-Z a-z)

TOOLS += kubectl
$(eval $(call download-tool, \
	kubectl, \
	https://storage.googleapis.com/kubernetes-release/release/v1.17.0/bin/$(OS)/amd64/kubectl \
))

TOOLS += kind
$(eval $(call download-tool, \
	kind, \
	https://github.com/kubernetes-sigs/kind/releases/download/v0.6.1/kind-$(OS)-amd64 \
))

TOOLS += helm
$(eval $(call download-gzip-tool, \
	$(OS)-amd64/helm, \
	https://get.helm.sh/helm-v3.0.2-$(OS)-amd64.tar.gz \
))

TOOLS += helmfile
$(eval $(call download-tool, \
	helmfile, \
	https://github.com/roboll/helmfile/releases/download/v0.98.1/helmfile_$(OS)_amd64 \
))

TOOLS += vault
$(eval $(call download-zip-tool, \
	vault, \
	https://releases.hashicorp.com/vault/1.3.1/vault_1.3.1_$(OS)_amd64.zip \
))

# ---------- Kind

KIND_CONFIG := $(CURDIR)/kind-cluster.yaml
KIND_KUBECONFIG := .kubeconfig
export KUBECONFIG := $(KIND_KUBECONFIG)

cluster: $(KIND_KUBECONFIG)

$(KIND_KUBECONFIG): $(KIND_CONFIG) kind
ifeq ($(strip $(shell kind get clusters)),)
	$(Q)kind create cluster --kubeconfig $@ --config $<
else
	$(Q)kind get kubeconfig > $@
endif

# ---------- Helm

XDG_DATA_HOME := $(CURDIR)/.helm
HELM_PLUGIN_DIR := $(XDG_DATA_HOME)/helm/plugins
export XDG_DATA_HOME := $(XDG_DATA_HOME)

$(HELM_PLUGIN_DIR):
	$(Q)mkdir -p $@

HELM_PLUGINS := \
	helm-diff::https://github.com/databus23/helm-diff::master

helm: $(KIND_KUBECONFIG)

define plugin-deps
$(eval info := $(subst ::, ,$(1)))
$(eval PLUGIN_NAME := $(word 1,$(info)))
.PHONY: $(PLUGIN_NAME)
helmfile: $(PLUGIN_NAME)
$(PLUGIN_NAME): $(HELM_PLUGIN_DIR) $(HELM_PLUGIN_DIR)/$(PLUGIN_NAME)
$(HELM_PLUGIN_DIR)/$(PLUGIN_NAME):
	$(Q)helm plugin install $(word 2,$(info)) --version $(word 3,$(info))
endef

$(foreach p,$(HELM_PLUGINS),$(eval $(call plugin-deps,$(p))))

# ---------- Helmfile

helmfile: helm

.PHONY: install-services
install-services: helmfile $(KIND_KUBECONFIG)
	$(Q)helmfile apply

# ---------- Vault

SA_NAME := vault
APP_ROLE := db-app
APP_POLICY := db-app-read

.PHONY: setup-vault
setup-vault: vault install-services
	$(Q)status=0; while [[ "$$status" != "Running" ]]; do \
		sleep 3; \
		status=`kubectl get pods -l app.kubernetes.io/name=vault -o 'jsonpath={.items[0].status.phase}'`; \
	done
ifeq ($(strip $(shell kubectl exec vault-0 -- vault auth list 2>/dev/null | grep kubernetes)),)
	$(Q)kubectl exec vault-0 -- vault auth enable kubernetes
endif
	$(Q)kubectl exec vault-0 -- vault write auth/kubernetes/config \
			token_reviewer_jwt="@/var/run/secrets/kubernetes.io/serviceaccount/token" \
  			kubernetes_host="https://kubernetes" \
  			kubernetes_ca_cert="@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
ifeq ($(strip $(shell kubectl exec vault-0 -- vault secrets list 2>/dev/null | grep database/creds)),)
	$(Q)kubectl exec vault-0 -- vault secrets enable -path=database/creds/ kv
endif
	$(Q)kubectl exec vault-0 -- vault kv put database/creds/db-app username=$(shell openssl rand -hex 8) password=$(shell openssl rand -hex 32)
	$(Q)kubectl cp vault/$(APP_POLICY).hcl default/vault-0:/tmp/policy.hcl
	$(Q)kubectl exec vault-0 -- vault policy write $(APP_POLICY) /tmp/policy.hcl
	$(Q)kubectl exec vault-0 -- vault write auth/kubernetes/role/$(APP_ROLE) \
    		bound_service_account_names=$(SA_NAME) \
    		bound_service_account_namespaces=default \
    		policies=$(APP_POLICY)

# ----------

.PHONY: setup
setup: setup-vault

.PHONY: deploy
deploy: kubectl setup
	$(Q)kubectl apply -f deploy/db-app.yaml

.PHONY: demo
demo: deploy
	$(Q)status=0; while [[ "$$status" != "Running" ]]; do \
		sleep 3; \
		status=`kubectl get pods -l app=db-app -o 'jsonpath={.items[0].status.phase}'`; \
	done
	@echo
	@echo "Secret: 👇"
	$(Q)kubectl exec $(shell kubectl get po -l app=db-app -o jsonpath="{.items[0].metadata.name}") -c app -- cat /vault/secrets/db-creds

# ----------

.PHONY: clean
clean:
	$(Q)rm -fr $(BIN_DIR)/* $(KIND_KUBECONFIG)

.PHONY: destroy-cluster
destroy-cluster:
	$(Q)kind delete cluster

.PHONY: destroy
destroy: destroy-cluster clean

.PHONY: help
help:
	@echo  'Main targets:'
	@echo  '  setup                       - Setup vault'
	@echo  '  deploy                      - Deploy the example application'
	@echo  '  demo                        - Dump the secret injected by vault agent'
	@echo  ''
	@echo  'Cleaning targets:'
	@echo  '  clean                       - Remove required tools and the kubeconfig'
	@echo  '  destroy-cluster             - Destroy the cluster only'
	@echo  '  destroy                     - Destroy the cluster and clean up'

.PHONY: FORCE
FORCE:

define tool-deps
$(1): $(BIN_DIR) $(BIN_DIR)/$(1)
endef

.PHONY: $(TOOLS)
$(foreach tool,$(TOOLS),$(eval $(call tool-deps,$(tool))))

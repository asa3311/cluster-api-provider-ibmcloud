# Copyright 2021 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

.DEFAULT_GOAL:=help

ROOT_DIR_RELATIVE := .

include $(ROOT_DIR_RELATIVE)/common.mk

# Image URL to use all building/pushing image targets
IMG ?= controller:latest
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:crdVersions=v1"

# Directories.
REPO_ROOT := $(shell git rev-parse --show-toplevel)
ARTIFACTS ?= $(REPO_ROOT)/_artifacts
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/bin
GO_INSTALL = ./scripts/go_install.sh
E2E_CONF_FILE_ENVSUBST := $(REPO_ROOT)/test/e2e/config/ibmcloud-e2e-envsubst.yaml
E2E_TEMPLATES := $(REPO_ROOT)/test/e2e/data/templates

GO_APIDIFF := $(TOOLS_BIN_DIR)/go-apidiff
GOLANGCI_LINT := $(TOOLS_BIN_DIR)/golangci-lint
KUSTOMIZE := $(TOOLS_BIN_DIR)/kustomize
GOJQ := $(TOOLS_BIN_DIR)/gojq
CONVERSION_GEN := $(TOOLS_BIN_DIR)/conversion-gen
GINKGO := $(TOOLS_BIN_DIR)/ginkgo
GOTESTSUM := $(TOOLS_BIN_DIR)/gotestsum
ENVSUBST := $(TOOLS_BIN_DIR)/envsubst
MOCKGEN := $(TOOLS_BIN_DIR)/mockgen
CONTROLLER_GEN := $(TOOLS_BIN_DIR)/controller-gen
CONVERSION_VERIFIER := $(TOOLS_BIN_DIR)/conversion-verifier
SETUP_ENVTEST := $(TOOLS_BIN_DIR)/setup-envtest

STAGING_REGISTRY ?= gcr.io/k8s-staging-capi-ibmcloud
STAGING_BUCKET ?= artifacts.k8s-staging-capi-ibmcloud.appspot.com
BUCKET ?= $(STAGING_BUCKET)
PROD_REGISTRY := k8s.gcr.io/capi-ibmcloud
REGISTRY ?= $(STAGING_REGISTRY)
RELEASE_TAG ?= $(shell git describe --abbrev=0 2>/dev/null)
PULL_BASE_REF ?= $(RELEASE_TAG) # PULL_BASE_REF will be provided by Prow
RELEASE_ALIAS_TAG ?= $(PULL_BASE_REF)
RELEASE_DIR := out

TAG ?= dev
ARCH ?= amd64
ALL_ARCH ?= amd64 ppc64le arm64
PULL_POLICY ?= Always

KUBEBUILDER_ENVTEST_KUBERNETES_VERSION ?= 1.24.1

# main controller
CORE_IMAGE_NAME ?= cluster-api-ibmcloud-controller
CORE_CONTROLLER_IMG ?= $(REGISTRY)/$(CORE_IMAGE_NAME)
CORE_CONTROLLER_ORIGINAL_IMG := gcr.io/k8s-staging-capi-ibmcloud/cluster-api-ibmcloud-controller
CORE_CONTROLLER_NAME := controller-manager
CORE_MANIFEST_FILE := infrastructure-components
CORE_CONFIG_DIR := config/default
CORE_NAMESPACE := capi-ibmcloud-system

PATH := $(abspath $(TOOLS_BIN_DIR)):$(PATH)
# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Set --output-base for conversion-gen if we are not within GOPATH
ifneq ($(abspath $(ROOT_DIR_RELATIVE)),$(shell go env GOPATH)/src/sigs.k8s.io/cluster-api-provider-ibmcloud)
	CONVERSION_GEN_OUTPUT_BASE := --output-base=$(ROOT_DIR_RELATIVE)
else
	export GOPATH := $(shell go env GOPATH)
endif

all: manager

## --------------------------------------
## Binaries
## --------------------------------------

##@ build:

# Build manager binary
manager: generate fmt vet ## Build the manager binary into the ./bin folder
	go build -o bin/manager main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet
	go run ./main.go

# Install CRDs into a cluster
install: generate-manifests $(KUSTOMIZE)
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: generate-manifests $(KUSTOMIZE)
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: generate-manifests $(KUSTOMIZE)
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

help:  # Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[0-9A-Za-z_-]+:.*?##/ { printf "  \033[36m%-45s\033[0m %s\n", $$1, $$2 } /^\$$\([0-9A-Za-z_-]+\):.*?##/ { gsub("_","-", $$1); printf "  \033[36m%-45s\033[0m %s\n", tolower(substr($$1, 3, length($$1)-7)), $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

## --------------------------------------
## Generate / Manifests
## --------------------------------------

##@ generate:

# Generate code
.PHONY: generate
generate: ## Run all generate-go generate-modules generate-manifests generate-go-deepcopy generate-go-conversions
	$(MAKE) generate-go generate-modules generate-manifests generate-go-deepcopy generate-go-conversions

generate-go-deepcopy: $(CONTROLLER_GEN) ## Generate deepcopy go code
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: generate-go
generate-go: $(MOCKGEN) ## Generate the Go mock code
	go generate ./...

.PHONY: generate-manifests
generate-manifests: $(CONTROLLER_GEN) ## Generate manifests e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate-go-conversions
generate-go-conversions: $(CONVERSION_GEN) ## Generate conversions go code
	$(MAKE) clean-generated-conversions SRC_DIRS="./api/v1beta1"
	$(CONVERSION_GEN) \
		--input-dirs=./api/v1beta1 \
		--build-tag=ignore_autogenerated_core \
		--output-file-base=zz_generated.conversion $(CONVERSION_GEN_OUTPUT_BASE) \
		--go-header-file=./hack/boilerplate/boilerplate.generatego.txt

.PHONY: generate-e2e-templates
generate-e2e-templates: $(KUSTOMIZE)
ifeq ($(E2E_FLAVOR), powervs-md-remediation)
	$(KUSTOMIZE) build $(E2E_TEMPLATES)/cluster-template-powervs-md-remediation --load-restrictor LoadRestrictionsNone > $(E2E_TEMPLATES)/cluster-template-powervs-md-remediation.yaml
endif

.PHONY: generate-modules
generate-modules: ## Runs go mod to ensure modules are up to date
	go mod tidy
	cd $(TOOLS_DIR); go mod tidy

images: docker-build

set-flavor: 
ifeq ($(findstring vpc,$(E2E_FLAVOR)),vpc)
	 $(eval E2E_CONF_FILE=$(REPO_ROOT)/test/e2e/config/ibmcloud-e2e-vpc.yaml)
else
	 $(eval E2E_CONF_FILE=$(REPO_ROOT)/test/e2e/config/ibmcloud-e2e-powervs.yaml)
endif
	@echo "Setting e2e test flavour to ${E2E_CONF_FILE}"

## --------------------------------------
## Testing
## --------------------------------------

##@ test:

.PHONY: setup-envtest
setup-envtest: $(SETUP_ENVTEST) # Build setup-envtest from tools folder
	@if [ $(shell go env GOOS) == "darwin" ]; then \
		$(eval KUBEBUILDER_ASSETS := $(shell $(SETUP_ENVTEST) use --use-env -p path --arch amd64 $(KUBEBUILDER_ENVTEST_KUBERNETES_VERSION))) \
		echo "kube-builder assets set using darwin OS"; \
	else \
		$(eval KUBEBUILDER_ASSETS := $(shell $(SETUP_ENVTEST) use --use-env -p path $(KUBEBUILDER_ENVTEST_KUBERNETES_VERSION))) \
		echo "kube-builder assets set using other OS"; \
	fi

# Run unit tests
test: generate fmt vet setup-envtest $(GOTESTSUM) ## Run tests
	KUBEBUILDER_ASSETS="$(KUBEBUILDER_ASSETS)" $(GOTESTSUM) --junitfile $(ARTIFACTS)/junit.xml

# Allow overriding the e2e configurations
GINKGO_FOCUS ?= Workload cluster creation
GINKGO_NODES ?= 3
GINKGO_NOCOLOR ?= false
GINKGO_TIMEOUT ?= 2h
E2E_FLAVOR ?= powervs-md-remediation
JUNIT_FILE ?= junit.e2e_suite.1.xml
GINKGO_ARGS ?= -v --trace --tags=e2e --timeout=$(GINKGO_TIMEOUT) --focus=$(GINKGO_FOCUS) --nodes=$(GINKGO_NODES) --no-color=$(GINKGO_NOCOLOR) --output-dir="$(ARTIFACTS)" --junit-report="$(JUNIT_FILE)"
ARTIFACTS ?= $(REPO_ROOT)/_artifacts
SKIP_CLEANUP ?= false
SKIP_CREATE_MGMT_CLUSTER ?= false

# Run the end-to-end tests
.PHONY: test-e2e
test-e2e: $(GINKGO) $(KUSTOMIZE) $(ENVSUBST) set-flavor e2e-image generate-e2e-templates ## Run e2e tests
	$(ENVSUBST) < $(E2E_CONF_FILE) > $(E2E_CONF_FILE_ENVSUBST) 
	$(GINKGO) $(GINKGO_ARGS) ./test/e2e -- \
		-e2e.artifacts-folder="$(ARTIFACTS)" \
		-e2e.config="$(E2E_CONF_FILE_ENVSUBST)" \
		-e2e.skip-resource-cleanup=$(SKIP_CLEANUP) \
		-e2e.use-existing-cluster=$(SKIP_CREATE_MGMT_CLUSTER) \
		-e2e.flavor="$(E2E_FLAVOR)"

# Basic checks for deploying kind cluster and required providers
.PHONY: test-sanity
test-sanity: ## Run sanity tests
	GINKGO_FOCUS="Run Sanity tests" $(MAKE) test-e2e

.PHONY: test-cover
test-cover: setup-envtest## Run tests with code coverage and code generate reports
	KUBEBUILDER_ASSETS="$(KUBEBUILDER_ASSETS)" go test ./... -coverprofile cover.out
	go tool cover -func=cover.out -o cover.txt
	go tool cover -html=cover.out -o cover.html

## --------------------------------------
## Release
## --------------------------------------

##@ release:

$(RELEASE_DIR):
	mkdir -p $@

$(ARTIFACTS):
	mkdir -p $@

.PHONY: list-staging-releases
list-staging-releases: ## List staging images for image promotion
	@echo $(CORE_IMAGE_NAME):
	$(MAKE) list-image RELEASE_TAG=$(RELEASE_TAG) IMAGE=$(CORE_IMAGE_NAME)

list-image:
	gcloud container images list-tags $(STAGING_REGISTRY)/$(IMAGE) --filter="tags=('$(RELEASE_TAG)')" --format=json

.PHONY: check-release-tag
check-release-tag:
	@if [ -z "${RELEASE_TAG}" ]; then echo "RELEASE_TAG is not set"; exit 1; fi
	@if ! [ -z "$$(git status --porcelain)" ]; then echo "Your local git repository contains uncommitted changes, use git clean before proceeding."; exit 1; fi

.PHONY: check-previous-release-tag
check-previous-release-tag:
	@if [ -z "${PREVIOUS_VERSION}" ]; then echo "PREVIOUS_VERSION is not set"; exit 1; fi

.PHONY: check-github-token
check-github-token:
	@if [ -z "${GITHUB_TOKEN}" ]; then echo "GITHUB_TOKEN is not set"; exit 1; fi

.PHONY: release
release: clean-release check-release-tag $(RELEASE_DIR)  ## Build and push container images using the latest git tag for the commit
	git checkout "${RELEASE_TAG}"
	CORE_CONTROLLER_IMG=$(PROD_REGISTRY)/$(CORE_IMAGE_NAME) $(MAKE) release-manifests
	$(MAKE) release-templates

.PHONY: release-manifests
release-manifests: ## Build the manifests to publish with a release
	$(MAKE) $(RELEASE_DIR)/$(CORE_MANIFEST_FILE).yaml TAG=$(RELEASE_TAG)
	# Add metadata to the release artifacts
	cp metadata.yaml $(RELEASE_DIR)/metadata.yaml

.PHONY: release-staging
release-staging: ## Build and push container images to the staging bucket
	$(MAKE) docker-build-all
	$(MAKE) docker-push-all
	$(MAKE) release-alias-tag
	$(MAKE) staging-manifests
	$(MAKE) release-templates
	$(MAKE) upload-staging-artifacts

.PHONY: staging-manifests
staging-manifests:
	$(MAKE) $(RELEASE_DIR)/$(CORE_MANIFEST_FILE).yaml TAG=$(RELEASE_ALIAS_TAG)
	cp metadata.yaml $(RELEASE_DIR)/metadata.yaml

.PHONY: upload-staging-artifacts
upload-staging-artifacts: ## Upload release artifacts to the staging bucket
	gsutil cp $(RELEASE_DIR)/* gs://$(BUCKET)/components/$(RELEASE_ALIAS_TAG)

.PHONY: release-alias-tag
release-alias-tag: ## Add the release alias tag to the last build tag
	gcloud container images add-tag -q $(CORE_CONTROLLER_IMG):$(TAG) $(CORE_CONTROLLER_IMG):$(RELEASE_ALIAS_TAG)

.PHONY: release-templates
release-templates: $(RELEASE_DIR) ## Generate release templates
	cp templates/cluster-template*.yaml $(RELEASE_DIR)/

IMAGE_PATCH_DIR := $(ARTIFACTS)/image-patch

$(IMAGE_PATCH_DIR): $(ARTIFACTS)
	mkdir -p $@

.PHONY: $(RELEASE_DIR)/$(CORE_MANIFEST_FILE).yaml
$(RELEASE_DIR)/$(CORE_MANIFEST_FILE).yaml:
	$(MAKE) compiled-manifest \
		PROVIDER=$(CORE_MANIFEST_FILE) \
		OLD_IMG=$(CORE_CONTROLLER_ORIGINAL_IMG) \
		MANIFEST_IMG=$(CORE_CONTROLLER_IMG) \
		CONTROLLER_NAME=$(CORE_CONTROLLER_NAME) \
		PROVIDER_CONFIG_DIR=$(CORE_CONFIG_DIR) \
		NAMESPACE=$(CORE_NAMESPACE) \

.PHONY: compiled-manifest
compiled-manifest: $(RELEASE_DIR) $(KUSTOMIZE)
	$(MAKE) image-patch-source-manifest
	$(MAKE) image-patch-kustomization
	$(KUSTOMIZE) build $(IMAGE_PATCH_DIR)/$(PROVIDER) > $(RELEASE_DIR)/$(PROVIDER).yaml

.PHONY: image-patch-source-manifest
image-patch-source-manifest: $(IMAGE_PATCH_DIR) $(KUSTOMIZE)
	mkdir -p $(IMAGE_PATCH_DIR)/$(PROVIDER)
	$(KUSTOMIZE) build $(PROVIDER_CONFIG_DIR) > $(IMAGE_PATCH_DIR)/$(PROVIDER)/source-manifest.yaml

.PHONY: image-patch-kustomization
image-patch-kustomization: $(IMAGE_PATCH_DIR)
	mkdir -p $(IMAGE_PATCH_DIR)/$(PROVIDER)
	$(MAKE) image-patch-kustomization-without-webhook

.PHONY: image-patch-kustomization-without-webhook
image-patch-kustomization-without-webhook: $(IMAGE_PATCH_DIR) $(GOJQ)
	mkdir -p $(IMAGE_PATCH_DIR)/$(PROVIDER)
	$(GOJQ) --yaml-input --yaml-output '.images[0]={"name":"$(OLD_IMG)","newName":"$(MANIFEST_IMG)","newTag":"$(TAG)"}' \
		"hack/image-patch/kustomization.yaml" > $(IMAGE_PATCH_DIR)/$(PROVIDER)/kustomization.yaml

## --------------------------------------
## Docker
## --------------------------------------

.PHONY: docker-build
docker-build: docker-pull-prerequisites ## Build the docker image for controller-manager
	docker build --build-arg ARCH=$(ARCH) . -t $(CORE_CONTROLLER_IMG)-$(ARCH):$(TAG)

.PHONY: docker-push
docker-push: ## Push the docker image
	docker push $(CORE_CONTROLLER_IMG)-$(ARCH):$(TAG)

.PHONY: docker-pull-prerequisites
docker-pull-prerequisites:
	docker pull docker.io/docker/dockerfile:1.1-experimental
	docker pull gcr.io/distroless/static:latest

.PHONY: e2e-image
e2e-image: docker-pull-prerequisites
	docker build --tag=$(CORE_CONTROLLER_ORIGINAL_IMG):e2e .
	$(MAKE) set-manifest-image MANIFEST_IMG=$(CORE_CONTROLLER_ORIGINAL_IMG):e2e TARGET_RESOURCE="./config/default/manager_image_patch.yaml"
	$(MAKE) set-manifest-pull-policy PULL_POLICY=Never TARGET_RESOURCE="./config/default/manager_pull_policy.yaml"

.PHONY: set-manifest-image
set-manifest-image:
	$(info Updating kustomize image patch file for default resource)
	sed -i'' -e 's@image: .*@image: '"${MANIFEST_IMG}"'@' ./config/default/manager_image_patch.yaml

.PHONY: set-manifest-pull-policy
set-manifest-pull-policy:
	$(info Updating kustomize pull policy file for default resource)
	sed -i'' -e 's@imagePullPolicy: .*@imagePullPolicy: '"$(PULL_POLICY)"'@' ./config/default/manager_pull_policy.yaml	

## --------------------------------------
## Docker - All ARCH
## --------------------------------------

.PHONY: docker-build-all ## Build docker images for all architectures
docker-build-all: $(addprefix docker-build-,$(ALL_ARCH))

docker-build-%:
	$(MAKE) ARCH=$* docker-build

.PHONY: docker-push-all ## Push all the architecture docker images
docker-push-all: $(addprefix docker-push-,$(ALL_ARCH))
	$(MAKE) docker-push-core-manifest

docker-push-%:
	$(MAKE) ARCH=$* docker-push

.PHONY: docker-push-core-manifest
docker-push-core-manifest: ## Push the multiarch manifest for the core docker images
	## Minimum docker version 18.06.0 is required for creating and pushing manifest images.
	$(MAKE) docker-push-manifest CONTROLLER_IMG=$(CORE_CONTROLLER_IMG) MANIFEST_FILE=$(CORE_MANIFEST_FILE)

.PHONY: docker-push-manifest
docker-push-manifest:
	docker manifest create --amend $(CONTROLLER_IMG):$(TAG) $(shell echo $(ALL_ARCH) | sed -e "s~[^ ]*~$(CONTROLLER_IMG)\-&:$(TAG)~g")
	@for arch in $(ALL_ARCH); do docker manifest annotate --arch $${arch} ${CONTROLLER_IMG}:${TAG} ${CONTROLLER_IMG}-$${arch}:${TAG}; done
	docker manifest push --purge ${CONTROLLER_IMG}:${TAG}

## --------------------------------------
## Lint / Verify
## --------------------------------------

##@ lint and verify:

.PHONY: lint
lint: $(GOLANGCI_LINT) ## Lint codebase
	$(GOLANGCI_LINT) run -v --fast=false

.PHONY: lint-fix
lint-fix: $(GOLANGCI_LINT) ## Lint the codebase and run auto-fixers if supported by the linter
	GOLANGCI_LINT_EXTRA_ARGS=--fix $(MAKE) lint

APIDIFF_OLD_COMMIT ?= $(shell git rev-parse origin/main)

.PHONY: apidiff
apidiff: $(GO_APIDIFF) ## Check for API differences.
	@if ($(call checkdiff) | grep "api/"); then \
		$(GO_APIDIFF) $(APIDIFF_OLD_COMMIT) --print-compatible; \
	else \
		echo "No changes to 'api/'. Nothing to do."; \
	fi

define checkdiff
	git --no-pager diff --name-only FETCH_HEAD
endef

ALL_VERIFY_CHECKS = doctoc boilerplate shellcheck modules gen conversions

.PHONY: verify
verify: $(addprefix verify-,$(ALL_VERIFY_CHECKS)) ## Run all verify-* targets

.PHONY: verify-doctoc
verify-doctoc:
	./hack/verify-doctoc.sh

.PHONY: verify-boilerplate
verify-boilerplate: ## Verify boilerplate text exists in each file
	./hack/verify-boilerplate.sh

.PHONY: verify-shellcheck
verify-shellcheck: ## Verify shell files
	./hack/verify-shellcheck.sh

.PHONY: verify-modules
verify-modules: generate-modules ## Verify go modules are up to date
	@if !(git diff --quiet HEAD -- go.sum go.mod $(TOOLS_DIR)/go.mod $(TOOLS_DIR)/go.sum); then \
		git diff; \
		echo "go module files are out of date"; exit 1; \
	fi
	@if (find . -name 'go.mod' | xargs -n1 grep -q -i 'k8s.io/client-go.*+incompatible'); then \
		find . -name "go.mod" -exec grep -i 'k8s.io/client-go.*+incompatible' {} \; -print; \
		echo "go module contains an incompatible client-go version"; exit 1; \
	fi

.PHONY: verify-gen
verify-gen: generate ## Verfiy go generated files are up to date
	@if !(git diff --quiet HEAD); then \
		git diff; \
		echo "generated files are out of date, run make generate"; exit 1; \
	fi

.PHONY: verify-conversions
verify-conversions: $(CONVERSION_VERIFIER) ## Verifies expected API conversion are in place
	$(CONVERSION_VERIFIER)

## --------------------------------------
## Cleanup / Verification
## --------------------------------------

##@ clean:

.PHONY: clean
clean: ## Remove all generated files
	$(MAKE) clean-bin
	$(MAKE) clean-book
	$(MAKE) clean-temporary

.PHONY: clean-bin
clean-bin: ## Remove all generated binaries
	rm -rf $(TOOLS_BIN_DIR)

.PHONY: clean-book
clean-book: ## Remove all generated GitBook files
	rm -rf ./docs/book/_book

.PHONY: clean-temporary
clean-temporary: ## Remove all temporary files and folders
	rm -f minikube.kubeconfig
	rm -f kubeconfig
	rm -rf _artifacts

.PHONY: clean-release
clean-release: ## Remove the release folder
	rm -rf $(RELEASE_DIR)

.PHONY: clean-generated-conversions
clean-generated-conversions: ## Remove files generated by conversion-gen from the mentioned dirs
	(IFS=','; for i in $(SRC_DIRS); do find $$i -type f -name 'zz_generated.conversion*' -exec rm -f {} \;; done)

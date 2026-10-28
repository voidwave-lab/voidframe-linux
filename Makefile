# ==============================================================================
# Voidframe Build & Provisioning System
# ==============================================================================

include config.mk
export

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

DIST_DIR := $(CURDIR)/dist
DEBS_DIR := $(DIST_DIR)/debs/$(ARCH)
ISO_DIR  := $(DIST_DIR)/iso
DOCKER_IMAGE := $(DISTRO_NAME)-deb-builder:$(DEBIAN_RELEASE)-$(ARCH)

DOCKER_PLATFORM := linux/$(ARCH)

.PHONY: help build-debs-docker patch-iso install lint clean

help: ## Show available build and provisioning targets
	@printf "\033[1;36m%s (%s) Build System\033[0m\n" "$(DISTRO_NAME)" "$(DISTRO_VERSION)"
	@printf "Target: Debian %s (%s)\n\n" "$(DEBIAN_RELEASE)" "$(ARCH)"
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m [ARCH=amd64|arm64] [DISTRO_NAME=voidframe]\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build-debs-docker: ## Compile all Ratatui & TUIOS .deb packages inside Debian Trixie container
	@mkdir -p "$(DEBS_DIR)"
	docker buildx build \
		--platform "$(DOCKER_PLATFORM)" \
		--build-arg DEBIAN_RELEASE="$(DEBIAN_RELEASE)" \
		--build-arg RUST_VERSION="$(RUST_VERSION)" \
		--build-arg GO_VERSION="$(GO_VERSION)" \
		-t "$(DOCKER_IMAGE)" \
		-f docker/Dockerfile.deb-builder \
		--load \
		.
	docker run --rm \
		--platform "$(DOCKER_PLATFORM)" \
		-e DISTRO_NAME="$(DISTRO_NAME)" \
		-e DISTRO_VERSION="$(DISTRO_VERSION)" \
		-e DISTRO_MAINTAINER="$(DISTRO_MAINTAINER)" \
		-e DEBIAN_RELEASE="$(DEBIAN_RELEASE)" \
		-e ARCH="$(ARCH)" \
		-e LEMURS_VERSION="$(LEMURS_VERSION)" \
		-e TUIOS_VERSION="$(TUIOS_VERSION)" \
		-e YAZI_VERSION="$(YAZI_VERSION)" \
		-e WIREMIX_VERSION="$(WIREMIX_VERSION)" \
		-e IMPALA_VERSION="$(IMPALA_VERSION)" \
		-e BLUETUI_VERSION="$(BLUETUI_VERSION)" \
		-e BOTTOM_VERSION="$(BOTTOM_VERSION)" \
		-e SYSTEMCTL_TUI_VERSION="$(SYSTEMCTL_TUI_VERSION)" \
		-e DUA_CLI_VERSION="$(DUA_CLI_VERSION)" \
		-e GITUI_VERSION="$(GITUI_VERSION)" \
		-v "$(DEBS_DIR):/dist/debs" \
		"$(DOCKER_IMAGE)"

patch-iso: ## Patch official Debian Trixie netinst ISO with preseed, setup scripts, and .debs
	@mkdir -p "$(ISO_DIR)"
	./iso/patch-netinst.sh \
		--distro "$(DISTRO_NAME)" \
		--version "$(DISTRO_VERSION)" \
		--release "$(DEBIAN_RELEASE)" \
		--arch "$(ARCH)" \
		--debs-dir "$(DEBS_DIR)" \
		--output-dir "$(ISO_DIR)"

install: ## Run bootstrap provisioning on the current Debian Trixie host (requires root)
	./setup/bootstrap.sh

lint: ## Validate shell scripts (bash -n / shellcheck) and configuration syntax
	@echo "==> Checking bash syntax across all scripts..."
	@for script in docker/build-packages.sh iso/patch-netinst.sh setup/*.sh configs/lemurs/wayland/tuios-session; do \
		echo "  [syntax] $$script"; \
		bash -n "$$script"; \
	done
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "==> Running shellcheck..."; \
		shellcheck -x docker/build-packages.sh iso/patch-netinst.sh setup/*.sh configs/lemurs/wayland/tuios-session; \
	else \
		echo "==> shellcheck not installed; skipped static lint (bash -n passed)."; \
	fi

clean: ## Remove generated build artifacts, ISOs, and .deb packages
	rm -rf "$(DIST_DIR)"

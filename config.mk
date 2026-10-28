# ==============================================================================
# Voidframe Central Configuration (Makefile & Shell Compatible)
# ==============================================================================
# Change DISTRO_NAME to rebrand the entire distribution, ISO volume label,
# hostname defaults, and offline media paths.

DISTRO_NAME ?= voidframe
DISTRO_VERSION ?= 0.1.0
DISTRO_MAINTAINER ?= Voidframe Maintainers <maintainers@voidframe.local>
GITHUB_REPO ?= voidframe/voidframe

# Target Debian Base
DEBIAN_RELEASE ?= trixie
DEBIAN_VERSION ?= 13.0.0
ARCH ?= amd64

# Default User (for preseed & post-install setup)
TARGET_USER ?= void
TARGET_HOSTNAME ?= $(DISTRO_NAME)

# Tool & Upstream Release Versions (Pinned Tags / Versions)
RUST_VERSION ?= 1.85.0
GO_VERSION ?= 1.24.0

LEMURS_VERSION ?= v0.3.2
TUIOS_VERSION ?= v0.4.0
YAZI_VERSION ?= v25.2.26
WIREMIX_VERSION ?= v0.5.0
IMPALA_VERSION ?= v0.3.1
BLUETUI_VERSION ?= v0.6.1
BOTTOM_VERSION ?= 0.10.2
SYSTEMCTL_TUI_VERSION ?= v0.3.4
DUA_CLI_VERSION ?= v2.29.4
GITUI_VERSION ?= v0.27.0
NERD_FONT_VERSION ?= v3.3.0
NERD_FONT_NAME ?= JetBrainsMono

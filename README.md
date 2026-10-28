# Voidframe (`voidframe`)

> **A suckless-inspired, keyboard-driven, ultra-low-latency TUI Operating System built on Debian 13 (Trixie), powered by the Ratatui ecosystem and TUIOS over an invisible Wayland micro-compositor kiosk.**

---

## 1. Architecture Overview

**Voidframe** transforms a minimal, headless **Debian 13 (Trixie) `netinst`** installation into a cohesive, GPU-accelerated Terminal User Interface (TUI) workstation without X11 bloat or desktop environment overhead:

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                     Debian 13 (Trixie) Minimal Base                      │
│          systemd-networkd + iwd  │  BlueZ  │  PipeWire + WirePlumber     │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   │
                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│               lemurs (TUI Login & Display Manager on tty2)               │
│                  PAM Authentication + systemd-logind/seatd               │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   │ Executes /etc/lemurs/wayland/tuios-session
                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│    exec cage -s -- foot --config=/etc/xdg/foot/foot.ini -e tuios         │
│   Invisible Wayland Kiosk (Cage) ──► Fullscreen GPU Terminal (Foot)      │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   │
                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│              TUIOS (Terminal Window Manager & Multiplexer)               │
│  ┌────────────┬────────────┬────────────┬────────────┬────────────────┐  │
│  │   yazi     │  wiremix   │   impala   │  bluetui   │   bottom (btm) │  │
│  │ (Files/ya) │ (PipeWire) │ (Wi-Fi/iwd)│  (BlueZ)   │ (Sys Monitor)  │  │
│  ├────────────┴────────────┼────────────┴────────────┼────────────────┤  │
│  │     systemctl-tui       │       dua-cli (dua)     │     gitui      │  │
│  │  (Services & Journal)   │     (Disk Analyzer)     │  (Git Client)  │  │
│  └─────────────────────────┴─────────────────────────┴────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

### Core System Components

| Layer | Component | Upstream | Description |
| :--- | :--- | :--- | :--- |
| **Base OS** | Debian 13 (`trixie`) | `debian.org` | Minimal headless `netinst` base (`systemd`, `seatd`, `dbus-user-session`) |
| **Display Manager** | `lemurs` | [`coastalwhite/lemurs`](https://github.com/coastalwhite/lemurs) | Rust TUI login manager on `tty2` with PAM session management |
| **Wayland Kiosk** | `cage` + `foot` | `cage-kiosk` / `foot` | Single-application Wayland micro-compositor running fullscreen GPU-accelerated `foot` |
| **Window Multiplexer** | `tuios` | [`Gaurav-Gosain/tuios`](https://github.com/Gaurav-Gosain/tuios) | Go-based terminal window manager with workspaces, tiling, and floating panes |
| **File Manager** | `yazi` + `ya` | [`sxyazi/yazi`](https://github.com/sxyazi/yazi) | Async Rust file manager with image, video, PDF, archive, and code previews |
| **Audio Mixer** | `wiremix` | [`tsowell/wiremix`](https://github.com/tsowell/wiremix) | Native PipeWire audio mixer built with Ratatui |
| **Wi-Fi Manager** | `impala` | [`pythops/impala`](https://github.com/pythops/impala) | Ratatui Wi-Fi manager communicating over D-Bus with `iwd` |
| **Bluetooth Manager** | `bluetui` | [`pythops/bluetui`](https://github.com/pythops/bluetui) | Ratatui Bluetooth manager communicating over D-Bus with `bluez` |
| **System Monitor** | `bottom` (`btm`) | [`ClementTsang/bottom`](https://github.com/ClementTsang/bottom) | Process, CPU, memory, disk, temperature, and network monitor |
| **Service Manager** | `systemctl-tui` | [`rgwood/systemctl-tui`](https://github.com/rgwood/systemctl-tui) | Fast TUI for inspecting/controlling `systemd` units and `journalctl` logs |
| **Disk Analyzer** | `dua-cli` (`dua`) | [`Byron/dua-cli`](https://github.com/Byron/dua-cli) | Parallel disk usage analyzer and interactive cleaner |
| **Git Client** | `gitui` | [`extrawurst/gitui`](https://github.com/extrawurst/gitui) | High-performance terminal UI for Git repositories |

---

## 2. Repository Structure

```text
.
├── .github/
│   └── workflows/
│       ├── build-debs.yml        # Compiles Rust/Go TUIs into .deb packages & publishes to GH Releases
│       └── build-iso.yml         # Patches official Debian Trixie netinst ISO with preseed + debs
├── Makefile                      # Targets: build-debs-docker, patch-iso, install, lint, clean
├── config.mk                     # Central configuration (DISTRO_NAME, DEBIAN_RELEASE=trixie, ARCH, tool versions)
├── docker/
│   ├── Dockerfile.deb-builder    # Multi-stage Debian Trixie builder for Rust (Ratatui tools) and Go (tuios)
│   └── build-packages.sh         # Inside-container script that outputs clean .deb packages into /dist/debs
├── setup/
│   ├── bootstrap.sh              # Main entrypoint for post-install or preseed late_command
│   ├── 01-base-packages.sh       # Installs apt dependencies (pipewire, wireplumber, iwd, bluez, cage, foot, fonts, cli tools)
│   ├── 02-install-tuis.sh        # Installs the pre-built .deb packages from local cache or GitHub Releases
│   ├── 03-network-audio.sh       # Replaces wpa_supplicant with iwd + systemd-networkd (for impala), enables bluez & pipewire
│   ├── 04-display-manager.sh     # Sets up lemurs systemd service, PAM rules, and /etc/lemurs/wayland/tuios-session
│   └── 05-dotfiles.sh            # Populates /etc/skel and target user's ~/.config with unified configs
├── configs/
│   ├── lemurs/
│   │   ├── config.toml           # Clean, minimal Lemurs config
│   │   └── wayland/tuios-session # Executable Wayland kiosk wrapper script
│   ├── foot/
│   │   └── foot.ini              # JetBrainsMono Nerd Font, 24-bit color, zero padding, dark high-contrast theme
│   ├── tuios/
│   │   └── config.toml           # TUIOS config & ergonomic keybindings to launch yazi, wiremix, impala, bluetui, btm
│   ├── yazi/
│   │   ├── yazi.toml
│   │   └── theme.toml
│   └── bottom/
│       └── bottom.toml
├── iso/
│   ├── preseed.cfg               # Automated Debian Trixie minimal installation + late_command hook
│   └── patch-netinst.sh          # Uses xorriso to unpack Debian netinst ISO, inject preseed + setup + .debs, and repack
└── README.md                     # Architecture overview, keyboard shortcuts cheatsheet, and build/install instructions
```

### Rebranding (`DISTRO_NAME`)

The distribution name is controlled by a single variable in [`config.mk`](config.mk):

```makefile
DISTRO_NAME ?= voidframe
```

You can override it globally at build or install time:

```bash
make build-debs-docker DISTRO_NAME=cyberdeck
make patch-iso DISTRO_NAME=cyberdeck ARCH=amd64
```

---

## 3. Building & Installing

### A. Triggering GitHub Actions CI/CD (Recommended)

The repository includes two automated GitHub Actions workflows:

1. **`.github/workflows/build-debs.yml` (`Build Debian Trixie TUI Packages (.deb)`):**
   - Runs natively on `ubuntu-24.04` (`amd64`) and `ubuntu-24.04-arm` (`arm64`) inside a `debian:trixie` container.
   - Packages all 10 tools (`lemurs`, `tuios`, `yazi`, `wiremix`, `impala`, `bluetui`, `bottom`, `systemctl-tui`, `dua-cli`, `gitui`) into standard `.deb` files with `DEBIAN/control` runtime dependencies.
   - **To trigger manually:** Go to **Actions → Build Debian Trixie TUI Packages (.deb) → Run workflow**.
2. **`.github/workflows/build-iso.yml` (`Build Patched Debian Trixie Netinst ISO`):**
   - Invokes `build-debs.yml`, downloads the official Debian 13 (`trixie`) `netinst` ISO for `amd64` and `arm64`, and runs `iso/patch-netinst.sh` to embed `/preseed.cfg`, `/voidframe/setup`, `/voidframe/configs`, `/voidframe/fonts`, and `/voidframe/debs`.
   - **To trigger manually:** Go to **Actions → Build Patched Debian Trixie Netinst ISO → Run workflow**.
   - **To publish a full GitHub Release (ISOs + `.deb` packages):** Push a version tag:
     ```bash
     git tag v0.1.0
     git push origin v0.1.0
     ```

### B. Local Docker `.deb` Build & ISO Patching

```bash
# 1. Build all 10 .deb packages inside Debian Trixie Docker container (amd64 or arm64)
make build-debs-docker ARCH=amd64

# 2. Patch the official Debian Trixie netinst ISO with preseed + setup + .debs
make patch-iso ARCH=amd64

# Output ISO:
# dist/iso/voidframe-0.1.0-debian-trixie-amd64-netinst.iso
```

### C. Online Post-Install Mode (On an Existing Fresh Debian Trixie System)

If you already installed a standard minimal Debian 13 (Trixie) system (without a desktop environment):

```bash
git clone https://github.com/voidframe/voidframe.git
cd voidframe
sudo ./setup/bootstrap.sh --online --user "$USER"
sudo reboot
```

---

## 4. Testing the ISO in QEMU & UTM (`amd64` and `arm64`)

> **Default Preseed Credentials:**
> - **Username:** `void`
> - **Password:** `voidframe` *(change after first login via `passwd`)*

### QEMU (`amd64` / `x86_64`)

```bash
# Create a 20 GB virtual disk
qemu-img create -f qcow2 voidframe-amd64.qcow2 20G

# Boot the patched ISO for automated preseed installation
qemu-system-x86_64 \
  -enable-kvm \
  -m 4096 \
  -smp 4 \
  -cpu host \
  -machine q35,accel=kvm:hvf:tcg \
  -device virtio-vga-gl -display gtk,gl=on \
  -audiodev pa,id=snd0 -device ich9-intel-hda -device hda-output,audiodev=snd0 \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -drive file=voidframe-amd64.qcow2,if=virtio,format=qcow2 \
  -cdrom dist/iso/voidframe-0.1.0-debian-trixie-amd64-netinst.iso \
  -boot d
```

### QEMU (`arm64` / `aarch64` — Linux or macOS Apple Silicon)

```bash
# Create a 20 GB virtual disk
qemu-img create -f qcow2 voidframe-arm64.qcow2 20G

# Boot with UEFI firmware (hvf acceleration on macOS Apple Silicon, kvm on Linux ARM64)
qemu-system-aarch64 \
  -M virt,accel=hvf:kvm:tcg,highmem=on \
  -cpu host \
  -m 4096 \
  -smp 4 \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -device virtio-gpu-pci \
  -display default,show-cursor=on \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -drive file=voidframe-arm64.qcow2,if=virtio,format=qcow2 \
  -cdrom dist/iso/voidframe-0.1.0-debian-trixie-arm64-netinst.iso \
  -boot d
```

### UTM (macOS Apple Silicon / Intel)

1. Open **UTM** → **Create a New Virtual Machine** → **Virtualize** (for `arm64` on Apple Silicon) or **Emulate** (for `amd64`).
2. Select **Linux** and choose `dist/iso/voidframe-0.1.0-debian-trixie-arm64-netinst.iso` as the Boot ISO image.
3. Set Memory to **4096 MB**, CPU cores to **4**, and Storage to **20 GB**.
4. In VM Settings → **Display**, select **`virtio-ramfb-gl`** (or `virtio-gpu-gl-pci`) for GPU-accelerated Wayland (`cage` + `foot`).
5. Start the VM: the GRUB menu will automatically select **`voidframe 0.1.0 Automated TUI OS Install`** after 5 seconds, install Debian Trixie + all Ratatui `.deb` packages, and reboot into **Lemurs** on `tty2`.
6. Eject the ISO on reboot, log in as `void` / `voidframe`, and you will land directly in **TUIOS**.

---

## 5. Keyboard Shortcuts Cheatsheet

### Lemurs Login Manager (`tty2`)

| Shortcut | Action |
| :--- | :--- |
| `Tab` / `Up` / `Down` | Move between Environment Switcher, Operator (Username), and Passphrase |
| `Left` / `Right` | Cycle sessions (`tuios-session` selected by default) |
| `Enter` | Authenticate via PAM and launch Wayland Kiosk (`cage` -> `foot` -> `tuios`) |
| `F1` / `F2` / `F3` | Poweroff / Reboot / Suspend |

### TUIOS Window Manager & Ratatui Suite Launchers

In **TUIOS**, press **`Ctrl+b`** (or **`Esc`** in Window Management mode) to enter Command/Window mode:

| Shortcut (in Window Mode) | Action |
| :--- | :--- |
| `Ctrl+b` / `Esc` | Toggle between **Window Management Mode** and **Terminal Input Mode** |
| `n` or `Enter` | Spawn a new terminal window |
| `w` or `x` | Close focused window |
| `t` | Toggle automatic master-stack tiling mode |
| `h` / `j` / `k` / `l` | Snap window Left / Bottom / Top / Right |
| `f` / `z` | Snap fullscreen / Toggle zoom on focused pane |
| `Tab` / `Shift+Tab` | Cycle focus to next / previous window |
| `Alt+1` .. `Alt+9` | Switch to Workspace `1` .. `9` |
| `Alt+Shift+1` .. `9` | Move focused window to Workspace `1` .. `9` |
| **`e`** | Launch **Yazi** (`yazi`) File Manager |
| **`a`** | Launch **Wiremix** (`wiremix`) PipeWire Audio Mixer (floating) |
| **`i`** | Launch **Impala** (`impala`) Wi-Fi Manager over `iwd` (floating) |
| **`b`** | Launch **Bluetui** (`bluetui`) Bluetooth Manager over `bluez` (floating) |
| **`v`** | Launch **Bottom** (`btm`) System & Process Monitor |
| **`s`** | Launch **systemctl-tui** (`sudo systemctl-tui`) Service & Journal Manager |
| **`d`** | Launch **Dua** (`dua i`) Interactive Disk Usage Analyzer |
| **`g`** | Launch **GitUI** (`gitui`) Git Repository Client |
| `?` | Show interactive TUIOS keybinding overlay |
| `q` | Quit TUIOS (exits `cage` session and returns to `lemurs` login screen) |

### Foot Terminal Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Ctrl+Shift+c` | Copy selection to Wayland clipboard |
| `Ctrl+Shift+v` | Paste from Wayland clipboard |
| `Ctrl++` / `Ctrl+-` / `Ctrl+0` | Increase / Decrease / Reset JetBrainsMono Nerd Font size |

---

## 6. License & GNU GPLv3 Compliance

This repository, including all build pipelines, provisioning scripts, preseed configurations, and dotfiles, is free software licensed under the **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** — see [`LICENSE`](LICENSE) for the full text.

### Upstream License Compatibility Matrix

All bundled TUI applications are distributed under Free Software licenses compatible with **GNU GPLv3**:

| Package | Upstream License | GPLv3 Compatible | Installed Debian Copyright Path |
| :--- | :--- | :---: | :--- |
| `lemurs` | `MIT OR Apache-2.0` | Yes | `/usr/share/doc/lemurs/copyright` |
| `tuios` | `MIT` | Yes | `/usr/share/doc/tuios/copyright` |
| `yazi` (`yazi` + `ya`) | `MIT` | Yes | `/usr/share/doc/yazi/copyright` |
| `wiremix` | `MIT OR GPL-3.0-or-later` | Yes | `/usr/share/doc/wiremix/copyright` |
| `impala` | `GPL-3.0-only` | Yes | `/usr/share/doc/impala/copyright` |
| `bluetui` | `GPL-3.0-only` | Yes | `/usr/share/doc/bluetui/copyright` |
| `bottom` (`btm`) | `MIT` | Yes | `/usr/share/doc/bottom/copyright` |
| `systemctl-tui` | `MIT` | Yes | `/usr/share/doc/systemctl-tui/copyright` |
| `dua-cli` (`dua`) | `MIT` | Yes | `/usr/share/doc/dua-cli/copyright` |
| `gitui` | `MIT` | Yes | `/usr/share/doc/gitui/copyright` |

### Corresponding Source & Binary Distribution (GPLv3 §4 & §6)

- Every `.deb` package built by [`docker/build-packages.sh`](docker/build-packages.sh) embeds a Debian machine-readable `/usr/share/doc/<pkg>/copyright` file and `/usr/share/doc/<pkg>/SOURCE_MANIFEST` recording the exact upstream repository URL, release tag, and license.
- Every patched ISO produced by [`iso/patch-netinst.sh`](iso/patch-netinst.sh) and every GitHub Release includes `/LICENSE` (full GNU GPLv3 text) and `SOURCE_MANIFEST.txt`.


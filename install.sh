#!/usr/bin/env bash
#
# install.sh — Installs the Quickshell dashboard on the user's system.
#
# Copies this project into ~/.config/quickshell/dashboard (the location that
# Quickshell recognizes as a configuration), checks dependencies, and creates a
# .desktop launcher, an autostart entry and (on request) the sudoers files for
# reading SMART data and the DMI memory table.
#
# Usage:
#   ./install.sh                 # install with defaults (all extras)
#   ./install.sh --yes           # auto-approve the dependency installs
#   ./install.sh --no-deps       # do not touch dependencies, only copy the files
#   ./install.sh --no-sudoers    # skip the SMART and DMI sudoers
#   ./install.sh --no-autostart  # skip launching at login
#   ./install.sh --no-launcher   # skip the entry in the applications menu
#   ./install.sh --path ~/myshell# install into an alternative folder
#   ./install.sh --help

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors and output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YEL=$'\e[33m'; C_CYN=$'\e[36m'; C_OFF=$'\e[0m'
else
    C_BOLD=""; C_RED=""; C_GREEN=""; C_YEL=""; C_CYN=""; C_OFF=""
fi

info()  { printf '%s[*]%s %s\n'   "$C_CYN" "$C_OFF" "$*"; }
ok()    { printf '%s[+]%s %s\n'   "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf '%s[!]%s %s\n'   "$C_YEL" "$C_OFF" "$*"; }
err()   { printf '%s[x]%s %s\n'   "$C_RED" "$C_OFF" "$*" >&2; }
die()   { err "$*"; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }

# Dependency instructions for distros without automatic installation.
print_deps_instructions() {
    if have apt; then
        echo
        echo "  Debian/Ubuntu - Quickshell is not in the repositories; build from source:"
        echo "    sudo apt install qt6-base-dev qt6-declarative-dev libqt6svg6-dev \\"
        echo "                     cmake ninja-build g++ git python3"
        echo "    git clone --recurse-submodules https://github.com/outfoxxed/quickshell.git"
        echo "    cmake -B build -S quickshell && cmake --build build"
        echo "    sudo cmake --install build"
    elif have pacman; then
        echo
        echo "  Arch/Manjaro - Quickshell is in AUR (needs a helper such as paru/yay):"
        echo "    paru -S quickshell-git      # or yay -S quickshell-git"
    elif have zypper; then
        echo
        echo "  openSUSE - Quickshell is not in the repositories; build from source"
        echo "  (see the build instructions on the project website)."
    elif have dnf; then
        echo
        echo "  Fedora/Nobara - install from COPR:"
        echo "    sudo dnf copr enable errornointernet/quickshell"
        echo "    sudo dnf install quickshell python3"
    fi
}

# ---------------------------------------------------------------------------
# Command-line options
# ---------------------------------------------------------------------------
YES=0
DO_DEPS=1
DO_SUDOERS=1
DO_AUTOSTART=1
DO_LAUNCHER=1
DEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)            YES=1 ;;
        --no-deps)           DO_DEPS=0 ;;
        --no-sudoers)        DO_SUDOERS=0 ;;
        --no-autostart)      DO_AUTOSTART=0 ;;
        --no-launcher)       DO_LAUNCHER=0 ;;
        -p|--path)           DEST="${2:?--path requires an argument}"; shift ;;
        -h|--help)           sed -n '2,22p' "$0"; exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Determine source and destination folders
# ---------------------------------------------------------------------------
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_ROOT="$XDG_CONFIG_HOME/quickshell"
DEST="${DEST:-$CONFIG_ROOT/dashboard}"

echo
info "${C_BOLD}Quickshell dashboard installation${C_OFF}"
info "  Source : $SOURCE_DIR"
info "  Destination: $DEST"
echo

[[ -d "$SOURCE_DIR" ]] || die "Source folder not found: $SOURCE_DIR"
[[ -f "$SOURCE_DIR/shell.qml" ]] || die "shell.qml not found in $SOURCE_DIR: not a valid Quickshell configuration."

# ---------------------------------------------------------------------------
# Dependency check (optional)
# ---------------------------------------------------------------------------
if [[ $DO_DEPS -eq 1 ]]; then
    echo
    info "${C_BOLD}1) Checking dependencies${C_OFF}"
    DEP_OK=1

    if ! have quickshell; then
        warn "  'quickshell' not found."
        DEP_OK=0
    else
        ok "  Quickshell present: $(quickshell --version 2>/dev/null | head -1)"
    fi

    if ! have python3; then
        warn "  'python3' not found."
        DEP_OK=0
    else
        ok "  Python3 present: $(python3 --version 2>&1)"
    fi

    if [[ $DEP_OK -eq 0 ]]; then
        if [[ $YES -eq 1 ]]; then
            if have dnf; then
                info "  Installing dependencies with dnf (COPR errornointernet/quickshell)..."
                sudo dnf copr enable -y errornointernet/quickshell
                sudo dnf install -y quickshell python3
            elif have pacman && have paru; then
                info "  Installing quickshell-git from AUR with paru..."
                paru -S --noconfirm quickshell-git
            elif have pacman && have yay; then
                info "  Installing quickshell-git from AUR with yay..."
                yay -S --noconfirm quickshell-git
            else
                warn "  No automatic installation available on this platform:"
                print_deps_instructions
            fi
        else
            warn "  Some dependencies are missing. Re-run with --yes to install them automatically,"
            warn "  or install them manually (see below):"
            print_deps_instructions
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Copy the files to the destination
# ---------------------------------------------------------------------------
echo
info "${C_BOLD}2) Copying files${C_OFF}"

mkdir -p "$DEST"

# If the destination is a symlink pointing back at the source, we are already
# in sync: leave it alone but mention it (any change in the source is already
# visible). If however it is a symlink to somewhere else, replace it with a
# real copy.
if [[ -L "$DEST" ]]; then
    readlink_dest="$(readlink "$DEST")"
    if [[ "$readlink_dest" == "$SOURCE_DIR" ]]; then
        ok "  The destination is already a symlink to the source; no copy needed."
        SKIP_COPY=1
    else
        warn "  $DEST is a symlink to '$readlink_dest'; replacing it with a real copy."
        rm -f "$DEST"
        mkdir -p "$DEST"
    fi
fi

if [[ "${SKIP_COPY:-0}" -ne 1 ]]; then
    # Avoid copying useless/recursive files.
    if have rsync; then
        # rsync keeps the destination aligned with the source (settings live in
        # dashboard.json, outside of this folder).
        #
        # panels/ is excluded from this first pass on purpose: --delete removes
        # whatever is in the destination and not in the source, so without the
        # exclusion a reinstall would silently wipe every panel the user had
        # added. The panels shipped with the dashboard live in that same folder
        # now, so they are copied by the second pass right below — which never
        # deletes.
        rsync -a --delete \
            --exclude '.git/' --exclude '.claude/' --exclude '__pycache__/' \
            --exclude '*.pyc' --exclude 'install.sh' --exclude '*.desktop' \
            --exclude 'panels/' \
            "$SOURCE_DIR"/ "$DEST"/
        # Shipped panels: copy-in only. User-added files are left alone, and a
        # panel modified in place is overwritten — it is part of the dashboard,
        # not personal work; anything personal belongs in a file of its own.
        mkdir -p "$DEST/panels"
        rsync -a "$SOURCE_DIR/panels/" "$DEST/panels/"
    else
        # Fallback with cp.
        cp -a "$SOURCE_DIR"/. "$DEST"/
    fi
    ok "  Files copied to $DEST"
fi

# ---------------------------------------------------------------------------
# .desktop launcher and autostart
# ---------------------------------------------------------------------------
[[ -d "$CONFIG_ROOT" ]] || mkdir -p "$CONFIG_ROOT"

LAUNCH_CMD="quickshell -c dashboard"

if [[ $DO_LAUNCHER -eq 1 ]]; then
    echo
    info "${C_BOLD}3) Creating .desktop launcher${C_OFF}"
    DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$DESKTOP_DIR"
    DESKTOP_FILE="$DESKTOP_DIR/dashboard-quickshell.desktop"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Omnitask-Linux
GenericName=System Dashboard
Comment=System and monitoring dashboard for Quickshell
Exec=$LAUNCH_CMD
Terminal=false
Categories=System;Monitor;
Keywords=dashboard;system;monitor;cpu;gpu;network;
EOF
    chmod +x "$DESKTOP_FILE"
    ok "  Launcher: $DESKTOP_FILE"
fi

if [[ $DO_AUTOSTART -eq 1 ]]; then
    echo
    info "${C_BOLD}4) Autostart at login${C_OFF}"
    AUTOSTART_DIR="$XDG_CONFIG_HOME/autostart"
    mkdir -p "$AUTOSTART_DIR"
    AUTOSTART_FILE="$AUTOSTART_DIR/dashboard-quickshell.desktop"
    if [[ "$DO_LAUNCHER" -eq 1 ]]; then
        cp "$DESKTOP_FILE" "$AUTOSTART_FILE"
    else
        cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Omnitask-Linux
Comment=Starts the Omnitask-Linux dashboard at login
Exec=$LAUNCH_CMD
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    fi
    ok "  Autostart: $AUTOSTART_FILE"
fi

# ---------------------------------------------------------------------------
# Sudoers for the two privileged reads (requires privileges)
#
# Both are the same shape — one file, one dropin, one thing that degrades to a
# reminder if it is refused — so they go through one function instead of two
# copies of the same twenty lines.
# ---------------------------------------------------------------------------
install_sudoers() {
    local name="$1" what="$2" without="$3"
    local src="$SOURCE_DIR/scripts/quickshell-$name.sudoers"
    local dst="/etc/sudoers.d/quickshell-$name"

    if [[ ! -f "$src" ]]; then
        warn "  $what sudoers not found ($src), skipping."
        return
    fi

    if [[ -f "$dst" ]]; then
        ok "  $dst already present."
        return
    fi

    if ! have sudo; then
        warn "  'sudo' is not available. To enable $what, install manually:"
        warn "    sudo install -m 0440 -o root -g root \\"
        warn "      scripts/quickshell-$name.sudoers $dst"
        return
    fi

    warn "  Administrator privileges will be requested to install:"
    warn "    $dst"
    info "  Installing the sudoers file (the dashboard works fine even without it)..."
    if sudo install -m 0440 -o root -g root "$src" "$dst" \
            && sudo visudo -c >/dev/null 2>&1; then
        ok "  $what sudoers installed and validated."
    else
        warn "  Sudoers installation failed or was cancelled; $without"
    fi
}

if [[ $DO_SUDOERS -eq 1 ]]; then
    echo
    info "${C_BOLD}5) Privileged reads sudoers${C_OFF}"
    install_sudoers smart "SMART data" \
        "the Disks panel will show a reminder instead of the health data."
    install_sudoers hardware "RAM module details" \
        "the Hardware window will show the memory total without the per-slot detail."
fi

# ---------------------------------------------------------------------------
# Network capabilities (requires privileges)
#
# Two separate one-offs, both about the same blind spot. nethogs needs to listen
# on the interfaces to measure per-process traffic; ss needs to read other
# users' file descriptors to say which process a connection belongs to. Without
# them the dashboard runs fine, it just shows only your own half of the network.
# ---------------------------------------------------------------------------
if [[ $DO_SUDOERS -eq 1 ]]; then
    echo
    info "${C_BOLD}6) Network capabilities${C_OFF}"

    if have setcap && have getcap && have sudo; then
        grant_caps() {
            local binary caps current
            binary=$(command -v "$1" 2>/dev/null) || return 0
            caps="$2"
            current=$(getcap "$binary" 2>/dev/null)
            if [[ -n "$current" ]]; then
                ok "  $binary already has capabilities: ${current#* }"
                return 0
            fi
            info "  Granting $caps to $binary..."
            if sudo setcap "$caps" "$binary"; then
                ok "  $binary is now allowed."
            else
                warn "  Failed or cancelled; run it yourself when convenient:"
                warn "    sudo setcap $caps $binary"
            fi
        }

        if have nethogs; then
            grant_caps nethogs cap_net_raw,cap_net_admin+ep
        else
            warn "  'nethogs' is not installed: no per-process traffic."
        fi

        if have ss; then
            grant_caps ss cap_dac_read_search,cap_sys_ptrace+ep
        else
            warn "  'ss' is not installed: no connections at all."
        fi
    else
        warn "  'setcap'/'getcap'/'sudo' not available. To see the network of all"
        warn "  users, run these once:"
        warn "    sudo setcap cap_net_raw,cap_net_admin+ep \$(which nethogs)"
        warn "    sudo setcap cap_dac_read_search,cap_sys_ptrace+ep \$(which ss)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo
ok "${C_BOLD}Installation complete!${C_OFF}"
echo
if have quickshell && [[ ! "${SKIP_COPY:-0}" -eq 1 ]]; then
    info "To start the dashboard now:"
    info "    $LAUNCH_CMD"
    info
    info "To show/hide the window from a shortcut or the terminal:"
    info "    qs ipc call dashboard toggle"
fi
echo
info "  Data configuration:       $CONFIG_ROOT/dashboard.json"
info "  Home Assistant configuration: $CONFIG_ROOT/home-assistant.json"
info "  MacroCam Web key (solar meter): $CONFIG_ROOT/macrocam.json"
if [[ $DO_LAUNCHER -eq 1 ]]; then
    info "  Applications menu:       ${DESKTOP_FILE:-$HOME/.local/share/applications/dashboard-quickshell.desktop}"
fi
if [[ $DO_AUTOSTART -eq 1 ]]; then
    info "  Autostart:               ${AUTOSTART_FILE:-$XDG_CONFIG_HOME/autostart/dashboard-quickshell.desktop}"
fi
echo
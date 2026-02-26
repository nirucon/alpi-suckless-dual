#!/usr/bin/env bash
# =============================================================================
#  alpi-suckless.sh — Arch Linux Post Install (NIRUCON Suckless Edition)
#  Author: Nicklas Rudolfsson (nirucon)
#
#  Supports two session variants:
#    x11   — dwm + suckless-stack (X11)
#    niri  — niri + waybar + wayland-stack (foot, swaylock, mako, wofi…)
#    both  — install everything, choose at login
#
#  Phases (run in order):
#    core        — upgrade system, btrfs/snapper, base packages, services
#    suckless    — clone/build dwm, st, dmenu, slock, slstatus  [x11/both]
#    niri        — install niri via AUR + waybar + full wayland stack  [niri/both]
#    lookandfeel — clone dotfiles/configs/scripts from lookandfeel repo
#    apps        — pacman + AUR packages
#    optimize    — zram, sysctl, journald, pacman, makepkg tuning
#
#  Usage:
#    ./alpi-suckless.sh                          # interactive variant selector
#    ./alpi-suckless.sh --variant x11            # X11 only (dwm)
#    ./alpi-suckless.sh --variant niri           # Wayland only (niri)
#    ./alpi-suckless.sh --variant both           # install both
#    ./alpi-suckless.sh --only suckless          # rebuild suckless only
#    ./alpi-suckless.sh --only niri              # reinstall niri stack only
#    ./alpi-suckless.sh --only lookandfeel       # refresh dotfiles only
#    ./alpi-suckless.sh --skip optimize          # skip system tuning
#    ./alpi-suckless.sh --dry-run                # preview without changes
#    ./alpi-suckless.sh --verify                 # check installation
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — edit these to change repos or paths
# ─────────────────────────────────────────────────────────────────────────────

readonly SUCKLESS_REPO="https://github.com/nirucon/suckless"
readonly LOOKANDFEEL_REPO="https://github.com/nirucon/suckless_lookandfeel"
readonly LOOKANDFEEL_BRANCH="main"
readonly NIRI_CONFIG_REPO="https://github.com/nirucon/niri"

readonly SUCKLESS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/suckless"
readonly LOOKANDFEEL_DIR="$HOME/.cache/alpi/lookandfeel"
readonly NIRI_CONFIG_DIR="$HOME/.cache/alpi/niri-config"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly XINITRC_HOOKS="$HOME/.config/xinitrc.d"
readonly SUCKLESS_PREFIX="/usr/local"

readonly SUCKLESS_COMPONENTS=(dwm st dmenu slock slstatus)

# MatteBlack palette (mirrors dwm config.h)
readonly COL_BG="#0f0f10"
readonly COL_FG="#e5e5e5"
readonly COL_FG_DIM="#a8a8a8"
readonly COL_ACCENT="#3a3a3d"
readonly COL_BORDER="#2a2a2d"
readonly COL_BORDER_SEL="#5a5a60"

# ─────────────────────────────────────────────────────────────────────────────
# PACKAGES
# ─────────────────────────────────────────────────────────────────────────────

PACMAN_CORE=(
    base base-devel git make gcc pkgconf curl wget unzip zip tar rsync
    grep sed findutils coreutils which diffutils gawk
    htop less nano tree imlib2 bash-completion
    networkmanager openssh inetutils bind-tools iproute2
    wireless_tools iw tailscale
    xorg-setxkbmap
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol
    xorg-server xorg-xinit xorg-xsetroot xorg-xrandr xorg-xset xorg-xinput
    ttf-dejavu noto-fonts ttf-nerd-fonts-symbols-mono
    ufw btrfs-progs
)

PACMAN_APPS=(
    feh arandr pcmanfm gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc udisks2 udiskie
    picom rofi
    flameshot maim slop
    alacritty
    dunst libnotify
    lxappearance materia-gtk-theme papirus-icon-theme
    qt5ct kvantum-qt5 qt5-base qt6ct qt6-base
    noto-fonts-emoji
    mpv cmus cava gimp sxiv imagemagick resvg playerctl
    7zip poppler yazi filezilla
    btop fastfetch
    blueman
    xclip brightnessctl bc
    nextcloud-client
    neovim lazygit ripgrep fd fzf jq zoxide
    python-pynvim nodejs npm
    gtk3 gtk4
)

# Wayland / niri packages — all from official repos
PACMAN_NIRI=(
    wayland wayland-protocols xorg-xwayland
    foot                          # terminal — native Wayland, minimal
    waybar                        # status bar
    swaylock                      # screen locker
    swayidle                      # idle management
    swaybg                        # wallpaper setter
    slurp                         # region selector for screenshots
    wl-clipboard                  # clipboard (wl-copy / wl-paste)
    mako                          # notification daemon
    wofi                          # launcher (used in niri config)
    kanshi                        # output/monitor management
    xdg-desktop-portal-gnome      # desktop portal (niri recommended)
    xdg-desktop-portal            # base portal
    qt5-wayland qt6-wayland       # Qt Wayland backends
    libinput                      # input handling
    polkit-gnome                  # polkit agent for Wayland
)

AUR_APPS=(
    ttf-jetbrains-mono-nerd
    brave-bin
    spotify
    xautolock
    localsend-bin
    reversal-icon-theme-git
    fresh-editor-bin
)

# niri via AUR
AUR_NIRI=(
    niri
)

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────

NC="\033[0m"
GRN="\033[1;32m"
RED="\033[1;31m"
YLW="\033[1;33m"
BLU="\033[1;34m"
CYN="\033[1;36m"
MAG="\033[1;35m"

say()  { printf "${BLU}[ALPI]${NC} %s\n" "$*"; }
step() { printf "${MAG}[====]${NC} %s\n" "$*"; }
ok()   { printf "${GRN}[ OK ]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[WARN]${NC} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; }
info() { printf "${CYN}[INFO]${NC} %s\n" "$*"; }
die()  { fail "$@"; exit 1; }

trap 'fail "Aborted at line $LINENO — command: ${BASH_COMMAND:-?}"' ERR

# ─────────────────────────────────────────────────────────────────────────────
# FLAGS
# ─────────────────────────────────────────────────────────────────────────────

DRY_RUN=0
JOBS="$(nproc 2>/dev/null || echo 2)"
ONLY_STEPS=()
SKIP_STEPS=()
DO_VERIFY=0
VARIANT=""

usage() {
    cat <<'EOF'
alpi-suckless.sh — NIRUCON Suckless Edition

USAGE:
  ./alpi-suckless.sh [flags]

FLAGS:
  --variant <x11|niri|both>  Session variant (interactive if omitted)
  --only <list>   Run only these phases (comma-separated)
  --skip <list>   Skip these phases (comma-separated)
  --jobs N        Parallel make jobs (default: nproc)
  --dry-run       Print actions, make no changes
  --verify        Check installation status and exit
  -h|--help       Show this help

PHASES:
  core, suckless, niri, lookandfeel, apps, optimize

VARIANTS:
  x11   — dwm + suckless tools (X11 only)
  niri  — niri + waybar + Wayland stack (foot, swaylock, mako, wofi)
  both  — install everything, interactive session selector at login

EXAMPLES:
  ./alpi-suckless.sh                           # Interactive setup
  ./alpi-suckless.sh --variant x11             # X11 only
  ./alpi-suckless.sh --variant both            # Install everything
  ./alpi-suckless.sh --only suckless           # Rebuild dwm/st/etc
  ./alpi-suckless.sh --only niri               # Reinstall niri stack
  ./alpi-suckless.sh --only lookandfeel        # Refresh dotfiles
  ./alpi-suckless.sh --verify                  # Verify installation
  ./alpi-suckless.sh --dry-run --variant both  # Preview everything
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant) shift; VARIANT="$1"; shift ;;
        --only)    shift; IFS=',' read -r -a ONLY_STEPS <<< "$1"; shift ;;
        --skip)    shift; IFS=',' read -r -a SKIP_STEPS <<< "$1"; shift ;;
        --jobs)    shift; JOBS="$1"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verify)  DO_VERIFY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown flag: $1 (see --help)" ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# VARIANT SELECTOR — whiptail TUI with plain fallback
# ─────────────────────────────────────────────────────────────────────────────

select_variant() {
    if [[ -n "$VARIANT" ]]; then
        case "$VARIANT" in
            x11|niri|both) return ;;
            *) die "Unknown variant '$VARIANT'. Choose: x11, niri, both" ;;
        esac
    fi

    if command -v whiptail >/dev/null 2>&1; then
        local choice
        choice=$(whiptail \
            --title "ALPI — NIRUCON Suckless Edition" \
            --menu "\nChoose your session variant:\n" \
            16 62 3 \
            "x11"   "dwm   · X11 · suckless tools" \
            "niri"  "niri  · Wayland · waybar · foot · swaylock · wofi" \
            "both"  "Both  · Install everything, choose at login" \
            3>&1 1>&2 2>&3) || die "No variant selected — aborting"
        VARIANT="$choice"
    else
        echo ""
        echo "  ╔════════════════════════════════════════════╗"
        echo "  ║     ALPI — NIRUCON Suckless Edition        ║"
        echo "  ╠════════════════════════════════════════════╣"
        echo "  ║  1)  x11   — dwm (X11 + suckless)         ║"
        echo "  ║  2)  niri  — niri (Wayland + waybar)      ║"
        echo "  ║  3)  both  — install everything            ║"
        echo "  ╚════════════════════════════════════════════╝"
        echo ""
        read -r -p "  Your choice [1-3]: " _pick
        case "$_pick" in
            1) VARIANT="x11" ;;
            2) VARIANT="niri" ;;
            3) VARIANT="both" ;;
            *) die "Invalid choice — aborting" ;;
        esac
    fi
    ok "Variant: $VARIANT"
}

want_x11()  { [[ "$VARIANT" == "x11"  || "$VARIANT" == "both" ]]; }
want_niri() { [[ "$VARIANT" == "niri" || "$VARIANT" == "both" ]]; }

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

[[ ${EUID:-$(id -u)} -ne 0 ]] || die "Do not run as root. Run as your normal user."

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        say "[dry-run] $*"
    else
        "$@"
    fi
}

run_sh() {
    if [[ $DRY_RUN -eq 1 ]]; then
        say "[dry-run] $*"
    else
        bash -c "$*"
    fi
}

should_run() {
    local phase="$1"
    if (( ${#ONLY_STEPS[@]} > 0 )); then
        for s in "${ONLY_STEPS[@]}"; do [[ "$s" == "$phase" ]] && return 0; done
        return 1
    fi
    for s in "${SKIP_STEPS[@]}"; do [[ "$s" == "$phase" ]] && return 1; done
    return 0
}

ensure_dir() { mkdir -p "$@"; }

git_sync() {
    local url="$1" dir="$2" branch="${3:-}"
    if [[ -d "$dir/.git" ]]; then
        say "Updating $(basename "$dir")..."
        run git -C "$dir" fetch --all --prune
        if [[ -n "$branch" ]]; then
            run git -C "$dir" checkout "$branch" 2>/dev/null || true
        fi
        run git -C "$dir" pull --ff-only || warn "git pull failed — keeping existing tree"
    else
        ensure_dir "$(dirname "$dir")"
        say "Cloning $(basename "$dir")..."
        if [[ -n "$branch" ]]; then
            run git clone --branch "$branch" "$url" "$dir"
        else
            run git clone "$url" "$dir"
        fi
    fi
}

ensure_yay() {
    if ! command -v yay >/dev/null 2>&1; then
        step "Installing yay (AUR helper)"
        local tmp
        tmp="$(mktemp -d)"
        run git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
        (cd "$tmp/yay-bin" && run makepkg -si --noconfirm)
        rm -rf "$tmp"
        ok "yay installed"
    else
        info "yay already installed"
    fi
}

copy_dir() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || { warn "Source dir not found: $src — skipping"; return 0; }
    ensure_dir "$dst"
    run cp -rf "$src/." "$dst/"
}

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY
# ─────────────────────────────────────────────────────────────────────────────

phase_verify() {
    local failures=0 warnings=0

    chk_cmd() {
        local cmd="$1" label="${2:-$1}"
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$label: $(command -v "$cmd")"
        else
            fail "$label: NOT FOUND"; ((failures++)) || true
        fi
    }
    chk_file() {
        local f="$1" label="${2:-$1}"
        if [[ -f "$f" ]]; then ok "$label"; else fail "$label: NOT FOUND"; ((failures++)) || true; fi
    }
    chk_dir() {
        local d="$1" label="${2:-$1}"
        if [[ -d "$d" ]]; then ok "$label"; else fail "$label: NOT FOUND"; ((failures++)) || true; fi
    }
    chk_svc() {
        local svc="$1"
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            ok "Service $svc: enabled"
        else
            warn "Service $svc: not enabled"; ((warnings++)) || true
        fi
    }
    chk_font() {
        local name="$1"
        if fc-list | grep -qi "$name"; then ok "Font: $name"
        else warn "Font not found: $name"; ((warnings++)) || true; fi
    }

    echo "════════════════════════════════════════"
    echo "  ALPI — Installation Verify"
    echo "════════════════════════════════════════"

    echo; info "X11 — suckless tools"
    for cmd in dwm st dmenu slock slstatus; do chk_cmd "$cmd"; done
    chk_file "$HOME/.xinitrc"                    "~/.xinitrc"
    chk_dir  "$XINITRC_HOOKS"                    "~/.config/xinitrc.d/"

    echo; info "Wayland — niri + tools"
    for cmd in niri waybar foot swaylock swayidle swaybg slurp mako wofi; do
        chk_cmd "$cmd"
    done
    chk_file "$HOME/.config/niri/config.kdl"     "niri config"
    chk_file "$HOME/.config/waybar/config"        "waybar config"
    chk_file "$HOME/.config/waybar/style.css"     "waybar style"
    chk_file "$HOME/.config/foot/foot.ini"        "foot config"
    chk_file "$HOME/.config/wofi/style.css"       "wofi style"
    chk_file "$LOCAL_BIN/start-niri"              "start-niri script"
    chk_file "$LOCAL_BIN/niri-wallpaper.sh"       "niri-wallpaper.sh"
    chk_file "$LOCAL_BIN/niri-wallpaper-rotate.sh" "niri-wallpaper-rotate.sh"

    echo; info "Session selector"
    grep -q "niri\|startx" "$HOME/.bash_profile" 2>/dev/null && \
        ok "~/.bash_profile: session selector present" || \
        warn "~/.bash_profile: no session selector found"

    echo; info "Essential tools"
    for cmd in git make gcc picom rofi feh alacritty nvim; do chk_cmd "$cmd"; done
    chk_cmd tailscale "Tailscale"

    echo; info "Services"
    chk_svc NetworkManager
    chk_svc tailscaled
    chk_svc "systemd-zram-setup@zram0"
    chk_svc paccache.timer
    chk_svc fstrim.timer

    echo; info "Fonts"
    chk_font "JetBrainsMono Nerd"
    chk_font "Symbols Nerd Font"

    echo
    echo "════════════════════════════════════════"
    if (( failures == 0 && warnings == 0 )); then
        ok "All checks passed!"
    elif (( failures == 0 )); then
        warn "Passed with $warnings warning(s)"
    else
        fail "FAILED: $failures error(s), $warnings warning(s)"
        return 1
    fi
    echo "════════════════════════════════════════"
}

[[ $DO_VERIFY -eq 1 ]] && { phase_verify; exit $?; }

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: CORE
# ─────────────────────────────────────────────────────────────────────────────

phase_core() {
    step "PHASE: core — system base"

    say "Syncing & upgrading system..."
    run sudo pacman -Syu --noconfirm

    say "Installing core packages..."
    run sudo pacman -S --needed --noconfirm "${PACMAN_CORE[@]}"

    local fstype
    fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
    if [[ "$fstype" == "btrfs" ]]; then
        say "Btrfs detected — setting up Snapper..."
        run sudo pacman -S --needed --noconfirm snapper snap-pac
        if command -v grub-mkconfig >/dev/null 2>&1; then
            run sudo pacman -S --needed --noconfirm grub-btrfs
        fi
        if [[ ! -d "/.snapshots" ]]; then
            run sudo snapper -c root create-config /
            for pair in \
                "TIMELINE_LIMIT_HOURLY=0" \
                "TIMELINE_LIMIT_DAILY=3" \
                "TIMELINE_LIMIT_WEEKLY=1" \
                "TIMELINE_LIMIT_MONTHLY=0" \
                "TIMELINE_LIMIT_YEARLY=0"
            do
                local key="${pair%%=*}" val="${pair##*=}"
                run sudo sed -i "s/^${key}=.*/${key}=\"${val}\"/" \
                    /etc/snapper/configs/root 2>/dev/null || true
            done
        else
            info "Snapper root config already exists"
        fi
        if command -v grub-mkconfig >/dev/null 2>&1; then
            run sudo systemctl enable --now grub-btrfsd.service 2>/dev/null || true
            run sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || \
                warn "grub-mkconfig failed (non-fatal)"
        fi
        ok "Snapper configured"
    else
        warn "Root is not Btrfs ($fstype) — skipping Snapper"
    fi

    say "Enabling services..."
    run sudo systemctl enable --now NetworkManager
    run sudo systemctl enable --now tailscaled || warn "tailscaled enable failed"
    run sudo systemctl enable --now ufw || true

    if command -v ufw >/dev/null 2>&1; then
        run sudo ufw default deny incoming  || true
        run sudo ufw default allow outgoing || true
        run sudo ufw enable || true
    fi

    ok "Phase core done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: SUCKLESS (X11 — unchanged)
# ─────────────────────────────────────────────────────────────────────────────

phase_suckless() {
    step "PHASE: suckless — build & install (X11)"

    local build_deps=(
        base-devel libx11 libxft libxinerama libxrandr libxext
        libxrender libxfixes freetype2 fontconfig xorg-xsetroot xorg-xinit
    )
    run sudo pacman -S --needed --noconfirm "${build_deps[@]}"

    git_sync "$SUCKLESS_REPO" "$SUCKLESS_DIR"

    for comp in "${SUCKLESS_COMPONENTS[@]}"; do
        if [[ -d "$SUCKLESS_DIR/$comp" ]]; then
            say "Building $comp..."
            if [[ $DRY_RUN -eq 0 ]]; then
                (
                    cd "$SUCKLESS_DIR/$comp"
                    make clean
                    make -j"$JOBS"
                    sudo make PREFIX="$SUCKLESS_PREFIX" install
                )
            else
                say "[dry-run] Would build $comp in $SUCKLESS_DIR/$comp"
            fi
            ok "$comp installed"
        else
            warn "$comp not found in $SUCKLESS_DIR — skipping"
        fi
    done

    ensure_dir "$XINITRC_HOOKS"

    if [[ ! -f "$HOME/.xinitrc" ]]; then
        warn "~/.xinitrc not found — writing minimal bootstrap"
        cat > "$HOME/.xinitrc" <<'XINITEOF'
#!/bin/sh
cd "$HOME"
if [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session "$0" "$@"
fi
[ -r "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"
command -v setxkbmap >/dev/null 2>&1 && setxkbmap se
command -v xsetroot  >/dev/null 2>&1 && xsetroot -solid "#0f0f10"
if [ -d "$HOME/.config/xinitrc.d" ]; then
  for hook in "$HOME/.config/xinitrc.d"/*.sh; do
    [ -x "$hook" ] && . "$hook"
  done
fi
trap 'kill -- -$$' EXIT
while true; do /usr/local/bin/dwm 2>/tmp/dwm.log; done
XINITEOF
        chmod 644 "$HOME/.xinitrc"
    else
        info "~/.xinitrc exists — not touched"
    fi

    say "Writing xinitrc hook 40-suckless.sh..."
    run install -Dm755 /dev/stdin "$XINITRC_HOOKS/40-suckless.sh" <<'HOOK'
#!/bin/sh
if command -v xautolock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1; then
    xautolock -time 10 -locker slock &
fi
HOOK

    ok "Phase suckless done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: NIRI — niri via AUR + waybar + full wayland stack
# Configs cloned from https://github.com/nirucon/niri
# ─────────────────────────────────────────────────────────────────────────────

phase_niri() {
    step "PHASE: niri — niri + waybar + wayland stack"

    # Install Wayland packages from official repos
    say "Installing Wayland packages from official repos..."
    run sudo pacman -S --needed --noconfirm "${PACMAN_NIRI[@]}"

    # Add user to input and video groups (needed for niri with logind)
    run sudo usermod -aG input,video "$USER"
    ok "User added to input/video groups"

    # Install niri via AUR
    ensure_yay
    say "Installing niri via AUR..."
    run yay -S --needed --noconfirm "${AUR_NIRI[@]}"
    ok "niri installed"

    # Enable pipewire as user service
    run systemctl --user enable --now pipewire pipewire-pulse wireplumber 2>/dev/null || \
        warn "pipewire user service enable failed (non-fatal)"

    # Enable polkit agent — needed for privilege escalation in Wayland sessions
    say "Enabling polkit-gnome autostart..."
    ensure_dir "$HOME/.config/autostart"
    if [[ $DRY_RUN -eq 0 ]]; then
        cat > "$HOME/.config/autostart/polkit-gnome.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PolicyKit Authentication Agent
Exec=/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
NoDisplay=true
X-GNOME-AutoRestart=false
EOF
    fi

    # Clone niri config repo
    say "Cloning niri config repo..."
    git_sync "$NIRI_CONFIG_REPO" "$NIRI_CONFIG_DIR"

    local nc="$NIRI_CONFIG_DIR"

    if [[ $DRY_RUN -eq 0 ]]; then
        # ── niri config ───────────────────────────────────────────────────────
        say "Deploying niri/config.kdl → ~/.config/niri/config.kdl..."
        if [[ -f "$nc/niri/config.kdl" ]]; then
            ensure_dir "$HOME/.config/niri"
            run install -Dm644 "$nc/niri/config.kdl" "$HOME/.config/niri/config.kdl"
            ok "~/.config/niri/config.kdl"
        else
            warn "niri/config.kdl not found in repo — skipping"
        fi

        # ── waybar config + style ─────────────────────────────────────────────
        say "Deploying waybar config..."
        ensure_dir "$HOME/.config/waybar/scripts"
        if [[ -f "$nc/waybar/config" ]]; then
            run install -Dm644 "$nc/waybar/config" "$HOME/.config/waybar/config"
            ok "~/.config/waybar/config"
        else
            warn "waybar/config not found in repo — skipping"
        fi
        if [[ -f "$nc/waybar/style.css" ]]; then
            run install -Dm644 "$nc/waybar/style.css" "$HOME/.config/waybar/style.css"
            ok "~/.config/waybar/style.css"
        else
            warn "waybar/style.css not found in repo — skipping"
        fi

        # ── waybar scripts (make executable) ─────────────────────────────────
        if [[ -d "$nc/waybar/scripts" ]]; then
            say "Deploying waybar scripts..."
            for script in "$nc/waybar/scripts/"*.sh; do
                [[ -f "$script" ]] || continue
                run install -Dm755 "$script" "$HOME/.config/waybar/scripts/$(basename "$script")"
                ok "~/.config/waybar/scripts/$(basename "$script")"
            done
        else
            warn "waybar/scripts not found in repo — skipping"
        fi

        # ── foot config ───────────────────────────────────────────────────────
        say "Deploying foot config..."
        if [[ -f "$nc/foot/foot.ini" ]]; then
            ensure_dir "$HOME/.config/foot"
            run install -Dm644 "$nc/foot/foot.ini" "$HOME/.config/foot/foot.ini"
            ok "~/.config/foot/foot.ini"
        else
            warn "foot/foot.ini not found in repo — skipping"
        fi

        # ── wofi config ───────────────────────────────────────────────────────
        say "Deploying wofi config..."
        if [[ -f "$nc/wofi/style.css" ]]; then
            ensure_dir "$HOME/.config/wofi"
            run install -Dm644 "$nc/wofi/style.css" "$HOME/.config/wofi/style.css"
            ok "~/.config/wofi/style.css"
        else
            warn "wofi/style.css not found in repo — skipping"
        fi

        # ── environment.d ─────────────────────────────────────────────────────
        say "Deploying environment.d config..."
        if [[ -f "$nc/environment.d/10-theme.conf" ]]; then
            ensure_dir "$HOME/.config/environment.d"
            run install -Dm644 "$nc/environment.d/10-theme.conf" \
                "$HOME/.config/environment.d/10-theme.conf"
            ok "~/.config/environment.d/10-theme.conf"
        else
            warn "environment.d/10-theme.conf not found in repo — skipping"
        fi

        # ── local/bin scripts (make executable) ───────────────────────────────
        say "Deploying local/bin scripts..."
        ensure_dir "$LOCAL_BIN"
        if [[ -d "$nc/local/bin" ]]; then
            for f in "$nc/local/bin/"*; do
                [[ -f "$f" ]] || continue
                run install -Dm755 "$f" "$LOCAL_BIN/$(basename "$f")"
                ok "~/.local/bin/$(basename "$f")"
            done
        else
            warn "local/bin not found in repo — skipping"
        fi
    else
        say "[dry-run] Would deploy niri configs from $NIRI_CONFIG_DIR"
    fi

    # ── Wayland environment variables ─────────────────────────────────────────
    say "Setting Wayland environment variables in ~/.bash_profile..."
    local profile="$HOME/.bash_profile"
    [[ -f "$profile" ]] || touch "$profile"
    grep -qxF 'export XDG_SESSION_TYPE=wayland'  "$profile" || echo 'export XDG_SESSION_TYPE=wayland'  >> "$profile"
    grep -qxF 'export MOZ_ENABLE_WAYLAND=1'      "$profile" || echo 'export MOZ_ENABLE_WAYLAND=1'      >> "$profile"
    grep -qxF 'export QT_QPA_PLATFORM=wayland'   "$profile" || echo 'export QT_QPA_PLATFORM=wayland'   >> "$profile"
    grep -qxF 'export ELECTRON_OZONE_PLATFORM_HINT=wayland' "$profile" || \
        echo 'export ELECTRON_OZONE_PLATFORM_HINT=wayland' >> "$profile"

    ok "Phase niri done"
    warn "IMPORTANT: Log out and back in for group changes to take effect (input/video)"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: LOOKANDFEEL
# ─────────────────────────────────────────────────────────────────────────────

phase_lookandfeel() {
    step "PHASE: lookandfeel — dotfiles, configs, scripts"

    ensure_dir "$LOOKANDFEEL_DIR"
    ensure_dir "$LOCAL_BIN"
    ensure_dir "$XINITRC_HOOKS"

    git_sync "$LOOKANDFEEL_REPO" "$LOOKANDFEEL_DIR" "$LOOKANDFEEL_BRANCH"

    local lf="$LOOKANDFEEL_DIR"

    # ── dotfiles → $HOME ──────────────────────────────────────────────────────
    say "Deploying dotfiles..."
    for f in .xinitrc .bashrc .bash_aliases .inputrc .Xresources; do
        if [[ -f "$lf/dotfiles/$f" ]]; then
            if [[ -f "$HOME/$f" ]] && ! diff -q "$HOME/$f" "$lf/dotfiles/$f" >/dev/null 2>&1; then
                run cp "$HOME/$f" "$HOME/${f}.bak.$(date +%Y%m%d)"
                say "Backed up ~/$f"
            fi
            run install -Dm644 "$lf/dotfiles/$f" "$HOME/$f"
            ok "~/$f"
        else
            warn "dotfiles/$f not found in repo — skipping"
        fi
    done

    # ── config → ~/.config ────────────────────────────────────────────────────
    say "Deploying config files..."
    for d in alacritty cmus dunst gtk-3.0 picom rofi; do
        if [[ -d "$lf/config/$d" ]]; then
            ensure_dir "$HOME/.config/$d"
            copy_dir "$lf/config/$d" "$HOME/.config/$d"
            ok "~/.config/$d/"
        else
            warn "config/$d not found in repo — skipping"
        fi
    done

    # ── local/bin → ~/.local/bin ──────────────────────────────────────────────
    say "Deploying scripts to ~/.local/bin..."
    if [[ -d "$lf/local/bin" ]]; then
        for script in "$lf/local/bin/"*.sh; do
            [[ -f "$script" ]] || continue
            run install -Dm755 "$script" "$LOCAL_BIN/$(basename "$script")"
            ok "~/.local/bin/$(basename "$script")"
        done
    else
        warn "local/bin not found in repo — skipping"
    fi

    # ── local/share → ~/.local/share ─────────────────────────────────────────
    if [[ -d "$lf/local/share" ]]; then
        say "Deploying local/share..."
        copy_dir "$lf/local/share" "$HOME/.local/share"
        ok "~/.local/share/"
    fi

    # ── PATH and editor exports ───────────────────────────────────────────────
    local profile="$HOME/.bash_profile"
    [[ -f "$profile" ]] || touch "$profile"
    grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$profile" || \
        run_sh "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> \"$profile\""
    grep -qxF 'export EDITOR=nvim' "$profile" || \
        run_sh "echo 'export EDITOR=nvim' >> \"$profile\""
    grep -qxF 'export VISUAL=nvim' "$profile" || \
        run_sh "echo 'export VISUAL=nvim' >> \"$profile\""

    # ── Session selector ──────────────────────────────────────────────────────
    say "Writing session selector to ~/.bash_profile..."
    if [[ $DRY_RUN -eq 0 ]]; then
        sed -i '/# >>> ALPI SESSION SELECTOR/,/# <<< ALPI SESSION SELECTOR/d' "$profile"

        if [[ "$VARIANT" == "both" ]]; then
            cat >> "$profile" <<'SELECTOR'

# >>> ALPI SESSION SELECTOR — managed by alpi-suckless.sh
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │      NIRUCON — Choose your session       │"
    echo "  ├──────────────────────────────────────────┤"
    echo "  │   1)  dwm  ·  X11     (suckless)        │"
    echo "  │   2)  niri ·  Wayland (waybar + foot)   │"
    echo "  │   3)  exit ·  Shell prompt only          │"
    echo "  └──────────────────────────────────────────┘"
    echo ""
    read -r -p "  Session [1/2/3, Enter = dwm]: " _ses
    case "$_ses" in
        2) exec "$HOME/.local/bin/start-niri" ;;
        3) : ;;
        *) exec startx ;;
    esac
fi
# <<< ALPI SESSION SELECTOR
SELECTOR

        elif [[ "$VARIANT" == "x11" ]]; then
            cat >> "$profile" <<'SELECTOR'

# >>> ALPI SESSION SELECTOR — managed by alpi-suckless.sh
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │      NIRUCON — Choose your session       │"
    echo "  ├──────────────────────────────────────────┤"
    echo "  │   1)  dwm  ·  X11 (suckless)            │"
    echo "  │   2)  exit ·  Shell prompt only          │"
    echo "  └──────────────────────────────────────────┘"
    echo ""
    read -r -p "  Session [1/2, Enter = dwm]: " _ses
    case "$_ses" in
        2) : ;;
        *) exec startx ;;
    esac
fi
# <<< ALPI SESSION SELECTOR
SELECTOR

        elif [[ "$VARIANT" == "niri" ]]; then
            cat >> "$profile" <<'SELECTOR'

# >>> ALPI SESSION SELECTOR — managed by alpi-suckless.sh
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │      NIRUCON — Choose your session       │"
    echo "  ├──────────────────────────────────────────┤"
    echo "  │   1)  niri ·  Wayland (waybar + foot)   │"
    echo "  │   2)  exit ·  Shell prompt only          │"
    echo "  └──────────────────────────────────────────┘"
    echo ""
    read -r -p "  Session [1/2, Enter = niri]: " _ses
    case "$_ses" in
        2) : ;;
        *) exec "$HOME/.local/bin/start-niri" ;;
    esac
fi
# <<< ALPI SESSION SELECTOR
SELECTOR
        fi

        ok "~/.bash_profile: session selector written ($VARIANT)"
    else
        say "[dry-run] Would write session selector ($VARIANT) to ~/.bash_profile"
    fi

    # ── X11 xinitrc hooks ────────────────────────────────────────────────────
    if want_x11; then
        say "Writing xinitrc hook 20-lookandfeel.sh..."
        run install -Dm755 /dev/stdin "$XINITRC_HOOKS/20-lookandfeel.sh" <<'HOOK'
#!/bin/sh
command -v picom >/dev/null 2>&1 && picom --config "$HOME/.config/picom/picom.conf" --daemon
if [ -x "$HOME/.local/bin/wallrotate.sh" ]; then
    "$HOME/.local/bin/wallrotate.sh" &
elif command -v feh >/dev/null 2>&1 && [ -d "$HOME/Wallpapers" ]; then
    feh --randomize --bg-fill "$HOME/Wallpapers" &
fi
command -v dunst >/dev/null 2>&1 && dunst &
command -v blueman-applet >/dev/null 2>&1 && blueman-applet &
command -v udiskie >/dev/null 2>&1 && udiskie --tray &
command -v nextcloud >/dev/null 2>&1 && nextcloud --background &
HOOK

        say "Writing xinitrc hook 30-statusbar.sh..."
        run install -Dm755 /dev/stdin "$XINITRC_HOOKS/30-statusbar.sh" <<'HOOK'
#!/bin/sh
[ -x "$HOME/.local/bin/dwm-status.sh" ] && "$HOME/.local/bin/dwm-status.sh" &
HOOK
    fi

    ok "Phase lookandfeel done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: APPS
# ─────────────────────────────────────────────────────────────────────────────

phase_apps() {
    step "PHASE: apps — desktop & dev tools"

    say "Installing pacman packages (${#PACMAN_APPS[@]} total)..."
    run sudo pacman -S --needed --noconfirm "${PACMAN_APPS[@]}"

    ensure_yay
    say "Installing AUR packages (${#AUR_APPS[@]} total)..."
    run yay -S --needed --noconfirm "${AUR_APPS[@]}"

    local nvim_dir="$HOME/.config/nvim"
    if command -v nvim >/dev/null 2>&1 && [[ ! -d "$nvim_dir" ]]; then
        step "Bootstrapping LazyVim..."
        run git clone --depth=1 https://github.com/LazyVim/starter "$nvim_dir"
        (cd "$nvim_dir" && run rm -rf .git)
        run nvim --headless "+Lazy! sync" +qa || true
        ok "LazyVim installed"
    elif [[ -d "$nvim_dir" ]]; then
        info "Neovim config exists — leaving as-is"
    fi

    ok "Phase apps done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: OPTIMIZE
# ─────────────────────────────────────────────────────────────────────────────

phase_optimize() {
    step "PHASE: optimize — system tuning"

    local cores
    cores="$(nproc)"

    local vendor
    vendor="$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2}' || echo unknown)"
    case "$vendor" in
        *Intel*) run sudo pacman -S --needed --noconfirm intel-ucode ;;
        *AMD*)   run sudo pacman -S --needed --noconfirm amd-ucode ;;
        *)       warn "Unknown CPU vendor '$vendor' — skipping microcode" ;;
    esac
    run sudo pacman -S --needed --noconfirm linux-firmware

    run sudo pacman -S --needed --noconfirm zram-generator
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo mkdir -p /etc/systemd/zram-generator.conf.d
        sudo tee /etc/systemd/zram-generator.conf.d/90-alpi.conf >/dev/null <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
    else
        say "[dry-run] Would write zram config"
    fi
    run sudo systemctl enable --now systemd-zram-setup@zram0.service || true

    if [[ $DRY_RUN -eq 0 ]]; then
        sudo mkdir -p /etc/systemd/journald.conf.d
        sudo tee /etc/systemd/journald.conf.d/90-alpi.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
RuntimeMaxUse=200M
MaxRetentionSec=1month
RateLimitIntervalSec=30s
RateLimitBurst=1000
EOF
        sudo systemctl restart systemd-journald
    else
        say "[dry-run] Would write journald config"
    fi

    local qdisc="fq"
    tc qdisc show 2>/dev/null | grep -q cake && qdisc="cake" || true
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo tee /etc/sysctl.d/90-alpi.conf >/dev/null <<EOF
vm.swappiness = 60
vm.vfs_cache_pressure = 50
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
        sudo sysctl --system >/dev/null
    else
        say "[dry-run] Would write sysctl config"
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        sudo sed -E -i 's/^#?Color$/Color/'                      /etc/pacman.conf
        sudo sed -E -i 's/^#?VerbosePkgLists$/VerbosePkgLists/'  /etc/pacman.conf
        sudo sed -E -i 's/^#?ParallelDownloads *= *.*/ParallelDownloads = 10/' \
            /etc/pacman.conf || \
            run_sh "echo 'ParallelDownloads = 10' | sudo tee -a /etc/pacman.conf"
        sudo sed -E -i "s|^#?MAKEFLAGS=.*|MAKEFLAGS=\"-j${cores}\"|" /etc/makepkg.conf
        sudo sed -E -i 's|^#?COMPRESSXZ=.*|COMPRESSXZ=(xz -c -T0 -z -)|'        /etc/makepkg.conf
        sudo sed -E -i 's|^#?COMPRESSZST=.*|COMPRESSZST=(zstd -c -T0 -z -q -19 -)|' /etc/makepkg.conf
    else
        say "[dry-run] Would tune pacman.conf and makepkg.conf"
    fi

    run sudo pacman -S --needed --noconfirm pacman-contrib util-linux
    run sudo systemctl enable --now paccache.timer
    run sudo systemctl enable --now fstrim.timer

    if [[ $DRY_RUN -eq 0 ]]; then
        sudo mkdir -p /etc/systemd/oomd.conf.d
        sudo tee /etc/systemd/oomd.conf.d/90-alpi.conf >/dev/null <<'EOF'
[OOM]
DefaultMemoryPressureDurationSec=2min
DefaultMemoryPressureThreshold=70%
EOF
    fi
    run sudo systemctl enable --now systemd-oomd.service || true

    ok "Phase optimize done — reboot recommended"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    select_variant

    echo
    say "════════════════════════════════════════"
    say "  ALPI-SUCKLESS — NIRUCON Edition"
    say "  User:    $USER"
    say "  Variant: $VARIANT"
    say "  Jobs:    $JOBS"
    say "  Dry-run: $DRY_RUN"
    (( ${#ONLY_STEPS[@]} > 0 )) && say "  Only:    ${ONLY_STEPS[*]}"
    (( ${#SKIP_STEPS[@]}  > 0 )) && say "  Skip:    ${SKIP_STEPS[*]}"
    say "════════════════════════════════════════"
    echo

    should_run core        && phase_core

    if should_run suckless; then
        want_x11 && phase_suckless || info "Skipping suckless (variant: $VARIANT)"
    fi

    if should_run niri; then
        want_niri && phase_niri || info "Skipping niri (variant: $VARIANT)"
    fi

    should_run lookandfeel && phase_lookandfeel
    should_run apps        && phase_apps
    should_run optimize    && phase_optimize

    echo
    say "════════════════════════════════════════"
    ok  "All selected phases completed!"
    say "  → Reboot to apply all changes"
    if want_x11;  then say "  → X11:     startx (via session selector)"; fi
    if want_niri; then say "  → Wayland: ~/.local/bin/start-niri"; fi
    say "  → Verify:  ./alpi-suckless.sh --verify"
    say "════════════════════════════════════════"
    echo
    if want_niri; then
        warn "IMPORTANT: Log out and back in before starting niri"
        warn "           (group changes for input/video need a fresh login)"
    fi
}

main

#!/usr/bin/env bash
# =============================================================================
#  alpi-suckless.sh — Arch Linux Post Install (NIRUCON Suckless Edition)
#  Author: Nicklas Rudolfsson (nirucon)
#
#  Supports two session variants:
#    x11     — dwm + suckless-stack (unchanged from original)
#    wayland — dwl + somebar + wayland-stack (foot, swaylock, grim, mako…)
#    both    — install everything, choose at login
#
#  Phases (run in order):
#    core        — upgrade system, btrfs/snapper, base packages, services
#    suckless    — clone/build dwm, st, dmenu, slock, slstatus  [x11/both]
#    wayland     — clone/build dwl, somebar                     [wayland/both]
#    lookandfeel — clone dotfiles/configs/scripts from lookandfeel repo
#    apps        — pacman + AUR packages
#    optimize    — zram, sysctl, journald, pacman, makepkg tuning
#
#  Usage:
#    ./alpi-suckless.sh                          # interactive variant selector
#    ./alpi-suckless.sh --variant x11            # X11 only (dwm)
#    ./alpi-suckless.sh --variant wayland        # Wayland only (dwl)
#    ./alpi-suckless.sh --variant both           # install both
#    ./alpi-suckless.sh --only suckless          # rebuild suckless only
#    ./alpi-suckless.sh --only wayland           # rebuild dwl/somebar only
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

# dwl source — official repo, build from source via AUR helper
readonly DWL_REPO="https://codeberg.org/dwl/dwl"
readonly SOMEBAR_REPO="https://git.sr.ht/~raphi/somebar"

readonly SUCKLESS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/suckless"
readonly WAYLAND_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wayland-wm"
readonly LOOKANDFEEL_DIR="$HOME/.cache/alpi/lookandfeel"
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

# Wayland-specific packages (replaces/supplements X11 equivalents)
PACMAN_WAYLAND=(
    wayland wayland-protocols xorg-xwayland
    foot                   # terminal (native Wayland)
    swaylock               # screen locker (replaces slock)
    swayidle               # idle management (replaces xautolock)
    swaybg                 # wallpaper setter (replaces feh --bg)
    grim                   # screenshot tool (replaces maim)
    slurp                  # region selector (replaces slop)
    wl-clipboard           # clipboard (replaces xclip)
    mako                   # notification daemon (replaces dunst for Wayland)
    kanshi                 # output management (replaces arandr/xrandr)
    xdg-desktop-portal-wlr # desktop portal for Wayland
    qt5-wayland qt6-wayland
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

AUR_WAYLAND=(
    rofi-wayland           # rofi with Wayland backend
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
VARIANT=""   # set interactively or via --variant

usage() {
    cat <<'EOF'
alpi-suckless.sh — NIRUCON Suckless Edition

USAGE:
  ./alpi-suckless.sh [flags]

FLAGS:
  --variant <x11|wayland|both>  Session variant (interactive if omitted)
  --only <list>   Run only these phases (comma-separated)
  --skip <list>   Skip these phases (comma-separated)
  --jobs N        Parallel make jobs (default: nproc)
  --dry-run       Print actions, make no changes
  --verify        Check installation status and exit
  -h|--help       Show this help

PHASES:
  core, suckless, wayland, lookandfeel, apps, optimize

VARIANTS:
  x11     — dwm + suckless tools (X11 only)
  wayland — dwl + somebar + Wayland stack
  both    — install everything, interactive session selector at login

EXAMPLES:
  ./alpi-suckless.sh                           # Interactive setup
  ./alpi-suckless.sh --variant x11             # X11 only
  ./alpi-suckless.sh --variant both            # Install everything
  ./alpi-suckless.sh --only suckless           # Rebuild dwm/st/etc
  ./alpi-suckless.sh --only wayland            # Rebuild dwl/somebar
  ./alpi-suckless.sh --only lookandfeel        # Refresh dotfiles
  ./alpi-suckless.sh --verify                  # Verify installation
  ./alpi-suckless.sh --dry-run                 # Preview everything
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
# VARIANT SELECTOR — whiptail TUI with fallback to plain read
# ─────────────────────────────────────────────────────────────────────────────

select_variant() {
    # If already set via flag, validate and return
    if [[ -n "$VARIANT" ]]; then
        case "$VARIANT" in
            x11|wayland|both) return ;;
            *) die "Unknown variant '$VARIANT'. Choose: x11, wayland, both" ;;
        esac
    fi

    if command -v whiptail >/dev/null 2>&1; then
        local choice
        choice=$(whiptail \
            --title "ALPI — NIRUCON Suckless Edition" \
            --menu "\nChoose your session variant:\n" \
            16 60 3 \
            "x11"     "dwm  ·  X11 · suckless tools (current setup)" \
            "wayland" "dwl  ·  Wayland · somebar · foot · swaylock" \
            "both"    "Both ·  Install everything, choose at login" \
            3>&1 1>&2 2>&3) || die "No variant selected — aborting"
        VARIANT="$choice"
    else
        # Plain fallback
        echo ""
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║   ALPI — NIRUCON Suckless Edition        ║"
        echo "  ╠══════════════════════════════════════════╣"
        echo "  ║  1) x11     — dwm (X11 + suckless)      ║"
        echo "  ║  2) wayland — dwl (Wayland + somebar)   ║"
        echo "  ║  3) both    — install everything         ║"
        echo "  ╚══════════════════════════════════════════╝"
        echo ""
        read -r -p "  Your choice [1-3]: " _pick
        case "$_pick" in
            1) VARIANT="x11" ;;
            2) VARIANT="wayland" ;;
            3) VARIANT="both" ;;
            *) die "Invalid choice — aborting" ;;
        esac
    fi
    ok "Variant: $VARIANT"
}

# Helpers to check variant
want_x11()     { [[ "$VARIANT" == "x11"     || "$VARIANT" == "both" ]]; }
want_wayland() { [[ "$VARIANT" == "wayland" || "$VARIANT" == "both" ]]; }

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

install_file() {
    local src="$1" dst="$2" mode="${3:-644}"
    if [[ ! -f "$src" ]]; then
        warn "Source not found: $src — skipping"
        return 0
    fi
    run install -Dm"$mode" "$src" "$dst"
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

    echo; info "X11 suckless tools"
    for cmd in dwm st dmenu slock slstatus; do chk_cmd "$cmd"; done
    chk_file "$HOME/.xinitrc" "~/.xinitrc"
    chk_dir  "$XINITRC_HOOKS" "~/.config/xinitrc.d/"
    chk_file "$XINITRC_HOOKS/20-lookandfeel.sh" "hook: 20-lookandfeel.sh"
    chk_file "$XINITRC_HOOKS/30-statusbar.sh"   "hook: 30-statusbar.sh"
    chk_file "$XINITRC_HOOKS/40-suckless.sh"    "hook: 40-suckless.sh"

    echo; info "Wayland tools"
    for cmd in dwl somebar foot swaylock swayidle swaybg grim slurp mako kanshi; do
        chk_cmd "$cmd"
    done
    chk_file "$HOME/.config/dwl/autostart.sh"    "dwl autostart script"
    chk_file "$HOME/.config/somebar/config.def.h" "somebar config"
    chk_file "$LOCAL_BIN/dwl-wallrotate.sh"       "dwl-wallrotate.sh"

    echo; info "Session selector"
    grep -q "dwl\|startx" "$HOME/.bash_profile" 2>/dev/null && \
        ok "~/.bash_profile: session selector present" || \
        warn "~/.bash_profile: no session selector found"

    echo; info "Essential tools"
    for cmd in git make gcc picom rofi feh alacritty nvim; do chk_cmd "$cmd"; done
    chk_cmd tailscale "Tailscale"

    echo; info "Suckless sources"
    for c in dwm st dmenu; do chk_dir "$SUCKLESS_DIR/$c" "source: $c"; done

    echo; info "Scripts"
    chk_file "$LOCAL_BIN/dwm-status.sh"       "dwm-status.sh"
    chk_file "$LOCAL_BIN/wallrotate.sh"        "wallrotate.sh"
    chk_file "$LOCAL_BIN/screenshot-select.sh" "screenshot-select.sh"

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
        warn "Passed with $warnings warning(s) — should work fine"
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
        ok "Snapper configured (3 daily, 1 weekly snapshots)"
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
# Minimal bootstrap — replace by running: ./alpi-suckless.sh --only lookandfeel
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
# Suckless hook — xautolock screen locker
if command -v xautolock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1; then
    xautolock -time 10 -locker slock &
fi
HOOK

    ok "Phase suckless done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: WAYLAND — dwl + somebar + full wayland stack
# ─────────────────────────────────────────────────────────────────────────────

phase_wayland() {
    step "PHASE: wayland — build & install (dwl + somebar)"

    # Wayland build dependencies
    local build_deps=(
        base-devel wayland wayland-protocols wlroots libinput
        libxkbcommon pixman xorg-xwayland
        cairo pango
    )
    run sudo pacman -S --needed --noconfirm "${build_deps[@]}"
    run sudo pacman -S --needed --noconfirm "${PACMAN_WAYLAND[@]}"

    ensure_yay
    run yay -S --needed --noconfirm "${AUR_WAYLAND[@]}"

    # ── Build dwl ─────────────────────────────────────────────────────────────
    local dwl_dir="$WAYLAND_DIR/dwl"
    git_sync "$DWL_REPO" "$dwl_dir"

    # Write dwl config.def.h mirroring dwm config.h (MatteBlack, same keybindings)
    say "Writing dwl config.def.h (MatteBlack theme, matched keybindings)..."
    if [[ $DRY_RUN -eq 0 ]]; then
        cat > "$dwl_dir/config.def.h" <<DWLCONF
/* dwl config — NIRUCON MatteBlack theme
 * Keybindings mirror dwm config.h as closely as Wayland allows.
 * Mod = Super (Mod4)
 */

/* appearance */
static const int sloppyfocus        = 1;  /* focus follows mouse */
static const int bypass_surface_visibility = 0;
static const unsigned int borderpx  = 2;
static const float rootcolor[]      = {0.059, 0.059, 0.063, 1.0};  /* #0f0f10 */
static const float bordercolor[]    = {0.165, 0.165, 0.176, 1.0};  /* #2a2a2d */
static const float focuscolor[]     = {0.353, 0.353, 0.376, 1.0};  /* #5a5a60 */
static const float urgentcolor[]    = {0.8,   0.2,   0.2,   1.0};

/* tagging — same as dwm */
static const char *tags[] = { "1","2","3","4","5","6","7","8","9" };

static const Rule rules[] = {
    /* app_id         title       tags mask  isfloating  monitor */
    { "gimp",         NULL,       0,         1,          -1 },
    { "pavucontrol",  NULL,       0,         1,          -1 },
    { "lxappearance", NULL,       0,         1,          -1 },
};

/* layout(s) — tile and monocle available natively in dwl */
static const Layout layouts[] = {
    { "[]=",  tile },    /* 0 — tile (default) */
    { "[M]",  monocle }, /* 1 — monocle */
    { "><>",  NULL },    /* 2 — floating */
};

/* monitors */
static const MonitorRule monrules[] = {
    { NULL, NULL, 0, 1, 0, WL_OUTPUT_TRANSFORM_NORMAL, -1, -1 },
};

/* keyboard */
static const struct xkb_rule_names xkb_rules = {
    .rules   = NULL,
    .model   = NULL,
    .layout  = "se",     /* Swedish layout — same as setxkbmap se */
    .variant = NULL,
    .options = "caps:escape",
};

static const int repeat_rate = 25;
static const int repeat_delay = 300;

/* cursor */
static const unsigned int cursor_timeout = 0;

#define MODKEY WLR_MODIFIER_LOGO  /* Super key */
#define TAGKEYS(KEY,SKEY,TAG) \
    { MODKEY,                  KEY,  view,        {.ui = 1 << TAG} }, \
    { MODKEY|WLR_MODIFIER_CTRL,KEY,  toggleview,  {.ui = 1 << TAG} }, \
    { MODKEY|WLR_MODIFIER_SHIFT,SKEY,tag,         {.ui = 1 << TAG} }, \
    { MODKEY|WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT,SKEY,toggletag,{.ui=1<<TAG}},

/* helper macros */
#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

/* commands */
static const char *footcmd[]      = { "foot", NULL };
static const char *alacrittycmd[] = { "alacritty", NULL };
static const char *bravecmd[]     = { "brave", NULL };
static const char *lockcmd[]      = { "swaylock", "-f",
                                       "--color", "0f0f10",
                                       "--inside-color", "0f0f10",
                                       "--ring-color", "3a3a3d",
                                       "--key-hl-color", "e5e5e5",
                                       NULL };
static const char *fmcmd[]        = { "pcmanfm", NULL };
static const char *roficmd[]      = { "rofi", "-show", "run", NULL };
static const char *wallnext[]     = { "/bin/sh", "-c",
                                       "\$HOME/.local/bin/dwl-wallrotate.sh next", NULL };

/* volume — PipeWire/wpctl (same as dwm) */
static const char *vol_up[]     = { "wpctl","set-volume","@DEFAULT_AUDIO_SINK@","5%+",NULL };
static const char *vol_down[]   = { "wpctl","set-volume","@DEFAULT_AUDIO_SINK@","5%-",NULL };
static const char *vol_toggle[] = { "wpctl","set-mute","@DEFAULT_AUDIO_SINK@","toggle",NULL };
static const char *mic_toggle[] = { "wpctl","set-mute","@DEFAULT_AUDIO_SOURCE@","toggle",NULL };

/* media — playerctl (same as dwm) */
static const char *media_play[] = { "playerctl","play-pause",NULL };
static const char *media_next[] = { "playerctl","next",NULL };
static const char *media_prev[] = { "playerctl","previous",NULL };

/* brightness */
static const char *br_up[]   = { "brightnessctl","set","+5%",NULL };
static const char *br_down[] = { "brightnessctl","set","5%-",NULL };

/* screenshots — grim + slurp (Wayland equivalents of maim/slop) */
static const char *ss_select[] = { "/bin/sh","-c",
    "grim -g \"\$(slurp)\" \$HOME/Pictures/Screenshots/\$(date +%F_%H-%M-%S).png && "
    "wl-copy < \$(ls -t \$HOME/Pictures/Screenshots/*.png | head -1) && "
    "notify-send 'Screenshot' 'Saved & copied'",
    NULL };
static const char *ss_full[] = { "/bin/sh","-c",
    "grim \$HOME/Pictures/Screenshots/\$(date +%F_%H-%M-%S).png && "
    "wl-copy < \$(ls -t \$HOME/Pictures/Screenshots/*.png | head -1) && "
    "notify-send 'Screenshot' 'Full screen saved & copied'",
    NULL };

static const Key keys[] = {
    /* Launchers */
    { MODKEY,                   XKB_KEY_Return,     spawn,          {.v = footcmd} },       /* Super+Enter → foot */
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_Return,     spawn,          {.v = alacrittycmd} },  /* Super+Shift+Enter → alacritty */
    { MODKEY,                   XKB_KEY_b,          spawn,          {.v = bravecmd} },       /* Super+b → Brave */
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_p,          spawn,          {.v = roficmd} },        /* Super+Shift+p → rofi */
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_f,          spawn,          {.v = fmcmd} },          /* Super+Shift+f → pcmanfm */

    /* System / security */
    { MODKEY,                   XKB_KEY_Escape,     spawn,          {.v = lockcmd} },        /* Super+Esc → swaylock */
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_Escape,     spawn, SHCMD("systemctl suspend") },    /* Super+Shift+Esc → suspend */

    /* Wallpaper */
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_w,          spawn,          {.v = wallnext} },       /* Super+Shift+w → next wallpaper */

    /* Window / layout control — identical to dwm */
    { MODKEY,                   XKB_KEY_j,          focusstack,     {.i = +1} },
    { MODKEY,                   XKB_KEY_k,          focusstack,     {.i = -1} },
    { MODKEY,                   XKB_KEY_h,          setmfact,       {.f = -0.05} },
    { MODKEY,                   XKB_KEY_l,          setmfact,       {.f = +0.05} },
    { MODKEY,                   XKB_KEY_i,          incnmaster,     {.i = +1} },
    { MODKEY,                   XKB_KEY_d,          incnmaster,     {.i = -1} },
    { MODKEY,                   XKB_KEY_Tab,        view,           {0} },
    { MODKEY,                   XKB_KEY_space,      setlayout,      {0} },
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_space,      togglefloating, {0} },

    /* Layout selection */
    { MODKEY,                   XKB_KEY_t,          setlayout,      {.v = &layouts[0]} },   /* tile */
    { MODKEY,                   XKB_KEY_m,          setlayout,      {.v = &layouts[1]} },   /* monocle */
    { MODKEY,                   XKB_KEY_f,          setlayout,      {.v = &layouts[2]} },   /* floating */

    /* Bar toggle */
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_b,          togglebar,      {0} },

    /* Kill / quit */
    { MODKEY,                   XKB_KEY_q,          killclient,     {0} },                   /* Super+q → kill */
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_q,          quit,           {0} },                   /* Super+Shift+q → quit dwl */

    /* Tags 1–9 — same as dwm */
    TAGKEYS(XKB_KEY_1, XKB_KEY_exclam,     0)
    TAGKEYS(XKB_KEY_2, XKB_KEY_at,         1)
    TAGKEYS(XKB_KEY_3, XKB_KEY_numbersign, 2)
    TAGKEYS(XKB_KEY_4, XKB_KEY_dollar,     3)
    TAGKEYS(XKB_KEY_5, XKB_KEY_percent,    4)
    TAGKEYS(XKB_KEY_6, XKB_KEY_asciicircum,5)
    TAGKEYS(XKB_KEY_7, XKB_KEY_ampersand,  6)
    TAGKEYS(XKB_KEY_8, XKB_KEY_asterisk,   7)
    TAGKEYS(XKB_KEY_9, XKB_KEY_parenleft,  8)
    { MODKEY,                   XKB_KEY_0,          view,           {.ui = ~0} },
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_0,          tag,            {.ui = ~0} },

    /* Monitors */
    { MODKEY,                   XKB_KEY_comma,      focusmon,       {.i = -1} },
    { MODKEY,                   XKB_KEY_period,     focusmon,       {.i = +1} },
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_comma,      tagmon,         {.i = -1} },
    { MODKEY|WLR_MODIFIER_SHIFT,XKB_KEY_period,     tagmon,         {.i = +1} },

    /* Screenshots */
    { 0,                        XKB_KEY_Print,      spawn,          {.v = ss_select} },     /* Print → region */
    { MODKEY,                   XKB_KEY_Print,      spawn,          {.v = ss_full} },        /* Super+Print → fullscreen */

    /* Audio */
    { 0,  XKB_KEY_XF86AudioRaiseVolume, spawn, {.v = vol_up} },
    { 0,  XKB_KEY_XF86AudioLowerVolume, spawn, {.v = vol_down} },
    { 0,  XKB_KEY_XF86AudioMute,        spawn, {.v = vol_toggle} },
    { 0,  XKB_KEY_XF86AudioMicMute,     spawn, {.v = mic_toggle} },

    /* Media */
    { 0,  XKB_KEY_XF86AudioPlay,  spawn, {.v = media_play} },
    { 0,  XKB_KEY_XF86AudioPause, spawn, {.v = media_play} },
    { 0,  XKB_KEY_XF86AudioNext,  spawn, {.v = media_next} },
    { 0,  XKB_KEY_XF86AudioPrev,  spawn, {.v = media_prev} },

    /* Brightness */
    { 0,  XKB_KEY_XF86MonBrightnessUp,   spawn, {.v = br_up} },
    { 0,  XKB_KEY_XF86MonBrightnessDown, spawn, {.v = br_down} },
};

static const Button buttons[] = {
    { MODKEY, BTN_LEFT,   moveresize,     {.ui = CurMove} },
    { MODKEY, BTN_MIDDLE, togglefloating, {0} },
    { MODKEY, BTN_RIGHT,  moveresize,     {.ui = CurResize} },
};
DWLCONF
    fi

    say "Building dwl..."
    if [[ $DRY_RUN -eq 0 ]]; then
        (
            cd "$dwl_dir"
            cp config.def.h config.h
            make clean
            make -j"$JOBS"
            sudo make PREFIX="$SUCKLESS_PREFIX" install
        )
    else
        say "[dry-run] Would build dwl in $dwl_dir"
    fi
    ok "dwl installed"

    # ── Build somebar ─────────────────────────────────────────────────────────
    local somebar_dir="$WAYLAND_DIR/somebar"
    git_sync "$SOMEBAR_REPO" "$somebar_dir"

    say "Writing somebar config (MatteBlack theme)..."
    if [[ $DRY_RUN -eq 0 ]]; then
        ensure_dir "$HOME/.config/somebar"
        cat > "$somebar_dir/src/config.def.hpp" <<SOMEBARCONF
// somebar config — NIRUCON MatteBlack
// Mirrors dwm bar appearance

static const bool topbar = true;
static const int  paddingX = 10;
static const int  paddingY = 3;

static const char font[] = "JetBrainsMono Nerd Font:size=11";

// Colors: {foreground, background}
static const ColorScheme colorInactive = {"#a8a8a8", "#0f0f10"};  /* inactive tag / title */
static const ColorScheme colorActive   = {"#e5e5e5", "#3a3a3d"};  /* active tag / title */
static const ColorScheme colorUrgent   = {"#e5e5e5", "#8b0000"};  /* urgent tag */

// Status script — reads from stdin (run dwl-status.sh which pipes to somebar)
static const char *termCmd[]  = { "foot", NULL };
SOMEBARCONF
        cp "$somebar_dir/src/config.def.hpp" "$HOME/.config/somebar/config.def.hpp"
    fi

    say "Building somebar..."
    if [[ $DRY_RUN -eq 0 ]]; then
        (
            cd "$somebar_dir"
            cp src/config.def.hpp src/config.hpp
            make clean
            make -j"$JOBS"
            sudo make PREFIX="$SUCKLESS_PREFIX" install
        )
    else
        say "[dry-run] Would build somebar in $somebar_dir"
    fi
    ok "somebar installed"

    # ── dwl autostart script ──────────────────────────────────────────────────
    say "Writing dwl autostart script..."
    ensure_dir "$HOME/.config/dwl"
    run install -Dm755 /dev/stdin "$HOME/.config/dwl/autostart.sh" <<'AUTOSTART'
#!/bin/sh
# dwl autostart — runs when dwl starts
# Equivalent to .xinitrc hooks in X11 setup

# PipeWire (should already be running via systemd user session, but ensure it)
command -v pipewire >/dev/null 2>&1 && pipewire &

# Notification daemon
command -v mako >/dev/null 2>&1 && mako &

# Wallpaper (rotating, same ~/Wallpapers dir as X11)
if [ -x "$HOME/.local/bin/dwl-wallrotate.sh" ]; then
    "$HOME/.local/bin/dwl-wallrotate.sh" &
elif command -v swaybg >/dev/null 2>&1 && [ -d "$HOME/Wallpapers" ]; then
    swaybg -m fill -i "$(find "$HOME/Wallpapers" -type f | shuf -n1)" &
fi

# Idle management — lock after 10 min, suspend after 20 min
command -v swayidle >/dev/null 2>&1 && swayidle -w \
    timeout 600  'swaylock -f --color 0f0f10' \
    timeout 1200 'systemctl suspend' \
    before-sleep 'swaylock -f --color 0f0f10' &

# Disk automounter
command -v udiskie >/dev/null 2>&1 && udiskie --tray &

# Bluetooth tray
command -v blueman-applet >/dev/null 2>&1 && blueman-applet &

# Nextcloud sync
command -v nextcloud >/dev/null 2>&1 && nextcloud --background &

# Status bar (somebar reads from its socket; dwl-status pipes to it)
sleep 1
command -v somebar >/dev/null 2>&1 && somebar &
sleep 0.5
[ -x "$HOME/.local/bin/dwl-status.sh" ] && "$HOME/.local/bin/dwl-status.sh" &
AUTOSTART

    # ── dwl-wallrotate.sh ─────────────────────────────────────────────────────
    say "Writing dwl-wallrotate.sh..."
    ensure_dir "$LOCAL_BIN"
    run install -Dm755 /dev/stdin "$LOCAL_BIN/dwl-wallrotate.sh" <<'WALLSCRIPT'
#!/bin/sh
# dwl-wallrotate.sh — rotating wallpapers for Wayland/swaybg
# Usage: dwl-wallrotate.sh [next|start]
# Mirrors wallrotate.sh for X11

WALLDIR="$HOME/Wallpapers"
STATEFILE="$HOME/.cache/alpi/dwl-wallpaper-index"
INTERVAL=300  # seconds between rotations

mkdir -p "$(dirname "$STATEFILE")"

[ -d "$WALLDIR" ] || { echo "No wallpaper dir: $WALLDIR"; exit 1; }

walls=()
while IFS= read -r -d '' f; do
    walls+=("$f")
done < <(find "$WALLDIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' \) -print0 | sort -z)

[ "${#walls[@]}" -eq 0 ] && { echo "No wallpapers found in $WALLDIR"; exit 1; }

# Read current index
idx=0
[ -f "$STATEFILE" ] && idx=$(cat "$STATEFILE")

case "${1:-start}" in
    next)
        idx=$(( (idx + 1) % ${#walls[@]} ))
        echo "$idx" > "$STATEFILE"
        pkill -SIGUSR1 swaybg 2>/dev/null || true
        swaybg -m fill -i "${walls[$idx]}" &
        ;;
    start)
        while true; do
            wall="${walls[$idx]}"
            # Kill previous swaybg
            pkill -x swaybg 2>/dev/null || true
            sleep 0.2
            swaybg -m fill -i "$wall" &
            echo "$idx" > "$STATEFILE"
            sleep "$INTERVAL"
            idx=$(( (idx + 1) % ${#walls[@]} ))
        done
        ;;
esac
WALLSCRIPT

    # ── dwl-status.sh ─────────────────────────────────────────────────────────
    say "Writing dwl-status.sh (somebar status feeder)..."
    run install -Dm755 /dev/stdin "$LOCAL_BIN/dwl-status.sh" <<'STATUSSCRIPT'
#!/bin/sh
# dwl-status.sh — pipes status text to somebar
# somebar reads status from a named pipe at $XDG_RUNTIME_DIR/somebar-0

PIPE="${XDG_RUNTIME_DIR:-/tmp}/somebar-0"

get_vol() {
    vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '{print $2}')
    muted=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -c MUTED || true)
    if [ "$muted" -gt 0 ]; then
        echo " MUTE"
    else
        pct=$(echo "$vol * 100" | bc | cut -d. -f1)
        echo " ${pct}%"
    fi
}

get_bat() {
    bat=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "")
    status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "")
    [ -z "$bat" ] && return
    icon=""
    [ "$status" = "Charging" ] && icon=""
    echo " ${icon}${bat}%"
}

get_net() {
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    [ -z "$iface" ] && echo " offline" && return
    echo " $iface"
}

while true; do
    stat="$(get_net) | $(get_vol)$(get_bat) |  $(date '+%a %d %b  %H:%M')"
    # somebar reads status via its IPC socket
    echo "status $stat" > "$PIPE" 2>/dev/null || true
    sleep 5
done
STATUSSCRIPT

    # ── Enable pipewire as user service ──────────────────────────────────────
    run systemctl --user enable --now pipewire pipewire-pulse wireplumber || \
        warn "pipewire user service enable failed (non-fatal, may already be running)"

    ok "Phase wayland done"
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
    local x11_configs=(alacritty cmus dunst gtk-3.0 picom rofi)
    local wayland_configs=(alacritty cmus gtk-3.0 foot mako)

    local configs_to_deploy=()
    want_x11     && configs_to_deploy+=("${x11_configs[@]}")
    want_wayland && configs_to_deploy+=("${wayland_configs[@]}")

    # deduplicate
    local -A seen_cfg
    for d in "${configs_to_deploy[@]}"; do
        [[ -v seen_cfg[$d] ]] && continue
        seen_cfg[$d]=1
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
        ok "~/.local/share/ (rofi themes etc)"
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

    # ── Session selector in .bash_profile ────────────────────────────────────
    # Writes a clean selector block. Idempotent: removes old block first.
    say "Writing session selector to ~/.bash_profile..."
    if [[ $DRY_RUN -eq 0 ]]; then
        # Remove any previous selector block
        sed -i '/# >>> ALPI SESSION SELECTOR/,/# <<< ALPI SESSION SELECTOR/d' "$profile"

        local sel_block=""

        if [[ "$VARIANT" == "both" ]]; then
            sel_block='
# >>> ALPI SESSION SELECTOR — managed by alpi-suckless.sh
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "  ┌─────────────────────────────────────┐"
    echo "  │   NIRUCON — Choose your session     │"
    echo "  ├─────────────────────────────────────┤"
    echo "  │  1)  dwm  ·  X11   (suckless)      │"
    echo "  │  2)  dwl  ·  Wayland               │"
    echo "  └─────────────────────────────────────┘"
    echo ""
    read -r -p "  Session [1/2, Enter=dwm]: " _ses
    case "$_ses" in
        2) exec dwl ;;
        *) exec startx ;;
    esac
fi
# <<< ALPI SESSION SELECTOR'
        elif [[ "$VARIANT" == "x11" ]]; then
            sel_block='
# >>> ALPI SESSION SELECTOR — managed by alpi-suckless.sh
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
# <<< ALPI SESSION SELECTOR'
        elif [[ "$VARIANT" == "wayland" ]]; then
            sel_block='
# >>> ALPI SESSION SELECTOR — managed by alpi-suckless.sh
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec dwl
fi
# <<< ALPI SESSION SELECTOR'
        fi

        echo "$sel_block" >> "$profile"
        ok "~/.bash_profile: session selector written ($VARIANT)"
    else
        say "[dry-run] Would write session selector ($VARIANT) to ~/.bash_profile"
    fi

    # ── X11 xinitrc hooks (only for x11/both) ────────────────────────────────
    if want_x11; then
        say "Writing xinitrc hook 20-lookandfeel.sh..."
        run install -Dm755 /dev/stdin "$XINITRC_HOOKS/20-lookandfeel.sh" <<'HOOK'
#!/bin/sh
# X11 hook — compositor, wallpaper, notifications, Bluetooth tray

# Compositor
command -v picom >/dev/null 2>&1 && picom --config "$HOME/.config/picom/picom.conf" --daemon

# Wallpaper
if [ -x "$HOME/.local/bin/wallrotate.sh" ]; then
    "$HOME/.local/bin/wallrotate.sh" &
elif command -v feh >/dev/null 2>&1 && [ -d "$HOME/Wallpapers" ]; then
    feh --randomize --bg-fill "$HOME/Wallpapers" &
fi

# Notifications
command -v dunst >/dev/null 2>&1 && dunst &

# Bluetooth tray
command -v blueman-applet >/dev/null 2>&1 && blueman-applet &

# Disk automounter
command -v udiskie >/dev/null 2>&1 && udiskie --tray &

# Nextcloud
command -v nextcloud >/dev/null 2>&1 && nextcloud --background &
HOOK

        say "Writing xinitrc hook 30-statusbar.sh..."
        run install -Dm755 /dev/stdin "$XINITRC_HOOKS/30-statusbar.sh" <<'HOOK'
#!/bin/sh
# X11 status bar hook
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

    # LazyVim bootstrap
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

    # ZRAM
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
        say "[dry-run] Would write /etc/systemd/zram-generator.conf.d/90-alpi.conf"
    fi
    run sudo systemctl enable --now systemd-zram-setup@zram0.service || true

    # Journald
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
        say "[dry-run] Would write /etc/systemd/journald.conf.d/90-alpi.conf"
    fi

    # sysctl
    local qdisc="fq"
    tc qdisc show 2>/dev/null | grep -q cake && qdisc="cake" || true
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo tee /etc/sysctl.d/90-alpi.conf >/dev/null <<EOF
# ALPI — conservative tunables
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
        say "[dry-run] Would write /etc/sysctl.d/90-alpi.conf"
    fi

    # pacman.conf
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo sed -E -i 's/^#?Color$/Color/'                   /etc/pacman.conf
        sudo sed -E -i 's/^#?VerbosePkgLists$/VerbosePkgLists/' /etc/pacman.conf
        sudo sed -E -i 's/^#?ParallelDownloads *= *.*/ParallelDownloads = 10/' \
            /etc/pacman.conf || \
            run_sh "echo 'ParallelDownloads = 10' | sudo tee -a /etc/pacman.conf"
    else
        say "[dry-run] Would enable Color, VerbosePkgLists, ParallelDownloads=10 in pacman.conf"
    fi

    # makepkg
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo sed -E -i "s|^#?MAKEFLAGS=.*|MAKEFLAGS=\"-j${cores}\"|" /etc/makepkg.conf
        sudo sed -E -i 's|^#?COMPRESSXZ=.*|COMPRESSXZ=(xz -c -T0 -z -)|'       /etc/makepkg.conf
        sudo sed -E -i 's|^#?COMPRESSZST=.*|COMPRESSZST=(zstd -c -T0 -z -q -19 -)|' /etc/makepkg.conf
    else
        say "[dry-run] Would tune makepkg.conf"
    fi

    # Maintenance timers
    run sudo pacman -S --needed --noconfirm pacman-contrib util-linux
    run sudo systemctl enable --now paccache.timer
    run sudo systemctl enable --now fstrim.timer

    # systemd-oomd
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
    # Select variant first (interactive if not set by flag)
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

    if should_run wayland; then
        want_wayland && phase_wayland || info "Skipping wayland (variant: $VARIANT)"
    fi

    should_run lookandfeel && phase_lookandfeel
    should_run apps        && phase_apps
    should_run optimize    && phase_optimize

    echo
    say "════════════════════════════════════════"
    ok  "All selected phases completed!"
    say "  → Reboot to apply all changes"
    if want_x11;     then say "  → X11:     startx"; fi
    if want_wayland; then say "  → Wayland: dwl (via session selector or direct)"; fi
    say "  → Verify: ./alpi-suckless.sh --verify"
    say "════════════════════════════════════════"
}

main

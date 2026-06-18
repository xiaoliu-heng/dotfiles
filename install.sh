#!/usr/bin/env sh
set -eu

DOTFILES_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
LOCAL_BIN="$HOME/.local/bin"
MAMBA_ROOT_PREFIX="$HOME/.local/share/dotfiles/micromamba"
MAMBA_ENV="$MAMBA_ROOT_PREFIX/envs/dotfiles"
PATH="$LOCAL_BIN:$PATH"
INSTALL_SCOPE="${DOTFILES_INSTALL_SCOPE:-}"
export PATH

info() {
  printf '%s\n' "$*"
}

has() {
  command -v "$1" >/dev/null 2>&1
}

has_sudo() {
  has sudo
}

choose_install_scope() {
  case "$INSTALL_SCOPE" in
    global|user)
      return
      ;;
    "")
      ;;
    *)
      info "Invalid DOTFILES_INSTALL_SCOPE=$INSTALL_SCOPE. Use 'global' or 'user'."
      exit 1
      ;;
  esac

  if [ ! -t 0 ]; then
    INSTALL_SCOPE=global
    info "No interactive input available. Defaulting to global package manager install when available."
    return
  fi

  while :; do
    printf '%s' "Install tools globally with the system package manager, or under your user directory? [global/user] "
    read -r answer

    case "$answer" in
      ""|g|G|global|Global|GLOBAL)
        INSTALL_SCOPE=global
        return
        ;;
      u|U|user|User|USER)
        INSTALL_SCOPE=user
        return
        ;;
      *)
        info "Please answer 'global' or 'user'."
        ;;
    esac
  done
}

download() {
  url=$1
  output=$2

  if has curl; then
    curl -fsSL "$url" -o "$output"
    return
  fi

  if has wget; then
    wget -qO "$output" "$url"
    return
  fi

  info "Neither curl nor wget is available. Please install one of them and rerun this script."
  exit 1
}

backup_path() {
  path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    mkdir -p "$BACKUP_DIR"
    mv "$path" "$BACKUP_DIR/"
    info "Backed up $path to $BACKUP_DIR/"
  fi
}

link_file() {
  source=$1
  target=$2
  mkdir -p "$(dirname "$target")"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
    info "Already linked: $target"
    return
  fi

  backup_path "$target"
  ln -s "$source" "$target"
  info "Linked $target -> $source"
}

install_homebrew_if_needed() {
  if has brew; then
    return
  fi

  if [ "$(uname -s)" != "Darwin" ]; then
    info "Homebrew is not installed. Skipping Homebrew install on non-macOS."
    return
  fi

  if ! has_sudo; then
    info "sudo is not available. Skipping Homebrew install and using user-local binaries."
    return
  fi

  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

install_with_micromamba() {
  mkdir -p "$LOCAL_BIN" "$MAMBA_ROOT_PREFIX"
  mamba_bin="$LOCAL_BIN/micromamba"

  if ! has micromamba; then
    os=$(uname -s)
    arch=$(uname -m)

    case "$os:$arch" in
      Darwin:arm64) platform=osx-arm64 ;;
      Darwin:x86_64) platform=osx-64 ;;
      Linux:aarch64|Linux:arm64) platform=linux-aarch64 ;;
      Linux:x86_64|Linux:amd64) platform=linux-64 ;;
      *)
        info "Unsupported platform for user-local micromamba install: $os $arch"
        exit 1
        ;;
    esac

    tmp_dir=$(mktemp -d)
    archive="$tmp_dir/micromamba.tar.bz2"
    info "Installing micromamba under $LOCAL_BIN..."
    download "https://micro.mamba.pm/api/micromamba/$platform/latest" "$archive"
    tar -xjf "$archive" -C "$tmp_dir" bin/micromamba
    mv "$tmp_dir/bin/micromamba" "$LOCAL_BIN/micromamba"
    chmod +x "$LOCAL_BIN/micromamba"
    rm -rf "$tmp_dir"
  else
    mamba_bin=$(command -v micromamba)
  fi

  if [ -d "$MAMBA_ENV" ]; then
    info "Updating packages in user-local micromamba env..."
    MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" "$mamba_bin" install -y -n dotfiles -c conda-forge \
      git \
      git-delta \
      lazygit \
      tmux \
      zsh
  else
    info "Installing packages into user-local micromamba env..."
    MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX" "$mamba_bin" create -y -n dotfiles -c conda-forge \
      git \
      git-delta \
      lazygit \
      tmux \
      zsh
  fi

  for tool in git delta lazygit tmux zsh; do
    if [ -x "$MAMBA_ENV/bin/$tool" ] && [ ! -e "$LOCAL_BIN/$tool" ]; then
      ln -s "$MAMBA_ENV/bin/$tool" "$LOCAL_BIN/$tool"
      info "Linked $LOCAL_BIN/$tool"
    fi
  done
}

install_packages() {
  if has brew; then
    info "Installing packages with Homebrew..."
    if brew bundle --file="$DOTFILES_DIR/Brewfile"; then
      return
    fi
    info "Homebrew install failed. Falling back to user-local binaries."
    install_with_micromamba
    return
  fi

  if has apt-get && has_sudo; then
    info "Installing packages with apt-get..."
    if sudo apt-get update && sudo apt-get install -y curl git tmux zsh; then
      return
    fi
    info "apt-get install failed. Falling back to user-local binaries."
    install_with_micromamba
    return
  fi

  if has dnf && has_sudo; then
    info "Installing packages with dnf..."
    if sudo dnf install -y curl git tmux zsh lazygit git-delta; then
      return
    fi
    info "dnf install failed. Falling back to user-local binaries."
    install_with_micromamba
    return
  fi

  if has pacman && has_sudo; then
    info "Installing packages with pacman..."
    if sudo pacman -Sy --needed curl git tmux zsh lazygit git-delta; then
      return
    fi
    info "pacman install failed. Falling back to user-local binaries."
    install_with_micromamba
    return
  fi

  info "No usable global package manager path found. Installing tools into the user home directory."
  install_with_micromamba
}

ensure_required_tools() {
  missing=

  for tool in git tmux zsh lazygit delta; do
    if ! has "$tool"; then
      missing="$missing $tool"
    fi
  done

  if [ -n "$missing" ]; then
    info "Missing required tools:$missing"
    install_with_micromamba
  fi
}

ensure_local_bin_tools() {
  mkdir -p "$LOCAL_BIN"

  if has lazygit && [ ! -e "$LOCAL_BIN/lazygit" ]; then
    ln -s "$(command -v lazygit)" "$LOCAL_BIN/lazygit"
    info "Linked $LOCAL_BIN/lazygit for tmux popup binding."
  fi
}

install_oh_my_zsh() {
  if [ -d "$HOME/.oh-my-zsh" ]; then
    info "Oh My Zsh already installed."
    return
  fi

  info "Installing Oh My Zsh..."
  tmp_dir=$(mktemp -d)
  installer="$tmp_dir/oh-my-zsh-install.sh"
  download "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" "$installer"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$installer"
  rm -rf "$tmp_dir"
}

install_zsh_plugin() {
  name=$1
  repo=$2
  target="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$name"

  if [ -d "$target/.git" ]; then
    info "Updating $name..."
    git -C "$target" pull --ff-only
    return
  fi

  if [ -e "$target" ]; then
    info "Plugin path exists but is not a git checkout, leaving it unchanged: $target"
    return
  fi

  info "Installing $name..."
  git clone --depth=1 "$repo" "$target"
}

install_zsh_plugins() {
  install_zsh_plugin zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git
  install_zsh_plugin zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git
  install_zsh_plugin zsh-completions https://github.com/zsh-users/zsh-completions.git
}

configure_zshrc() {
  zshrc="$HOME/.zshrc"
  plugins_line="plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-completions)"
  marker_start="# >>> dotfiles managed >>>"
  marker_end="# <<< dotfiles managed <<<"

  if [ ! -e "$zshrc" ]; then
    cat >"$zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"

plugins=(git)

source "$ZSH/oh-my-zsh.sh"
EOF
    info "Created $zshrc"
  fi

  tmp_file=$(mktemp)
  awk -v plugins_line="$plugins_line" '
    /^[[:space:]]*plugins=\(/ && !done {
      print plugins_line
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print plugins_line
      }
    }
  ' "$zshrc" >"$tmp_file"
  mv "$tmp_file" "$zshrc"

  tmp_file=$(mktemp)
  awk -v marker_start="$marker_start" -v marker_end="$marker_end" '
    $0 == marker_start { skip = 1; next }
    $0 == marker_end { skip = 0; next }
    !skip { print }
  ' "$zshrc" >"$tmp_file"
  mv "$tmp_file" "$zshrc"

  cat >>"$zshrc" <<'EOF'

# >>> dotfiles managed >>>
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-$EDITOR}"
export PAGER="${PAGER:-less}"

alias ll='ls -lah'
alias lg='lazygit'
alias mux='tmux new-session -A -s main'

export NVM_DIR="$HOME/.nvm"
if [ -s "/opt/homebrew/opt/nvm/nvm.sh" ]; then
  . "/opt/homebrew/opt/nvm/nvm.sh"
fi
if [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ]; then
  . "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
fi

if [ -f "$HOME/.zshrc.local" ]; then
  source "$HOME/.zshrc.local"
fi
# <<< dotfiles managed <<<
EOF

  info "Configured $zshrc"
}

configure_shell() {
  if ! has zsh; then
    return
  fi

  zsh_path=$(command -v zsh)
  current_shell=${SHELL:-}

  if [ "$current_shell" = "$zsh_path" ]; then
    info "Default shell is already zsh."
    return
  fi

  if has chsh; then
    info "To make zsh your default shell, run: chsh -s $zsh_path"
  fi
}

main() {
  choose_install_scope

  if [ "$INSTALL_SCOPE" = "user" ]; then
    info "Installing tools into the user home directory."
    install_with_micromamba
  else
    install_homebrew_if_needed
    install_packages
  fi

  ensure_required_tools
  ensure_local_bin_tools
  install_oh_my_zsh
  install_zsh_plugins
  configure_zshrc

  link_file "$DOTFILES_DIR/dotfiles/tmux.conf" "$HOME/.tmux.conf"
  link_file "$DOTFILES_DIR/config/lazygit/config.yml" "$HOME/.config/lazygit/config.yml"

  if [ ! -e "$HOME/.zshrc.local" ]; then
    cp "$DOTFILES_DIR/templates/zshrc.local.example" "$HOME/.zshrc.local"
    chmod 600 "$HOME/.zshrc.local"
    info "Created $HOME/.zshrc.local for private machine-specific settings."
  fi

  configure_shell
  info "Done."
}

main "$@"

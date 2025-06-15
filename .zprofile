typeset -U path

# locale
export LANG="en_US.UTF-8"

# XDG
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"

[[ -d ~/.bash ]] && path=($HOME/.bash $path)

# HOMEBREW
if [ -f /opt/homebrew/bin/brew ]; then
    path=(/opt/homebrew/bin /opt/homebrew/sbin $path)
elif [ -f /usr/local/bin/brew ]; then
    path=(/usr/local/bin /usr/local/sbin $path)
fi
if command -v brew >/dev/null; then
    export HOMEBREW_NO_ENV_HINTS=1
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_ANALYTICS=1
    #export HOMEBREW_UPDATE_REPORT_ONLY_INSTALLED=1
    export HOMEBREW_GITHUB_API_TOKEN=your-github-api-token
    export HOMEBREW_EDITOR=/usr/bin/vim
    #export HOMEBREW_VERBOSE=1
    export HOMEBREW_CASK_OPTS="--appdir=$HOME/Applications"
    #https://github.com/Homebrew/brew/issues/14595
    export HOMEBREW_NO_INSTALL_FROM_API=1
    # openssl@1.1
    #[[ -d $(brew --prefix)/opt/openssl@1.1/bin ]] && \
    #    path=($(brew --prefix)/opt/openssl@1.1/bin $path)
fi

# golang
if command -v go >/dev/null; then
    export GOPATH="$HOME/.go"
    path=($HOME/.go/bin $path)
fi

# gem home
if command -v gem >/dev/null; then
    export GEM_HOME=$HOME/.gem
    path=($path $(ruby -r rubygems -e "puts Gem.user_dir")/bin)
fi

# GPG_TTY
if command -v gpg-agent >/dev/null; then
    export GPG_TTY=$(tty)
fi
# gpgconf
if command -v gpgconf >/dev/null; then
    unset SSH_AGENT_PID
    if [ "${gnupg_SSH_AUTH_SOCK_by:-0}" -ne $$ ]; then
        export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
    fi
fi

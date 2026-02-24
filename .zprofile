typeset -U path


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
    [[ -f "$XDG_CONFIG_HOME/secrets" ]] && source "$XDG_CONFIG_HOME/secrets"
    command -v vim >/dev/null && export HOMEBREW_EDITOR=vim
    #export HOMEBREW_VERBOSE=1
    export HOMEBREW_CASK_OPTS="--appdir=$HOME/Applications"
fi

# golang
if command -v go >/dev/null; then
    export GOPATH="$HOME/.go"
    path=($HOME/.go/bin $path)
fi

# gem home
if command -v gem >/dev/null; then
    export GEM_HOME=$HOME/.gem
    path=($path $HOME/.gem/ruby/$(ruby -e 'puts RUBY_VERSION[/\d+\.\d+/]')/bin)
fi

# gpg
if command -v gpgconf >/dev/null; then
    export GPG_TTY=$TTY
    unset SSH_AGENT_PID
    if [ "${gnupg_SSH_AUTH_SOCK_by:-0}" -ne $$ ]; then
        export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
    fi
fi

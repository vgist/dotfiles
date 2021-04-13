# locale
export LANG="en_US.UTF-8"

# XDG
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"

[[ -d ~/.bash ]] && path=($HOME/.bash $path)

# HOMEBREW
if [ -f /opt/homebrew/bin/brew ]; then
    path=($path /opt/homebrew/bin /opt/homebrew/sbin)
elif [ -f /usr/local/bin/brew ]; then
    path=($path /usr/local/sbin)
fi
if hash brew 2>/dev/null; then
    fpath=($(brew --prefix)/share/zsh/site-functions $fpath)
    [[ -d $(brew --prefix)/share/zsh-completions ]] && fpath=($(brew --prefix)/share/zsh-completions $fpath)
    export HOMEBREW_NO_ANALYTICS=1
    export HOMEBREW_UPDATE_REPORT_ONLY_INSTALLED=1
    export HOMEBREW_GITHUB_API_TOKEN=your-github-api-token
    export HOMEBREW_EDITOR=/usr/bin/vim
    #export HOMEBREW_VERBOSE=1
    export HOMEBREW_CASK_OPTS="--appdir=$HOME/Applications"
fi

# golang
if hash go 2>/dev/null; then
    export GOPATH="$HOME/.go"
    path=($HOME/.go/bin $path)
fi

# gem home
if hash gem 2>/dev/null; then
    export GEM_HOME=$HOME/.gem
    path=($GEM_HOME/bin $path)
fi

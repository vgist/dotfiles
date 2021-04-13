#!/usr/bin/env zsh

# Turn off all beeps
unsetopt BEEP
# Turn off autocomplete beeps
unsetopt LIST_BEEP

# Search history with up and down key
autoload -U history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end history-search-end
bindkey "\e[A" history-beginning-search-backward
bindkey "\e[B" history-beginning-search-forward

# need zsh-completions
zstyle ':completion:*' rehash true
zstyle ':completion:*:ssh:*' hosts on
zstyle ':completion:*' menu select=2
zstyle ':completion::complete:*' gain-privileges 1
zstyle ":completion:*" auto-description "specify: %d"
zstyle ":completion:*:default" list-colors ${(s.:.)LS_COLORS}
zstyle ":completion:*" list-colors ""

autoload -Uz compinit && compinit
autoload -Uz promptinit && promptinit
autoload -Uz colors && colors

#setopt COMPLETE_ALIASES
setopt completealiases
#setopt correctall
setopt extendedglob
setopt hist_ignore_all_dups
setopt hist_ignore_space
setopt sharehistory

# git plugin, require CommandLineTools or Xcode.app
if [ -d $(xcode-select -p)/usr/share/git-core ]; then
    setopt promptsubst
    source $(xcode-select -p)/usr/share/git-core/git-prompt.sh
    export GIT_PS1_SHOWDIRTYSTATE=1
    export GIT_PS1_SHOWSTASHSTATE=1
    export GIT_PS1_SHOWUNTRACKEDFILES=1
fi

git_ps1() {
    if command git branch >/dev/null 2>&1; then
        __git_ps1;
    fi
}

# prompt
export PS1='%F{7}%*%f %F{6}%m:%~%f%F{2}$(git_ps1)%f %F{6}$%f '

ttyctl -f

[[ -f ~/.alias ]] && . ~/.alias

run_ccal() {
    if hash ccal 2>/dev/null; then
        tty | grep -i -E 'tty|pts' &> /dev/null && ccal -u
    fi
}
run_ccal

#!/usr/bin/env zsh

typeset -U fpath

# ----- behavior -----
unsetopt BEEP
unsetopt LIST_BEEP

setopt completealiases
setopt extendedglob
setopt hist_ignore_all_dups
setopt hist_ignore_space
setopt sharehistory

# ----- history search -----
autoload -U history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end history-search-end
bindkey "\e[A" history-beginning-search-backward
bindkey "\e[B" history-beginning-search-forward

# ----- completion -----
zstyle ':completion:*' rehash true
zstyle ':completion:*:ssh:*' hosts on
zstyle ':completion:*' menu select=2
zstyle ':completion::complete:*' gain-privileges 1
zstyle ":completion:*" auto-description "specify: %d"

autoload -Uz compinit
compinit -d "$XDG_CACHE_HOME/zsh/zcompdump"

# ----- homebrew -----
_brew() {
    unfunction _brew 2>/dev/null
    command -v brew >/dev/null || return 1

    local bp
    bp="$(command brew --prefix)"
    [[ -d $bp/share/zsh/site-functions ]] && \
        fpath=($bp/share/zsh/site-functions $fpath)
    [[ -d $bp/share/zsh-completions ]] && \
        fpath=($bp/share/zsh-completions $fpath)

    autoload -Uz compinit
    compinit -i
    zle .complete-word
}
compdef _brew brew

autoload -Uz vcs_info
autoload -Uz add-zsh-hook
add-zsh-hook precmd vcs_info
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:git:*' check-for-changes true
zstyle ':vcs_info:git:*' stagedstr '+'
zstyle ':vcs_info:git:*' unstagedstr '*'
zstyle ':vcs_info:git:*' formats ' (%b%u%c)'
setopt promptsubst

autoload -Uz colors && colors
export PS1='%F{7}%*%f %F{6}%m:%~%f%F{2}${vcs_info_msg_0_}%f %F{6}$%f '

[[ -t 1 ]] && ttyctl -f

[[ -f ~/.bash_aliases ]] && . ~/.bash_aliases


# run ccal
#if [[ "$(tput colors)" == 256 ]]; then
#    hash ccal 2>/dev/null && ccal -u
#fi

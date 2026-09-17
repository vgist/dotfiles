# ~/.bashrc: executed by bash(1) for non-login interactive shells.
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

command -v dircolors >/dev/null 2>&1 && eval "$(dircolors -b)"
[[ -f $HOME/.bash_aliases ]] && . ~/.bash_aliases
[[ -f /usr/bin/sudo ]] && complete -cf sudo
[[ -f /usr/bin/man ]] && complete -cf man
[[ -d $HOME/.bash ]] && export PATH=$PATH:$HOME/.bash

# history
export HISTTIMEFORMAT="%Y-%m-%d %T "
export HISTCONTROL="$HISTCONTROL ignoreboth:erasedups"
export HISTSIZE=100000
export HISTFILESIZE=100000
shopt -s histappend

# GPG_TTY
if command -v gpg-agent >/dev/null 2>&1; then
    export GPG_TTY=$(tty)
fi
# gpgconf
if command -v gpgconf >/dev/null 2>&1; then
    unset SSH_AGENT_PID
    if [ "${gnupg_SSH_AUTH_SOCK_by:-0}" -ne $$ ]; then
        export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
    fi
fi


# bash prompt color
# https://misc.flogisoft.com/bash/tip_colors_and_formatting
export GIT_PS1_SHOWDIRTYSTATE=1
color1="\[\033[37m\]"
color2="\[\033[36m\]"
color3="\[\033[32m\]"
reset="\[\033[0m\]"

if command -v git >/dev/null 2>&1; then
    for _git_prompt_path in \
        /usr/share/git/git-prompt.sh \
        /usr/share/git-core/contrib/completion/git-prompt.sh \
        /usr/lib/git-core/git-sh-prompt
    do
        if [[ -f $_git_prompt_path ]]; then
            source "$_git_prompt_path"
            break
        fi
    done
fi
PS1="${color1}\t ${color2}\h:\w${color3}"'$(type -t __git_ps1 >/dev/null 2>&1 && __git_ps1)'" ${color2}\$${reset} "
#export LANG="en_US.UTF-8"


# run ccal
#if [[ "$(tput colors)" == 256 ]]; then
#    hash ccal 2>/dev/null && ccal -u
#fi

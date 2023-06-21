# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

hash dircolors 2>/dev/null && eval "$(dircolors -b)"
[[ -f $HOME/.bash_alias ]] && . ~/.bash_alias
[[ -f /usr/bin/sudo ]] && complete -cf sudo
[[ -f /usr/bin/man ]] && complete -cf man
[[ -d $HOME/.bash ]] && export PATH=$PATH:$HOME/.bash


# GPG_TTY
if hash gpg-agent 2>/dev/null; then
    export GPG_TTY=$(tty)
fi
# gpgconf
if hash gpgconf 2>/dev/null; then
    unset SSH_AGENT_PID
    if [ "${gnupg_SSH_AUTH_SOCK_by:-0}" -ne $$ ]; then
        export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
    fi
fi


# source git-prompt
_git_prompt_path="
    /usr/share/git/git-prompt.sh
    /usr/share/git-core/contrib/completion/git-prompt.sh
    /usr/lib/git-core/git-sh-prompt
"
for _i in $_git_prompt_path; do
    [[ -f $_i ]] && source $_i;
done

# bash prompt color
# https://misc.flogisoft.com/bash/tip_colors_and_formatting
export GIT_PS1_SHOWDIRTYSTATE=1i
color1="\[$(tput setaf 7)\]"   # \e[32m
color2="\[$(tput setaf 6)\]"
color3="\[$(tput setaf 2)\]"
reset="\[$(tput sgr0)\]"

git_ps1() { hash __git_ps1 2>/dev/null && __git_ps1; }
export PS1="${color1}\t ${color2}\h:\w${color3}"'$(shopt -q login_shell && git_ps1)'" ${color2}\$${reset} "
#export LANG="en_US.UTF-8"


# run ccal
#if [[ "$(tput colors)" == 256 ]]; then
#    hash ccal 2>/dev/null && ccal -u
#fi

# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return
[[ -f $HOME/.bash_alias ]] && . ~/.bash_alias
[[ -f /usr/bin/sudo ]] && complete -cf sudo
[[ -f /usr/bin/man ]] && complete -cf man
[[ -f $HOME/.dir_colors ]] && . ~/.dir_colors
[[ -d $HOME/.bash ]] && export PATH=$PATH:$HOME/.bash
[[ -f /usr/bin/gpg-agent ]] && export GPG_TTY=$(tty)
# gpgconf
unset SSH_AGENT_PID
if [ "${gnupg_SSH_AUTH_SOCK_by:-0}" -ne $$ ]; then
    export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
fi

# PS
OS=`uname`

PS() {
    export GIT_PS1_SHOWDIRTYSTATE=1i
    # bash prompt color
    # https://wiki.archlinux.org/index.php/Bash/Prompt_customization
    # https://misc.flogisoft.com/bash/tip_colors_and_formatting
    if [[ $- == *i* ]]; then
        color1="\[$(tput setaf 7)\]"   # \e[32m
        color2="\[$(tput setaf 6)\]"
        color3="\[$(tput setaf 2)\]"
        reset="\[$(tput sgr0)\]"
    fi
    git_ps1() {
        if hash __git_ps1 2>/dev/null; then
            __git_ps1;
        fi
    }
    export PS1="${color1}\t ${color2}\h:\w${color3}"'$(git_ps1)'" ${color2}\$${reset} "
    #export LANG="en_US.UTF-8"
}

[[ -f /usr/share/git/git-prompt.sh ]] && . /usr/share/git/git-prompt.sh
[[ -f /usr/share/git-core/contrib/completion/git-prompt.sh ]] && . /usr/share/git-core/contrib/completion/git-prompt.sh
[[ -f /usr/lib/git-core/git-sh-prompt ]] && . /usr/lib/git-core/git-sh-prompt
[[ ${EUID} -ge "1000" ]] && PS

#run_ccal() {
#    if hash ccal 2>/dev/null; then
#        tty | grep -i -E 'ttys|pts' &> /dev/null && ccal -u
#    fi
#}
#run_ccal

function ssh () {
    local _sshpath=$(which -a ssh | sed -n '$p')
    if [[ ! $@ =~ tmux ]]; then
        #$_sshpath -t $@ "tmux attach || tmux new"
        $_sshpath -C -t $@ "tmux attach >/dev/null 2>&1 || bash -l"
    else
        $_sshpath -C $@
    fi
}

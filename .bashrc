# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return
[[ -f $HOME/.alias ]] && . ~/.alias
[[ -f /usr/bin/sudo ]] && complete -cf sudo
[[ -f /usr/bin/man ]] && complete -cf man
[[ -f $HOME/.dir_colors ]] && . ~/.dir_colors
[[ -d $HOME/.bash ]] && export PATH=$PATH:$HOME/.bash
[[ -f /usr/bin/gpg-agent ]] && export GPG_TTY=$(tty)

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


case $OS in
    Darwin)
        [[ -f $(xcode-select -p)/usr/share/git-core/git-prompt.sh ]] && . $(xcode-select -p)/usr/share/git-core/git-prompt.sh
        [[ ${EUID} -ge "501" ]] && PS
        ;;
    Linux)
        [[ -f /usr/share/git/git-prompt.sh ]] && . /usr/share/git/git-prompt.sh
        [[ -f /usr/share/git-core/contrib/completion/git-prompt.sh ]] && . /usr/share/git-core/contrib/completion/git-prompt.sh
        [[ -f /usr/lib/git-core/git-sh-prompt ]] && . /usr/lib/git-core/git-sh-prompt
        [[ ${EUID} -ge "1000" ]] && PS
        ;;
esac

run_ccal() {
    if hash ccal 2>/dev/null; then
        tty | grep -i -E 'tty' &> /dev/null && ccal -u
    fi
}
run_ccal

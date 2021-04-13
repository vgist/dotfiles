# /etc/skel/.bash_profile

# This file is sourced by bash for login shells.  The following line
# runs your .bashrc and is recommended by the bash info pages.
[[ -f ~/.bash_color ]] && . ~/.bash_color
[[ -f ~/.bashrc ]] && . ~/.bashrc

# pinentry for ssh
[[ -n "$SSH_CONNECTION" ]] && export PINENTRY_USER_DATA="USE_CURSES=1"

# history
export HISTTIMEFORMAT="%Y-%m-%d %T "
export HISTCONTROL="$HISTCONTROL ignoreboth:erasedups"
export HISTSIZE=100000
export HISTFILESIZE=100000
#[[ "${BASH_VERSINFO:-0}" -ge 4 ]] && shopt -s histappend
hash shopt 2>/dev/null && shopt -s histappend

# gem
[[ -d ~/.gem ]] && \
    export PATH=$PATH:$(ruby -rubygems -e "puts Gem.user_dir")/bin

# ~/.bash_profile: executed by bash(1) for login shells.

# This file is sourced by bash for login shells.  The following line
# runs your .bashrc and is recommended by the bash info pages.
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME"/.bashrc ]; then
        . "$HOME"/.bashrc
    fi
fi

# pinentry for ssh
[[ -n "$SSH_CONNECTION" ]] && export PINENTRY_USER_DATA="USE_CURSES=1"

# gem
[[ -d ~/.gem ]] && \
    export PATH=$PATH:$(ruby -rubygems -e "puts Gem.user_dir")/bin

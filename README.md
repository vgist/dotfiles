simple/weight vim's configration with [vim-plug](https://github.com/junegunn/vim-plug)

Installation
------------

To install, run

    $ git clone git://github.com/vgist/vimrc.git ~/.vim
    $ cd ~/.vim && make install

To update the repository, run

    $ make update

Note
----

If you are going to use this colorscheme of the configuration in Terminal mode (e.g. not in a GUI version like gvim or macvim), please consider setting your terminal emulator's colorscheme to used.

Test the terminals color bit depth:

    $ tput colors

If the result is 8, that means your Terminal was using 8 bit color (e.g. xterm on Gentoo), please:

    $ echo "export TERM=xterm-256color" >> ~/.bashrc

You may need unicode suported terminal to display [airline unicode symbols](https://github.com/vim-airline/vim-airline/blob/master/doc/airline.txt#L157-L275).

Other Notes
-----------

vimrc.mine and gvimrc.mine contain system-specific settings or other settings
that should not be part of a general configuration.

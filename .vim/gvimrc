" GUI
set termencoding=utf-8
if has("gui_running")
    set guioptions-=m   "remove menu bar
    set guioptions-=T   "remove toolbar
    set guioptions-=r   "remove right-hand scroll bar
    set guioptions-=L   "remove left-hand scroll bar

    set lines=38 columns=126
    autocmd VimEnter * set vb t_vb=

    set scrolloff=999
    if has("macunix")
        set guifont=Monaco:h13
        noremap <D-0> :set guifont=Monaco:h13<CR>       " Command + 0
    elseif has("unix")
        set guifont=Monospace\ 11
        noremap <C-F1> :set guifont=Monospace\ 11<CR>
        noremap <C-F2> :set guifont=Monospace\ 13<CR>
    " elseif has("win32") || has('win64')
    "   set ...
    endif
endif

" vim: set et fenc=utf-8 ff=unix sts=4 sw=4 ts=4 :

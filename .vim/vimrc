" encoding
set encoding=utf-8
scriptencoding utf-8
set termencoding=utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,cp936,gb18030,big5,euc-jp,euc-kr,latin1
set fileformats=unix,dos,mac
"set langmenu=zh_CN.UTF-8
"set helplang=cn

" Create needed folder
silent !mkdir -p $HOME/.vim/.swap

" Be iMproved, required
if &compatible
    set nocompatible
endif

" MacOS & Unix italic
if has("macunix") || has("unix")
    let &t_ZH="\e[3m"
    let &t_ZR="\e[23m"
endif

" viminfo: remember certain things when we exit
set viminfo=%50,\"100,'20,/20,:50,h,f1,n$HOME/.vim/.swap/viminfo
"           |    |    |   |   |   | |  + viminfo file path
"           |    |    |   |   |   | + file marks 0-9,A-Z. 0 = not storeed
"           |    |    |   |   |   + disable hlsearch loading viminfo
"           |    |    |   |   + command line history saved
"           |    |    |   + search history saved
"           |    |    + file marks saved
"           |    + lines saved each register (old name for <, vi6,2)
"           + save/restore buffer list


" Global Settings
syntax on
set cursorline
"set cursorcolumn
set number
set title
"set t_ti= t_te=
set ruler                           " Always show current position
set virtualedit=onemore             " block, insert, all, onemore
set list!                           " Display unprintable characters
set listchars=tab:▸\ ,trail:•,extends:»,precedes:«

" Formatting, indentation and tabbing
set autoindent smartindent
set smarttab                        " Make <tab> and <backspace> smarter
set expandtab
"set noexpandtab
set tabstop=4 softtabstop=4 shiftwidth=4
set formatoptions-=t formatoptions+=croql
set modeline

" Misc
filetype plugin indent on
set hidden
set wildmenu                        " Enhanced completion hints in command
set wildmode=list:longest,full
set backspace=eol,start,indent      " Allow backspace
set complete=.,w,b,u,U,t,i,d        " Do lots of scanning on tab completion
set updatecount=100                 " Write swap file to disk every 100 chars
"set autochdir
set directory=$HOME/.vim/.swap      " Directory to use for the swap file
set diffopt=filler,iwhite
set history=10000
"set wrap
"set linebreak
set scrolloff=3
set visualbell t_vb=                " Disable error bells
set shortmess+=A                    " Always edit file
set nobackup                        " close backup files
set nowritebackup
set modifiable
"set laststatus=2
set mouse=a                         " Mouse wheel
let g:netrw_home=$HOME.'/.vim/.swap'
"set showcmd
set magic                           " For regular expressions

" Persistent undo
set undolevels=10000
if has("persistent_undo")
    set undodir=$HOME/.vim/.swap
    set undofile
    set undoreload=10000
endif

" Search settings
set ignorecase                      " ignore case buring search
set smartcase                       " ignore 'ignorecase' when UPPer in search
set hlsearch                        " highlight search
set incsearch                       " do incremental searching
set showmatch                       " show matching parenthese
set wrapscan

set textwidth=0
autocmd FileType c,cmake,cpp,css,fortran,lisp,make,perl,scss,sh,vim
            \ setlocal textwidth=78 colorcolumn=+1 wrap linebreak formatoptions+=t
autocmd FileType html setlocal shiftwidth=2 softtabstop=2 expandtab

" Auto reload when editing it
autocmd! bufwritepost .vimrc source %

" When opening a file, always jump to the last cursor position
autocmd BufReadPost *
            \ if line("'\"") > 0 && line ("'\"") <= line("$") |
            \ exe "normal g'\"zz" |
            \ endif |

" After 4s of inactivity, check for file modifications on next keyrpress
autocmd CursorHold * checktime

" Cscope
if has("cscope")
    set cscopetag
    set csto=0
    if filereadable("cscope.out")
        cs add cscope.out
    endif
    set cscopeverbose
endif

" Keybindings
let mapleader=","
let localmapleader=","

" allow saving files as sudo
cmap w!! w !sudo tee > /dev/null %

" yank to clipboard
if has("clipboard")
    " Copy, paste, undo, save, select all
    vnoremap <C-c> "+y
    nnoremap <C-V> "*p
    nnoremap <C-z> u
    nnoremap <C-s> :w!<cr>
    nnoremap <C-a> ggVG
    set clipboard=unnamed             " copy to the system clipboard
    if has("unnamedplus")             " X11 support
        set clipboard+=unnamedplus
    endif
endif

" Follow scroll wheel to cursor
noremap <ScrollWheelUp>     3k
noremap <ScrollWheelDown>   3j

nnoremap <Leader>s  :%S/
vnoremap <Leader>s  :S/

vnoremap .  :normal .<cr>
vnoremap @  :normal! @

" up/down on displayed lines, not real lines. More useful than painful.
nnoremap k   gk
nnoremap j   gj

" toggle numbers
noremap <Leader>/  :nohlsearch<cr>

" tabprevious and tabnext
noremap <S-l>      :tabprevious<cr>
noremap <S-h>      :tabnext<cr>

" Do also cnext and cprev as a fallback
noremap <PageDown>  :lnext<cr>
noremap <PageUp>    :lprev<cr>

" Disable K for manpages - not used often and easy to accidentally hit
noremap K   k

" Resize window splits
nnoremap <C-k>  3<C-w>-
nnoremap <C-j>  3<C-w>+
nnoremap <C-h>  3<C-w><
nnoremap <C-l>  3<C-w>>

" Split window
nnoremap _  :split<cr>
nnoremap \| :vsplit<cr>

vnoremap s  :!sort<cr>
vnoremap u  :!sort -u<cr>

" colorscheme
try
    if empty(glob('~/.vim/colors/lucario.vim'))
        silent !curl -fLo $HOME/.vim/colors/lucario.vim --create-dirs
                    \ https://raw.githubusercontent.com/raphamorim/lucario/master/colors/lucario.vim
    endif
    colorscheme lucario
    hi CursorLineNr ctermfg=NONE ctermbg=236 cterm=bold guifg=NONE guibg=#405160 gui=NONE
    hi SpecialKey   ctermfg=NONE ctermbg=NONE cterm=NONE guifg=#61bbc8 guibg=NONE gui=NONE
    hi Comment      ctermfg=44 ctermbg=NONE cterm=italic guifg=#5c98cd guibg=NONE gui=italic
    hi clear SignColumn
catch
    colorscheme default
endtry

" Load plug.vim
silent! so $HOME/.vim/plugrc.vim

" vim: set et fenc=utf-8 ff=unix sts=4 sw=4 ts=4 :

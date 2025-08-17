map <leader>; "zy:call writefile(getreg('z', 1, 1), $HOME."/tmp/tt.jl"):silent :!tmux send-keys -t=g:tmux_target $'include("=$HOME/tmp/tt.jl")\n':redraw!
map <leader>. ma?^ *(\=\*\=##j0V/^ *##\*\=)\="zy:call writefile(getreg('z', 1, 1), $HOME."/tmp/tt.jl"):silent :!tmux send-keys -t=g:tmux_target $'include("=$HOME/tmp/tt.jl")\n':redraw!`a
vmap <leader>m  "zymmggewve"xy`m:call writefile([getreg('x', 1, 1)[0].".eval(quote"]+getreg('z', 1, 1)+["end)"], $HOME."/tmp/tt.jl"):silent :!tmux send-keys -t=g:tmux_target $'include("=$HOME/tmp/tt.jl")\n':redraw!

autocmd FileType julia      nmap <buffer>  <leader>m  mmggewve"xy`m:call search('^function', 'b')0V%"zy`m:call writefile([getreg('x', 1, 1)[0].".eval(:("]+getreg('z', 1, 1)+["))"], $HOME."/tmp/tt.jl"):silent :!tmux send-keys -t=g:tmux_target $'include("=$HOME/tmp/tt.jl")\n':redraw!
autocmd FileType sql,aichat nmap <buffer>  <leader>m  mm:call search('^CREATE OR REPLACE', 'b')0ml:call search('\$BODY\$'):call search('\$BODY\$')V`l"zy`m:call writefile(["Postgres.execute(:p0, raw\"\"\""] + getreg('z', 1, 1) + ["\"\"\")"], $HOME."/tmp/tt.jl"):silent :!tmux send-keys -t=g:tmux_target $'include("=$HOME/tmp/tt.jl")\n':redraw!


map <leader>; "zy:call writefile(getreg('z', 1, 1), $HOME."/tmp/tt.jl")
map <leader>. ma?^ *(\=\*\=##
map <leader>m  mmggewve"xy`m:call search('^function', 'b')
vmap <leader>m  "zymmggewve"xy`m:call writefile([getreg('x', 1, 1)[0].".eval(quote"]+getreg('z', 1, 1)+["end)"], $HOME."/tmp/tt.jl")
JULIA_DIR=/nix/store/ywvksia2sycb56mmd7ln6x2xilsil3ww-julia-1.9.4
gcc -g3 -fPIC -c primal-ext.c -I/nix/store/lkam97iwn8s1qhbhvs0zyjv9m80f4sxa-postgresql-15.5/include/server -I$JULIA_DIR/include/julia && gcc -shared -o primal-ext.so primal-ext.o -L$JULIA_DIR/lib -ljulia

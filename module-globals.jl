for n in names(PrimalServer; all=true)
    if getproperty(PrimalServer, n) isa Module && !isdefined(Main, n)
        Main.eval(:($n = PrimalServer.$n))
    end
end

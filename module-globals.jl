for n in names(PrimalServer; all=true)
    if getproperty(PrimalServer, n) isa Module
        Main.eval(:($n = PrimalServer.$n))
    end
end

module PrometheusExporter

import Genie

PORT = Ref(9990)

est() = Main.eval(:sqlstorage)

Genie.route("/metrics") do
    bio = IOBuffer()
    for (k, c) in collect(est().stats)
        k = "primalcache_$(k)"
        if c isa Int
            println(bio, "# TYPE $k counter")
            println(bio, "$k $c")
        end
    end
    println(bio, "# TYPE primalcache_cputime_avg gauge")
    println(bio, "primalcache_cputime_avg $(Main.MetricsLogger.cputime_avg[])")
    String(take!(bio))
end

Genie.config.log_requests = false
function start()
    Genie.isrunning() || Genie.up(PORT[])
end
function stop()
    Genie.isrunning() && Genie.down()
end

end

let d = pwd()
    try
        cd("primal-caching-service")
        include("primal-caching-service/load.jl")
    finally
        cd(d)
    end
end

for fn in [
           "pushgateway_exporter.jl",
           "filterlist.jl",
           "media.jl",
           "spam_detection.jl",
           "firehose_client.jl",
           "firehose_server.jl",
           "cache_server_sync.jl",
          ]
    fn = "src/$fn"
    println(fn, " -> ", include(fn))
end

using Glob: glob

function include_ext(fn)
    d, f = splitdir(fn)
    m, _ = splitext(f)
    mod = eval(Meta.parse(m))
    expr = :(include($(fn)))
    println(expr, " in ", mod)
    mod.eval(expr)
end

for fn in [
           "ext/Utils.jl",
           "ext/MetricsLogger.jl",
           "ext/DB.jl",
           "ext/App.jl",
           "ext/CacheServerHandlers.jl",
          ]
    include_ext(fn)
end

include("firehose_server_default_message_processors.jl")

include("internal_services.jl")

pqconnstr = get(ENV, "PRIMALSERVER_PGCONNSTR", "host=127.0.0.1 dbname=primal user=primal")
DB.PG_DISABLE[] = get(ENV, "PRIMALSERVER_PG_DISABLE", "") == "1"

cache_storage.ext[] = DB.CacheStorageExt(; commons=cache_storage.commons, pqconnstr)

DB.init(cache_storage)

PushGatewayExporter.JOB[] = "primalnode$(NODEIDX)"

function fetching_pushgateway_sender_start()
    global fetching_pushgateway_sender_running = Ref(true)
    global fetching_pushgateway_sender_task = 
    errormonitor(@async while fetching_pushgateway_sender_running[]
                              for sym in [:message_count
                                          :exception_count
                                          :chars_received
                                          :chars_sent]
                                  v = sum(getproperty(f, sym) for f in values(Fetching.fetchers); init=0)
                                  PushGatewayExporter.set!("fetcher_$sym", v)
                              end
                              Utils.active_sleep(15.0, fetching_pushgateway_sender_running)
                          end)
end
function fetching_pushgateway_sender_stop()
    fetching_pushgateway_sender_running[] = false
    wait(fetching_pushgateway_sender_task)
end

CONFIG_FILE = get(ENV, "PRIMALNODE_CONFIG", "primalnode_config.jl")
isfile(CONFIG_FILE) && include(CONFIG_FILE)

CacheServer.PORT[] = 8800+NODEIDX

FirehoseServer.HOST[] = "0.0.0.0"
FirehoseServer.PORT[] = 12000+NODEIDX

InternalServices.PORT[] = 14000+NODEIDX

union!(DB.stat_names, Set([:media_downloads,
                           :media_downloaded_bytes,
                           :media_download_errors,
                           :media_processing_errors,
                          ]))

stuff = []

include("primal-caching-service/disable_keep_alive.jl")

include("ws_conn_unblocker.jl")


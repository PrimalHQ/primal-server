for fn in [
           "utils.jl",
           "nostr.jl",
           "bech32.jl",
           "clocks.jl",
           "perf_stats.jl",
           "fetching.jl",
           "db.jl",
           "metrics_logger.jl",
           "app.jl",
           "perf_test_redirection.jl",
           "cache_server_handlers.jl",
           "cache_server.jl",

           "pushgateway_exporter.jl",
           "filterlist.jl",
           "media.jl",
           "spam_detection.jl",
           "trust_rank.jl",
           "firehose_client.jl",
           "firehose_server.jl",
           "cache_server_sync.jl",
           "event_sync.jl",
           "postgres.jl",
           "blossom.jl",
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



STORAGEPATH   = get(ENV, "PRIMALSERVER_STORAGE_PATH", "$(pwd())/var")
PROXY         = get(ENV, "PRIMALSERVER_PROXY", nothing)
FETCHER_SINCE = try parse(Int, ENV["PRIMALSERVER_FETCHER_SINCE"]) catch _ trunc(Int, time()) end
NODEIDX       = parse(Int, get(ENV, "PRIMALSERVER_NODE_IDX", "1"))
RELAYS_FILE   = get(ENV, "PRIMALSERVER_RELAYS", nothing)

#DB.PRINT_EXCEPTIONS[] = true

gctask = Utils.GCTask(; full=true, period=300)

auto_fetch_missing_events = get(ENV, "PRIMALSERVER_AUTO_FETCH_MISSING_EVENTS", nothing) == "1"

cache_storage = DB.CacheStorage(;
                                directory="$(STORAGEPATH)/primalnode$(NODEIDX)/cache",
                                dbargs=(; ndbs=1, journal_mode="WAL"), 
                                auto_fetch_missing_events)

Fetching.message_processors[:cache_storage] = (msg)->DB.import_msg_into_storage(msg, cache_storage)

Fetching.EVENTS_DATA_DIR[] = "$(STORAGEPATH)/primalnode$(NODEIDX)/fetcher"
Fetching.PROXY_URI[] = PROXY
if isnothing(RELAYS_FILE)
    Fetching.load_relays()
else
    union!(Fetching.relays, [r for r in readlines(RELAYS_FILE) if !isempty(r)])
end

CacheServer.HOST[] = get(ENV, "PRIMALSERVER_HOST", "0.0.0.0")
CacheServer.PORT[] = 8800+NODEIDX

cache_storage.event_processors[:broadcast_event] = CacheServerHandlers.broadcast


CONFIG_FILE = get(ENV, "PRIMALNODE_CONFIG", "primalnode_config.jl")
isfile(CONFIG_FILE) && include(CONFIG_FILE)

pqconnstr = get(ENV, "PRIMALSERVER_PGCONNSTR", "host=127.0.0.1 dbname=primal user=primal")
if startswith(pqconnstr, ":"); pqconnstr = Symbol(pqconnstr[2:end]); end
DB.PG_DISABLE[] = get(ENV, "PRIMALSERVER_PG_DISABLE", "") == "1"

Postgres.server_tracking()

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

CacheServer.PORT[] = 8800+NODEIDX

FirehoseServer.HOST[] = "0.0.0.0"
FirehoseServer.PORT[] = 12000+NODEIDX

InternalServices.PORT[] = 14000+NODEIDX

Blossom.PORT[] = 21000+NODEIDX

union!(DB.stat_names, Set([:media_downloads,
                           :media_downloaded_bytes,
                           :media_download_errors,
                           :media_processing_errors,
                          ]))

stuff = []
stuffd = Dict() |> Utils.ThreadSafe
stuffd_push(k, v) = lock(stuffd) do stuffd; push!(get!(stuffd, k, []), v); end
pexc(body) = try body() catch ex println(ex) end

include("primal-caching-service/disable_keep_alive.jl")

include("ws_conn_unblocker.jl")


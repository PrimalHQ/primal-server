import PrimalServer
include("module-globals.jl")
using PrimalServer: stuff, stuffd

include("env-vars.jl")

#Fetching.TIMEOUT[] = 30

Fetching.EVENTS_DATA_DIR[] = "$(STORAGEPATH)/primalnode$(NODEIDX)/fetcher"
Fetching.PROXY_URI[] = PROXY
if isnothing(RELAYS_FILE)
    Fetching.load_relays()
else
    union!(Fetching.relays, [r for r in readlines(RELAYS_FILE) if !isempty(r)])
end

include("disable_keep_alive.jl")

include("ws_conn_unblocker.jl")

directory="$(STORAGEPATH)/primalnode$(NODEIDX)/cache"

Postgres.SESSIONS_PER_POOL[] = 5
for s in [:p0, :membership, :p0timelimit]
    Postgres.servers[s] = Postgres.Server(; connstr=Postgres.PGConnStr("host=127.0.0.1 port=54017 dbname=primal1 user=pr", ["set statement_timeout=10000"]))
end
Postgres.maintain_connection_pools()

SCmns = DB.StorageCommons{(args...; kwargs...)->Dict()}

pqconnstr = :p0
dbargs = (; connsel=:p0, skipinit=false)
cache_storage = DB.CacheStorage{SCmns, DB.PSQLDict, DB.PSQLSet, DB.PSQLDict}(;
                                dbargs,
                                commons = SCmns(; dbargs=(; rootdirectory="$directory/db")),
                                pqconnstr,
                                events = DB.mkevents(dbargs; init_queries=[]),
                                auto_fetch_missing_events = true,
                                disable_trustrank = true,
                               )

CacheServer.HOST[] = get(ENV, "PRIMALSERVER_HOST", "0.0.0.0")
CacheServer.PORT[] = 8800+NODEIDX

DB.init(cache_storage)

InternalServices.PORT[] = 14000+NODEIDX

DB.VERIFY_ZAPPERS[] = false

App.DAG_OUTPUTS_DB[] = :p0
DAG.PROCESS_SEGMENTS_TASKS[] = 6
DAGRunner.PRINT_EXCEPTIONS[] = true
function cache_storage_ready(cache_storage)
    cache_storage.commons.gc_task[].period[] = 300
    cache_storage.commons.gc_task[].full[] = false
    DAG.init()
    global DAG_20240803_1 = DAG
    DAGRunner.register(:DAG_20240803_1;
                       est=cache_storage, runtag=:dev30,
                       targetserver=:p0,
                       pipeline=DAG_20240803_1.default_pipeline,
                       opts=(; usethreads=false),
                       onsuccessful=function(m)
                           outputs = m.successful[end].result.outputs
                           App.DAG_OUTPUTS[] = (Main.DAG, outputs)
                       end)
    # return
    DAGRunner.start()
    # DVMFeedChecker.start()
end

## start

Postgres.start()

FirehoseServer.PORT[] = 9000+NODEIDX
FirehoseServer.start()

Fetching.start(; since=FETCHER_SINCE)

App.start(cache_storage)
# App.load_lists()
App.start_periodics(cache_storage)
App.register_cache_function(:precalculate_analytics, App.precalculate_analytics, 600)

InternalServices.start(cache_storage)

WSConnUnblocker.start()

CacheServerHandlers.netstats_start()

CacheServer.start()

Blossom.start(cache_storage)

spamdetector = SpamDetection.SpamDetector(; pubkey_follower_cnt_cb=pk->get(cache_storage.pubkey_followers_cnt, pk, 0))
Fetching.message_processors[:cache_storage] = function(msg)
    fetch(Threads.@spawn begin
              SpamDetection.on_message(spamdetector, msg, time())
              tdur = @elapsed begin
                  DB.import_msg_into_storage(msg, cache_storage)
              end
          end)
end
spamdetector.spamlist_processors[:mark_spammers] = function (spamlist)
    for pk in spamlist
        pk in Filterlist.access_pubkey_unblocked && continue
        push!(Filterlist.access_pubkey_blocked_spam, pk)
    end
end
spamdetector.spamevent_processors[:mark_event_as_spam] = function(e)
    s = Filterlist.access_event_blocked_spam
    push!(s, e.id)
    while length(s) >= 100000; popfirst!(s); end
end

# disable humaness checks if we don't have trustrank initialized
DB.ext_is_human(est::DB.CacheStorage, pubkey::Nostr.PubKeyId) = true
DB.is_trusted_user(est::DB.CacheStorage, pubkey::Nostr.PubKeyId) = true

cache_storage_ready(cache_storage)

module CacheStoragePgListener

import JSON

import ..Utils
import ..Nostr
import ..DB
import ..Postgres

ENABLED = Ref{Bool}(false)
RATE_LIMIT_PERIOD = Ref(3600)

LOG = Ref{Bool}(false)

PRINT_EXCEPTIONS = Ref{Bool}(true)

task = Ref{Any}(nothing)
running = Ref{Bool}(true)

cache_storage = Ref{Any}(nothing)

last_notification = Dict{Tuple{Nostr.PubKeyId, Nostr.PubKeyId}, Float64}() # (event_pubkey, follower_pubkey) => last_notification_time

function start(est)
    @assert isnothing(task[])
    cache_storage[] = est
    running[] = true
    task[] = errormonitor(@async listener())
    nothing
end

function stop()
    running[] = false
    wait(task[])
    task[] = nothing
    nothing
end

function listener()
    session = Postgres.make_session(Postgres.servers[:p0].connstr)
    try
        Postgres.execute_simple(session, "listen cache_storage")
        while running[]
            if ENABLED[]
                try
                    notifs = []
                    Postgres.execute_simple(session, "select 1"; 
                                            callbacks=(; 
                                                       on_notice=(_)->nothing,
                                                       on_row_description=(_)->nothing,
                                                       on_row=(_)->nothing,
                                                       on_notification_response=(n)->push!(notifs, n),
                                                      ))
                    Base.invokelatest(handle_notifications, notifs)
                catch _
                    PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                end
            end
            sleep(1)
        end
    finally
        try close(session) catch _ end
    end
end

function handle_notifications(notifs)
    LOG[] && println("CacheStoragePgListener: received $(length(notifs)) notifications")
    for n in notifs
        try
            d = JSON.parse(n.payload)
            if d["type"] == "live_event"
                kind, pubkey, identifier = d["kind"], Nostr.PubKeyId(d["pubkey"]), d["identifier"]
                for r in Postgres.execute(:p0, "
                                          select es.* from parametrized_replaceable_events pre, events es 
                                          where pre.kind = \$1 and pre.pubkey = \$2 and pre.identifier = \$3 and pre.event_id = es.id
                                          ", [kind, pubkey, identifier])[2]
                    e = Main.App.event_from_row(r)
                    host_pubkey = nothing
                    for tag in e.tags
                        if length(tag.fields) >= 4 && tag.fields[1] == "p" && lowercase(tag.fields[4]) == "host"
                            host_pubkey = Nostr.PubKeyId(tag.fields[2])
                            break
                        end
                    end
                    if !isnothing(host_pubkey)
                        for (follower_pubkey,) in Postgres.execute(:p0, "select follower_pubkey from pubkey_followers pk where pubkey = \$1", [host_pubkey])[2]
                            follower_pubkey = Nostr.PubKeyId(follower_pubkey)
                            for _ in Postgres.execute(:p0, "
                                                 insert into live_event_notification_created values (\$1, \$2, \$3, \$4, \$5)
                                                 on conflict do nothing
                                                 returning 1
                                                 ", [kind, pubkey, identifier, follower_pubkey, Utils.current_time()])[2]
                                if isempty(Postgres.execute(:p0, "select 1 from live_event_pubkey_filterlist where user_pubkey = \$1 and blocked_pubkey = \$2 limit 1", [follower_pubkey, host_pubkey])[2])
                                    coord = "$(kind):$(Nostr.hex(pubkey)):$(identifier)"
                                    k = (host_pubkey, follower_pubkey)
                                    t = Utils.current_time()
                                    if !haskey(last_notification, k) || (t - last_notification[k] >= RATE_LIMIT_PERIOD[])
                                        @show coord
                                        last_notification[k] = t
                                        DB.notification(cache_storage[], follower_pubkey, e.created_at, DB.LIVE_EVENT_HAPPENING,
                                                        #= live_event =# e.id, #= host =# host_pubkey, #= coord =# coord)
                                    end
                                end
                            end
                        end
                    end
                    break
                end
            end
        catch _
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        end
    end
end

end


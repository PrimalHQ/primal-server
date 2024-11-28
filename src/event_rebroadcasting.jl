module EventRebroadcasting

import ..Dates
import ..JSON
import ..SHA

import ..Utils
import ..Nostr
import ..Postgres
import ..NostrClient
using ..Tracing: @tr

PRINT_EXCEPTIONS = Ref(false)
LOG = Ref(false)

exceptions_lock = ReentrantLock()

const RUN_PERIOD = Ref(1)
const TIMEOUT = Ref(30)
const EVENT_RATE = Ref(10.0)
const BATCH_SIZE = Ref(100)
const TASKS = Ref(8)

const task = Ref{Any}(nothing)
const running = Ref(true)

function start()
    @assert isnothing(task[]) || istaskdone(task[])

    @tr running[] = true

    task[] = 
    errormonitor(@async while running[]
                     try
                         Base.invokelatest(run_rebroadcasting)
                     catch _
                         PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                     end
                     Utils.active_sleep(RUN_PERIOD[], running)
                 end)

    nothing
end

function stop()
    @assert !isnothing(task[])
    @tr running[] = false
    Utils.wait_for(()->istaskdone(task[]))
end

function run_rebroadcasting()
    funcname = "run_rebroadcasting"

    rs = Postgres.execute(:membership, "
                          select pubkey, event_created_at, kinds, target_relays, batchhash, event_idx
                          from event_rebroadcasting 
                          where started_at is not null and finished_at is null")[2]
    asyncmap(rs; ntasks=TASKS[]) do r
        (pubkey, since, kinds, relays, pbatchhash, event_idx) = r
        pubkey = Nostr.PubKeyId(pubkey)
        @tr (; pubkey, since, kinds, relays, pbatchhash, event_idx)
        # @show (:rebroadcasting, pubkey, Dates.unix2datetime(since))
        try
            (events, cnt) = Main.App.get_user_events(Main.cache_storage; pubkey, since, limit=BATCH_SIZE[], kinds)
            batchhash = SHA.sha256(JSON.json(events))
            if !ismissing(pbatchhash) && pbatchhash == batchhash
                Postgres.execute(:membership, "update event_rebroadcasting set finished_at = now(), status = 'finished fine' where pubkey = \$1", 
                                 [pubkey])
            else
                intidx = Ref(0)
                res = broadcast_events(relays, events;
                                       on_first_accept=function (e)
                                           intidx[] += 1
                                           Postgres.execute(:membership, "update event_rebroadcasting set event_idx_intermediate = \$2 where pubkey = \$1", 
                                                            [pubkey, event_idx+intidx[]])
                                       end)
                @tr res
                Postgres.execute(:membership, "update event_rebroadcasting set last_batch_status = \$2 where pubkey = \$1", 
                                 [pubkey, JSON.json(res, 2)])
                if @tr res.success[]
                    Postgres.execute(:membership, "update event_rebroadcasting set event_created_at = \$2, event_idx = event_idx + \$3, batchhash = \$4 where pubkey = \$1", 
                                     [pubkey, events[end].created_at, cnt, batchhash])
                end
            end
        catch _
            Postgres.execute(:membership, "update event_rebroadcasting set exception = \$2, finished_at = now(), status = 'failed' where pubkey = \$1", 
                             [pubkey, Utils.get_exceptions()])
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        end
    end
end

function broadcast_events(
        relays::Vector, events::Vector{Nostr.Event}; 
        timeout=TIMEOUT[], 
        on_first_accept::Function=(e::Nostr.Event)->nothing,
    )
    funcname = "broadcast_events"

    cond = Condition()

    cnts = (; 
            relays_started = Ref(0),
            relays_done    = Ref(0),
            per_eid        = Dict{Nostr.EventId, Int}(),
            sends          = Ref(0),
            duplicates     = Ref(0),
            success        = Ref(false),
           ) |> Utils.ThreadSafe

    function handle_connection(client)
        lock(cnts) do cnts
            cnts.relays_started[] += 1
        end
        try
            for e in events
                @tr (:event, (; client.relay_url, e.id, e.pubkey, e.created_at))
                NostrClient.send(client, e; 
                                 on_response=function (m)
                                     # @show m
                                     @tr (:response, (; client.relay_url, e.id, e.pubkey, e.created_at, m))
                                     try
                                         if m[1] == "OK"
                                             eid = Nostr.EventId(m[2])
                                             lock(cnts) do cnts
                                                 cnts.sends[] += 1
                                                 m[3] || (cnts.duplicates[] += 1)
                                                 haskey(cnts.per_eid, eid) || on_first_accept(e)
                                                 cnts.per_eid[eid] = get(cnts.per_eid, eid, 0) + 1
                                             end
                                         end
                                     catch _
                                         PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                                     end
                                 end)
                sleep(1.0/EVENT_RATE[])
            end
        catch _
            @tr (:event, (; client.relay_url, exception=Utils.get_exceptions()))
        end
        lock(cnts) do cnts
            cnts.relays_done[] += 1
            if cnts.relays_done[] == cnts.relays_started[]
                notify(cond, cnts)
            end
        end
    end

    @async begin
        sleep(timeout)
        notify(cond, NostrClient.Timeout("broadcast_events"); error=true)
    end

    clients = []
    for relay_url in relays
        push!(clients, NostrClient.Client(relay_url;
                                          on_connect=(client)->@async try
                                              @tr handle_connection(client)
                                          catch _
                                              PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                                          end))
    end

    try
        res = wait(cond)
        if res isa Exception
            throw(res)
        else
            lock(cnts) do cnts
                res.success[] = length(cnts.per_eid) == length(events)
                (; 
                 success        = cnts.success[],
                 relays         = length(relays),
                 relays_started = cnts.relays_started[],
                 relays_done    = cnts.relays_done[],
                 events         = length(events),
                 events_done    = length(cnts.per_eid),
                 sends          = cnts.sends[],
                 duplicates     = cnts.duplicates[],
                 per_eid        = Dict([Nostr.hex(eid)=>cnt for (eid, cnt) in cnts.per_eid]),
                )
            end
        end
    finally
        for client in clients
            @async try close(client) catch ex println(ex) end
        end
    end
end

end

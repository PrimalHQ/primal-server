module SpamDetection

import JSON
using DataStructures: CircularBuffer, SortedDict

import ..Utils
using ..Utils: ThreadSafe, Throttle
import ..Nostr
import ..DB
import ..PushGatewayExporter

PRINT_EXCEPTIONS = Ref(true)

TClusters = Dict{Set{String}, Vector{Nostr.EventId}}

Base.@kwdef struct SpamDetector
    SPAMLIST_PERIOD = Ref(1200.0)
    CLUSTER_SIZE_THRESHOLD = Ref(10)
    MIN_NOTE_SIZE = Ref(3) # words
    FOLLOWER_CNT_THRESHOLD = Ref(50)

    spamlist_processors = SortedDict{Symbol, Function}() |> ThreadSafe
    spamlist_processors_errors = CircularBuffer(200) |> ThreadSafe

    spamevent_processors = SortedDict{Symbol, Function}() |> ThreadSafe
    spamevent_processors_errors = CircularBuffer(200) |> ThreadSafe

    import_lock = ReentrantLock()

    events = Dict{Nostr.EventId, Nostr.Event}()
    latest_events = Dict{Nostr.EventId, Nostr.Event}()

    clusters = TClusters()
    latest_clusters = TClusters()
    latest_spamlist = Set{Nostr.PubKeyId}()

    realtime_spamlist = Set{Nostr.PubKeyId}()
    realtime_spamlist_diff = Set{Nostr.PubKeyId}()
    realtime_spamlist_periodic = Throttle(; period=10.0)
    realtime_spam_note_cnt = Ref(0)
    latest_realtime_spam_note_cnt = Ref(0)
    latest_realtime_spamlist = Set{Nostr.PubKeyId}()

    tlatest = Ref(0.0)

    max_msg_duration = Ref(0.0) |> ThreadSafe
    max_spammer_follower_cnt = Ref(0) |> ThreadSafe

    pubkey_follower_cnt_cb = nothing
end

function is_spam(ewords, cwords)
    abs(length(ewords) - length(cwords)) / length(cwords) < 0.10 && # length of note is similar enough
    length(intersect(ewords, cwords)) / length(cwords) > 0.90       # content of note is similar enough
end

function on_message(sd::SpamDetector, msg::String, time::Float64)::Bool
    relay, e = try DB.event_from_msg(JSON.parse(msg)) catch _; ("", nothing) end
    e isa Nostr.Event || return true
    on_event(sd, e, time)
end

function on_event(sd::SpamDetector, e::Nostr.Event, time::Float64=Float64(e.created_at))::Bool
    notspam = Ref(true)
    try
        tdur = @elapsed begin
            lock(sd.import_lock) do
                (e.created_at < time+300) || return
                e.kind == Int(Nostr.TEXT_NOTE) || return
                haskey(sd.events, e.id) && return
                sd.events[e.id] = e
                Nostr.verify(e) || return

                isnothing(sd.pubkey_follower_cnt_cb) || sd.pubkey_follower_cnt_cb(e.pubkey) < sd.FOLLOWER_CNT_THRESHOLD[] || return

                s = replace(e.content, r"[:;/.,?!'\n，]"=>' ')
                ewords = Set(split(s))
                if length(ewords) >= sd.MIN_NOTE_SIZE[]
                    for (cwords, cvec) in sd.latest_clusters
                        if length(cvec) >= sd.CLUSTER_SIZE_THRESHOLD[] && is_spam(ewords, cwords)
                            # @show sd.realtime_spam_note_cnt[] += 1
                            notspam[] = false
                            push!(sd.realtime_spamlist, e.pubkey)
                            push!(sd.realtime_spamlist_diff, e.pubkey)
                            sd.realtime_spamlist_periodic() do
                                # @show :realtime_spamlist_periodic
                                process_spamlist(sd, sd.realtime_spamlist_diff)
                                empty!(sd.realtime_spamlist_diff)
                            end
                            lock(sd.spamevent_processors) do mprocs
                                for processor in values(mprocs)
                                    try Base.invokelatest(processor, e)
                                    catch ex
                                        push!(sd.spamevent_processors_errors, (e, ex))
                                        #rethrow()
                                    end
                                end
                            end
                            break
                        end
                    end
                    for (cwords, cvec) in sd.clusters
                        if is_spam(ewords, cwords)
                            push!(cvec, e.id)
                            @goto cont
                        end
                    end
                    sd.clusters[ewords] = [e.id]
                    @label cont
                end

                t = time
                if t - sd.tlatest[] >= sd.SPAMLIST_PERIOD[]
                    sd.tlatest[] = t

                    copy!(sd.latest_events, sd.events)
                    copy!(sd.latest_clusters, sd.clusters)
                    copy!(sd.latest_realtime_spamlist, sd.realtime_spamlist)
                    empty!(sd.events)
                    empty!(sd.clusters)
                    empty!(sd.realtime_spamlist)

                    sd.latest_realtime_spam_note_cnt[] = sd.realtime_spam_note_cnt[]
                    sd.realtime_spam_note_cnt[] = 0

                    produce_spamlist(sd)

                    PushGatewayExporter.set!("cache_spam_latest_spamlist_length", length(sd.latest_spamlist))
                    PushGatewayExporter.set!("cache_spam_latest_realtime_spam_note_cnt", sd.latest_realtime_spam_note_cnt[])
                end
            end
        end
        lock(sd.max_msg_duration) do max_msg_duration
            max_msg_duration[] = max(tdur, max_msg_duration[])
        end
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        rethrow()
    end
    notspam[]
end

function produce_spamlist(sd::SpamDetector)
    empty!(sd.latest_spamlist)
    union!(sd.latest_spamlist, 
           [sd.latest_events[eid].pubkey 
            for (_, cvec) in sd.latest_clusters 
            for eid in cvec 
            if length(cvec) >= sd.CLUSTER_SIZE_THRESHOLD[]])

    process_spamlist(sd, sd.latest_spamlist)
end

function process_spamlist(sd::SpamDetector, spamlist)
    if !isnothing(sd.pubkey_follower_cnt_cb)
        lock(sd.max_spammer_follower_cnt) do max_spammer_follower_cnt
            max_spammer_follower_cnt[] = 
            max(max_spammer_follower_cnt[], 
                maximum([sd.pubkey_follower_cnt_cb(pk) for pk in collect(spamlist)]; init=0))
        end
    end

    lock(sd.spamlist_processors) do mprocs
        for processor in values(mprocs)
            try Base.invokelatest(processor, spamlist)
            catch ex
                push!(sd.spamlist_processors_errors, (lst, ex))
                #rethrow()
            end
        end
    end
end

function get_clusters(sd::SpamDetector; limit=50)
    [(cwords, length(cvec), Set([sd.latest_events[eid].pubkey for eid in cvec]))
     for (cwords, cvec) in first(sort(collect(sd.latest_clusters); by=c->-length(c[2])), limit)]
end

end

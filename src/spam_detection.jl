module SpamDetection

import JSON
using DataStructures: CircularBuffer, SortedDict

using ..Utils: ThreadSafe, Throttle
import ..Nostr
import ..DB
import ..PushGatewayExporter

PRINT_EXCEPTIONS = Ref(true)

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

TClusters = Dict{Set{String}, Vector{Nostr.EventId}}
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

function is_spam(ewords, cwords)
    abs(length(ewords) - length(cwords)) / length(cwords) < 0.10 && # length of note is similar enough
    length(intersect(ewords, cwords)) / length(cwords) > 0.90       # content of note is similar enough
end

function on_message(msg::String)::Bool
    notspam = Ref(true)
    try
        tdur = @elapsed begin
            lock(import_lock) do
                e = try DB.event_from_msg(JSON.parse(msg)) catch _ end
                e isa Nostr.Event || return
                (e.created_at < time()+300) || return
                e.kind == Int(Nostr.TEXT_NOTE) || return
                haskey(events, e.id) && return
                events[e.id] = e
                Nostr.verify(e) || return

                get(Main.cache_storage.pubkey_followers_cnt, e.pubkey, 0) < FOLLOWER_CNT_THRESHOLD[] || return

                s = replace(e.content, r"[:;/.,?!'\n，]"=>' ')
                ewords = Set(split(s))
                if length(ewords) >= MIN_NOTE_SIZE[]
                    for (cwords, cvec) in latest_clusters
                        if length(cvec) >= CLUSTER_SIZE_THRESHOLD[] && is_spam(ewords, cwords)
                            realtime_spam_note_cnt[] += 1
                            notspam[] = false
                            push!(realtime_spamlist, e.pubkey)
                            push!(realtime_spamlist_diff, e.pubkey)
                            realtime_spamlist_periodic() do
                                process_spamlist(realtime_spamlist_diff)
                                empty!(realtime_spamlist_diff)
                            end
                            lock(spamevent_processors) do mprocs
                                for processor in values(mprocs)
                                    try Base.invokelatest(processor, e)
                                    catch ex
                                        push!(spamevent_processors_errors, (e, ex))
                                        #rethrow()
                                    end
                                end
                            end
                            break
                        end
                    end
                    for (cwords, cvec) in clusters
                        if is_spam(ewords, cwords)
                            push!(cvec, e.id)
                            @goto cont
                        end
                    end
                    clusters[ewords] = [e.id]
                    @label cont
                end

                t = time()
                if t - tlatest[] >= SPAMLIST_PERIOD[]
                    tlatest[] = t

                    copy!(latest_events, events)
                    copy!(latest_clusters, clusters)
                    copy!(latest_realtime_spamlist, realtime_spamlist)
                    empty!(events)
                    empty!(clusters)
                    empty!(realtime_spamlist)

                    latest_realtime_spam_note_cnt[] = realtime_spam_note_cnt[]
                    realtime_spam_note_cnt[] = 0

                    produce_spamlist()

                    PushGatewayExporter.set!("cache_spam_latest_spamlist_length", length(latest_spamlist))
                    PushGatewayExporter.set!("cache_spam_latest_realtime_spam_note_cnt", latest_realtime_spam_note_cnt[])
                end
            end
        end
        lock(max_msg_duration) do max_msg_duration
            max_msg_duration[] = max(tdur, max_msg_duration[])
        end
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        rethrow()
    end
    notspam[]
end

function produce_spamlist()
    empty!(latest_spamlist)
    union!(latest_spamlist, 
           [latest_events[eid].pubkey 
            for (_, cvec) in latest_clusters 
            for eid in cvec 
            if length(cvec) >= CLUSTER_SIZE_THRESHOLD[]])

    process_spamlist(latest_spamlist)
end

function process_spamlist(spamlist)
    lock(max_spammer_follower_cnt) do max_spammer_follower_cnt
        max_spammer_follower_cnt[] = 
        max(max_spammer_follower_cnt[], 
            maximum([get(Main.cache_storage.pubkey_followers_cnt, pk, 0) 
                     for pk in collect(spamlist)]))
    end

    lock(spamlist_processors) do mprocs
        for processor in values(mprocs)
            try Base.invokelatest(processor, spamlist)
            catch ex
                push!(spamlist_processors_errors, (lst, ex))
                #rethrow()
            end
        end
    end
end

function get_clusters(limit=50)
    [(cwords, length(cvec), Set([latest_events[eid].pubkey for eid in cvec]))
     for (cwords, cvec) in first(sort(collect(latest_clusters); by=c->-length(c[2])), limit)]
end

end

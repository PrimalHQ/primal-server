module DVMServiceProvider

import JSON
import SHA
using Dates: datetime2unix, DateTime

import ..Utils
import ..Nostr
import ..NostrClient
import ..Postgres

PRINT_EXCEPTIONS = Ref(true)

exceptions_lock = ReentrantLock()

NIP89_HANDLER_INFORMATION=31990
NIP90_NOSTR_CONTENT_DISCOVERY_REQUEST=5300
NIP90_NOSTR_CONTENT_DISCOVERY_RESULT=6300
NIP90_JOB_FEEDBACK=7000

PRIMAL_DVM_KEYPAIR_SALT = Ref{Any}(nothing)

RELAY_URLS = ["ws://192.168.18.7:7777", "wss://relay.damus.io", "wss://nostr.mom"]
# RELAY_URLS = ["ws://192.168.14.7:7777", "wss://nostr.mom"]

clients = []
keypairs = Dict{String, NamedTuple}()

function start()
    @assert isempty(clients)

    for relay_url in RELAY_URLS
        push!(clients, connect_client(relay_url))
    end

    nothing
end

function stop()
    @assert !isempty(clients)
    for client in clients
        try close(client) catch ex; println(ex); end
    end
    empty!(clients)
    nothing
end

function connect_client(relay_url)
    NostrClient.Client(relay_url;
                       on_connect=(client)->@async try
                           on_connect(client)
                       catch _
                           lock(exceptions_lock) do
                               PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                           end
                       end)
end

FEEDS = [
         ("primal-dvm-0", :active,
          "Trending on Primal 4h",
          "Global trending notes in the past 4 hours",
          "https://m.primal.net/LsXL.png",
          "{\"id\":\"global-trending\",\"kind\":\"notes\",\"hours\":4}",
          false),
         ("primal-dvm-1", :deleted,
          "Trending 4h Notes on Primal",
          "Trending notes on Primal posted in the last four hours",
          "",
          "",
          false),
         ("primal-dvm-2", :active,
          "Trending on Primal 24h",
          "Global trending notes in the past 24 hours",
          "https://m.primal.net/LsDT.png",
          "{\"id\":\"global-trending\",\"kind\":\"notes\",\"hours\":24}",
          false),
         ("primal-dvm-3", :deleted,
          "Nostr Topic Reads",
          "Nostr Topic Reads",
          "",
          "",
          true),
         ("primal-dvm-4", :deleted,
          "Bitcoin Topic Reads",
          "Bitcoin Topic Reads",
          "",
          "",
          false),
         ("primal-dvm-5", :deleted,
          "Linux Topic Reads - deletion test",
          "Linux Topic Reads - deletion test",
          "",
          "",
          false),
         ("primal-dvm-6", :active,
          "Trending on Primal 1h",
          "Global trending notes in the past hour",
          "https://m.primal.net/LsDO.png",
          "{\"id\":\"global-trending\",\"kind\":\"notes\",\"hours\":1}",
          false),
         ("primal-dvm-7", :active,
          "Trending on Primal 12h",
          "Global trending notes in the past 12 hours",
          "https://m.primal.net/LsDc.png",
          "{\"id\":\"global-trending\",\"kind\":\"notes\",\"hours\":12}",
          false),
         ("primal-dvm-8", :active,
          "Trending on Primal 48h",
          "Global trending notes in the past 48 hours",
          "https://m.primal.net/LsDf.png",
          "{\"id\":\"global-trending\",\"kind\":\"notes\",\"hours\":48}",
          false),
         ("primal-dvm-9", :active,
          "Trending on Primal 7d",
          "Global trending notes in the past 7 days",
          "https://m.primal.net/LsDh.png",
          "{\"id\":\"global-trending\",\"kind\":\"notes\",\"hours\":168}",
          false),
        ]

function on_connect(client)
    println("dvm: connected to $(client.relay_url)")

    hinfo = (;
             amount="free",
             personalized=false,
             cashuAccepted=false,
             nip90Params=(;
                          max_results=(;
                                       values=[],
                                       required=false,
                                       description="The number of maximum results to return (default currently 100)"
                                      )
                         ),
             encryptionSupported=false,
             lud16="primal@primal.net",
             # subscription=true,
            )

    for (feed_id, state, name, about, image, spec, verifiedonly) in FEEDS
        seckey, pubkey = Nostr.generate_keypair(; seckey=SHA.sha256([PRIMAL_DVM_KEYPAIR_SALT[]; collect(transcode(UInt8, feed_id))]))
        keypairs[feed_id] = (; seckey, pubkey, verifiedonly)
        created_at = trunc(Int, datetime2unix(DateTime("2024-11-04T15:00"))) # bump when any feed is updated
        eact = Nostr.Event(seckey, pubkey,
                           created_at,
                           NIP89_HANDLER_INFORMATION,
                           [Nostr.TagAny(t)
                            for t in [["d", feed_id],
                                      ["k", "$NIP90_NOSTR_CONTENT_DISCOVERY_REQUEST"],
                                     ]],
                           JSON.json((; hinfo..., 
                                      name, about, picture=image, image, 
                                      primal_spec=spec,
                                      (verifiedonly ? [:subscription=>verifiedonly] : [])...)))
        edel = Nostr.Event(seckey, pubkey,
                           created_at,
                           Int(Nostr.EVENT_DELETION),
                           [Nostr.TagAny(t) for t in [
                                                      ["e", Nostr.hex(eact.id)],
                                                      ["a", "$(NIP89_HANDLER_INFORMATION):$(Nostr.hex(pubkey)):$(feed_id)"],
                                                     ]],
                           "")
        e = 
        if     state == :active; eact
        elseif state == :deleted; edel
        else; error("invalid DVM feed state: $state")
        end
        NostrClient.send(client, e; timeout=(5.0, "dvm: handler info event ack for $(client.relay_url)")) do m, done
            # @show (client.relay_url, m)
            m[1] == "OK" || error("dvm: broadcasting to $(client.relay_url) handler info event for feed $feed_id failed")
            done(:ok)
        end

        if state == :active
            NostrClient.subscription(client, (; 
                                              limit=0,
                                              kinds=[NIP90_NOSTR_CONTENT_DISCOVERY_REQUEST], 
                                              Symbol("#p")=>[pubkey])) do m
                try
                    handle_request(client, m)
                catch _
                    lock(exceptions_lock) do
                        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                    end
                end
            end
        end
    end
end

function handle_request(client, m)
    m[1] == "EVENT" || return
    push!(Main.stuff, (:dvm_handle_request, (; m)))
    e = Nostr.Event(m[3])
    @assert e.kind == NIP90_NOSTR_CONTENT_DISCOVERY_REQUEST
    @assert Nostr.verify(e)

    limit = 100
    relays = copy(RELAY_URLS)
    user_pubkey = e.pubkey
    feed_id = nothing
    for t in e.tags
        if length(t.fields) >= 3 && t.fields[1] == "param"
            if t.fields[2] == "max_results"
                limit = parse(Int, t.fields[3])
            elseif t.fields[2] == "user"
                user_pubkey = Nostr.PubKeyId(t.fields[3])
            end
        elseif length(t.fields) >= 1 && t.fields[1] == "relays"
            append!(relays, t.fields[2:end])
        elseif length(t.fields) >= 2 && t.fields[1] == "p"
            dvmpk = Nostr.PubKeyId(t.fields[2])
            for (id, (_, pk)) in collect(keypairs)
                if pk == dvmpk
                    feed_id = id
                    break
                end
            end
        end
    end

    haskey(keypairs, feed_id) || return

    # @show feed_id

    Postgres.execute(:membership, "insert into dvm_usage values (\$1, \$2, \$3, \$4) on conflict do nothing",
                     [e.id, e.created_at, e.pubkey, feed_id])

    function send(re)
        errormonitor(@async Main.App.broadcast_event_to_relays_async(re; relays=RELAY_URLS))
        # errormonitor(@async Main.App.broadcast_event_to_relays_async(re; relays=[client.relay_url]))
        # NostrClient.send(client, re; timeout=5.0) do m, done
        #     m[1] == "OK" || error("dvm: broadcasting to $(client.relay_url) for feed $feed_id failed")
        #     done(:ok)
        # end
    end

    eids = 
    if keypairs[feed_id].verifiedonly && isempty(Main.InternalServices.nostr_json_query_by_pubkey(e.pubkey))
        # re = Nostr.Event(keypairs[feed_id].seckey, keypairs[feed_id].pubkey,
        #                 # trunc(Int, time()), 
        #                 trunc(Int, datetime2unix(DateTime("2024-08-08"))),
        #                 Int(Nostr.TEXT_NOTE),
        #                 [Nostr.TagAny(t) for t in []],
        #                 "error: user not verified @primal")
        # send(re)
        # [re.id]
        re = Nostr.Event(keypairs[feed_id].seckey, keypairs[feed_id].pubkey,
                         trunc(Int, time()), 
                         NIP90_JOB_FEEDBACK,
                         [Nostr.TagAny(t) for t in [["status", "error", "user not verified @primal"],
                                                    ["e", Nostr.hex(e.id)],
                                                    ["p", Nostr.hex(e.pubkey)],
                                                   ]],
                         "")
        send(re)
        []
    else
        res = []
        ok = false
        for (fid, state, _, _, _, spec, verifiedonly) in FEEDS
            if state == :active && feed_id == fid
                append!(res, Main.App.mega_feed_directive(Main.cache_storage; spec, user_pubkey))
                ok = true
                break
            end
        end
        ok || return

        [e.id for e in res if e.kind == 1 || e.kind == 30023 || e.kind == 10030023]
    end

    # @show (feed_id, length(eids))

    isempty(eids) && return

    content = JSON.json([["e", Nostr.hex(eid)] for eid in eids]) 

    re = Nostr.Event(keypairs[feed_id].seckey,
                     keypairs[feed_id].pubkey,
                     trunc(Int, time()), 
                     NIP90_NOSTR_CONTENT_DISCOVERY_RESULT,
                     [Nostr.TagAny(t)
                      for t in [["e", Nostr.hex(e.id)],
                                ["p", Nostr.hex(e.pubkey)],
                                ["request", JSON.json(e)],
                                ["status", "success"],
                               ]],
                     content)
    send(re)
end

function nip89_delete_announcement(seckey::Nostr.SecKey, pubkey::Nostr.PubKeyId; eid=nothing, feed_id=nothing)
    tags = [
            (isnothing(eid)     ? [] : [["e", Nostr.hex(eid)]])...,
            (isnothing(feed_id) ? [] : [["a", "$(NIP89_HANDLER_INFORMATION):$(Nostr.hex(pubkey)):$(feed_id)"]])...,
           ]
    @assert !isempty(tags)

    Nostr.Event(seckey, pubkey,
                trunc(Int, time()), 
                Int(Nostr.EVENT_DELETION),
                [Nostr.TagAny(t) for t in tags],
                "")
end

end

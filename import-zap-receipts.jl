##
@time eids = collect(keys(cache_storage.event_ids))
##
empty!(cache_storage.zap_receipts)
empty!(cache_storage.pubkey_zapped)
# empty!(cache_storage.dyn[:pubkey_zap_stats])
#
running = Utils.PressEnterToStop()
i = Ref(0) |> Utils.ThreadSafe
cnt = Ref(0) |> Utils.ThreadSafe
errs = Ref(0) |> Utils.ThreadSafe
tstart = time()
#@time for (i, eid) in enumerate(eids)
@time Threads.@threads for eid in eids #[120_000_000:length(eids)]
    yield()
    running[] || break
    DB.incr(i)
    i[] % 10000 == 0 && print("$(i[])  $(time()-tstart)s   \r")
    e = cache_storage.events[eid]
    e.kind == Int(Nostr.ZAP_RECEIPT) || continue
    DB.incr(cnt)
    try
        amount_sats = 0
        parent_eid = nothing
        zapped_pk = nothing
        description = nothing
        for tag in e.tags
            if length(tag.fields) >= 2
                if tag.fields[1] == "e"
                    parent_eid = try Nostr.EventId(tag.fields[2]) catch _ end
                elseif tag.fields[1] == "p"
                    zapped_pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end
                elseif tag.fields[1] == "bolt11"
                    b = tag.fields[2]
                    if !isnothing(local amount = DB.parse_bolt11(b))
                        if amount <= DB.MAX_SATSZAPPED[]
                            amount_sats = amount
                        end
                    end
                elseif tag.fields[1] == "description"
                    description = try Nostr.Event(JSON.parse(tag.fields[2])) catch _ nothing end
                end
            end
        end
        if amount_sats > 0 && !isnothing(description) && !isnothing(parent_eid)
            DB.import_zap_receipt(cache_storage, e, parent_eid, amount_sats)
            if !isnothing(zapped_pk)
                DB.ext_pubkey(est, zapped_pk)
                DB.ext_pubkey_zap(est, e, zapped_pk, amount_sats)
            end
        end
    catch _
        DB.incr(errs)
        #Utils.print_exceptions()
        # break
    end
end
@show cnt[]
@show errs[]
nothing
##

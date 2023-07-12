##
@time eids = [eid for (eid, _) in collect(cache_storage.event_ids)]
empty!(cache_storage.pubkey_directmsgs)
empty!(cache_storage.pubkey_directmsgs_cnt)
##
eids=[Nostr.EventId(eid) for (eid,) in DB.exec(cache_storage.pubkey_directmsgs, "select event_id from pubkey_directmsgs order by created_at")]
empty!(cache_storage.pubkey_directmsgs_cnt)
##
running = Utils.PressEnterToStop()
errs = Ref(0)
ttotal = Ref(0.0)
tstart = time()
@time for (i, eid) in enumerate(eids)
    yield()
    running[] || break
    i % 1000 == 0 && print("$i  $(time()-tstart)s  $((time()-tstart)/i)s/e    \r")
    e = cache_storage.events[eid]
    e.kind == Int(Nostr.DIRECT_MESSAGE) || continue
    try
        ttotal[] += @elapsed DB.import_directmsg(cache_storage, e)
    catch _
        errs[] += 1
        Utils.print_exceptions()
    end
end
errs[], ttotal[], ttotal[]/length(eids)
##

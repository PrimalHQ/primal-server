##
mds = collect(cache_storage.meta_data)
@show length(mds)
##
running = Utils.PressEnterToStop()
errs = Ref(0)
ttotal = Ref(0.0)
tstart = time()
cnt = Ref(0)
@time for (i, (pk, eid)) in enumerate(mds)
    # i <= 2019000 && continue
    yield()
    running[] || break
    i % 1000 == 0 && print("$i/$(length(mds))  $(time()-tstart)s  $((time()-tstart)/i)s/e    \r")
    try
        e = cache_storage.events[eid]
        cache_storage.pubkey_followers_cnt[e.pubkey] >= 10 || continue
        ttotal[] += @elapsed begin
            d = JSON.parse(e.content)
            for a in ["banner", "picture"]
                if haskey(d, a)
                    url = d[a]
                    if !isempty(url)
                        _, ext = splitext(lowercase(url))
                        if ext in DB.image_exts
                            cnt[] += 1
                            if isempty(DB.exec(cache_storage.event_media, "select 1 from event_media where event_id = ? and url = ? limit 1", (eid, url,)))
                                while Media.media_queue_executor_taskcnt[] >= 5 && running[]; sleep(0.1); end
                                println("downloading ", i, " ", url)
                                DB.import_media_async(cache_storage, e.id, url, Media.all_variants)
                            else
                                println("skipping    ", i, " ", url)
                            end
                        end
                    end
                end
            end
        end
    catch _
        errs[] += 1
        Utils.print_exceptions()
    end
end
println()
cnt[], errs[], ttotal[], ttotal[]/length(mds)
##
url = "https://nostr.build/i/525a0fe39c0871a192a46682c7833862cdab14e2c4159e3d683a8bec51b7f0cb.jpg"
DB.exec(cache_storage.media, "select * from media where url = ? limit 1", (url,))
DB.exec(cache_storage.media, "select * from media limit 1")
##

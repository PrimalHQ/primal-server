##
pks=keys(cache_storage.meta_data)
##
cnt = Ref(0)
propnames = DataStructures.Accumulator{String, Int}()
@time for (i, pk) in enumerate(pks[1:end])
    #i == 100000 && break
    yield()
    i % 1000 == 0 && print("$i  $(cnt[])  \r")
    # get(cache_storage.pubkey_followers_cnt, pk, 0) >= 3 || continue
    try
        local c = JSON.parse(cache_storage.events[cache_storage.meta_data[pk]].content)
        !isnothing(c) || continue
        c isa Dict || continue
        for k in collect(keys(c))
            push!(propnames, k)
        end
    catch _ end
end
sort(collect(propnames); by=x->-x[2])
##
pks = [Nostr.PubKeyId(r[1]) for r in DB.exec(cache_storage.pubkey_followers_cnt, "select key from pubkey_followers_cnt where value >= 3")]
##
DB.exec(cache_storage.dyn[:user_search], "delete from user_search")
cnt = Ref(0) |> Utils.ThreadSafe
i = Ref(0) |> Utils.ThreadSafe
running = Utils.PressEnterToStop()
@time Threads.@threads for pk in pks #[1:10000]
# @time for pk in pks #[100000:200000]
    running[] || break
    lock(i) do i
        i[] += 1
        i[] % 100 == 0 && yield()
        i[] % 1000 == 0 && print("$(i[])  $(cnt[])  \r")
    end
    DB.update_user_search_(cache_storage, pk) && DB.incr(cnt)
end
@show cnt[]
@show length(cache_storage.dyn[:user_search])
##

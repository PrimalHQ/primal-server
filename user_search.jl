##
init_qs = [
           "drop table if exists user_search",
           "create virtual table if not exists user_search using fts5(
           pubkey unindexed,
           name,
           username,
           display_name,
           displayName,
           nip05
           )",
          ]
for q in init_qs
    DB.exec(cache_storage.pubkey_followers, q)
end
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
DB.exec(cache_storage.pubkey_followers, "delete from user_search")
cnt = Ref(0)
@time for (i, pk) in enumerate(pks[1:end])
    i % 100 == 0 && yield()
    # i == 100000 && break
    # pk == test_pubkeys[:pedja] || continue
    i % 1000 == 0 && print("$i  $(cnt[])  \r")
    DB.update_user_search(cache_storage, pk) && (cnt[] += 1)
end
@show cnt[]
@show DB.exec(cache_storage.pubkey_followers, "select count(1) from user_search")
##

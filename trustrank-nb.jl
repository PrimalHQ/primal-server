##
import JSON, URIs, Dates
using Serialization
using DataStructures: Accumulator
using Printf: @printf, @sprintf
##
mdeids = collect(values(cache_storage.meta_data))
##
function check_nip05(pubkey, domain, name)
    try
        JSON.parse(String(HTTP.request("GET", "https://$domain/.well-known/nostr.json?name=$(URIs.escapeuri(name))"; 
                          retry=false, connect_timeout=5, readtimeout=5, 
                          verbose=0,
                          proxy=Media.MEDIA_PROXY[],
                         ).body)
                  )["names"][name] == Nostr.hex(pubkey)
    catch _
        # rethrow()
        false
    end
end
##
function iterate_mdeids(body)
    running = Utils.PressEnterToStop()
    i = Ref(0) |> Utils.ThreadSafe
    Threads.@threads for eid in mdeids
        yield(); running[] || break
        DB.incr(i)
        i[] % 10000 == 0 && print("$(i[])/$(length(mdeids))    \r")
        body(eid)
    end
    println()
end
##
domains = Accumulator{String, Int}() |> Utils.ThreadSafe
@time iterate_mdeids() do eid
    try
        md = cache_storage.events[eid]
        d = JSON.parse(md.content)
        if haskey(d, "nip05")
            parts = split(d["nip05"], '@')
            name = strip(parts[1])
            domain = strip(parts[2])
            push!(domains, domain)
        end
    catch _ end
end
##
domains = sort(collect(domains); by=r->-r[2])
open("nip05-domains-1.txt", "w+") do f
    for (domain, cnt) in domains
        println(f, "$domain\t$cnt")
    end
end
##
domain_status = Dict()
    # get!(domain_status, domain) do
    #     @show domain
    #     @show check_nip05(md.pubkey, domain, name)
    # end && 
##
good_domains = Set()
import Sockets
out = []
for r in readlines("nip05-domains.txt")
    isempty(r) && continue
    try
        a, _ = split(r, '\t')
        s, c, domain = a[1], a[3], a[13:end]
        if s == '1'
            println(domain, "  ", Sockets.getaddrinfo(domain))
            push!(good_domains, domain)
        end
        push!(out, "$s $c $domain")
    catch ex
        # println(ex)
    end
end
open("nip05-domains-2.txt", "w+") do f
    for s in out; println(f, s); end
end
##
domain_names = Dict()
@time for domain in good_domains
    try
        names = Dict([name=>Nostr.PubKeyId(pk) 
                      for (name, pk) in JSON.parse(String(HTTP.request("GET", "https://$domain/.well-known/nostr.json"; 
                                                                       retry=false, connect_timeout=5, readtimeout=5, 
                                                                       verbose=0,
                                                                       proxy=Media.MEDIA_PROXY[],
                                                                      ).body))["names"]])
        if !isempty(names)
            domain_names[domain] = names
            println("$domain: ok")
        end
    catch ex
        println("$domain: $(typeof(ex))")
    end
end
# @time for domain in good_domains
#     haskey(domain_names, domain) && continue
# end
##
function parse_nip05(nip05)
    parts = split(nip05, '@')
    name = strip(parts[1])
    domain = strip(parts[2])
    name, domain
end
##
good_pks_unverified = Set() |> Utils.ThreadSafe
@time iterate_mdeids() do eid
    try
        md = cache_storage.events[eid]
        d = JSON.parse(md.content)
        if haskey(d, "nip05")
            name, domain = parse_nip05(d["nip05"])
            domain in good_domains && push!(good_pks_unverified, md.pubkey)
        end
    catch _ end
end
good_pks_unverified = collect(good_pks_unverified)
##
good_pks_verified = Dict()
#
running = Utils.PressEnterToStop()
good_pks_domains = Accumulator{String, Int}()
good_cnt = Ref(0)
i = Ref(0)
#for (i, pk) in enumerate(collect(good_pks_unverified)[1:end])
asyncmap(collect(good_pks_unverified); ntasks=100) do pk
    yield(); running[] || return
    DB.incr(i)
    print("$(i[])/$(length(good_pks_unverified))/$(length(good_pks_verified))    \r")
    md = cache_storage.events[cache_storage.meta_data[pk]]
    local d = JSON.parse(md.content)
    name, domain = parse_nip05(d["nip05"])
    if get!(good_pks_verified, md.pubkey) do 
            if haskey(domain_names, domain)
                if haskey(domain_names[domain], name) && domain_names[domain][name] == md.pubkey
                    return true
                end
            elseif check_nip05(md.pubkey, domain, name)
                return true
            end
            return false
        end
        good_cnt[] += 1
        push!(good_pks_domains, domain)
    end
end
println()
@show length(good_pks_verified) length(good_pks_unverified) good_cnt[]
##
users = Dict() |> Utils.ThreadSafe
@time iterate_mdeids() do eid
    try
        md = cache_storage.events[eid]
        local d = JSON.parse(md.content)
        if haskey(d, "nip05")
            name, domain = parse_nip05(d["nip05"])
            domain == "nostr-vip.top" && return
        end
        follows = Set()
        if md.pubkey in cache_storage.contact_lists
            for tag in cache_storage.events[cache_storage.contact_lists[md.pubkey]].tags
                if length(tag.fields) >= 2 && tag.fields[1] == "p"
                    if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                        push!(follows, pk)
                        lock(users) do users
                            get!(users, pk) do; Set{Nostr.PubKeyId}(); end
                        end
                    end
                end
            end
        end
        users[md.pubkey] = follows
    catch ex
        #println(ex)
        # rethrow()
    end
end
println()
users = users.wrapped
for (pk, follows) in users; delete!(follows, pk); end
println("number of users: ", length(users))
println("avg number of follows: ", sum([length(follows) for (_, follows) in users])/length(users))
##
serialize("../tr-1.jls", (; good_pks_verified, good_pks_domains, users))
##
(; good_pks_verified, good_pks_domains, users) = deserialize("../tr-1.jls", )
##
ui = Dict([pk=>i for (i, pk) in enumerate(keys(users))])
iu = [pk for (_, pk) in enumerate(keys(users))]
d = [get(good_pks_verified, pk, false) ? 1.0 : 0.0 for pk in keys(ui)]
d /= sum(d)
N = 20
tr = d
a = 0.85
delta = NaN
#
running = Utils.PressEnterToStop()
@time begin
    for i in 1:N
        yield(); running[] || break
        energy = sum(tr)
        println("$i/$N  E:$energy  D:$delta    \r")
        tr_ = [0.0 for pk in keys(ui)]
        for (pk, follows) in users
            for f in follows
                tr_[ui[f]] += a * tr[ui[pk]] / length(follows)
            end
            tr_[ui[pk]] += (1-a) * d[ui[pk]]
        end
        global delta = sum(abs.(tr_ - tr))
        global tr = tr_
    end
    println()
end
#
tr_sorted = sort(collect(zip(keys(users), tr)); by=t->-t[2])
##
serialize("../tr_sorted.jls", tr_sorted)
####
user_profiles = Dict()
##
running = Utils.PressEnterToStop()
rex(1,0,:(empty!(App.trustranks)))
for from_i in [
               1,
               10000,
               100000,
               110000,
               120000,
               130000,
               140000,
               150000,
               160000,
               170000,
               180000,
               190000,
               200000,
               300000,
               500000,
               1000000,
               1500000,
              ]
    local rows = []
    for (i, (pk, t)) in enumerate(tr_sorted[from_i:from_i+1000])
        i % 100 == 0 && print("$from_i - $i    \r")
        yield(); running[] || break
        pk in cache_storage.meta_data || continue
        cache_storage.meta_data[pk] in cache_storage.events || continue
        c = try JSON.parse(cache_storage.events[cache_storage.meta_data[pk]].content) catch _ continue end
        addr = try strip(c["nip05"]) catch _ "" end
        md = InternalServices.mdpubkey(cache_storage, pk)
        followercnt = cache_storage.pubkey_followers_cnt[pk]
        label = first(md.title, 200) * (isempty(addr) ? "" : " - $addr")
        link = get(md, :url, "https://primal.net/p/$(Nostr.hex(pk))")
        # @printf "%3d  %10.8f (%6d)  %-50s  %s\n" i t followercnt label link
        user_profile = get!(user_profiles, pk) do
            JSON.parse(App.user_profile(cache_storage; pubkey=pk)[end].content)
        end
        #user_profile = nothing
        push!(rows, (; i=from_i+i-1, t, followercnt, user_profile, label, link))
    end
    rex(1,0,:(App.trustranks[$("pubkeys only, from $(from_i)")] = $((; updated_at=Dates.now(), rows=rows))))
end
nothing
##
tr_sorted = deserialize("../tr_sorted.jls", )
#
for (pk, t) in tr_sorted
    TrustRank.pubkey_rank[pk] = t
end
##
lud16_domains = Accumulator{String, Int}() |> Utils.ThreadSafe
th = tr_sorted[100000][2]
@time iterate_mdeids() do eid
    try
        md = cache_storage.events[eid]
        TrustRank.pubkey_rank[md.pubkey] >= th || return
        d = JSON.parse(md.content)
        if haskey(d, "lud16")
            parts = split(d["lud16"], '@')
            name = strip(parts[1])
            domain = strip(parts[2])
            push!(lud16_domains, domain)
        end
    catch _ end
end
lud16_domains = sort(collect(lud16_domains); by=r->-r[2])
##

module TrustRankMaker

import JSON, URIs, Dates, HTTP
using Serialization
using DataStructures: Accumulator
using Printf: @printf, @sprintf
import Sockets

using ..Utils
import ..Utils
import ..Nostr
import ..DB
import ..Fetching
import ..Postgres
using ..Tracing: @tr

PROXY = Ref{Any}(nothing)
TIMEOUT = Ref(10)

PRINT_EXCEPTIONS = Ref(false)
LOG = Ref(false)

exceptions_lock = ReentrantLock()

const cache_storage = Ref{Any}(nothing)
const RUN_PERIOD = Ref(3600)
const task = Ref{Any}(nothing)
const running = Ref(true)

function start(est::DB.CacheStorage)
    cache_storage[] = est

    @assert isnothing(task[]) || istaskdone(task[])

    @tr running[] = true

    task[] = 
    Base.errormonitor(@async while running[]
                          Utils.active_sleep(RUN_PERIOD[], running)
                          try
                              Base.invokelatest(run_make)
                          catch _
                              PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                          end
                      end)

    nothing
end

function stop()
    @assert !isnothing(task[])
    @tr running[] = false
    Utils.wait_for(()->istaskdone(task[]))
end

function make_2(
        cache_storage; 
        output_filename="../tr_sorted.jls", 
        iterations=20,
        running=Utils.PressEnterToStop())

    users = Dict() |> ThreadSafe
    visited = Set{Nostr.PubKeyId}() |> ThreadSafe
    function visit_user(pubkey::Nostr.PubKeyId)
        running[] || return
        pubkey in visited && return
        push!(visited, pubkey)
        try
            follows = Set{Nostr.PubKeyId}()
            if pubkey in cache_storage.contact_lists
                for tag in cache_storage.events[cache_storage.contact_lists[pubkey]].tags
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
            users[pubkey] = follows
            # @show length(users)
        catch ex
            # println(ex)
            # rethrow()
        end
    end

    verified_pubkeys = [Nostr.PubKeyId(pubkey) for (pubkey,) in Postgres.execute(:membership, "select pubkey from verified_users where default_name")[2]]

    Threads.@threads for pk in verified_pubkeys
        yield()
        visit_user(pk)
    end
    @show length(users)
    
    while true
        yield(); running[] || break
        nusers1 = length(users)
        Threads.@threads for pk in collect(keys(users))
            yield()
            visit_user(pk)
        end
        nusers2 = length(users)
        @show (nusers1, nusers2)
        nusers1 == nusers2 && break
    end
    println()
    users = users.wrapped
    for (pk, follows) in users; delete!(follows, pk); end
    println("number of users: ", length(users))
    println("avg number of follows: ", sum([length(follows) for (_, follows) in users]; init=0)/length(users))
    ##
    ui = Dict([pk=>i for (i, pk) in enumerate(keys(users))])
    iu = [pk for (_, pk) in enumerate(keys(users))]
    d = [pk in verified_pubkeys ? 1.0 : 0.0 for pk in keys(ui)]
    d /= sum(d)
    tr = d
    a = 0.85
    delta = NaN
    #
    for i in 1:iterations
        yield(); running[] || break
        energy = sum(tr)
        println("$i/$iterations  E:$energy  D:$delta    \r")
        tr_ = [0.0 for pk in keys(ui)]
        for (j, (pk, follows)) in enumerate(users)
            j % 1000 == 0 && yield()
            for f in follows
                tr_[ui[f]] += a * tr[ui[pk]] / length(follows)
            end
            tr_[ui[pk]] += (1-a) * d[ui[pk]]
        end
        delta = sum(abs.(tr_ - tr))
        tr = tr_
    end
    println()
    #
    tr_sorted = sort([(pk, t) for (pk, t) in collect(zip(keys(users), tr)) if t > 0]; by=t->-t[2])
    ##
    serialize(output_filename, tr_sorted)
    ##
    (;
     users,
     tr_sorted,
    )
end

function run_make()
    r = make_2(cache_storage[]; running=Ref(true))
    Main.TrustRank.load(Dict(r.tr_sorted))
end

# ---------------------------------------------- #

function check_nip05(pubkey, domain, name)
    try
        JSON.parse(String(HTTP.request("GET", "https://$domain/.well-known/nostr.json?name=$(URIs.escapeuri(name))"; 
                                       retry=false, connect_timeout=TIMEOUT[], readtimeout=TIMEOUT[], 
                          verbose=0,
                          proxy=PROXY[],
                         ).body)
                  )["names"][name] == Nostr.hex(pubkey)
    catch _
        # rethrow()
        false
    end
end

function parse_nip05(nip05)
    parts = split(nip05, '@')
    name = strip(parts[1])
    domain = strip(parts[2])
    name, domain
end

function make(
        cache_storage; 
        output_filename="../tr_sorted.jls", 
        nip05_verification=false,
        iterations=20,
        running=Utils.PressEnterToStop(),
        mdeids=nothing)
    ##
    if isnothing(mdeids)
        # mdeids = collect(values(cache_storage.meta_data))
        mdeids = [Nostr.EventId(eid) for (eid,) in Main.Postgres.execute(:p0, "select value from meta_data")[2]]
    end
    @show length(mdeids)
    ##
    function iterate_mdeids(body, desc="")
        i = Ref(0) |> ThreadSafe
        Threads.@threads for eid in mdeids
            yield(); running[] || break
            i[] += 1
            # i[] > 10000 && break
            i[] % 10000 == 0 && print("$(isempty(desc) ? "" : "$desc  ")$(i[])/$(length(mdeids))    \r")
            body(eid)
        end
        println()
    end
    ##
    domains = Accumulator{String, Int}() |> ThreadSafe
    @time iterate_mdeids("domains") do eid
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
    good_domains = Set()
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
        yield(); running[] || break
        try
            names = Dict([name=>Nostr.PubKeyId(pk) 
                          for (name, pk) in JSON.parse(String(HTTP.request("GET", "https://$domain/.well-known/nostr.json"; 
                                                                           retry=false, connect_timeout=TIMEOUT[], readtimeout=TIMEOUT[], 
                                                                           verbose=0,
                                                                           proxy=PROXY[],
                                                                          ).body))["names"]])
            if !isempty(names)
                domain_names[domain] = names
                println("$domain: ok")
            end
        catch ex
            println("$domain: $(typeof(ex))")
        end
    end
    ##
    good_pks_unverified = Set() |> ThreadSafe
    @time iterate_mdeids("good_pks_unverified") do eid
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
    good_pks_domains = Accumulator{String, Int}()
    good_cnt = Ref(0)
    if nip05_verification
        i = Ref(0)
        asyncmap(collect(good_pks_unverified); ntasks=100) do pk
            yield(); running[] || return
            i[] += 1
            print("good_pks_verified  $(i[])/$(length(good_pks_unverified))/$(length(good_pks_verified))    \r")
            md = cache_storage.events[cache_storage.meta_data[pk]]
            local d = JSON.parse(md.content)
            if !isnothing(local p = try parse_nip05(d["nip05"]) catch _ nothing end)
                name, domain = p
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
        end
        println()
    else
        good_pks_verified = Dict([pk=>true for pk in good_pks_unverified])
    end
    @show length(good_pks_verified) length(good_pks_unverified) good_cnt[]
    ##
    users = Dict() |> ThreadSafe
    @time iterate_mdeids("user-follows") do eid
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
    println("avg number of follows: ", sum([length(follows) for (_, follows) in users]; init=0)/length(users))
    ##
    ui = Dict([pk=>i for (i, pk) in enumerate(keys(users))])
    iu = [pk for (_, pk) in enumerate(keys(users))]
    d = [get(good_pks_verified, pk, false) ? 1.0 : 0.0 for pk in keys(ui)]
    d /= sum(d)
    tr = d
    a = 0.85
    delta = NaN
    #
    @time for i in 1:iterations
        yield(); running[] || break
        energy = sum(tr)
        println("$i/$iterations  E:$energy  D:$delta    \r")
        tr_ = [0.0 for pk in keys(ui)]
        for (pk, follows) in users
            for f in follows
                tr_[ui[f]] += a * tr[ui[pk]] / length(follows)
            end
            tr_[ui[pk]] += (1-a) * d[ui[pk]]
        end
        delta = sum(abs.(tr_ - tr))
        tr = tr_
    end
    println()
    #
    tr_sorted = sort(collect(zip(keys(users), tr)); by=t->-t[2])
    ##
    serialize(output_filename, tr_sorted)
    ##
    (;
     mdeids,
     domains,
     good_domains,
     domain_names,
     good_pks_unverified,
     good_pks_verified,
     good_pks_domains,
     users,
     tr_sorted,
    )
end

function write_to_text_file(filename, tr_sorted)
    open(filename, "w+") do f
        for (pk, rank) in tr_sorted
            println(f, "$(Nostr.hex(pk))  $rank")
        end
    end
end

end


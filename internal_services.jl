module InternalServices

import HTTP, EzXML, JSON, URIs
using DataStructures: CircularBuffer
import Glob

import ..Utils
import ..Nostr
import ..Bech32
import ..DB
import ..Media
import ..Postgres

PORT = Ref(14000)
PORT2 = Ref(24000)

PRINT_EXCEPTIONS = Ref(true)

APPLE_APP_SITE_ASSOCIATION_FILE = Ref("apple-app-site-association.json")
ANDROID_ASSETLINKS_FILE = Ref("assetlinks.json")

server = Ref{Any}(nothing)
router = Ref{Any}(nothing)
server2 = Ref{Any}(nothing)
router2 = Ref{Any}(nothing)

exceptions = CircularBuffer(200)

est = Ref{Any}(nothing)

short_urls = Ref{Any}(nothing)
verified_users = Ref{Any}(nothing)
inappropriate_names = Ref{Any}(nothing)
memberships = Ref{Any}(nothing)
membership_tiers = Ref{Any}(nothing)
membership_products = Ref{Any}(nothing)

function catch_exception(body::Function, handler::Symbol, args...)
    try
        body()
    catch ex
        push!(exceptions, (handler, time(), ex, args...))
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        HTTP.Response(500, "error")
    end
end

function start(cache_storage::DB.CacheStorage; setup_handlers=true)
    @assert isnothing(server[])

    est[] = cache_storage

    short_urls[] = est[].params.MembershipDBDict(Int, String, "short_urls"; connsel=est[].pqconnstr,
                                          init_queries=["create table if not exists short_urls (
                                                        idx int8 not null,
                                                        url text not null,
                                                        path text not null,
                                                        ext text not null
                                                        )",
                                                        "create index if not exists short_urls_idx on short_urls (idx asc)",
                                                        "create index if not exists short_urls_url on short_urls (url asc)",
                                                        "create index if not exists short_urls_path on short_urls (path asc)",
                                                       ])

    verified_users[] = est[].params.MembershipDBDict(String, Int, "verified_users"; connsel=est[].pqconnstr,
                                              init_queries=["create table if not exists verified_users (name varchar(200) not null, pubkey bytea not null)",
                                                            "create index if not exists verified_users_pubkey on verified_users (pubkey asc)",
                                                            "create index if not exists verified_users_name on verified_users (name asc)",
                                                           ])

    inappropriate_names[] = est[].params.MembershipDBDict(String, Int, "inappropriate_names"; connsel=est[].pqconnstr,
                                              init_queries=["create table if not exists inappropriate_names (name varchar(200) primary key)",
                                                            "create index if not exists inappropriate_names_name on inappropriate_names (name asc)",
                                                           ])

    memberships[] = est[].params.MembershipDBDict(String, Int, "memberships"; connsel=est[].pqconnstr,
                                           init_queries=["create table if not exists memberships (
                                                         pubkey bytea,
                                                         tier varchar(300),
                                                         valid_until timestamp,
                                                         name varchar(500),
                                                         used_storage int8
                                                         )",
                                                         "create index if not exists memberships_pubkey on memberships (pubkey asc)",
                                                        ])
    membership_tiers[] = est[].params.MembershipDBDict(String, Int, "membership_tiers"; connsel=est[].pqconnstr,
                                                init_queries=["create table if not exists membership_tiers (
                                                              tier varchar(300) not null,
                                                              max_storage int8
                                                              )",
                                                              "create index if not exists membership_tiers_tier on membership_tiers (tier asc)",
                                                             ])
    membership_products[] = est[].params.MembershipDBDict(String, Int, "membership_products"; connsel=est[].pqconnstr,
                                                   init_queries=["create table if not exists membership_products (
                                                                 product_id varchar(100) not null,
                                                                 tier varchar(300),
                                                                 months int,
                                                                 amount_usd decimal,
                                                                 max_storage int8
                                                                 )",
                                                                 "create index if not exists membership_products_product_id on membership_products (product_id asc)",
                                                                ])

    router[] = HTTP.Router()
    server[] = HTTP.serve!(router[], "0.0.0.0", PORT[])

    router2[] = HTTP.Router()
    server2[] = HTTP.serve!(router2[], "0.0.0.0", PORT2[])

    if setup_handlers
        HTTP.register!(router[], "POST", "/collect_metadata", function (req::HTTP.Request)
                           pubkeys = JSON.parse(String(req.body))
                           res = try
                               collect_metadata(pubkeys)
                           catch ex
                               ["ERROR", string(ex)]
                           end
                           return HTTP.Response(200, JSON.json(res))
                       end)

        HTTP.register!(router[], "/.well-known/nostr.json", nostr_json_handler)

        for path in ["/**", "/"]
            HTTP.register!(router[], path, preview_handler)
        end

        HTTP.register!(router[], "/media-upload", media_upload_handler)
        HTTP.register!(router[], "/media-cache", media_cache_handler)

        HTTP.register!(router[], "/link-preview", link_preview_handler)

        HTTP.register!(router[], "/url-shortening", url_shortening_handler)
        HTTP.register!(router[], "/url-lookup/*", url_lookup_handler)

        HTTP.register!(router[], "/spam", spam_handler)

        HTTP.register!(router[], "/api", api_handler)

        HTTP.register!(router[], "/api/suggestions", suggestions_handler)

        HTTP.register!(router2[], "/purge-media", purge_media_handler)
    end

    nothing
end

function stop()
    @assert !isnothing(server[])
    close(server[])
    server[] = nothing

    @assert !isnothing(server2[])
    close(server2[])
    server2[] = nothing

    close(short_urls[])
    short_urls[] = nothing
    close(verified_users[])
    verified_users[] = nothing
end

function collect_metadata(pubkeys)
    cache_storage = est[]
    pubkeys = [pk isa Nostr.PubKeyId ? pk : Nostr.PubKeyId(pk) for pk in pubkeys]
    res = Dict()
    for pk in pubkeys
        haskey(res, pk) && continue
        pk in cache_storage.meta_data || continue
        eid = cache_storage.meta_data[pk]
        eid in cache_storage.events || continue
        res[pk] = cache_storage.events[eid]
    end
    Dict([(Nostr.hex(pk), e) for (pk, e) in res])
end

re_url = r"https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)"
# re_url = r"[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)"

function get_image_links(content)
    urls = String[]
    for m in eachmatch(re_url, content)
        url = m.match
        _, ext = splitext(lowercase(url))
        if ext in [".png", ".gif", ".jpg", ".jpeg", ".webp"]
            push!(urls, url)
        end
    end
    urls
end

re_mention = r"\b(nostr:)?((note|npub|naddr|nevent|nprofile)1\w+)\b"

function content_refs_resolved(e::Nostr.Event)
    cache_storage = est[]
    c = replace(e.content, DB.re_hashref => function (r)
                i = parse(Int, r[3:end-1]) + 1
                if 1 <= i <= length(e.tags)
                    tag = e.tags[i]
                    if length(tag.fields) >= 2
                        if tag.fields[1] == "p"
                            try
                                c = JSON.parse(cache_storage.events[cache_storage.meta_data[Nostr.PubKeyId(tag.fields[2])]].content)
                                return "@"*mdtitle(c)
                            catch _ end
                        end
                    end
                end
                ""
            end)
    replace(c, re_mention => function (r)
                r = string(r)
                if startswith(r, "nostr:"); r = r[7:end]; end
                x = Bech32.nip19_decode_wo_tlv(r)
                if     x isa Nostr.PubKeyId
                    try
                        c = JSON.parse(cache_storage.events[cache_storage.meta_data[x]].content)
                        return "@"*mdtitle(c)
                    catch _ end
                elseif x isa Nostr.EventId
                    try
                        pk = cache_storage.events[x].pubkey
                        c = JSON.parse(cache_storage.events[cache_storage.meta_data[pk]].content)
                        return "[nostr note by $(mdtitle(c))]"
                    catch _ end
                    return "[nostr note]"
                end
                r
            end)
end

function mdtitle(c::Dict)
    for k in ["displayName", "display_name", "name", "username"]
        if haskey(c, k) && !isnothing(c[k]) && !isempty(c[k])
            return strip(c[k])
        end
    end
    ""
end

function mdpubkey(cache_storage, pk)
    title = description = image = ""
    url = nothing
    if isempty(Postgres.execute(:membership, "select 1 from filterlist where target_type = 'pubkey' and target = \$1 and blocked limit 1", [pk])[2])
        if pk in cache_storage.meta_data
            c = JSON.parse(cache_storage.events[cache_storage.meta_data[pk]].content)
            if c isa Dict
                addr = try strip(c["nip05"]) catch _ "" end
                if !isnothing(addr) && endswith(addr, "@primal.net")
                    url = "https://primal.net/$(split(addr, '@')[1])"
                end
                try title = mdtitle(c) catch _ end
                description = try replace(c["about"], re_url=>"") catch _ "" end
                image = try c["picture"] catch _ "" end
            end
        end
        if !isempty(local r = DB.exec(cache_storage.media, DB.@sql("select media_url, width, height from media where url = ?1 order by (width*height) limit 1"), (image,)))
            image = r[1][1]
        end
    end
    return (; title, description, image, (isnothing(url) ? (;) : (; url))...)
end

function get_meta_elements(host::AbstractString, path::AbstractString)
    cache_storage = est[]

    title = description = image = url = ""
    twitter_card = "summary"

    mdpubkey_(pk) = (; url="https://$host$path", twitter_card, mdpubkey(cache_storage, pk)...)

    if !isnothing(local m = match(r"^/(profile|p)/(.*)", path))
        pk = string(m[2])
        pk = (startswith(pk, "npub") || startswith(pk, "nprofile")) ? Bech32.nip19_decode_wo_tlv(pk) : Nostr.PubKeyId(pk)
        return mdpubkey_(pk)

    elseif !isnothing(local m = match(r"^/(thread|e|a)/(.*)", path))
        eid = string(m[2])
        if startswith(eid, "nevent")
            for x in Bech32.nip19_decode(eid)
                if x[2] isa Nostr.EventId
                    eid = x[2]
                    break
                end
            end
        else
            try eid = Bech32.nip19_decode(eid) catch _ end
        end
        try eid = Bech32.nip19_decode(eid) catch _ end
        isnothing(eid) && (eid = try Nostr.EventId(eid) catch _ end)
        if eid isa Nostr.EventId
            if eid in cache_storage.events
                e = cache_storage.events[eid]
                url = "https://$(host)/e/$(m[2])"
                description = replace(content_refs_resolved(e), re_url => "")
                if e.pubkey in cache_storage.meta_data
                    c = JSON.parse(cache_storage.events[cache_storage.meta_data[e.pubkey]].content)
                    title = mdtitle(c)
                    image = get(c, "picture", "")
                end
                media_urls = DB.exec(cache_storage.event_media, "select url from event_media where event_id = ?1 limit 1", (eid,))
                if !isempty(media_urls)
                    twitter_card = "summary_large_image"
                    image = media_urls[1][1]
                    thumbnails = DB.exec(cache_storage.dyn[:video_thumbnails], DB.@sql("select thumbnail_url from video_thumbnails where video_url = ?1 limit 1"), (image,))
                    if !isempty(thumbnails)
                        image = (thumbnails[1][1],)
                    else
                        if !isempty(local r = DB.exec(cache_storage.media, DB.@sql("select media_url, width, height from media where url = ?1 order by (width*height) limit 1"), (image,)))
                            image = r[1][1]
                        end
                    end
                end
            end
        elseif eid isa Vector
            if startswith(string(m[2]), "naddr")
                d = Dict(eid)
                for (eid,) in DB.exec(cache_storage.dyn[:parametrized_replaceable_events], 
                                      DB.@sql("select event_id from parametrized_replaceable_events where pubkey = ?1 and kind = ?2 and identifier = ?3 limit 1"), 
                                      (d[Bech32.Author], d[Bech32.Kind], d[Bech32.Special]))
                    eid = Nostr.EventId(eid)
                    if eid in cache_storage.events
                        e = cache_storage.events[eid]
                        url = "https://$(host)/e/$(m[2])"
                        for t in e.tags
                            if length(t.fields) >= 2
                                t.fields[1] == "title" && (title = t.fields[2])
                                t.fields[1] == "summary" && (description = t.fields[2])
                                t.fields[1] == "image" && (image = t.fields[2])
                            end
                        end
                        twitter_card = "summary_large_image"
                    end
                end
            end
        end
        return (; title, description, image, url, twitter_card)

    elseif !isnothing(local md = begin
                          md = nothing
                          m = match(r"^/([^/]*)/([^?]*)", path)
                          if !isnothing(m)
                              name, identifier = string(m[1]), string(m[2])
                              identifier = URIs.unescapeuri(identifier)
                              pubkey = nothing
                              for pk in nostr_json_query_by_name(name)
                                  pubkey = pk
                                  break
                              end
                              if !isnothing(pubkey)
                                  kind = 30023
                                  for (eid,) in DB.exec(cache_storage.dyn[:parametrized_replaceable_events], 
                                                        DB.@sql("select event_id from parametrized_replaceable_events where pubkey = ?1 and kind = ?2 and identifier = ?3 limit 1"), 
                                                        (pubkey, kind, identifier))
                                      eid = Nostr.EventId(eid)
                                      if eid in cache_storage.events
                                          e = cache_storage.events[eid]
                                          naddr = Bech32.nip19_encode_naddr(kind, pubkey, identifier)
                                          url = "https://$(host)/e/$(naddr)"
                                          for t in e.tags
                                              if length(t.fields) >= 2
                                                  t.fields[1] == "title" && (title = t.fields[2])
                                                  t.fields[1] == "summary" && (description = t.fields[2])
                                                  t.fields[1] == "image" && (image = t.fields[2])
                                              end
                                          end
                                          twitter_card = "summary_large_image"
                                          if isempty(image)
                                              image = mdpubkey(cache_storage, pubkey).image
                                          end
                                          md = (; title, description, image, url, twitter_card)
                                      end
                                  end
                              end
                          end
                          md
                      end)
        return md

    elseif !isnothing(local m = match(r"^/downloads?", path)) && 1==1
        return (; 
                title="Download Primal apps and source code", 
                description="",
                image="https://$host/public/primal-link-preview.jpg",
                url="https://$host/downloads",
                twitter_card = "summary_large_image",
                # twitter_image = "https://$host/images/twitter-hero.jpg",
                twitter_image = "https://$host/public/primal-link-preview.jpg?a=444",
               )

    elseif !isnothing(local m = match(r"^/legends", path)) && 1==1
        return (; 
                title="Primal Legends", 
                description="Recognizing users who made a contribution to Nostr and Primal",
                image="https://$host/public/legends-link-preview.png",
                url="https://$host/legends",
                twitter_card = "summary_large_image",
                twitter_image = "https://$host/public/legends-link-preview.png?a=444",
               )

    elseif !isnothing(local m = match(r"^/myarticles$", path)) && 1==1
        return (; 
                title="Primal Article Editor", 
                description="Create long form articles for Nostr",
                image=("https://$host/public/article-editor-link-preview.png",),
                url="https://$host/myarticles",
                twitter_card = "summary_large_image",
                twitter_image = "https://$host/public/article-editor-link-preview.png?a=444",
               )

    elseif !isnothing(local m = match(r"^/(\?.|$)", path)) && 1==1
        return (; 
                title="Primal", 
                description="Discover the best of Nostr",
                image=("https://$host/public/primal-link-preview.jpg",),
                url="https://$host/",
                twitter_card = "summary_large_image",
                twitter_image = "https://$host/images/twitter-hero.jpg")

    elseif !isnothing(local m = match(r"^/landing$", path)) && 1==1
        return (; 
                title="Primal", 
                description="Discover the best of Nostr",
                image=("https://$host/public/primal-link-preview.jpg",),
                url="https://primal.net/",
                twitter_card = "summary_large_image",
                twitter_image = "https://primal.net/images/twitter-hero.jpg")

    elseif !isnothing(local m = match(r"^/(.*)", path))
        name = string(m[1])
        if !isempty(local pks = nostr_json_query_by_name(name))
            return mdpubkey_(pks[1])
        end

    end

    return nothing
end

index_htmls = Dict([host=>(; 
                           throttle=Utils.Throttle(; period=5.0, t=0), 
                           index_html=Ref(""), 
                           index_doc=Ref{Any}(nothing),
                           index_elems=Dict{Symbol, EzXML.Node}(),
                          )
                    for host in ["primal.net", "dev.primal.net"]])
index_html = Ref("")
index_doc = Ref{Any}(nothing)
index_elems = Dict{Symbol, EzXML.Node}()
# index_defaults = Dict{Symbol, String}()
index_lock = ReentrantLock()

# nostr_json_reading = Utils.Throttle(; period=5.0, t=0)
# nostr_json = Ref(Dict{String, String}())

APP_ROOT = Ref("www")
# NOSTR_JSON_FILE = Ref("nostr.json")

# function get_nostr_json()
#     nostr_json_reading() do
#         # nostr_json[] = JSON.parse(read("$(APP_ROOT[])/.well-known/nostr.json", String))["names"]
#         nostr_json[] = JSON.parse(read(NOSTR_JSON_FILE[], String))["names"]
#         # nostr_json[] = Dict([name=>Nostr.hex(Nostr.PubKeyId(pk)) for (name, pk) in DB.rows(verified_users[])])
#     end
#     nostr_json[]
# end

nostr_json_query_lock = ReentrantLock()
function nostr_json_query_by_name(name::String)
    lock(nostr_json_query_lock) do 
        [Nostr.PubKeyId(pk) for (pk,) in DB.exec(verified_users[], DB.@sql("select pubkey from verified_users where lower(name) = lower(?1)"), (name,))]
    end
end
function nostr_json_query_by_pubkey(pubkey::Nostr.PubKeyId; default_name=false)
    lock(nostr_json_query_lock) do 
        q = if default_name
            DB.@sql("select name from verified_users where pubkey = ?1 and default_name = true")
        else
            DB.@sql("select name from verified_users where pubkey = ?1")
        end
        [name for (name,) in DB.exec(verified_users[], q, (pubkey,))]
    end
end

function preview_handler(req::HTTP.Request)
    lock(index_lock) do
        # if startswith(req.target, "/search/")
        #     return HTTP.Response(404, HTTP.Headers(["Content-Type"=>"text/plain"]), "not found")
        if     req.target == "/.well-known/apple-app-site-association"
            return HTTP.Response(200, HTTP.Headers(["Content-Type"=>"application/json"]), read(APPLE_APP_SITE_ASSOCIATION_FILE[], String))
        elseif req.target == "/.well-known/assetlinks.json"
            return HTTP.Response(200, HTTP.Headers(["Content-Type"=>"application/json"]), read(ANDROID_ASSETLINKS_FILE[], String))
        end
        host = Dict(req.headers)["Host"]
        h = index_htmls[host]
        dochtml = h.index_html[]
        try
            h.throttle() do
                index_dir = host == "primal.net" ? "/var/www/dev.primal.net" : "$(ENV["HOME"])/tmp/dev.primal.net"
                h.index_html[] = read("$(index_dir)/index.html", String)
                h.index_doc[] = doc = EzXML.parsehtml(h.index_html[])
                for e in EzXML.findall("/html/head/meta", doc)
                    if haskey(e, "property") && startswith(e["property"], "og:")
                        # index_defaults[Symbol(e["property"][4:end])] = e["content"]
                        EzXML.unlink!(e)
                    end
                end
                head = EzXML.findall("/html/head", doc)[1]
                for k in [:title,
                          :description,
                          :image,
                          :url,
                         ]
                    el = EzXML.ElementNode("meta")
                    el["property"] = "og:$(k)"
                    EzXML.link!(head, el)
                    h.index_elems[k] = el
                end
                
                el = EzXML.ElementNode("meta")
                el["name"] = "og:type"
                el["content"] = "website"
                EzXML.link!(head, el)

                el = EzXML.ElementNode("meta")
                el["name"] = "twitter:card"
                EzXML.link!(head, el)
                h.index_elems[:twitter_card] = el

                el = EzXML.ElementNode("meta")
                el["name"] = "twitter:image"
                EzXML.link!(head, el)
                h.index_elems[:twitter_image] = el

                for e in EzXML.findall("/html/head/script", doc) # WARN needed to run client app in browser
                    EzXML.link!(e, EzXML.TextNode(" "))
                end
            end
            if !isnothing(local mels = get_meta_elements(host, req.target))
                for (k, v) in pairs(mels)
                    if k == :image && !isempty(v)
                        if v isa Tuple
                            v = v[1]
                        else
                            v = "https://primal.net/media-cache?u=$(URIs.escapeuri(v))"
                        end
                    end
                    v = strip(v)
                    if !isempty(v)
                        h.index_elems[k]["content"] = v
                    else
                        delete!(h.index_elems[k], "content")
                    end
                end

                eltitle = EzXML.findall("/html/head/title", h.index_doc[])[1]
                for el in EzXML.nodes(eltitle)
                    EzXML.unlink!(el)
                end
                maxlen = 50
                s = mels.description
                s = length(s) > maxlen ? (first(s, maxlen) * "...") : s
                s = strip(mels.title * ": " * s)
                EzXML.link!(eltitle, EzXML.TextNode(s))

                dochtml = string(h.index_doc[])
            end
        catch ex
            push!(exceptions, (:preview_handler, time(), ex, req))
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        end
        HTTP.Response(200, HTTP.Headers(["Content-Type"=>"text/html",
                                         "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
                                        ]), dochtml)
    end
end

function nostr_json_handler(req::HTTP.Request)
    catch_exception(:nostr_json_handler, req) do
        host = Dict(req.headers)["Host"]
        path = req.target
        uri = HTTP.URI("https://$(host)$(path)")
        nj = Dict()
        if !isnothing(local m = match(r"^name=(.*)", uri.query))
            name = string(m[1])
            if !isempty(local pks = nostr_json_query_by_name(name))
                nj = Dict([name=>pks[1]])
            end
        end
        HTTP.Response(200, HTTP.Headers(["Content-Type"=>"application/json"]), JSON.json((; names=nj), 2))
    end
end

ALLOWED_MEDIA_HOSTS = [
                       "media.primal.net", 
                       "m.primal.net",
                       "blossom.primal.net",
                       "primaldata.s3.us-east-005.backblazeb2.com",
                       "primaldata.fsn1.your-objectstorage.com",
                       "r2.primal.net",
                      ]

function media_upload_handler(req::HTTP.Request)
    catch_exception(:media_upload_handler, req) do
        host = Dict(req.headers)["Host"]
        path, query = split(req.target, '?')
        args = NamedTuple([Symbol(k)=>v for (k, v) in [split(s, '=') for s in split(query, '&')]])
        url = string(URIs.unescapeuri(args.u))
        if URIs.parse_uri(url).host in ALLOWED_MEDIA_HOSTS
            # println((:media_upload_ok, url))
            HTTP.Response(302, HTTP.Headers(["Location"=>url, "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]))
        else
            println((:media_upload_blocked, url))
            HTTP.Response(404, HTTP.Headers(["Content-Type"=>"text/plain", "Cache-Control"=>"max-age=20"]), "not found")
        end
    end
end

function media_cache_handler(req::HTTP.Request)
    catch_exception(:media_cache_handler, req) do
        host = Dict(req.headers)["Host"]
        path, query = split(req.target, '?')

        args = NamedTuple([Symbol(k)=>v for (k, v) in [split(s, '=') for s in split(query, '&')]])
        variant = if !haskey(args, :s)
            (:original, true)
        else (let s=args.s
                  if s=="o"; :original 
                  elseif s=="s"; :small
                  elseif s=="m"; :medium
                  elseif s=="l"; :large
                  else error("invalid size")
                  end
              end,
              if !haskey(args, :a); true
              elseif args.a == "1"; true
              elseif args.a == "0"; false
              else error("invalid animated")
              end)
        end

        # send_content = !(haskey(args, :c) && args.c == "0")
        send_content = false

        url = string(URIs.unescapeuri(args.u))

        if     variant[1] == :small;  variant = (:medium, variant[2])
        elseif variant[1] == :medium; variant = (:large,  variant[2])
        end

        variant_specs = variant == (:original, true) ? [variant] : Media.all_variants
        # @show (url, variant_specs)

        if isempty(Postgres.execute(:p0, "select 1 from media m where m.url = \$1", [url])[2]) && !(URIs.parse_uri(url).host in ALLOWED_MEDIA_HOSTS)
            # println((:media_cache_blocked, url))
            return HTTP.Response(404, HTTP.Headers(["Content-Type"=>"text/plain", "Cache-Control"=>"max-age=20"]), "not found")
        else
            # println((:media_cache_ok, url))
        end

        tr = @elapsed (r = Media.media_variants(est[], url; variant_specs, sync=true, already_imported=true))
        # println("$tr  $query  $(isnothing(r))")

        if isnothing(r)
            HTTP.Response(302, HTTP.Headers(["Location"=>url, "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]))
        else
            resurl = r[variant]
            # @show (send_content, resurl)
            if !send_content
                HTTP.Response(302, HTTP.Headers(["Location"=>resurl, "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]))
            else
                @assert startswith(resurl, Media.MEDIA_URL_ROOT[])
                fp = Media.MEDIA_PATH[] * resurl[length(Media.MEDIA_URL_ROOT[])+1:end]
                fpb, ext = splitext(fp)
                ct = "application/octet-stream"
                for (mt, ext2) in Media.mimetype_ext
                    if ext2 == ext
                        ct = mt
                        break
                    end
                end

                ps = splitpath(fpb)
                for p in Glob.glob(ps[end]*"*", join(ps[1:end-1], '/')[2:end])
                    rm(p)
                end

                r = Media.media_variants(est[], url; variant_specs, sync=true, already_imported=true)
                if isnothing(r)
                    HTTP.Response(302, HTTP.Headers(["Location"=>url, "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]))
                else
                    resurl = r[variant]
                    if !send_content
                        HTTP.Response(302, HTTP.Headers(["Location"=>resurl, "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]))
                    else
                        fp = Media.MEDIA_PATH[] * resurl[length(Media.MEDIA_URL_ROOT[])+1:end]
                        if !isfile(fp)
                            HTTP.Response(302, HTTP.Headers(["Location"=>resurl, "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]))
                        else
                            d = read(fp)
                            # HTTP.Response(200, HTTP.Headers(["Content-Type"=>ct, "Content-Length"=>"$(length(d))", "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]), d)
                            HTTP.Response(200, HTTP.Headers(["Content-Type"=>ct, "Content-Length"=>"$(length(d))", "Cache-Control"=>"max-age=20"]), d)
                        end
                    end
                end
            end
        end
    end
end

function link_preview_handler(req::HTTP.Request)
    catch_exception(:link_preview_handler, req) do
        host = Dict(req.headers)["Host"]
        path, query = split(req.target, '?')
        args = NamedTuple([Symbol(k)=>v for (k, v) in [split(s, '=') for s in split(query, '&')]])
        url = string(URIs.unescapeuri(args.u))
        r = Media.fetch_resource_metadata(url)
        HTTP.Response(200, api_headers, JSON.json(r))
    end
end

short_urls_lock = ReentrantLock()
short_urls_chars = ['A':'Z'..., 'a':'z'...]

URL_SHORTENING_ROOT_URL = Ref("https://m.primal.net")

function url_shortening(url)
    lock(short_urls_lock) do
        r = DB.exec(short_urls[], DB.@sql("select path, ext from short_urls where url = ?1 limit 1"), (url,))
        if isempty(r)
            maxidx = DB.exec(short_urls[], DB.@sql("select max(idx) from short_urls"))[1][1]
            ismissing(maxidx) && (maxidx = 0)
            idx = maxidx + 1
            i = 1000000+idx
            cs = []
            while i > 0
                push!(cs, short_urls_chars[i % length(short_urls_chars) + 1])
                i = i ÷ length(short_urls_chars)
            end
            u = URIs.parse_uri(url)
            ext = lowercase(splitext(u.path)[end])
            spath = join(reverse(cs))
            DB.exec(short_urls[], DB.@sql("insert into short_urls values (?1, ?2, ?3, ?4)"), (idx, url, spath, ext))
        else
            spath, ext = r[1]
        end
        "$(URL_SHORTENING_ROOT_URL[])/$spath$ext"
    end
end

function url_shortening_handler(req::HTTP.Request)
    catch_exception(:url_shortening_handler, req) do
        host = Dict(req.headers)["Host"]
        path, query = split(req.target, '?')
        args = NamedTuple([Symbol(k)=>v for (k, v) in [split(s, '=') for s in split(query, '&')]])
        url = string(URIs.unescapeuri(args.u))
        res = url_shortening(url)
        HTTP.Response(200, HTTP.Headers(["Content-Type"=>"application/text"]), res)
    end
end

function url_lookup_handler(req::HTTP.Request)
    headers = HTTP.Headers([
                            "Access-Control-Allow-Origin"=>"*",
                            "Access-Control-Allow-Methods"=>"*",
                            "Access-Control-Allow-Headers"=>"*"
                           ])
    catch_exception(:url_lookup_handler, req) do
        host = Dict(req.headers)["Host"]
        spath = splitext(string(split(req.target, '/')[end]))[1]
        r = DB.exec(short_urls[], DB.@sql("select url from short_urls where path = ?1 and media_block_id is null limit 1"), (spath,))
        # @show (spath, r)
        if isempty(r)
            HTTP.Response(404, headers, "unknown url")
        else
            url = r[1][1]
            h = splitext(splitpath(url)[end])[1]
            rurl = 
            if !isempty(local rs = Postgres.execute(:p0, "
                                                    select media_url 
                                                    from media_storage ms, media_storage_priority msp
                                                    where ms.h = \$1 and ms.storage_provider = msp.storage_provider
                                                    order by msp.priority limit 1", 
                                                    [h])[2])
            # if !isempty(local rs = Postgres.execute(:p0, "
            #                                         select media_url 
            #                                         from media_storage ms
            #                                         where ms.h = \$1 and ms.storage_provider = 'cloudflare'
            #                                         limit 1", 
            #                                         [h])[2])
                url2 = rs[1][1]
                # @show url2
                u = URIs.parse_uri(url2)
                if u.host == "media.primal.net"
                    "https://primal.b-cdn.net/media-upload?u=$(URIs.escapeuri(url2))"
                else
                    url2
                end
            else
                # @show url
                # "https://primal.b-cdn.net/media-upload?u=$(URIs.escapeuri(url))"
                "https://primal.b-cdn.net/media-upload?u=$(URIs.escapeuri("https://media.primal.net"*URIs.parse_uri(url).path))"
            end
            HTTP.Response(302, HTTP.Headers([headers..., "Location"=>rurl]))
        end
    end
end

function spam_handler(req::HTTP.Request)
    catch_exception(:spam_handler, req) do
        host = Dict(req.headers)["Host"]
        res = Main.Filterlist.get_dict()
        HTTP.Response(200, HTTP.Headers(["Content-Type"=>"application/json"]), JSON.json(res, 2))
    end
end

api_headers = HTTP.Headers(["Content-Type"=>"application/json",
                            "Access-Control-Allow-Origin"=>"*",
                            "Access-Control-Allow-Methods"=>"*",
                            "Access-Control-Allow-Headers"=>"*"
                           ])

function api_handler(req::HTTP.Request)
    catch_exception(:api_handler, req) do
        req.method == "OPTIONS" && return HTTP.Response(200, api_headers, "ok")
        body = String(req.body)
        # @show req.method req.target body
        host = Dict(req.headers)["Host"]
        filt = JSON.parse(body)
        funcall = Symbol(filt[1])

        @assert funcall in Main.App.exposed_functions
        kwargs = Pair{Symbol, Any}[Symbol(k)=>v for (k, v) in get(filt, 2, Dict())]
        res = Ref{Any}(nothing)

        try
            Main.CacheServerHandlers.metrics_logged(funcall, kwargs; subid="http") do
                wait(Threads.@spawn Base.invokelatest(Main.CacheServerHandlers.app_funcall, funcall, kwargs, 
                                                      function(r)
                                                          res[] = Main.App.content_moderation_filtering_2(est[], r, funcall, kwargs)
                                                      end))
            end
        catch ex
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
            ex isa TaskFailedException && (ex = ex.task.result)
            res[] = (; error=(ex isa ErrorException ? ex.msg : "error"))
        end

        HTTP.Response(200, api_headers, JSON.json(res[]))
    end
end

function suggestions_handler(req::HTTP.Request)
    catch_exception(:suggestions_handler, req) do
        req.method == "OPTIONS" && return HTTP.Response(200, api_headers, "ok")
        body = String(req.body)
        # @show req.method req.target body
        host = Dict(req.headers)["Host"]
        d = JSON.parse(read(Main.App.SUGGESTED_USERS_FILE[], String))
        mds = Dict{Nostr.PubKeyId, Nostr.Event}()
        for (_, ms) in d
            for (pubkey, name) in ms
                pubkey = Nostr.PubKeyId(pubkey)
                if !haskey(mds, pubkey) && pubkey in est[].meta_data
                    eid = est[].meta_data[pubkey]
                    if eid in est[].events
                        mds[pubkey] = est[].events[eid]
                    end
                end
            end
        end
        res = (; 
               metadata=Dict([Nostr.hex(pk)=>md for (pk, md) in mds]), 
               suggestions=[(; group, members=[(; name, pubkey) for (pubkey, name) in ms])
                            for (group, ms) in d])
        HTTP.Response(200, api_headers, JSON.json(res))
    end
end

function purge_media_handler(req::HTTP.Request)
    catch_exception(:purge_media_handler, req) do
        r = JSON.parse(String(req.body))
        purge_media(Nostr.PubKeyId(r["pubkey"]), r["url"])
        HTTP.Response(200, api_headers, "ok")
    end
end

BUNNY_API_KEY = Ref{Any}(nothing)

function bunny_purge()
    @assert HTTP.request("POST", "https://api.bunny.net/pullzone/1425721/purgeCache", ["AccessKey"=>BUNNY_API_KEY[]]).status == 204
end

function purge_media(pubkey::Nostr.PubKeyId, surl::String)
    # @show (:purge_media, pubkey, surl)
    function purge(url)
        path = string(URIs.parse_uri(url).path)

        for mps in values(Main.Media.MEDIA_PATHS)
            for mp in mps
                if mp[1] == :local
                    filepath = join(split(mp[3], '/')[1:end-1], '/') * path
                    # @show (:rmlocal, filepath)
                    try isfile(filepath) && rm(filepath) 
                    catch ex println(ex) end
                elseif mp[1] == :s3
                    # @show (:rms3, Media.s3_check(mp[2], path[2:end]), path)
                    try Media.s3_delete(mp[2], path[2:end])
                    catch ex println(ex) end
                end
            end
        end
    end

    spath, ext = splitext(URIs.parse_uri(surl).path[2:end])

    for (url,) in Postgres.execute(:p0, "select media_url from media where url = \$1", [surl])[2]
        # @show url
        purge(url)
    end
    for (url,) in Postgres.execute(:p0, "select thumbnail_url from video_thumbnails where video_url = \$1", [surl])[2]
        # @show url
        purge(url)
    end

    for (url,) in Postgres.execute(:membership,
                                   "select url from short_urls where path = \$1 and ext = \$2 ",
                                   [spath, ext])[2]
        # @show url
        purge(url)

        path = string(URIs.parse_uri(url).path)

        path, size = Postgres.execute(:membership,
                                      "select path, size from media_uploads where pubkey = \$1 and path = \$2 ",
                                      [pubkey, path])[2][1]

        Postgres.execute(:membership, "delete from media_uploads where pubkey = \$1 and path = \$2",
                         [pubkey, path])

        Postgres.execute(:membership, "delete from short_urls where path = \$1 and ext = \$2",
                         [spath, ext])

        Postgres.execute(:membership, "update memberships set used_storage = used_storage - \$2 where pubkey = \$1",
                         [pubkey, size])
    end
end

end

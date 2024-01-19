module InternalServices

import HTTP, EzXML, JSON, URIs
using DataStructures: CircularBuffer

import ..Utils
import ..Nostr
import ..Bech32
import ..DB
import ..Media

PORT = Ref(14000)

PRINT_EXCEPTIONS = Ref(true)

server = Ref{Any}(nothing)
router = Ref{Any}(nothing)

exceptions = CircularBuffer(200)

est = Ref{Any}(nothing)

short_urls = Ref{Any}(nothing)
verified_users = Ref{Any}(nothing)

function catch_exception(body::Function, handler::Symbol, args...)
    try
        body()
    catch ex
        push!(exceptions, (handler, time(), ex, args...))
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        HTTP.Response(500, "error")
    end
end

function start(cache_storage, pqconnstr; setup_handlers=true)
    @assert isnothing(server[])

    est[] = cache_storage

    router[] = HTTP.Router()
    server[] = HTTP.serve!(router[], "0.0.0.0", PORT[])

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

        HTTP.register!(router[], "/media-cache", media_cache_handler)

        HTTP.register!(router[], "/link-preview", link_preview_handler)

        HTTP.register!(router[], "/url-shortening", url_shortening_handler)
        HTTP.register!(router[], "/url-lookup/*", url_lookup_handler)

        HTTP.register!(router[], "/spam", spam_handler)

        HTTP.register!(router[], "/api", api_handler)
    end

    short_urls[] = DB.PQDict{Int, String}("short_urls", pqconnstr,
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

    verified_users[] = DB.PQDict{String, Int}("verified_users", pqconnstr,
                                              init_queries=["create table if not exists verified_users (name varchar(200) not null, pubkey bytea not null)",
                                                            "create index if not exists verified_users_pubkey on verified_users (pubkey asc)",
                                                            "create index if not exists verified_users_name on verified_users (name asc)",
                                                           ])
    nothing
end

function stop()
    @assert !isnothing(server[])
    close(server[])
    server[] = nothing
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
    replace(c, DB.re_mention => function (r)
                prefix = "nostr:npub"
                startswith(r, prefix) || return r
                if !isnothing(local pk = Bech32.nip19_decode_wo_tlv(r[7:end]))
                    try
                        c = JSON.parse(cache_storage.events[cache_storage.meta_data[pk]].content)
                        return "@"*mdtitle(c)
                    catch _ end
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
    return (; title, description, image, (isnothing(url) ? (;) : (; url))...)
end

function get_meta_elements(host::AbstractString, path::AbstractString)
    cache_storage = est[]

    title = description = image = url = ""
    twitter_card = "summary"

    mdpubkey_(pk) = (; url="https://$host$path", twitter_card, mdpubkey(cache_storage, pk)...)

    if !isnothing(local m = match(r"^/(profile|p)/(.*)", path))
        pk = string(m[2])
        pk = startswith(pk, "npub") ? Bech32.nip19_decode_wo_tlv(pk) : Nostr.PubKeyId(pk)
        return mdpubkey_(pk)

    elseif !isnothing(local m = match(r"^/(thread|e)/(.*)", path))
        eid = string(m[2])
        eid = startswith(eid, "note") ? Bech32.nip19_decode_wo_tlv(eid) : Nostr.EventId(eid)
        if eid in cache_storage.events
            e = cache_storage.events[eid]
            url = "https://$(host)/e/$(m[2])"
            description = replace(content_refs_resolved(e), re_url => "")
            if e.pubkey in cache_storage.meta_data
                c = JSON.parse(cache_storage.events[cache_storage.meta_data[e.pubkey]].content)
                title = mdtitle(c)
                image = get(c, "picture", "")
            end
            if !isempty(local image_links = get_image_links(e.content))
                image = image_links[1]
                twitter_card = "summary_large_image"
            end
        end
        return (; title, description, image, url, twitter_card)

    elseif !isnothing(local m = match(r"^/downloads?", path)) && 1==1
        return (; 
                title="Download Primal apps and source code", 
                description="Unleash the power of Nostr",
                image=("https://primal.net/public/primal-download-thumbnail.png", :from_origin),
                url="https://primal.net/downloads",
                twitter_card = "summary_large_image")

    elseif !isnothing(local m = match(r"^/(.*)", path))
        name = string(m[1])
        if !isempty(local pks = nostr_json_query_by_name(name))
            return mdpubkey_(pks[1])
        end

    end

    return nothing
end

index_html_reading = Utils.Throttle(; period=5.0, t=0)
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
        [Nostr.PubKeyId(pk) for (pk,) in DB.exec(verified_users[], DB.@sql("select pubkey from verified_users where name = ?1"), (name,))]
    end
end
function nostr_json_query_by_pubkey(pubkey::Nostr.PubKeyId)
    lock(nostr_json_query_lock) do 
        [name for (name,) in DB.exec(verified_users[], DB.@sql("select name from verified_users where pubkey = ?1"), (pubkey,))]
    end
end

function preview_handler(req::HTTP.Request)
    lock(index_lock) do
        dochtml = index_html[]
        try
            host = Dict(req.headers)["Host"]
            index_html_reading() do
                index_html[] = read("$(APP_ROOT[])/index.html", String)
                index_doc[] = doc = EzXML.parsehtml(index_html[])
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
                    index_elems[k] = el
                end
                
                el = EzXML.ElementNode("meta")
                el["name"] = "og:type"
                el["content"] = "website"
                EzXML.link!(head, el)

                el = EzXML.ElementNode("meta")
                el["name"] = "twitter:card"
                EzXML.link!(head, el)
                index_elems[:twitter_card] = el

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
                        index_elems[k]["content"] = v
                    else
                        delete!(index_elems[k], "content")
                    end
                end

                eltitle = EzXML.findall("/html/head/title", index_doc[])[1]
                for el in EzXML.nodes(eltitle)
                    EzXML.unlink!(el)
                end
                maxlen = 50
                s = mels.description
                s = length(s) > maxlen ? (first(s, maxlen) * "...") : s
                s = strip(mels.title * ": " * s)
                EzXML.link!(eltitle, EzXML.TextNode(s))

                dochtml = string(index_doc[])
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
        send_content = !(haskey(args, :c) && args.c == "0")
        # send_content = 1==1
        url = string(URIs.unescapeuri(args.u))
        variants = variant == (:original, true) ? [variant] : Media.all_variants
        tr = @elapsed (r = Media.media_variants(est[], url, variants; sync=true))
        # println("$tr  $query")
        if isnothing(r)
            HTTP.Response(302, HTTP.Headers(["Location"=>url, "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]))
        else
            resurl = r[variant]
            if !send_content
                HTTP.Response(302, HTTP.Headers(["Location"=>resurl, "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]))
            else
                @assert startswith(resurl, Media.MEDIA_URL_ROOT[])
                fp = Media.MEDIA_PATH[] * "/" * resurl[length(Media.MEDIA_URL_ROOT[])+1:end]
                _, ext = splitext(fp)
                ct = "application/octet-stream"
                for (mt, ext2) in Media.mimetype_ext
                    if ext2 == ext
                        ct = mt
                        break
                    end
                end
                d = read(fp)
                # HTTP.Response(200, HTTP.Headers(["Content-Type"=>ct, "Content-Length"=>"$(length(d))", "Cache-Control"=>"no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"]), d)
                HTTP.Response(200, HTTP.Headers(["Content-Type"=>ct, "Content-Length"=>"$(length(d))", "Cache-Control"=>"max-age=20"]), d)
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

function url_shortening_handler(req::HTTP.Request)
    catch_exception(:url_shortening_handler, req) do
        lock(short_urls_lock) do
            host = Dict(req.headers)["Host"]
            path, query = split(req.target, '?')
            args = NamedTuple([Symbol(k)=>v for (k, v) in [split(s, '=') for s in split(query, '&')]])
            url = string(URIs.unescapeuri(args.u))
            res = url_shortening(url)
            HTTP.Response(200, HTTP.Headers(["Content-Type"=>"application/text"]), res)
        end
    end
end

function url_lookup_handler(req::HTTP.Request)
    catch_exception(:url_lookup_handler, req) do
        host = Dict(req.headers)["Host"]
        spath = splitext(string(split(req.target, '/')[end]))[1]
        r = DB.exec(short_urls[], DB.@sql("select url from short_urls where path = ?1 limit 1"), (spath,))
        if isnothing(r)
            HTTP.Response(404, "unknown url")
        else
            url = r[1][1]
            HTTP.Response(302, HTTP.Headers(["Location"=>url]))
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
            Base.invokelatest(Main.CacheServerHandlers.app_funcall, funcall, kwargs, function(r); res[] = r; end)
        catch ex
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
            ex isa TaskFailedException && (ex = ex.task.result)
            res[] = (; error=(ex isa ErrorException ? ex.msg : "error"))
        end
        HTTP.Response(200, api_headers, JSON.json(res[]))
    end
end

end

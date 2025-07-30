module Blossom

import HTTP, JSON, URIs, Base64, SHA
using DataStructures: CircularBuffer

import ..Utils
import ..Nostr
import ..Postgres
import ..Media

PORT = Ref(21000)
DB = Ref(:membership)

BASE_URL = Ref("https://blossom.primal.net")

PRINT_EXCEPTIONS = Ref(true)

server = Ref{Any}(nothing)
router = Ref{Any}(nothing)

exceptions = CircularBuffer(200)

est = Ref{Any}(nothing)

pex(query::String, params=[]) = Postgres.execute(DB[], replace(query, '?'=>'$'), params)
pex(server::Symbol, query::String, params=[]) = Postgres.execute(server, replace(query, '?'=>'$'), params)

struct BlossomException <: Exception
    status::Int
    message::String
end

function blossom_error(status::Int, message::String)
    throw(BlossomException(status, message))
end

exceptions_lock = ReentrantLock()
function catch_exception(body::Function, handler::Symbol, args...)
    try
        body()
    catch ex
        lock(exceptions_lock) do
            push!(exceptions, (handler, time(), ex, args...))
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        end
        if ex isa BlossomException
            HTTP.Response(ex.status, response_headers("text/plain"; extra=["X-Reason"=>ex.message]), ex.message)
        else
            HTTP.Response(500, response_headers("text/plain"; extra=["X-Reason"=>"unspecified error"]), "error")
        end
    end
end

function start(cache_storage)
    @assert isnothing(server[])

    est[] = cache_storage

    router[] = HTTP.Router()
    server[] = HTTP.serve!(router[], "0.0.0.0", PORT[])

    for path in ["/**", "/"]
        HTTP.register!(router[], path, blossom_handler)
    end

    nothing
end

function stop()
    @assert !isnothing(server[])
    close(server[])
    server[] = nothing
end

function mimetype_for_ext(ext::String)
    for (mimetype, ext2) in Main.Media.mimetype_ext
        if ext2 == ext
            return mimetype
        end
    end
    nothing
end

function response_headers(content_type="application/json"; extra=[])
    HTTP.Headers(collect(Dict(["Content-Type"=>content_type,
                               "Access-Control-Allow-Origin"=>"*",
                               "Access-Control-Allow-Methods"=>"*",
                               "Access-Control-Allow-Headers"=>"*",
                               extra...
                              ])))
end

function get_header(headers, header)
    for (k, v) in collect(headers)
        if lowercase(k) == lowercase(header)
            return v
        end
    end
    nothing
end

function find_blob(req_target)
    r = find_upload(req_target)
    return r # !!
    isnothing(r) || return r

    h, ext = splitext(req_target[2:end])
    h = lowercase(h)
    sha256 = hex2bytes(h)
    for (media_url, mimetype, size, storage_provider) in pex(:p0, "
                                                       select ms.media_url, ms.content_type, ms.size, ms.storage_provider 
                                                       from media_storage ms
                                                       where 
                                                         ms.sha256 = ?1 and ms.media_block_id is null and
                                                         not exists (
                                                           select 1 from media_uploads mu, media_block mb 
                                                           where 
                                                             ms.sha256 = mu.sha256 and mu.media_block_id = mb.id and
                                                             mb.d->>'reason' like 'csam%'
                                                           limit 1
                                                         )
                                                       limit 1", 
                                                       [sha256])[2]
        storage_provider = Symbol(storage_provider)
        return (; media_url, storage_provider, mimetype, size, sha256)
    end
    nothing
end

function find_upload(req_target)
    h, ext = splitext(req_target[2:end])
    h = lowercase(h)
    sha256 = try hex2bytes(h) catch _ return nothing end
    for (mimetype, size, path, pubkey, key) in pex("select mimetype, size, path, pubkey, key::varchar 
                                             from media_uploads 
                                             where sha256 = ?1 and media_block_id is null limit 1", 
                                             [sha256])[2]
        kh = splitpath(splitext(path)[1])[end]
        for (media_url, mimetype, size, storage_provider) in pex(:p0, "
                                                           select ms.media_url, ms.content_type, ms.size, ms.storage_provider 
                                                           from media_storage ms, media_storage_priority msp
                                                           where ms.h = ?1 and ms.media_block_id is null and msp.storage_provider = ms.storage_provider
                                                           order by msp.priority limit 1", 
                                                           [kh])[2]
            storage_provider = Symbol(storage_provider)
            return (; media_url, storage_provider, path, mimetype, size, sha256, pubkey=Nostr.PubKeyId(pubkey))
        end
        for mp in Main.Media.MEDIA_PATHS[Main.App.UPLOADS_DIR[]]
            if mp[1] == :local
                filepath = join(split(mp[3], '/')[1:end-1], '/') * path
                media_url = "https://media.primal.net$path"
                try isfile(filepath) && return (; media_url, storage_provider=nothing, filepath, path, mimetype, size, sha256, pubkey=Nostr.PubKeyId(pubkey))
                catch _ end
            end
        end
    end
    nothing
end

function check_action(req, action::String; x_tag_hash=nothing)
    parts = []
    if !isnothing(local v = get_header(req.headers, "Authorization"))
        parts = split(v)
    end
    length(parts) == 2 || blossom_error(400, "missing auth event")
    parts[1] == "Nostr" || blossom_error(400, "invalid auth event")
    e = Nostr.Event(JSON.parse(String(Base64.base64decode(parts[2]))))
    Nostr.verify(e) || blossom_error(400, "auth event verification failed")
    e.kind == 24242 || blossom_error(400, "wrong kind in auth event")
    # @assert e.created_at <= trunc(Int, time())
    action_ok = false
    x_tag_ok = isnothing(x_tag_hash)
    for t in e.tags
        if length(t.fields) >= 2
            if t.fields[1] == "expiration"
                expiration = parse(Int, t.fields[2])
                expiration > trunc(Int, time()) || blossom_error(400, "auth event expired")
            elseif t.fields[1] == "t"
                action_ok |= action == t.fields[2] 
            elseif t.fields[1] == "x" && !isnothing(x_tag_hash)
                x_tag_ok |= hex2bytes(t.fields[2]) == x_tag_hash
            end
        end
    end
    action_ok || blossom_error(400, "invalid action in auth event")
    x_tag_ok || blossom_error(400, "invalid x tag")
    e
end

function blossom_handler(req::HTTP.Request)
    catch_exception(:blossom_handler, req) do
        host = get_header(req.headers, "Host")
        # @show (req.method, req.target)
        
        if req.method == "OPTIONS"
            return HTTP.Response(200, response_headers("text/plain"; extra=[
                                                                            "Access-Control-Allow-Headers"=>"Authorization, *",
                                                                            "Access-Control-Allow-Methods"=>"GET, PUT, DELETE",
                                                                           ]), "ok")

        elseif req.method == "GET"
            if req.target == "/"
                return HTTP.Response(200, response_headers("text/plain"), "Welcome to Primal Blossom server. Implemented: BUD-01, BUD-02, BUD-04, BUD-05")

            elseif startswith(req.target, "/list/")
                pk = Nostr.PubKeyId(string(split(req.target, '/')[end]))
                res = []
                for (mimetype, created_at, path, size, sha256) in pex("select mimetype, created_at, path, size, sha256 from media_uploads where pubkey = ?1", [pk])[2]
                    # _, ext = splitext(path)
                    # mimetype = mimetype_for_ext(ext)
                    ext = get(Main.Media.mimetype_ext, mimetype, "")
                    push!(res, (;
                                url="$(BASE_URL[])/$(bytes2hex(sha256))$(ext)",
                                sha256=bytes2hex(sha256),
                                size,
                                type=mimetype,
                                uploaded=created_at,
                               ))
                end
                return HTTP.Response(200, response_headers(), JSON.json(res))

            elseif !isnothing(match(r"^/[0-9a-fA-F]{64}", req.target))
                # @show req.target
                r = find_blob(req.target)
                if !isnothing(r)
                    # return HTTP.Response(302, response_headers(r.mimetype; extra=["Location"=>"https://primal.b-cdn.net/media-cache?s=o&a=1&u=$(URIs.escapeuri(r.media_url))"]), 
                    #                      "redirecting")
                    return HTTP.Response(302, response_headers(r.mimetype; extra=["Location"=>r.media_url]), 
                                         "redirecting")
                else
                    blossom_error(404, "not found")
                end
            end

        elseif req.method == "HEAD"
            if req.target in ["/upload", "/media"]
                h = 
                try hex2bytes(get_header(req.headers, "X-SHA-256"))
                catch _ blossom_error(401, "X-SHA-256 request header is missing") end
                check_action(req, "upload"; x_tag_hash=h)
                return HTTP.Response(200, response_headers("text/plain"), "ok")
            else
                r = find_blob(req.target)
                if !isnothing(r)
                    return HTTP.Response(200, response_headers(r.mimetype; extra=["Content-Length"=>string(r.size)]), "")
                else
                    blossom_error(404, "not found")
                end
            end

        elseif req.method == "DELETE"
            r = find_upload(req.target)
            e = check_action(req, "delete"; x_tag_hash=r.sha256)
            if !isnothing(r) && r.pubkey == e.pubkey
                @show Main.InternalServices.purge_media_(e.pubkey, r.media_url; reason="delete from blossom", extra=(; initiator_pubkey=e.pubkey))
                return HTTP.Response(200, response_headers("text/plain"), "ok")
            else
                blossom_error(404, "not found")
            end

        elseif req.method == "PUT"
            # push!(Main.stuff, (:blossomupload, req))
            if req.target == "/mirror"
                url = JSON.parse(String(req.body))["url"]
                h = hex2bytes(match(r"/([0-9a-fA-F]{64})", url)[1])
                e = check_action(req, "upload"; x_tag_hash=h)
                data = Media.download(est[], url; timeout=300)
                return import_blob(e, data; strip_metadata=false)
            else
                data = collect(req.body)
                e = check_action(req, "upload"; x_tag_hash=SHA.sha256(data))
                strip_metadata = req.target == "/media"
                return import_blob(e, data; strip_metadata)
            end
        end

        blossom_error(404, "not found")
    end
end

function import_blob(e::Nostr.Event, data::Vector{UInt8}; strip_metadata::Bool)
    h = SHA.sha256(data)
    r = JSON.parse([x for x in Main.App.import_upload_2(est[], e.pubkey, data; strip_metadata)
                    if x.kind == Int(Main.App.UPLOADED_2)][1].content)
    sha256 = hex2bytes(r["sha256"])
    strip_metadata || @assert h == sha256
    for (mimetype, created_at, path, size) in pex("select mimetype, created_at, path, size from media_uploads where sha256 = ?1", [sha256])[2]
        # @show path
        # _, ext = splitext(path)
        # mimetype = mimetype_for_ext(ext)
        ext = get(Main.Media.mimetype_ext, mimetype, "")
        return HTTP.Response(200, response_headers("application/json"), 
                             JSON.json((;
                                        url="$(BASE_URL[])/$(bytes2hex(sha256))$(ext)",
                                        sha256=bytes2hex(sha256),
                                        size,
                                        type=mimetype,
                                        uploaded=created_at,
                                       )))
    end
    blossom_error(404, "not found")
end

end

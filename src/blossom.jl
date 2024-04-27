module Blossom

import HTTP, JSON, URIs, Base64, SHA
using DataStructures: CircularBuffer

import ..Utils
import ..Nostr
import ..Postgres

PORT = Ref(21000)
DB = Ref(:membership)

BASE_URL = Ref("https://blossom.primal.net")

PRINT_EXCEPTIONS = Ref(true)

server = Ref{Any}(nothing)
router = Ref{Any}(nothing)

exceptions = CircularBuffer(200)

est = Ref{Any}(nothing)

pex(query::String, params=[]) = Postgres.execute(DB[], replace(query, '?'=>'$'), params)

function catch_exception(body::Function, handler::Symbol, args...)
    try
        body()
    catch ex
        push!(exceptions, (handler, time(), ex, args...))
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        HTTP.Response(500, "error")
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

function response_headers(content_type="application/json")
    HTTP.Headers(["Content-Type"=>content_type,
                  "Access-Control-Allow-Origin"=>"*",
                  "Access-Control-Allow-Methods"=>"*",
                  "Access-Control-Allow-Headers"=>"*"
                 ])
end

function find_blob(req_target)
    h, ext = splitext(req_target[2:end])
    sha256 = hex2bytes(h)
    # mimetype = mimetype_for_ext(ext)
    # if isnothing(mimetype); mimetype = "application/octet-stream"; end
    for (mimetype, path, pubkey) in pex("select mimetype, path, pubkey from media_uploads where sha256 = ?1 limit 1", [sha256])[2]
        for mp in Main.Media.MEDIA_PATHS[Main.App.UPLOADS_DIR[]]
            filepath = join(split(mp, '/')[1:end-1], '/') * path
            try isfile(filepath) && return (; filepath, path, mimetype, sha256, pubkey=Nostr.PubKeyId(pubkey))
            catch _ end
        end
    end
    nothing
end

function check_action(req, action::String)
    parts = []
    for (k, v) in collect(req.headers)
        if lowercase(k) == "authorization"
            parts = split(v)
        end
    end
    @assert parts[1] == "Nostr"
    e = Nostr.Event(JSON.parse(String(Base64.base64decode(parts[2]))))
    Nostr.verify(e) || return HTTP.Response(401, response_headers("text/plain"), "unauthorized")
    @assert e.kind == 24242
    @assert e.created_at <= trunc(Int, time())
    for t in e.tags
        if length(t.fields) >= 2
            if t.fields[1] == "expiration"
                expiration = parse(Int, t.fields[2])
                @assert expiration > trunc(Int, time())
            elseif t.fields[1] == "t"
                @assert action == t.fields[2]
            end
        end
    end
    e
end

function blossom_handler(req::HTTP.Request)
    catch_exception(:blossom_handler, req) do
        host = Dict(req.headers)["Host"]
        @show (req.method, req.target)
        
        if req.method == "OPTIONS"
            return HTTP.Response(200, response_headers("text/plain"), "ok")

        elseif req.method == "GET"
            if req.target == "/"
                return HTTP.Response(200, response_headers("text/plain"), "Welcome to Primal Blossom server.")

            elseif startswith(req.target, "/list/")
                pk = Nostr.PubKeyId(string(split(req.target, '/')[end]))
                res = []
                for (mimetype, created_at, path, size, sha256) in pex("select mimetype, created_at, path, size, sha256 from media_uploads where pubkey = ?1", [pk])[2]
                    # _, ext = splitext(path)
                    # mimetype = mimetype_for_ext(ext)
                    ext = get(Main.Media.mimetype_ext, mimetype, "application/octet-stream")
                    push!(res, (;
                                url="$(BASE_URL[])/$(bytes2hex(sha256))$(ext)",
                                sha256=bytes2hex(sha256),
                                size,
                                type=mimetype,
                                created=created_at,
                               ))
                end
                return HTTP.Response(200, response_headers(), JSON.json(res))

            elseif !isnothing(match(r"^/[0-9a-fA-F]{64}", req.target))
                r = find_blob(req.target)
                if !isnothing(r)
                    return HTTP.Response(200, response_headers(r.mimetype), read(r.filepath))
                else
                    return HTTP.Response(404, response_headers("text/plain"), "not found")
                end
            end

        elseif req.method == "HEAD"
            r = find_blob(req.target)
            if !isnothing(r)
                return HTTP.Response(200, response_headers(r.mimetype), "")
            else
                return HTTP.Response(404, response_headers("text/plain"), "not found")
            end

        elseif req.method == "DELETE"
            e = check_action(req, "delete")
            r = find_blob(req.target)
            if !isnothing(r)
                pex("delete from media_uploads where pubkey = ?1 and sha256 = ?2", [e.pubkey, r.sha256])
                if isempty(pex("select 1 from media_uploads where sha256 = ?1 limit 1", [r.sha256])[2])
                    @show (:rm, r.path)
                    for mp in Main.Media.MEDIA_PATHS[Main.App.UPLOADS_DIR[]]
                        filepath = join(split(mp, '/')[1:end-1], '/') * r.path
                        try 
                            if isfile(filepath)
                                rm(filepath) 
                                @show (:rm_ok, filepath)
                            end
                        catch ex
                            println(ex)
                        end
                    end
                end
                return HTTP.Response(200, response_headers("text/plain"), "ok")
            else
                return HTTP.Response(404, response_headers("text/plain"), "not found")
            end

        elseif req.method == "PUT"
            e = check_action(req, "upload")
            data = collect(req.body)
            @show r = JSON.parse([x for x in Main.App.import_upload(est[], e.pubkey, data) 
                                  if x.kind == Int(Main.App.UPLOADED_2)][1].content)
            @show sha256 = hex2bytes(r["sha256"])
            for (mimetype, created_at, path, size) in pex("select mimetype, created_at, path, size from media_uploads where sha256 = ?1", [sha256])[2]
                @show path
                # _, ext = splitext(path)
                # mimetype = mimetype_for_ext(ext)
                ext = get(Main.Media.mimetype_ext, mimetype, "application/octet-stream")
                return HTTP.Response(200, response_headers("application/json"), 
                                     JSON.json(@show (;
                                                url="$(BASE_URL[])/$(bytes2hex(sha256))$(ext)",
                                                sha256=bytes2hex(sha256),
                                                size,
                                                type=mimetype,
                                                created=created_at,
                                               )))
            end
            return HTTP.Response(404, response_headers("text/plain"), "not found")
        end

        return HTTP.Response(404, response_headers("text/plain"), "not found")
    end
end

end

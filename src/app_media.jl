#module App

import Base64
import URIs

import ..Media
using ..Tracing: @ti, @tc, @td, @tr

union!(exposed_functions, Set([
                               :upload,
                               :upload_chunk,
                               :upload_complete,
                               :upload_cancel,
                              ]))

UPLOAD=10_000_120
UPLOADED=10_000_121

UPLOADS_DIR = Ref(:uploads)
MEDIA_URL_ROOT = Ref("https://media.primal.net/uploads")
URL_SHORTENING_SERVICE = Ref("http://127.0.0.1:14001/url-shortening?u=")
MEDIA_UPLOAD_PATH = Ref("incoming")

categorized_uploads = Ref{Any}(nothing)

function import_upload_2(est::DB.CacheStorage, pubkey::Nostr.PubKeyId, data::Vector{UInt8})
    funcname = "import_upload_2"

    tbefore, tstart = Dates.now(), time()

    if !isempty(DB.exec(categorized_uploads[], "select 1 from categorized_uploads where sha256 = ?1 and type = 'blocked' limit 1", (SHA.sha256(data),)))
        error("blocked content")
    end

    @tr pubkey @elapsed (data = Media.strip_metadata(data))

    @tr pubkey sha256 = SHA.sha256(data)
    key = (; type="member_upload", pubkey, sha256=bytes2hex(sha256))

    new_import = Ref(false)
    (mi, lnk, murl) = @tr pubkey Media.media_import(function (_)
                                             new_import[] = true
                                             data
                                         end, key; media_path=UPLOADS_DIR[], pubkey)
    @tr key mi lnk murl new_import[] ()
    @show (pubkey ,mi, lnk, murl)

    @tr key murl if new_import[]
        if isempty(DB.exec(Main.InternalServices.memberships[], "select 1 from memberships where pubkey = ?1 limit 1", (pubkey,)))
            tier = isempty(DB.exec(Main.InternalServices.verified_users[], "select 1 from verified_users where pubkey = ?1 limit 1", (pubkey,))) ? "free" : "premium"
            DB.exec(Main.InternalServices.memberships[], "insert into memberships values (?1, ?2, ?3, ?4, ?5)", (pubkey, tier, missing, missing, 0))
        end
        tier, used_storage = DB.exec(Main.InternalServices.memberships[], "select tier, used_storage from memberships where pubkey = ?1", (pubkey,))[1]
        max_storage, = DB.exec(Main.InternalServices.membership_tiers[], "select max_storage from membership_tiers where tier = ?1", (tier,))[1]

        used_storage += length(data)
        if used_storage > max_storage
            @show (:insufficient_storage, pubkey)
            error("insufficient storage available")
            rm(mi.path)
        end

        DB.exec(Main.InternalServices.memberships[], "update memberships set used_storage = ?2 where pubkey = ?1",
                (pubkey, used_storage))

        try
            _, ext = splitext(lnk)
            path = "/uploads/$(mi.subdir)/$(mi.h)$(ext)"
            DB.ext_media_import(est, nothing, nothing, path, data)
        catch ex
            #println(ex)
            Utils.print_exceptions()
        end
    end

    @tr key murl wh = Media.parse_image_dimensions(data)
    width, height = isnothing(wh) ? (0, 0) : wh
    @tr key murl mimetype = Media.parse_mimetype(data)

    if isempty(DB.exe(est.media_uploads, DB.@sql("select 1 from media_uploads where pubkey = ?1 and key = ?2 limit 1"), pubkey, JSON.json(key)))
        DB.exe(est.media_uploads, DB.@sql("insert into media_uploads values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)"), 
               pubkey,
               key.type, JSON.json(key),
               trunc(Int, time()),
               string(URIs.parse_uri(murl).path),
               stat(mi.path).size, 
               mimetype,
               "", 1.0, 
               width, height,
               0.0,
               sha256)
    end

    @tr key murl surl = Main.InternalServices.url_shortening(murl)

    if length(data) < 10*1024^2 && splitext(surl)[2] in [".jpg", ".png", ".gif", ".mp4", ".mov", ".webp"]
        @async try
            # @tr key murl surl DB.import_media(est, nothing, surl, [(:original, true)])
            @tr key murl surl DB.import_media(est, nothing, surl, Media.all_variants)
            # r = Media.media_variants(est, surl; variant_specs=Media.all_variants, sync=true, proxy=nothing)
            # DB.DOWNLOAD_MEDIA[] && Media.media_queue(@task @ti @tr surl DB.import_media(est, nothing, surl, Media.all_variants))
            # @sync for ((size, anim), media_url) in r
            #     @async @show begin HTTP.get(Media.cdn_url(surl, size, anim); readtimeout=15, connect_timeout=5).body; nothing; end
            # end
        catch ex
            println("import_upload_2: $(typeof(ex))")
        end
    end

    try Main.Tracing.log_trace(@__MODULE__, funcname, "done", nothing; table="tracekeep", t=tbefore, duration=time()-tstart, extra=(; pubkey, surl, size=length(data)))
    catch _ Utils.print_exceptions() end

    @show @tr [
     (; kind=Int(UPLOADED_2), content=JSON.json((; sha256=bytes2hex(sha256)))),
     (; kind=Int(UPLOADED), content=surl),
    ]
end

function import_upload(est::DB.CacheStorage, pubkey::Nostr.PubKeyId, data::Vector{UInt8})
    [e for e in import_upload_2(est, pubkey, data) if e.kind == UPLOADED]
end

UPLOAD_MAX_SIZE = Ref(1024^4)

UPLOAD_BLOCKED_TRUSTRANK_THRESHOLD = Ref(0.0)
function is_upload_blocked(pubkey::Nostr.PubKeyId)
    !isempty(Postgres.execute(:membership, "select 1 from verified_users where pubkey = \$1 limit 1", [pubkey])[2]) && return false
    !isempty(DB.exec(lists[], "select 1 from lists where list = ?1 and pubkey = ?2 limit 1", ("upload_block", pubkey))) && return true
    !isempty(Postgres.execute(:p0, "select 1 from filterlist where target = \$1 and target_type = 'pubkey' and grp = 'csam' and blocked limit 1", [pubkey])[2]) && return true
    0==1 && isempty(Postgres.execute(:p0, "select 1 from pubkey_trustrank where pubkey = \$1 and rank >= \$2 limit 1", [pubkey, UPLOAD_BLOCKED_TRUSTRANK_THRESHOLD[]])[2]) && return true
    false
end

function use_external_storage(pubkey::Nostr.PubKeyId)
    !isempty(Postgres.execute(:membership, "select 1 from verified_users where pubkey = \$1 limit 1", [pubkey])[2]) && return false
    isempty(Postgres.execute(:p0, "select 1 from pubkey_trustrank where pubkey = \$1 and rank >= \$2 limit 1", [pubkey, UPLOAD_BLOCKED_TRUSTRANK_THRESHOLD[]])[2]) && return true
    false
end

function upload(est::DB.CacheStorage; event_from_user::Dict)
    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD) || error("invalid event kind")
    is_upload_blocked(e.pubkey) && error("upload blocked")

    contents = e.content
    data = Base64.base64decode(contents[findfirst(',', contents)+1:end])

    length(data) > UPLOAD_MAX_SIZE[] && error("upload is too large")

    import_upload(est, e.pubkey, data)
end

active_uploads = Dict() |> ThreadSafe
upload_stats = (; started=Ref(0), completed=Ref(0), canceled=Ref(0))

function check_upload_id(ulid)
    @assert !isnothing(match(r"^[-a-zA-Z0-9_]+$", ulid)) ulid
    ulid
end

function upload_chunk(est::DB.CacheStorage; event_from_user::Dict)
    # push!(Main.stuff, (:upload_chunk, event_from_user))

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    is_upload_blocked(e.pubkey) && error("upload blocked")

    c = JSON.parse(e.content)
    ulid = check_upload_id(c["upload_id"])

    lock(active_uploads) do active_uploads
        if !haskey(active_uploads, ulid)
            active_uploads[ulid] = trunc(Int, time())
            upload_stats.started[] += 1
            PushGatewayExporter.set!("cache_upload_stats_started", upload_stats.started[])
        end
    end

    c["file_length"] > UPLOAD_MAX_SIZE[] && error("upload size too large")

    fn = "$(MEDIA_UPLOAD_PATH[])/$(Nostr.hex(e.pubkey))_$(ulid)"
    # @show (; t=Dates.now(), fn, offset=c["offset"], file_length=c["file_length"])
    
    data = Base64.base64decode(c["data"][findfirst(',', c["data"])+1:end])
    c["offset"] + length(data) > UPLOAD_MAX_SIZE[] && error("upload size too large")

    open(fn, "a+") do f
        seek(f, c["offset"])
        write(f, data)
    end

    []
end

function upload_complete(est::DB.CacheStorage; event_from_user::Dict)
    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    is_upload_blocked(e.pubkey) && error("upload blocked")

    c = JSON.parse(e.content)
    ulid = check_upload_id(c["upload_id"])

    fn = "$(MEDIA_UPLOAD_PATH[])/$(Nostr.hex(e.pubkey))_$(ulid)"
    c["file_length"] == stat(fn).size || error("incorrect upload size")

    data = read(fn)
    c["sha256"] == bytes2hex(SHA.sha256(data)) || error("incorrect sha256")

    res = import_upload(est, e.pubkey, data)
    rm(fn)

    lock(active_uploads) do active_uploads
        delete!(active_uploads, ulid)
        upload_stats.completed[] += 1
        PushGatewayExporter.set!("cache_upload_stats_completed", upload_stats.completed[])
    end

    res
end

function upload_cancel(est::DB.CacheStorage; event_from_user::Dict)
    # push!(Main.stuff, (:upload_cancel, (; event_from_user)))

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    is_upload_blocked(e.pubkey) && error("upload blocked")

    c = JSON.parse(e.content)
    ulid = check_upload_id(c["upload_id"])

    fn = "$(MEDIA_UPLOAD_PATH[])/$(Nostr.hex(e.pubkey))_$(ulid)"
    rm(fn)

    lock(active_uploads) do active_uploads
        delete!(active_uploads, ulid)
        upload_stats.canceled[] += 1
        PushGatewayExporter.set!("cache_upload_stats_canceled", upload_stats.canceled[])
    end

    []
end


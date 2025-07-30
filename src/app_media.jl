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

function import_upload_3(
        est::DB.CacheStorage, 
        pubkey::Nostr.PubKeyId, 
        data::Vector{UInt8}, 
        sha256_before::Vector{UInt8}, 
        burl::String,
    )
    funcname = "import_upload_3"

    tbefore, tstart = Dates.now(), time()

    sha256 = SHA.sha256(data)

    key = (; type="member_upload", pubkey, sha256=bytes2hex(sha256))

    @tr mimetype = Media.parse_mimetype(data)

    width, height, dur = 0, 0, 0
    if startswith(mimetype, "image/")
        @tr r = Media.parse_image_dimensions(data)
        !isnothing(r) && ((width, height, dur) = r)
    elseif startswith(mimetype, "video/")
        @tr r = Media.parse_video_dimensions(data)
        !isnothing(r) && ((width, height, dur) = r)
    end

    new_import = Ref(false)
    # @tr pubkey bytes2hex(sha256) Media.media_import_2(function (_)
    #                                          new_import[] = true
    #                                          data
    #                                      end, key, sha256; media_path=:uploadfast, pubkey)
    # @tr new_import[] ()
    new_import[] = true

    Threads.@spawn Media.media_import_2(_->data, key, sha256; media_path=:upload, pubkey)

    if new_import[]
        if isempty(DB.exec(Main.InternalServices.memberships[], "select 1 from memberships where pubkey = ?1 limit 1", (pubkey,)))
            tier = isempty(DB.exec(Main.InternalServices.verified_users[], "select 1 from verified_users where pubkey = ?1 limit 1", (pubkey,))) ? "free" : "premium"
            DB.exec(Main.InternalServices.memberships[], "insert into memberships values (?1, ?2, ?3, ?4, ?5)", (pubkey, tier, missing, missing, 0))
        end
        tier, used_storage = DB.exec(Main.InternalServices.memberships[], "select tier, used_storage from memberships where pubkey = ?1", (pubkey,))[1]
        max_storage, = DB.exec(Main.InternalServices.membership_tiers[], "select max_storage from membership_tiers where tier = ?1", (tier,))[1]

        used_storage += length(data)
        # if used_storage > max_storage
        #     @show (:insufficient_storage, pubkey)
        #     error("insufficient storage available")
        #     rm(mi.path)
        # end

        DB.exec(Main.InternalServices.memberships[], "update memberships set used_storage = ?2 where pubkey = ?1",
                (pubkey, used_storage))
    end

    Threads.@spawn @tr burl length(data) pubkey mimetype begin
        try
            startswith(mimetype, "video/") && @tr surl bytes2hex(sha256) DB.import_video(burl, data, sha256) # TODO: remove
            if startswith(mimetype, "image/") || startswith(mimetype, "video/")
                @tr burl bytes2hex(sha256) pubkey ext_after_import_upload(burl, data; pubkey, origin="upload")
            end
        catch _ 
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        end
    end

    blocked = false
    try
        shas = [sha256_before, sha256]
        for (sha256_after,) in Postgres.execute(:p0, "select sha256_after from media_metadata_stripping where sha256_before = \$1 limit 1", [sha256_before])[2]
            push!(shas, sha256_after)
            append!(shas, map(first, Postgres.execute(:p0, "select sha256_before from media_metadata_stripping where sha256_after = \$1 limit 1", [sha256_after])[2]))
        end
        shas = collect(Set(shas))
        @tr burl pubkey sha256 collect(map(bytes2hex, shas))
        if (@tr burl pubkey sha256 upload_check_similarity_by_sha256(pubkey, shas, burl)) == :blocked
            push!(Main.stuff, (:upload_check_similarity_by_sha256_blocked, Dates.now(), (; pubkey, shas, mimetype, data, burl)))
            Main.InternalServices.bunny_purge()
            blocked = true
        # else
        #     Postgres.execute(:p0, "
        #                      update media_storage ms set media_block_id = null 
        #                      where ms.sha256 = \$1 and ms.media_block_id is not null and exists (
        #                         select 1 from media_block mb where mb.id = ms.media_block_id and mb.d->>'reason' like 'deleted%'
        #                      )", [sha256])
        end
        errormonitor(Threads.@spawn @tr burl length(data) pubkey mimetype begin
            if (@tr burl pubkey sha256 upload_check_similarity_by_embedding(pubkey, shas, mimetype, data, burl)) == :blocked
                push!(Main.stuff, (:upload_check_similarity_by_embedding_blocked, Dates.now(), (; pubkey, shas, mimetype, data, burl)))
                Main.InternalServices.bunny_purge()
            end
        end)
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        true
    end

    if !blocked && length(data) < 10*1024^2 && splitext(burl)[2] in [".jpg", ".png", ".gif", ".mp4", ".mov", ".webp"]
        Threads.@spawn try
            # @tr burl DB.import_media_pn(est, nothing, burl, Media.all_variants)
            @tr burl DB.import_media(est, nothing, burl, Media.all_variants)
            # @tr burl DB.import_media(est, nothing, burl, Media.all_variants, media_variants_fn=Main.Media.media_variants_2)
        catch _
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        end
    end

    try Main.Tracing.log_trace(@__MODULE__, funcname, "done", nothing; table="tracekeep", t=tbefore, duration=time()-tstart, extra=(; pubkey, burl, size=length(data)))
    catch _ Utils.print_exceptions() end

    nothing
end

function import_upload_2(est::DB.CacheStorage, pubkey::Nostr.PubKeyId, data::Vector{UInt8}; strip_metadata=true)
    funcname = "import_upload_2"

    qalog = pubkey == Main.test_pubkeys[:qa]
    qalog = false

    tbefore, tstart = Dates.now(), time()
    qalog && @show tbefore

    @tr pubkey sha256_before = SHA.sha256(data)

    qalog && @show (:after_sha256, Dates.now()-tbefore)

    @tr mimetype = Media.parse_mimetype(data)

    if !(mimetype in [
                      "image/jpeg",
                      "image/png",
                      "image/gif",
                      "image/webp",
                      "video/mp4",
                      "video/x-m4v",
                      "video/mov",
                      "video/webp",
                      "video/webm",
                      "video/quicktime",
                      "video/x-matroska",
                     ])
        strip_metadata = false
    end

    # if pubkey == Main.test_pubkeys[:qa]
    #     strip_metadata = false
    # end

    if strip_metadata
        @tr pubkey @elapsed (data = Media.strip_metadata(data))
    end

    qalog && @show (:after_strip, Dates.now()-tbefore)
    @tr pubkey sha256 = SHA.sha256(data)

    qalog && @show (:after_second_sha256, Dates.now()-tbefore)

    if strip_metadata
        Postgres.execute(:p0, "insert into media_metadata_stripping values (\$1, \$2, now(), \$3)", 
                         [sha256_before, sha256, JSON.json((; func="import_upload_2", pubkey=Nostr.hex(pubkey)))])
    end

    width, height, dur = 0, 0, 0
    if startswith(mimetype, "image/")
        @tr r = Media.parse_image_dimensions(data)
        !isnothing(r) && ((width, height, dur) = r)
    elseif startswith(mimetype, "video/")
        @tr r = Media.parse_video_dimensions(data)
        !isnothing(r) && ((width, height, dur) = r)
    end

    qalog && @show (:after_parse, Dates.now()-tbefore)

    key = (; type="member_upload", pubkey, sha256=bytes2hex(sha256))

    new_import = Ref(false)
    (mi, lnk, murl) = @tr pubkey Media.media_import(function (_)
                                             new_import[] = true
                                             data
                                         end, key; media_path=:uploadfast, pubkey, use_external=false)
    @tr key mi lnk murl new_import[] ()
    # @show (pubkey ,mi, lnk, murl)

    qalog && @show (:after_import_fast, Dates.now()-tbefore)

    Threads.@spawn Media.media_import(_->data, key; media_path=:upload, pubkey)

    @tr key murl if new_import[]
        if isempty(DB.exec(Main.InternalServices.memberships[], "select 1 from memberships where pubkey = ?1 limit 1", (pubkey,)))
            tier = isempty(DB.exec(Main.InternalServices.verified_users[], "select 1 from verified_users where pubkey = ?1 limit 1", (pubkey,))) ? "free" : "premium"
            DB.exec(Main.InternalServices.memberships[], "insert into memberships values (?1, ?2, ?3, ?4, ?5)", (pubkey, tier, missing, missing, 0))
        end
        tier, used_storage = DB.exec(Main.InternalServices.memberships[], "select tier, used_storage from memberships where pubkey = ?1", (pubkey,))[1]
        max_storage, = DB.exec(Main.InternalServices.membership_tiers[], "select max_storage from membership_tiers where tier = ?1", (tier,))[1]

        used_storage += length(data)
        # if used_storage > max_storage
        #     @show (:insufficient_storage, pubkey)
        #     error("insufficient storage available")
        #     rm(mi.path)
        # end

        DB.exec(Main.InternalServices.memberships[], "update memberships set used_storage = ?2 where pubkey = ?1",
                (pubkey, used_storage))

        #try
        #    _, ext = splitext(lnk)
        #    path = "/uploads/$(mi.subdir)/$(mi.h)$(ext)"
        #    DB.ext_media_import(est, nothing, nothing, path, data)
        #catch ex
        #    #println(ex)
        #    Utils.print_exceptions()
        #end
    end

    if isempty(DB.exe(est.media_uploads, DB.@sql("select 1 from media_uploads where pubkey = ?1 and key = ?2 limit 1"), pubkey, JSON.json(key)))
        DB.exe(est.media_uploads, DB.@sql("insert into media_uploads values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)"), 
               pubkey,
               key.type, JSON.json(key),
               trunc(Int, time()),
               string(URIs.parse_uri(murl).path),
               stat(mi.path).size, 
               mimetype,
               "", 1.0, 
               width, height, dur,
               sha256)
    end

    qalog && @show (:after_db, Dates.now()-tbefore)

    surl = Main.InternalServices.url_shortening(murl)
    try
        if pubkey in [Main.test_pubkeys[:pedja], Main.test_pubkeys[:qa], Main.test_pubkeys[:moysie]]
            ext = splitext(surl)[2]
            surl = "https://blossom.primal.net/$(bytes2hex(sha256))$(ext)"
        end
    catch _ Utils.print_exceptions() end

    qalog && @show (:after_url_shortening, Dates.now()-tbefore)

    @tr key murl surl ()

    # try push!(Main.stuff, (:import_upload_2, (; pubkey, surl, sha256, mimetype, data)))
    # catch _ Utils.print_exceptions() end
    
    errormonitor(Threads.@spawn @tr surl length(data) pubkey mimetype begin
                     try
                         startswith(mimetype, "video/") && @tr surl bytes2hex(sha256) DB.import_video(surl, data, sha256) # TODO: remove
                         if startswith(mimetype, "image/") || startswith(mimetype, "video/")
                             @tr surl bytes2hex(sha256) pubkey ext_after_import_upload(surl, data; pubkey, origin="upload")
                         end
                         # @show :ext_after_import_upload_after_ok
                     catch _ 
                         PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                     end
                 end)

    try
        shas = [sha256_before, sha256]
        for (sha256_after,) in Postgres.execute(:p0, "select sha256_after from media_metadata_stripping where sha256_before = \$1 limit 1", [sha256_before])[2]
            push!(shas, sha256_after)
            append!(shas, map(first, Postgres.execute(:p0, "select sha256_before from media_metadata_stripping where sha256_after = \$1 limit 1", [sha256_after])[2]))
        end
        shas = collect(Set(shas))
        @tr key murl surl pubkey sha256 collect(map(bytes2hex, shas))
        # push!(Main.stuff, (:upload_check_similarity, (; pubkey, shas, mimetype, data, surl)))
        if (@tr key murl surl pubkey sha256 upload_check_similarity_by_sha256(pubkey, shas, surl)) == :blocked
            push!(Main.stuff, (:upload_check_similarity_by_sha256_blocked, Dates.now(), (; pubkey, shas, mimetype, data, surl)))
            Main.InternalServices.bunny_purge()
        end
        errormonitor(Threads.@spawn @tr surl length(data) pubkey mimetype begin
            if (@tr key murl surl pubkey sha256 upload_check_similarity_by_embedding(pubkey, shas, mimetype, data, surl)) == :blocked
                push!(Main.stuff, (:upload_check_similarity_by_embedding_blocked, Dates.now(), (; pubkey, shas, mimetype, data, surl)))
                Main.InternalServices.bunny_purge()
            end
        end)
        # @show :check_after_ok
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        true
    end

    qalog && @show (:after_similarity_checks, Dates.now()-tbefore)

    if length(data) < 10*1024^2 && splitext(surl)[2] in [".jpg", ".png", ".gif", ".mp4", ".mov", ".webp"]
        Threads.@spawn try
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

    qalog && @show (:after_log_trace, Dates.now()-tbefore)

    @tr [
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
    funcname = "upload_chunk"

    # push!(Main.stuff, (:upload_chunk, event_from_user))

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    @tr e.pubkey (is_upload_blocked(e.pubkey) && error("upload blocked"))

    c = JSON.parse(e.content)
    @tr e.pubkey ulid = check_upload_id(c["upload_id"])
    @tr e.pubkey c["file_length"] c["offset"]

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
    funcname = "upload_complete"

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    @tr e.pubkey (is_upload_blocked(e.pubkey) && error("upload blocked"))

    @tr e.pubkey c = JSON.parse(e.content)
    ulid = check_upload_id(c["upload_id"])

    @tr e.pubkey fn = "$(MEDIA_UPLOAD_PATH[])/$(Nostr.hex(e.pubkey))_$(ulid)"
    c["file_length"] == stat(fn).size || error("incorrect upload size")

    data = read(fn)
    c["sha256"] == bytes2hex(SHA.sha256(data)) || error("incorrect sha256")

    @tr res = import_upload(est, e.pubkey, data)
    rm(fn)

    lock(active_uploads) do active_uploads
        delete!(active_uploads, ulid)
        upload_stats.completed[] += 1
        PushGatewayExporter.set!("cache_upload_stats_completed", upload_stats.completed[])
    end

    res
end

function upload_cancel(est::DB.CacheStorage; event_from_user::Dict)
    funcname = "upload_cancel"

    # push!(Main.stuff, (:upload_cancel, (; event_from_user)))

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    @tr e.pubkey (is_upload_blocked(e.pubkey) && error("upload blocked"))

    @tr e.pubkey c = JSON.parse(e.content)
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

function upload_check_similarity_by_sha256(pubkey::Nostr.PubKeyId, sha256s::Vector, surl::String; dry_run=false)
    try
        for (matching_sha256, matching_media_block_id, matching_reason) in Postgres.execute(:p0, "
                   select mu.sha256, mb.id, mb.d->>'reason'
                   from 
                       media_uploads mu,
                       media_block mb
                   where 
                       mu.sha256 = any (\$1::bytea[]) and 
                       mu.media_block_id = mb.id and mb.d->>'reason' like 'csam%'
                   limit 1", 
                   ['{'*join(["\\\\x"*bytes2hex(sha256) for sha256 in sha256s], ',')*'}'])[2]
            kwa = (; reason = "$matching_reason; blocked by matching sha256",
                   block_all_uploads=true,
                   extra = (; 
                            matching_sha256=bytes2hex(matching_sha256), 
                            matching_media_block_id=string(matching_media_block_id)))
            @show kwa
            if dry_run
                display(kwa)
            else
                @tr surl pubkey Main.InternalServices.purge_media_(pubkey, surl; kwa...)
            end
            return :blocked
        end
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
    end
end

function upload_check_similarity_by_embedding(pubkey::Nostr.PubKeyId, sha256s::Vector, mimetype::String, data::Vector{UInt8}, surl::String; dry_run=false)
    try
        emb = nothing
        if startswith(mimetype, "image/")
            model = "google/vit-base-patch16-384"
            emb = Media.image_features(data; model)["output"]
        elseif startswith(mimetype, "video/")
            model = "google/vivit-b-16x2-kinetics400"
            emb = Media.video_features(data; model)["output"]
        end
        if !isnothing(emb)
            for (matching_sha256, matching_media_block_id, matching_reason, cosinedist) in Postgres.execute(:p0, "
                     select mu.sha256, mb.id, mb.d->>'reason', me.emb <=> \$2
                     from media_embedding me, media_uploads mu, media_block mb
                     where 
                         me.model = \$1 and me.emb <=> \$2 <= 0.02 and
                         mu.sha256 = me.sha256 and 
                         mu.media_block_id = mb.id and mb.d->>'reason' like 'csam%'
                     order by me.emb <=> \$2
                     limit 1", [model, JSON.json(emb)])[2]
                kwa = (; reason = "$matching_reason; blocked by matching embedding",
                       block_all_uploads=true,
                       extra = (; 
                                matching_sha256=bytes2hex(matching_sha256), 
                                matching_media_block_id=string(matching_media_block_id),
                                cosinedist))
                @show kwa
                if dry_run
                    display(kwa)
                else
                    @tr surl pubkey Main.InternalServices.purge_media_(pubkey, surl; kwa...)
                end
                return :blocked
            end
        end
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
    end
end

function ext_after_import_upload(surl::String, data::Vector{UInt8}; pubkey=nothing, eid=nothing, origin=nothing) end

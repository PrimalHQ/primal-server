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
            @tr burl DB.import_media_pn(est, nothing, burl, Media.all_variants)
            # @tr burl DB.import_media(est, nothing, burl, Media.all_variants)
            # @tr burl DB.import_media(est, nothing, burl, Media.all_variants, media_variants_fn=Main.Media.media_variants_2)
        catch _
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        end
    end

    try Main.Tracing.log_trace(@__MODULE__, funcname, "done", nothing; table="tracekeep", t=tbefore, duration=time()-tstart, extra=(; pubkey, burl, size=length(data)))
    catch _ Utils.print_exceptions() end

    nothing
end

function upload_check_similarity_by_sha256(pubkey::Nostr.PubKeyId, sha256s::Vector, surl::String; dry_run=false)
    try
        for (matching_sha256, matching_media_block_id, matching_reason) in Postgres.execute(:p0, "
                    select mumb.sha256, mumb.id, mumb.reason
                    from
                        media_uploads_media_block_csam mumb
                    where
                        mumb.sha256 = any (\$1::bytea[])
                    limit 1
                    ",
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
                    select mumb.sha256, mumb.id, mumb.reason, me.emb <=> \$2
                    from media_embedding me, media_uploads_media_block_csam mumb
                    where 
                        me.model = \$1 and me.emb <=> \$2 <= 0.02 and
                        mumb.sha256 = me.sha256
                    order by me.emb <=> \$2
                    limit 1
                    ", [model, JSON.json(emb)])[2]
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

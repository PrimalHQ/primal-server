#module DB

import URIs
import HTTP

using ..ProcessingGraph: @procnode, @pn, @pnl, @pnd

import_media_lock = ReentrantLock()

function low_trust_user(est::CacheStorage, pubkey::Nostr.PubKeyId)
    !isempty(Postgres.execute(:p0, "select 1 from verified_users where pubkey = \$1 limit 1", [pubkey])[2]) && return false
    !isempty(Postgres.execute(:p0, "select 1 from pubkey_trustrank where pubkey = \$1 and log10(rank) > -6 limit 1", [pubkey])[2]) && return false
    !isempty(Postgres.execute(:p0, "select 1 from pn_time_for_pubkeys where pubkey = \$1 and duration > 1800 limit 1", [pubkey])[2]) && return true
    false
end

@procnode function import_media_pn(
        est::CacheStorage, eid::Union{Nostr.EventId, Nothing}, url::String, variant_specs::Vector;
        no_media_analysis=false,
    )
    E(; (isnothing(eid) ? [] : [:eid=>Nostr.hex(eid)])..., url)
    
    isnothing(eid) || low_trust_user(est, est.events[eid].pubkey) && return :low_trust_user

    vr = Main.Media.media_variants_pn(est, url; variant_specs).r
    isnothing(vr) && return

    isnothing(eid) || lock(import_media_lock) do
        extralog((; op="insert", table="event_media", eid, url))
        Postgres.execute(:p0, "insert into event_media values (\$1, \$2, nextval('event_media_rowid_seq')) on conflict do nothing", [eid, url])
    end

    orig_sha256 = nothing
    orig_data = nothing
    for ((size, anim), media_url) in vr
        if size == :original && anim == 1
            orig_data = try
                Main.Media.download(est, media_url)
            catch _
                Main.Media.download(est, url)
            end
            orig_sha256 = SHA.sha256(orig_data)
        end
    end
    isnothing(orig_sha256) || extralog((; orig_sha256=bytes2hex(orig_sha256)))

    for ((size, anim), media_url) in vr
        import_media_variant_pn(est, eid, url, size, anim, media_url, orig_sha256, orig_data)
    end

    if !isnothing(orig_sha256) && !no_media_analysis && 1==1
        try
            Main.MediaAnalysis.ext_after_import_upload_2(url, orig_data; 
                                                         pubkey=try est.events[eid].pubkey catch _ nothing end,
                                                         eid, origin="nostr")
        catch ex println("import_media_pn: $ex") end
    end
end

@procnode function import_media_variant_pn(
        est::CacheStorage, eid::Union{Nostr.EventId, Nothing}, url::String, 
        size::Symbol, anim::Bool, media_url::String, 
        orig_sha256::Union{Nothing, Vector{UInt8}}, orig_data::Union{Nothing, Vector{UInt8}};
    )
    v = (; eid, url, size, anim, media_url)
    E(; v...)

    dldur = @elapsed (data = Main.Media.download(est, media_url))
    mimetype = try
        Main.Media.parse_mimetype(data)
    catch _
        "application/octet-stream"
    end
    ftype = string(split(mimetype, '/')[1])
    dims = if ftype == "image"
        Main.Media.parse_image_dimensions(data)
    elseif ftype == "video"
        Main.Media.parse_video_dimensions(data)
    else
        nothing
    end
    extralog((; v, dldur, dlsize=length(data), mimetype, ftype, dims))
    if !isnothing(dims)
        width, height, duration = dims

        category, category_prob = "", 1.0
        if ftype == "image"
            rotated = Main.Media.is_image_rotated(data)
            extralog((; v, rotated))
            if rotated
                width, height = height, width
            end
        elseif ftype == "video"
            if !isnothing(local d = Main.Media.extract_video_thumbnail(data))
                (_, _, murl) = Main.Media.media_import((_)->d, (; url, type=:video_thumbnail))
                thumbnail_media_url = murl
                extralog((; v, thumbnail_media_url))
                extralog((; op="insert", table="video_thumbnails", url, thumbnail_media_url))
                Postgres.execute(:p0, "insert into video_thumbnails values (\$1, \$2, nextval('video_thumbnails_rowid_seq')) on conflict do nothing",
                                 [url, thumbnail_media_url])
                import_media_pn(est, eid, thumbnail_media_url, Main.Media.all_variants)
            end
            try
                # @show eid
                # if est.events[eid].pubkey == Main.test_pubkeys[:qa]
                #     @pnd import_media_video_variants_pn(est; mimetype, url, media_url, width=dims[1], height=dims[2], duration=dims[3], orig_sha256)
                # end
            catch _ Utils.print_exceptions() end
        end

        extralog((; op="insert", table="media", url, media_url, size, anim, dldur, width, height, mimetype, duration, (isnothing(orig_sha256) ? [] : [:orig_sha256=>bytes2hex(orig_sha256)])...))
        Postgres.execute(:p0, "insert into media_1_16fa35f2dc values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, nextval('media_rowid_seq'), \$13) on conflict do nothing",
                         [url, media_url, size, anim, trunc(Int, time()), dldur, width, height, mimetype, category, category_prob, duration, orig_sha256])
    
        # try
        #     @time "update media" @show Postgres.execute(:p0, "update media_1_16fa35f2dc set orig_sha256 = \$4 where url = \$1 and media_url = \$2 and size = \$3 and animated = \$4 where orig_sha256 is null",
        #                                                 [url, size, anim, orig_sha256])
        # catch _
        #     Utils.print_exceptions()
        # end
    end
end

@procnode function import_media_fast_pn(est::CacheStorage, eid::Union{Nostr.EventId, Nothing}, url::String)
    E(; (isnothing(eid) ? [] : [:eid=>Nostr.hex(eid)])..., url)
    
    isnothing(eid) || low_trust_user(est, est.events[eid].pubkey) && return :low_trust_user

    cleaned_url = Main.Media.clean_url(url)
    dldur = @elapsed (data_start = Main.Media.download(est, cleaned_url; range=(1, 5*1024*1024)))
    extralog((; url, cleaned_url, dldur, dlsize=length(data_start)))

    ext = splitext(cleaned_url)[2]

    mimetype = Main.Media.parse_mimetype(data_start)

    dims =
    if startswith(mimetype, "image/")
        Main.Media.parse_image_dimensions(data_start)
    elseif startswith(mimetype, "video/")
        Main.Media.parse_video_dimensions(data_start)
    else
        nothing
    end
    isnothing(dims) && return :no_dims

    extralog((; url, ext, mimetype, dims))

    (startswith(mimetype, "image/") || startswith(mimetype, "video/")) || return

    size, animated = :original, 0
    width, height, duration = dims

    if !isnothing(eid)
        extralog((; op="insert", table="event_media", eid, url))
        Postgres.execute(:p0, "insert into event_media values (\$1, \$2, nextval('event_media_rowid_seq')) on conflict do nothing", [eid, url])
    end

    # media_url = ""
    media_url = url
    category, category_prob = "", 1.0
    extralog((; op="insert", table="media", url, media_url, size, animated, dldur, width, height, mimetype, duration))
    Postgres.execute(:p0, "insert into media_1_16fa35f2dc values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, nextval('media_rowid_seq'), \$13) on conflict do nothing",
                     [url, media_url, size, animated, trunc(Int, time()), dldur, width, height, mimetype, category, category_prob, duration, nothing])

    nothing
end

@procnode function import_media_video_variants_pn(est::CacheStorage; mimetype, url, media_url, width, height, duration, orig_sha256=nothing)
    E(; url)
    
    if isnothing(orig_sha256)
        orig_data = SHA.sha256(Main.Media.download(est, media_url))
    end

    r = Main.Media.media_video_variants_pn(url, media_url, (width, height), duration).r
    isnothing(r) && return :no_variants

    for ((size, animated), (murl, dims)) in r
        category, category_prob = "", 1.0
        dldur = 0.0
        width, height = dims
        extralog(@show (; op="insert", table="media", url, murl, size, animated, dldur, width, height, mimetype, duration))
        Postgres.execute(:p0, "insert into media_1_16fa35f2dc values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, nextval('media_rowid_seq'), \$13) on conflict do nothing",
                         [url, murl, size, animated, trunc(Int, time()), dldur, width, height, mimetype, category, category_prob, duration, orig_sha256])
    end

    (length(r), :variants)
end

import_preview_lock = ReentrantLock()

@procnode function import_preview_pn(est::CacheStorage, eid::Nostr.EventId, url::String)
    E(; (isnothing(eid) ? [] : [:eid=>Nostr.hex(eid)])..., url)

    low_trust_user(est, est.events[eid].pubkey) && return :low_trust_user

    dldur = @elapsed (r = begin
                          r = Main.Media.fetch_resource_metadata(url)
                          !isempty(r.image) && try import_media_pn(est, eid, r.image, Main.Media.all_variants) catch _ end
                          r
                      end)

    lock(import_preview_lock) do
        extralog((; op="insert", table="preview", url, dldur, r...))
        if isempty(exe(est.preview, @sql("select 1 from preview where url = ?1 limit 1"), url))
            category = ""
            exe(est.preview, @sql("insert into preview values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, nextval('preview_rowid_seq'))"),
                url, trunc(Int, time()), dldur, r.mimetype, category, 1.0,
                r.title, r.description, r.image, r.icon_url)
        end
        extralog((; op="insert", table="event_preview", eid, url))
        if isempty(exe(est.event_preview, @sql("select 1 from event_preview where event_id = ?1 and url = ?2 limit 1"), eid, url))
            exe(est.event_preview, @sql("insert into event_preview values (?1, ?2, nextval('event_preview_rowid_seq'))"),
                eid, url)
        end
    end
end

function import_video_frames(frames::Vector, video_sha256::Vector{UInt8}; added_at=Utils.current_time())
    funcname = "import_video_frames"
    for (frame_idx, (frame_pos, frame)) in enumerate(frames)
        @tr video_sha256 (_, _, murl) = Main.Media.media_import((_)->frame, (; type=:video_frame, video_sha256=bytes2hex(video_sha256), frame_idx, frame_pos))
        # @show (video_sha256, murl)
        Postgres.execute(:p0, "insert into video_frames values (\$1, \$2, \$3, \$4, \$5) on conflict do nothing",
                         [video_sha256, frame_idx, frame_pos, SHA.sha256(frame), added_at])
    end
end

function import_video(video_url::String, video_data::Vector{UInt8}, video_sha256::Vector{UInt8})
    funcname = "import_video"
    added_at = Utils.current_time()
    Postgres.execute(:p0, "insert into video_urls values (\$1, \$2, \$3) on conflict do nothing",
                     [video_url, video_sha256, added_at])
    if @tr isempty(Postgres.execute(:p0, "select 1 from video_frames where video_sha256 = \$1 limit 1", [video_sha256])[2])
        frames = @tr video_sha256 Main.Media.extract_video_frames(video_data)
        # @show length(frames)
        import_video_frames(frames, video_sha256; added_at)
    end
end


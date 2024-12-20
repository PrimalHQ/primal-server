#module DB

MEDIA_SERVER = Ref("https://primal.b-cdn.net")

import URIs
import HTTP

# function media_url(url, size, anim)
#     "$(MEDIA_SERVER[])/media-cache?s=$(size)&a=$(anim)&u=$(URIs.escapeuri(url))"
# end

import_media_lock = ReentrantLock()
function import_media(est::CacheStorage, eid::Union{Nostr.EventId, Nothing}, url::String, variant_specs::Vector)
    funcname = "import_media"
    # @show (eid, url)
    try
        catch_exception(est, :import_media, eid, url) do
            @tr "begin" eid url variant_specs ()
            dldur = @elapsed (r = @tr url Main.Media.media_variants(est, url; variant_specs, sync=true))
            @tr url dldur r ()
            isnothing(r) && return
            !isnothing(eid) && lock(import_media_lock) do
                if isempty(exe(est.event_media, @sql("select 1 from event_media where event_id = ?1 and url = ?2"), eid, url))
                    @tr url exe(est.event_media, @sql("insert into event_media values (?1, ?2, nextval('event_media_rowid_seq'))"),
                                eid, url)
                end
            end

            @tc "variant" for ((size, anim), media_url) in r
                @tr url size anim media_url ()
                # lock(import_media_lock) do
                    if isempty(exe(est.media, @sql("select 1 from media where url = ?1 and size = ?2 and animated = ?3 limit 1"), url, size, anim))
                        dldur2 = @elapsed (data = Main.Media.download(est, media_url))
                        @tr url media_url dldur2 length(data)
                        @tr mimetype = try
                            Main.Media.parse_mimetype(data)
                        catch _
                            "application/octet-stream"
                        end
                        @tr ftype = string(split(mimetype, '/')[1])
                        @tr m = if ftype == "image"
                            Main.Media.parse_image_dimensions(data)
                        elseif ftype == "video"
                            Main.Media.parse_video_dimensions(data)
                        else
                            nothing
                        end
                        @tr url mimetype ftype m ()
                        if !isnothing(m)
                            @tr width, height, duration = m

                            category, category_prob = "", 1.0
                            try
                                if ftype == "image"
                                    # category, category_prob = Main.Media.image_category(fn)
                                    # size == :original && anim && ext_media_import(est, eid, url, string(URIs.parse_uri(media_url).path), orig_data)
                                    if @tr Main.Media.is_image_rotated(data)
                                        width, height = height, width
                                    end
                                elseif ftype == "video"
                                    if !isnothing(local d = try read(pipeline(`ffmpeg -v error -i - -vframes 1 -an -ss 0 -c:v png -f image2pipe -`; stdin=IOBuffer(data), stdout=`convert - -`)) catch _ end)
                                        (mi, lnk, murl) = Main.Media.media_import((_)->d, (; url, type=:video_thumbnail))
                                        @tr thumbnail_media_url = murl
                                        # @tr thumb_fn = abspath(Main.Media.MEDIA_PATH[] * "/.." * URIs.parse_uri(thumbnail_media_url).path)
                                        if isempty(exe(est.dyn[:video_thumbnails], @sql("select 1 from video_thumbnails where video_url = ?1 limit 1"), url))
                                            @tr exe(est.dyn[:video_thumbnails], @sql("insert into video_thumbnails values (?1, ?2, nextval('video_thumbnails_rowid_seq'))"),
                                                    url, thumbnail_media_url)
                                        end
                                        Main.Media.media_queue(@task @ti @tr eid thumbnail_media_url import_media(est, eid, thumbnail_media_url, Main.Media.all_variants))
                                        # category, category_prob = Main.Media.image_category(thumb_fn)
                                        # size == :original && anim && ext_media_import(est, eid, url, string(URIs.parse_uri(media_url).path), read(thumb_fn))
                                    end
                                end
                            catch _
                                Utils.print_exceptions()
                            end

                            lock(import_media_lock) do
                                if isempty(exe(est.media, @sql("select 1 from media where url = ?1 and size = ?2 and animated = ?3 limit 1"), url, size, anim))
                                    @tr eid url exe(est.media, @sql("insert into media values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, nextval('media_rowid_seq')) on conflict do nothing"),
                                                    url, media_url, size, anim, trunc(Int, time()), dldur2, width, height, mimetype, category, category_prob, duration)
                                    # @show url
                                end
                            end
                        end
                    end
                    # @async begin HTTP.get(Main.Media.cdn_url(url, size, anim); readtimeout=15, connect_timeout=5).body; nothing; end
                # end
            end
            @tr "done" eid url ()
        end
    finally
        Main.Media.update_media_queue_executor_taskcnt(-1)
    end
end

import_preview_lock = ReentrantLock()
function import_preview(est::CacheStorage, eid::Nostr.EventId, url::String)
    funcname = "import_preview"
    # @show (eid, url)
    try
        catch_exception(est, :import_preview, eid, url) do
            @tr "begin" eid url ()
            if isempty(exe(est.preview, @sql("select 1 from preview where url = ?1 limit 1"), url))
                dldur = @elapsed (r = begin
                                      @tr "fetch_resource_metadata" eid url r = Main.Media.fetch_resource_metadata(url)
                                      if !isempty(r.image)
                                          try 
                                              @tr eid url r.image import_media(est, eid, r.image, Main.Media.all_variants) 
                                              @async begin HTTP.get(Main.Media.cdn_url(r.icon_url, :o, true); readtimeout=15, connect_timeout=5).body; nothing; end
                                          catch _ end
                                      end
                                      # if !isempty(r.icon_url)
                                      #     try
                                      #         import_media(est, eid, r.icon_url, [(:original, true)]) 
                                      #         @async begin HTTP.get(Main.Media.cdn_url(r.icon_url, :o, true); readtimeout=15, connect_timeout=5).body; nothing; end
                                      #     catch _ end
                                      # end
                                      r
                                  end)
                @tr "download_metadata" eid url dldur ()
                lock(import_preview_lock) do
                    if isempty(exe(est.preview, @sql("select 1 from preview where url = ?1 limit 1"), url))
                        category = ""
                        @tr eid url exe(est.preview, @sql("insert into preview values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, nextval('preview_rowid_seq'))"),
                                        url, trunc(Int, time()), dldur, r.mimetype, category, 1.0,
                                        r.title, r.description, r.image, r.icon_url)
                    end
                end
            end
            lock(import_preview_lock) do
                if !isempty(exe(est.preview, @sql("select 1 from preview where url = ?1 limit 1"), url))
                    if isempty(exe(est.event_preview, @sql("select 1 from event_preview where event_id = ?1 and url = ?2 limit 1"), eid, url))
                        @tr eid url exe(est.event_preview, @sql("insert into event_preview values (?1, ?2, nextval('event_preview_rowid_seq'))"),
                                        eid, url)
                    end
                end
            end
            @tr "done" eid url ()
        end
    finally
        Main.Media.update_media_queue_executor_taskcnt(-1)
    end
end


module Media

import JSON
import SHA
import URIs
import Dates
using DataStructures: CircularBuffer
import HTTP
import EzXML
import Gumbo, Cascadia
import Base64
import Random

import ..Utils
using ..Utils: ThreadSafe
import ..DB
import ..Postgres
using ..Tracing: @ti, @tc, @td, @tr
using ..ProcessingGraph: @procnode, @pn, @pnl, @pnd

PRINT_EXCEPTIONS = Ref(false)

MEDIA_PATH = Ref("/mnt/ppr1/var/www/cdn/cache")
MEDIA_PATH_2 = Ref("/mnt/ppr1/var/www/cdn/cache2")
MEDIA_PATHS = Dict{Symbol, Vector}()
MEDIA_PATHS[:cache] = ["/mnt/ppr1/var/www/cdn/cache"]
MEDIA_PATHS_2 = Dict{Symbol, Vector}()
MEDIA_PATHS_2[:cache] = ["/mnt/ppr1/var/www/cdn/cache2"]
MEDIA_URL_ROOT = Ref("https://media.primal.net/cache")
# MEDIA_TMP_DIR  = Ref("/tmp/primalmedia")
MEDIA_TMP_DIR = Ref("/mnt/ppr1/var/www/cdn/cache/tmp")
MEDIA_PROXY = Ref{Any}(nothing)
MEDIA_METADATA_PROXY = Ref{Any}(nothing)
MEDIA_SSH_COMMAND = Ref([])

max_task_duration = Ref(0.0) |> ThreadSafe
tasks_per_period = Ref(0) |> ThreadSafe

max_download_duration = Ref(0.0) |> ThreadSafe
downloads_per_period = Ref(0) |> ThreadSafe

media_resolutions = Dict([
    :small=>(200, 200),
    :medium=>(400, 400),
    :large=>(1000, 1000),
])
##
mimetype_ext = Dict([
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "image/svg+xml" => ".svg",
    "video/mp4" => ".mp4",
    "video/x-m4v" => ".mp4",
    "video/mov" => ".mov",
    "video/webp" => ".webp",
    "video/webm" => ".webm",
    "video/quicktime"  => ".mov",
    "video/x-matroska" => ".mkv",
    "video/3gpp" => ".3gp",
    "image/vnd.microsoft.icon" => ".ico",
    "text/plain" => ".txt",
    "application/json" => ".json",

    "text/html" => ".html",
    "text/javascript" => ".js",
    "application/wasm" => ".wasm",
])
##
# downloader_headers = ["User-Agent"=>"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36"]
downloader_headers = ["User-Agent"=>"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/81.0.4044.113 Safari/537.36"]

function clean_url(url::String)
    u = URIs.parse_uri(url)
    string(URIs.URI(; [p=>getproperty(u, p) for p in propertynames(u) if !(p in [:fragment, :uri])]...))
end

DOWNLOAD_PROXIES = String[]

function download(est::DB.CacheStorage, url::String; proxy=nothing, timeout=30, range=nothing)::Vector{UInt8}
    funcname = "download"

    if occursin(".primal.net", url) || occursin(".primalnode.net", url)
        timeout = 180
    end

    headers =
    if isnothing(range)
        downloader_headers
    else
        [downloader_headers; "Range"=>"bytes=$(range[1]-1)-$(range[2]-1)"]
    end

    DB.incr(est, :media_downloads)
    exc = nothing
    proxies = isnothing(proxy) ? Random.shuffle(DOWNLOAD_PROXIES) : [proxy]
    for proxy in proxies
        try
            @tr url timeout proxy ()
            res = HTTP.get(url; readtimeout=timeout, connect_timeout=timeout, headers, proxy, verbose=0, retry=false).body
            DB.incr(est, :media_downloaded_bytes; by=length(res))
            return res
        catch ex
            exc = ex
            # println("Media.download error: ", (length(proxies), proxy, typeof(ex), url))
            sleep(2)
        end
    end

    DB.incr(est, :media_download_errors)
    isnothing(exc) || throw(exc)

    nothing
end

Base.@kwdef struct MediaImport
    key
    media_path = MEDIA_PATH[]

    k = JSON.json(key)
    h = bytes2hex(SHA.sha256(k))
    subdir = "$(h[1:1])/$(h[2:3])/$(h[4:5])"
    dirpath = "$(media_path)/$(subdir)"
    path = "$(dirpath)/$(h)"
end

media_tasks = Dict() |> ThreadSafe # relpath(key) => Task

media_variants_lock = ReentrantLock()
media_variants_log = CircularBuffer(500)

all_variants = [(size, animated)
                for size in [:original, :small, :medium, :large]
                for animated in [true, false]]

# make_media_url(mi::MediaImport, ext::String) = "$(MEDIA_URL_ROOT[])/$(mi.subdir)/$(mi.h)$(ext)"

function media_variants(
        est::DB.CacheStorage, 
        url::String; 
        variant_specs::Vector=all_variants, 
        key=(;), 
        proxy=nothing,
        sync=false, 
        already_imported=false,
    )
    # sync || @show (sync, url)
    funcname = "media_variants"
    @tr "media_variants_lock" url variant_specs key proxy sync lock(sync ? ReentrantLock() : media_variants_lock) do
        variants = Dict{Tuple{Symbol, Bool}, String}() |> ThreadSafe

        k = (; key..., url, type=:original)
        mi = MediaImport(; key=k)

        if @tr url k mi.h already_imported (isempty(Postgres.execute(:p0, "select 1 from media_storage where h = \$1 limit 1", [mi.h])[2]) && !already_imported)
            if @tr url k :original !haskey(media_tasks, k)
                media_tasks[k] = 
                let k=k
                    tsk = @task task_wrapper(est, k, max_download_duration, downloads_per_period) do
                        @tr "import original and variants" url k proxy try
                            data = nothing
                            @tr url k @elapsed (data = download(est, (@tr url k clean_url(url)); proxy))
                            @tr url k length(data)
                            @tr url k media_import((_)->data, k)
                            @tr url k media_variants(est, url; variant_specs, key, proxy, sync)
                        finally
                            update_media_queue_executor_taskcnt(-1)
                            delete!(media_tasks, k)
                        end
                    end
                    if sync
                        update_media_queue_executor_taskcnt(+1)
                        schedule(tsk)
                        wait(tsk)
                        @goto cont
                    else
                        media_queue(tsk)
                    end
                end
            end
            return nothing
        end
        @label cont

        rs = Postgres.execute(:p0, "select media_url, ext from media_storage where h = \$1 limit 1", [mi.h])[2]
        (@tr url mi.h isempty(rs)) && return nothing
        orig_media_url, ext = rs[1]
        @tr url orig_media_url ext ()

        orig_data = nothing

        ext == ".bin" && return nothing

        # original_mi = mi

        variant_missing = false
        for (size, animated) in variant_specs
            if size == :original
                variants[(size, animated)] = orig_media_url
                continue
            end
            convopts = []
            filters = []
            if !animated
                append!(convopts, ["-frames:v", "1", "-update", "1"])
            end
            if size in [:small, :medium]
                w, h = media_resolutions[size]
                push!(filters, "scale=-1:'min($h,ih)'")
            elseif size in [:large]
                w, h = media_resolutions[size]
                push!(filters, "scale='min($w,iw)':-1")
            end
            #push!(filters, "colorchannelmixer=1:0:0:0:0:0:0:0:0:0:0:0")
            append!(convopts, ["-vf", isempty(MEDIA_SSH_COMMAND[]) ? join(filters, ',') : '"'*join(filters, ',')*'"'])
            k = (; key..., url, type=:resized, size, animated)
            mi = MediaImport(; key=k)
            rs = Postgres.execute(:p0, "select media_url from media_storage where h = \$1 limit 1", [mi.h])[2]
            if @tr url k mi.h already_imported :variant (isempty(rs) && !already_imported)
                if @tr k :variant !haskey(media_tasks, k)
                    if isnothing(orig_data)
                        @tr @elapsed (orig_data = download(est, orig_media_url; proxy))
                        @tr url orig_media_url length(orig_data)
                    end
                    media_tasks[k] = 
                    let k=k, mi=mi, convopts=convopts, size=size, animated=animated, variants=variants
                        tsk = @task task_wrapper(est, k, max_task_duration, tasks_per_period) do
                            @tr "media_task_processing_variant" url k try
                                mkpath(MEDIA_TMP_DIR[])
                                outfn = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext)"
                                logfile = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext).log"
                                cmd = Cmd([MEDIA_SSH_COMMAND[]..., "nice", "ionice", "-c3", "ffmpeg", "-y", "-i", "-", convopts..., outfn])
                                try
                                    @tr url k cmd run(pipeline(cmd, stdin=IOBuffer(orig_data), stdout=logfile, stderr=logfile))
                                catch _
                                    DB.incr(est, :media_processing_errors)
                                    rethrow()
                                end
                                # fn = stat(original_mi.path).size <= stat(outfn).size ? original_mi.path : outfn
                                fn = outfn #!!!
                                @tr url k fn (_, _, murl) = media_import((_)->read(fn), k)
                                variants[(size, animated)] = murl
                                try rm(outfn) catch _ end
                                try rm(logfile) catch _ end
                                nothing
                            finally
                                update_media_queue_executor_taskcnt(-1)
                                delete!(media_tasks, k)
                                nothing
                            end
                        end
                        if sync
                            update_media_queue_executor_taskcnt(+1)
                            schedule(tsk)
                            wait(tsk)
                            @goto cont2
                        else
                            media_queue(tsk)
                        end
                    end
                end
                variant_missing = true
            else
                if !isempty(rs)
                    variants[(size, animated)] = rs[1][1]
                end
            end
            @label cont2
        end
        variant_missing && return nothing

        variants.wrapped
    end
end

@procnode function media_variants_pn(
        est::DB.CacheStorage, 
        url::String; 
        variant_specs::Vector=all_variants, 
        key=(;),
        hnd=DEFAULT_HANDLERS,
    )
    E(; url)

    proxy = MEDIA_PROXY[]

    variants = Dict{Tuple{Symbol, Bool}, String}()

    k = (; key..., url, type=:original)
    mi = MediaImport(; key=k)

    cleaned_url = clean_url(url)
    extralog((; url, k, mi_h=mi.h, cleaned_url))

    if isempty(Postgres.execute(:p0, "select 1 from media_storage where h = \$1 limit 1", [mi.h])[2])
        dldur = @elapsed (data = hnd.download(est, cleaned_url))
        extralog((; url, cleaned_url, dldur, dlsize=length(data)))
        hnd.media_import((_)->data, k)
    end

    rs = Postgres.execute(:p0, "
                          select ms.media_url, ms.ext, ms.content_type 
                          from media_storage ms, media_storage_priority msp 
                          where ms.h = \$1 and ms.storage_provider = msp.storage_provider 
                          order by msp.priority limit 1", 
                          [mi.h])[2]
    orig_media_url, ext, mimetype = rs[1]
    extralog((; url, orig_media_url, ext))

    ext == ".bin" && return nothing

    dldur = @elapsed (orig_data = hnd.download(est, orig_media_url))
    extralog((; url, orig_media_url, dldur, dlsize=length(orig_data)))

    for (size, animated) in variant_specs
        v = (; url, size, animated)
        if size == :original || mimetype == "image/svg+xml"
            murl = orig_media_url
            variants[(size, animated)] = murl
            extralog((; v, murl))
        else
            convopts = []
            filters = []
            if !animated || (startswith(mimetype, "image/") && !startswith(mimetype, "image/gif"))
                append!(convopts, ["-frames:v", "1", "-update", "1"])
            end
            if size in [:small, :medium]
                w, h = media_resolutions[size]
                push!(filters, "scale=-1:'min($h,ih)'")
            elseif size in [:large]
                w, h = media_resolutions[size]
                push!(filters, "scale='min($w,iw)':-1")
            end
            #push!(filters, "colorchannelmixer=1:0:0:0:0:0:0:0:0:0:0:0")
            append!(convopts, ["-vf", isempty(MEDIA_SSH_COMMAND[]) ? join(filters, ',') : '"'*join(filters, ',')*'"'])
            k = (; key..., url, type=:resized, size, animated)
            mi = MediaImport(; key=k)
            rs = Postgres.execute(:p0, "
                                  select ms.media_url, ms.ext from media_storage ms, media_storage_priority msp 
                                  where ms.h = \$1 and ms.storage_provider = msp.storage_provider 
                                  order by msp.priority limit 1", 
                                  [mi.h])[2]
            if !isempty(rs)
                murl = rs[1][1]
                variants[(size, animated)] = murl
                extralog((; v, murl))
            else
                mkpath(MEDIA_TMP_DIR[])
                outfn = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext)"
                logfile = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext).log"
                cmd = Cmd([MEDIA_SSH_COMMAND[]..., "nice", "ionice", "-c3", "ffmpeg", "-y", "-i", "-", convopts..., outfn])
                try
                    hnd.run(pipeline(cmd, stdin=IOBuffer(orig_data), stdout=logfile, stderr=logfile))
                    extralog((; v, cmd=string(cmd), outfn, logfile, status=true))
                catch _
                    DB.incr(est, :media_processing_errors)
                    extralog((; v, cmd=string(cmd), outfn, logfile, status=false))
                    rethrow()
                end
                # fn = stat(original_mi.path).size <= stat(outfn).size ? original_mi.path : outfn
                fn = outfn #!!!
                (_, _, murl) = hnd.media_import((_)->read(fn), k)
                variants[(size, animated)] = murl
                extralog((; v, murl))
                try rm(outfn) catch _ end
                try rm(logfile) catch _ end
            end
        end
    end

    extralog((; url, variants))

    variants
end

#=
@procnode function media_variants_fast_pn(
        est::DB.CacheStorage, 
        url::String; 
        variant_specs::Vector=[(size, animated) for size in [:small, :medium, :large] for animated in [true, false]], 
        key=(;), 
    )
    E(; url)

    proxy = MEDIA_PROXY[]

    variants = Dict{Tuple{Symbol, Bool}, Tuple{String, Vector{UInt8}}}()

    k = (; key..., url, type=:original)
    mi = MediaImport(; key=k)

    cleaned_url = clean_url(url)
    extralog((; url, k, mi_h=mi.h, cleaned_url))

    dldur = @elapsed (data_start = download(est, cleaned_url; range=(1, 5*1024*1024)))
    @show dldur
    # dldur = @elapsed (data_start = download(est, cleaned_url))
    extralog((; url, cleaned_url, dldur, dlsize=length(data_start)))

    ext = splitext(cleaned_url)[2]
    mimetype = parse_mimetype(data_start)
    extralog((; url, ext, mimetype))

    ext == ".bin" && return nothing

    # for (size, animated) in variant_specs
    asyncmap(variant_specs) do (size, animated)
        v = (; url, size, animated)
        
        convopts = []
        filters = []
        if !animated || (startswith(mimetype, "image/") && !startswith(mimetype, "image/gif"))
            append!(convopts, ["-frames:v", "1", "-update", "1"])
        end
        if size in [:small, :medium]
            w, h = media_resolutions[size]
            push!(filters, "scale=-1:'min($h,ih)'")
        elseif size in [:large]
            w, h = media_resolutions[size]
            push!(filters, "scale='min($w,iw)':-1")
        end
        append!(convopts, ["-vf", isempty(MEDIA_SSH_COMMAND[]) ? join(filters, ',') : '"'*join(filters, ',')*'"'])
        k = (; key..., url, type=:resized, size, animated)
        mi = MediaImport(; key=k)

        mkpath(MEDIA_TMP_DIR[])
        outfn = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext)"
        logfile = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext).log"
        @show logfile
        cmd = Cmd([MEDIA_SSH_COMMAND[]..., "nice", "ionice", "-c3", "ffmpeg", "-y", "-i", "-", convopts..., outfn])
        try
            run(pipeline(cmd, stdin=IOBuffer(data_start), stdout=logfile, stderr=logfile))
            extralog((; v, cmd=string(cmd), outfn, logfile, status=true))
        catch _
            DB.incr(est, :media_processing_errors)
            extralog((; v, cmd=string(cmd), outfn, logfile, status=false))
            rethrow()
        end
        d = read(outfn)
        (_, _, murl) = media_import((_)->d, k)
        variants[(size, animated)] = (murl, d)
        extralog((; v, murl))
        try rm(outfn) catch _ end
        try rm(logfile) catch _ end
    end

    extralog((; url, variants=[k=>v[1] for (k, v) in variants]))

    variants
end
=#

@procnode function media_variant_fast_pn(
        est::DB.CacheStorage, 
        url::String; 
        key=(;), 
    )
    E(; url)

    proxy = MEDIA_PROXY[]

    k = (; key..., url, type=:original)
    mi = MediaImport(; key=k)

    cleaned_url = clean_url(url)
    extralog((; url, k, mi_h=mi.h, cleaned_url))

    dldur = @elapsed (data_start = download(est, cleaned_url; range=(1, 5*1024*1024)))
    @show dldur
    # dldur = @elapsed (data_start = download(est, cleaned_url))
    extralog((; url, cleaned_url, dldur, dlsize=length(data_start)))

    ext = splitext(cleaned_url)[2]

    mimetype = parse_mimetype(data_start)

    dims =
    if startswith(mimetype, "image/")
        parse_image_dimensions(data_start)
    elseif startswith(mimetype, "video/")
        parse_video_dimensions(data_start)
    else
        return nothing
    end

    extralog(@show (; url, ext, mimetype, dims))

    (startswith(mimetype, "image/") || startswith(mimetype, "video/")) || return

    size, animated = :large, 0

    v = (; url, size, animated)
    
    convopts = []
    filters = []

    append!(convopts, ["-frames:v", "1", "-update", "1"])

    w, h = media_resolutions[size]
    push!(filters, "scale='min($w,iw)':-1")

    append!(convopts, ["-vf", isempty(MEDIA_SSH_COMMAND[]) ? join(filters, ',') : '"'*join(filters, ',')*'"'])
    k = (; key..., url, type=:resized, size, animated)
    mi = MediaImport(; key=k)

    mkpath(MEDIA_TMP_DIR[])
    outfn = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext)"
    logfile = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext).log"
    @show logfile
    cmd = Cmd([MEDIA_SSH_COMMAND[]..., "nice", "ionice", "-c3", "ffmpeg", "-y", "-i", "-", convopts..., outfn])
    @show cmd
    try
        run(pipeline(cmd, stdin=IOBuffer(data_start), stdout=logfile, stderr=logfile))
        extralog((; v, cmd=string(cmd), outfn, logfile, status=true))
    catch _
        DB.incr(est, :media_processing_errors)
        extralog((; v, cmd=string(cmd), outfn, logfile, status=false))
        rethrow()
    end
    d = read(outfn)
    (_, _, murl) = media_import((_)->d, k)
    extralog((; v, murl))
    try rm(outfn) catch _ end
    try rm(logfile) catch _ end

    size, animated, murl, mimetype, dims, dldur, data_start
end

function media_import(fetchfunc::Union{Function,Nothing}, key; media_path::Symbol=:cache, pubkey=nothing, use_external=nothing)
    funcname = "media_import"

    if isnothing(pubkey) && key isa NamedTuple && haskey(key, :type) && key.type == "member_upload" && haskey(key, :pubkey)
        pubkey = key.pubkey
    end

    external =
    if !isnothing(pubkey)
        Main.App.use_external_storage(pubkey)
    else
        true
    end
    if !isnothing(use_external)
        external = use_external
    end

    @tr key external ()
    # @show (; external, key)

    rs = []
    excs = []
    failed = []
    for mp in MEDIA_PATHS[media_path]
        try
            if     mp[1] == :local && !external
                @tr key r = media_import_local(fetchfunc, key, mp[2:end]...)
                push!(rs, r)
            elseif mp[1] == :s3    # && external
                @tr key r = media_import_s3(fetchfunc, key, mp[2:end]...)
                push!(rs, r)
            end
        catch ex
            println("media_import for $media_path to $mp for key $key: ", typeof(ex))
            # PRINT_EXCEPTIONS[] && Utils.print_exceptions()
            push!(excs, ex)
            ex isa Base.IOError && push!(failed, mp)
        end
    end
    @tr key external rs ()
    # filter!(mp->!(mp in failed), MEDIA_PATHS[media_path])
    isempty(rs) ? throw(excs[1]) : rs[1]
end

function media_import_local(
        fetchfunc::Union{Function,Nothing}, key, host::String, media_path::String;
        hnd=(; Postgres.execute))
    funcname = "media_import_local"
    @tr key host media_path ()
    mi = MediaImport(; key, media_path)
    rs = hnd.execute(:p0, "select h, ext, media_url from media_storage where storage_provider = \$1 and h = \$2 limit 1",
                     [host, mi.h])[2]
    if @tr key mi.h isempty(rs)
        data = fetchfunc(key)
        sha256 = SHA.sha256(data)
        mkpath(mi.dirpath)
        rnd = bytes2hex(rand(UInt8, 12))
        open(mi.path*".key.tmp-$rnd", "w+") do f; write(f, mi.k); end
        mv(mi.path*".key.tmp-$rnd", mi.path*".key"; force=true)
        open(mi.path*".tmp-$rnd", "w+") do f; write(f, data); end
        mt = string(chomp(read(`file -b --mime-type $(mi.path*".tmp-$rnd")`, String)))
        ext = get(mimetype_ext, mt, ".bin")

        mv(mi.path*".tmp-$rnd", mi.path*ext; force=true)
        symlink("$(mi.h)$(ext)", "$(mi.path).tmp-$rnd")
        try 
            mv("$(mi.path).tmp-$rnd", mi.path; force=true)
        catch ex
            if ex isa ArgumentError
                try rm("$(mi.path).tmp-$rnd") catch _ end
            else
                rethrow()
            end
        end
        p = "$(splitpath(media_path)[end])/$(mi.subdir)/$(mi.h)"
        @tr key mi.h url = "https://media.primal.net/"*p*ext
        hnd.execute(:p0, "insert into media_storage values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9) on conflict do nothing",
                    [url, host, Utils.current_time(), mi.k, mi.h, ext, mt, length(data), sha256])
        lnk = readlink(mi.path)
    else
        lnk = "$(rs[1][1])$(rs[1][2])"
        url = rs[1][3]
    end
    @tr key lnk url ()
    @tr (mi, lnk, url)
end

function media_import_s3(fetchfunc::Union{Function,Nothing}, key, provider, dir)
    funcname = "media_import_s3"
    @tr key provider dir ()
    mi = MediaImport(; key, media_path="s3:"*dir)
    p = "$dir/$(mi.subdir)/$(mi.h)"
    rs = Postgres.execute(:p0, "select h, ext, media_url from media_storage where storage_provider = \$1 and h = \$2 limit 1",
                          [provider, mi.h])[2]
    if @tr key mi.h isempty(rs)
        data = fetchfunc(key)
        sha256 = SHA.sha256(data)
        mt = parse_mimetype(data)
        ext = get(mimetype_ext, mt, ".bin")
        s3_upload(provider, p*ext, data, mt)
        pd = Main.S3_CONFIGS[provider]
        domain = isnothing(pd.domain) ? pd.bucket*"."*URIs.parse_uri(pd.endpoint).host : pd.domain
        @tr key mi.h url = "https://$domain/"*p*ext
        # @show url
        Postgres.execute(:p0, "insert into media_storage values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9) on conflict do nothing",
                         [url, provider, Utils.current_time(), mi.k, mi.h, ext, mt, length(data), sha256])
        lnk = mi.h*ext
    else
        lnk = "$(rs[1][1])$(rs[1][2])"
        url = rs[1][3]
    end
    @tr key lnk url ()
    @tr (mi, lnk, url)
end

function media_variants_2(
        est::DB.CacheStorage, 
        url::String; 
        variant_specs::Vector=all_variants, 
        key=(;), 
        proxy=MEDIA_PROXY[], 
        sync=false, 
        already_imported=false,
    )
    funcname = "media_variants_2"
    @assert sync
    @tr url variant_specs key proxy begin
        variants = Dict{Tuple{Symbol, Bool}, String}() |> ThreadSafe

        k = (; key..., url, type=:original)
        mi = MediaImport(; key=k)

        if @tr url k mi.h already_imported (isempty(Postgres.execute(:p0, "select 1 from media_storage where h = \$1 limit 1", [mi.h])[2]) && !already_imported)
            @tr "import original and variants" url k proxy begin
                data = nothing
                @tr url k @elapsed (data = download(est, (@tr url k clean_url(url)); proxy))
                @tr url k length(data)
                @tr url k media_import_2((_)->data, k, SHA.sha256(data))
                @tr url k media_variants(est, url; variant_specs, key, proxy, sync)
            end
        end

        rs = Postgres.execute(:p0, "select media_url, ext from media_storage where h = \$1 limit 1", [mi.h])[2]
        @assert !isempty(rs)
        orig_media_url, ext = rs[1]
        @tr url orig_media_url ext mi.h ()

        orig_data = nothing

        ext == ".bin" && return nothing

        variant_missing = false
        for (size, animated) in variant_specs
            if size == :original
                variants[(size, animated)] = orig_media_url
                continue
            end
            convopts = []
            filters = []
            if !animated
                append!(convopts, ["-frames:v", "1", "-update", "1"])
            end
            if size in [:small, :medium]
                w, h = media_resolutions[size]
                push!(filters, "scale=-1:'min($h,ih)'")
            elseif size in [:large]
                w, h = media_resolutions[size]
                push!(filters, "scale='min($w,iw)':-1")
            end
            #push!(filters, "colorchannelmixer=1:0:0:0:0:0:0:0:0:0:0:0")
            append!(convopts, ["-vf", isempty(MEDIA_SSH_COMMAND[]) ? join(filters, ',') : '"'*join(filters, ',')*'"'])
            k = (; key..., url, type=:resized, size, animated)
            mi = MediaImport(; key=k)
            rs = Postgres.execute(:p0, "select media_url from media_storage where h = \$1 limit 1", [mi.h])[2]
            if @tr url k mi.h already_imported :variant (isempty(rs) && !already_imported)
                if isnothing(orig_data)
                    @tr @elapsed (orig_data = download(est, orig_media_url; proxy))
                    @tr url orig_media_url length(orig_data)
                end
                @tr "media_task_processing_variant" url k begin
                    mkpath(MEDIA_TMP_DIR[])
                    outfn = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext)"
                    logfile = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext).log"
                    cmd = Cmd([MEDIA_SSH_COMMAND[]..., "nice", "ionice", "-c3", "ffmpeg", "-y", "-i", "-", convopts..., outfn])
                    try
                        @tr url k cmd run(pipeline(cmd, stdin=IOBuffer(orig_data), stdout=logfile, stderr=logfile))
                    catch _
                        DB.incr(est, :media_processing_errors)
                        rethrow()
                    end
                    # fn = stat(original_mi.path).size <= stat(outfn).size ? original_mi.path : outfn
                    fn = outfn #!!!
                    variant_data = read(fn)
                    @tr url k fn murl = media_import_2((_)->variant_data, k, SHA.sha256(variant_data))
                    variants[(size, animated)] = murl
                    try rm(outfn) catch _ end
                    try rm(logfile) catch _ end
                    nothing
                end
                variant_missing = true
            else
                if !isempty(rs)
                    variants[(size, animated)] = rs[1][1]
                end
            end
            @label cont2
        end
        variant_missing && return nothing

        variants.wrapped
    end
end

BLOSSOM_HOST = Ref("blossom-dev.primal.net")

function media_import_2(fetchfunc::Union{Function,Nothing}, key, sha256::Vector{UInt8}; media_path::Symbol=:cache, pubkey=nothing, use_external=nothing)
    funcname = "media_import_2"

    external =
    if !isnothing(pubkey)
        Main.App.use_external_storage(pubkey)
    else
        true
    end
    if !isnothing(use_external)
        external = use_external
    end

    sha256_hex = bytes2hex(sha256)
    @tr sha256_hex external ()

    rs = []
    excs = []
    failed = []
    for mp in MEDIA_PATHS_2[media_path]
        try
            if     mp[1] == :local && !external
                @tr sha256_hex r = media_import_local_2(fetchfunc, key, sha256, mp[2:end]...)
                push!(rs, r)
            elseif mp[1] == :s3    # && external
                @tr sha256_hex r = media_import_s3_2(fetchfunc, key, sha256, mp[2:end]...)
                push!(rs, r)
            end
        catch ex
            println("media_import_2 for $media_path to $mp for sha256 $sha256_hex: ", typeof(ex))
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
            push!(excs, ex)
            ex isa Base.IOError && push!(failed, mp)
        end
    end
    @tr sha256_hex external rs ()
    # filter!(mp->!(mp in failed), MEDIA_PATHS_2[media_path])
    isempty(rs) ? throw(excs[1]) : BLOSSOM_HOST[]*"/"*splitpath(URIs.parse_uri(rs[1]).path)[end]
end

function media_import_local_2(fetchfunc::Union{Function,Nothing}, key, sha256::Vector{UInt8}, host::String, media_path::String)
    funcname = "media_import_local_2"
    sha256_hex = bytes2hex(sha256)
    @tr sha256_hex host media_path ()
    rs = Postgres.execute(:p0, "select media_url from media_storage where storage_provider = \$1 and sha256 = \$2 limit 1",
                          [host, sha256])[2]
    if @tr sha256_hex isempty(rs)
        data = fetchfunc(sha256)
        @assert sha256 == SHA.sha256(data)
        h = sha256_hex
        subdir = "$(h[1:1])/$(h[2:3])/$(h[4:5])"
        dirpath = "$(media_path)/$(subdir)"
        path = "$(dirpath)/$(h)"
        mt = parse_mimetype(data)
        ext = get(mimetype_ext, mt, ".bin")

        mkpath(dirpath)
        rnd = bytes2hex(rand(UInt8, 12))
        open(path*".tmp-$rnd", "w+") do f; write(f, data); end
        mv(path*".tmp-$rnd", path*ext; force=true)
        symlink("$(h)$(ext)", "$(path).tmp-$rnd")
        try 
            mv("$(path).tmp-$rnd", path; force=true)
        catch ex
            if ex isa ArgumentError
                try rm("$(path).tmp-$rnd") catch _ end
            else
                rethrow()
            end
        end
        p = "$(splitpath(media_path)[end])/$(subdir)/$(h)"
        @tr sha256_hex url = "https://media.primal.net/"*p*ext
        h = bytes2hex(SHA.sha256(JSON.json(key)))
        Postgres.execute(:p0, "insert into media_storage values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9) on conflict do nothing",
                         [url, host, Utils.current_time(), JSON.json(key), h, ext, mt, length(data), sha256])
    else
        url = rs[1][1]
    end
    @tr sha256_hex url ()
    url
end

function media_import_s3_2(fetchfunc::Union{Function,Nothing}, key, sha256::Vector{UInt8}, provider, dir)
    funcname = "media_import_s3_2"
    sha256_hex = bytes2hex(sha256)
    @tr sha256_hex provider dir ()
    rs = Postgres.execute(:p0, "select media_url from media_storage where storage_provider = \$1 and sha256 = \$2 limit 1",
                          [provider, sha256])[2]
    if @tr sha256_hex isempty(rs)
        data = fetchfunc(sha256)
        @assert sha256 == SHA.sha256(data)
        h = sha256_hex
        subdir = "$(h[1:1])/$(h[2:3])/$(h[4:5])"
        dirpath = "$(dir)/$(subdir)"
        path = "$(dirpath)/$(h)"
        mt = parse_mimetype(data)
        ext = get(mimetype_ext, mt, ".bin")

        p = "$(splitpath(dir)[end])/$(subdir)/$(h)"
        s3_upload(provider, p*ext, data, mt)
        pd = Main.S3_CONFIGS[provider]
        domain = isnothing(pd.domain) ? pd.bucket*"."*URIs.parse_uri(pd.endpoint).host : pd.domain
        @tr sha256_hex url = "https://$domain/"*p*ext
        h = bytes2hex(SHA.sha256(JSON.json(key)))
        Postgres.execute(:p0, "insert into media_storage values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9) on conflict do nothing",
                         [url, provider, Utils.current_time(), JSON.json(key), h, ext, mt, length(data), sha256])
    else
        url = rs[1][1]
    end
    @tr sha256_hex url ()
    url
end

media_processing_channel_lock = ReentrantLock()
media_processing_channel = Channel(100_000)

media_queue_executor_running = Ref(false)
media_queue_executor = Ref{Any}(nothing)

function media_queue(task::Task)
    lock(media_processing_channel_lock) do
        if !Utils.isfull(media_processing_channel)
            put!(media_processing_channel, task)
        else
            @warn "media_processing_channel is full"
        end
    end
end

media_queue_executor_taskcnt = Ref(0) |> ThreadSafe

update_media_queue_executor_taskcnt(by=1) = lock(media_queue_executor_taskcnt) do taskcnt; taskcnt[] += by; end

MEDIA_PROCESSING_TASKS = Ref(8)

function start_media_queue()
    while !isempty(media_processing_channel); take!(media_processing_channel); end
    media_queue_executor_running[] = true
    media_queue_executor[] = 
    errormonitor(@async while media_queue_executor_running[]
                     r = take!(media_processing_channel)
                     r == :exit && break
                     update_media_queue_executor_taskcnt(+1)
                     schedule(r)
                     while media_queue_executor_running[] && media_queue_executor_taskcnt[] >= MEDIA_PROCESSING_TASKS[]
                         sleep(0.01)
                     end
                 end)
end

function stop_media_queue()
    media_queue_executor_running[] = false
    put!(media_processing_channel, :exit)
    wait(media_queue_executor[])
    media_queue_executor[] = nothing
end

function task_wrapper(body, est, k, maxdur, perperiod)
    tdur = Ref(0.0)
    DB.catch_exception(est, :media_variants, k) do
        tdur[] = @elapsed body()
    end
    lock(maxdur) do maxdur
        maxdur[] = max(maxdur[], tdur[]) 
    end
    lock(perperiod) do perperiod
        perperiod[] += 1
    end
end

function parse_image_dimensions(data::Vector{UInt8})
    data = collect(data)
    mimetype = try parse_mimetype(data) catch _ return end
    if mimetype == "image/svg+xml"
        s = String(data)
        m1 = match(r"<svg.* width=\"([0-9]+)", s)
        isnothing(m1) && return nothing
        m2 = match(r"<svg.* height=\"([0-9]+)", s)
        isnothing(m2) && return nothing
        w = parse(Int, m1[1])
        h = parse(Int, m2[1])
        x = 500
        (x, x*h/w, 0.0)
    else
        m = mktemp() do fn, io
            write(io, data)
            close(io)
            match(r", ([0-9]+) ?x ?([0-9]+)(, |$)", read(pipeline(`file $fn`; stdin=devnull), String))
        end
        isnothing(m) ? nothing : (parse(Int, m[1]), parse(Int, m[2]), try parse(Float64, m[3]) catch _ 0.0 end)
    end
end

function parse_video_dimensions(data::Vector{UInt8})
    res = nothing
    Main.Logging.with_logger(Main.Logging.NullLogger()) do
        try 
            width = height = duration = rotation = 0
            for s in split(read(pipeline(`ffprobe -v error -probesize 10M -select_streams v:0 -show_entries stream -`; stdin=IOBuffer(data)), String), '\n')
                ps = split(s, '=')
                if length(ps) == 2
                    if     ps[1] == "width";    width    = parse(Int, ps[2])
                    elseif ps[1] == "height";   height   = parse(Int, ps[2])
                    elseif ps[1] == "duration"; try duration = parse(Float64, ps[2]) catch _ end
                    elseif ps[1] == "rotation"; rotation = parse(Int, ps[2])
                    end
                end
            end
            if duration == 0
                for s in split(read(pipeline(`ffprobe -v error -probesize 10M -select_streams v:0 -show_format -`; stdin=IOBuffer(data)), String), '\n')
                    ps = split(s, '=')
                    if length(ps) == 2
                        if ps[1] == "duration"; duration = parse(Float64, ps[2])
                        end
                    end
                end
            end
            if rotation == 90 || rotation == -90 || rotation == 270
                width, height = height, width
            end
            res = (width, height, duration)
        catch _ end
    end
    res
end

function parse_mimetype(data::Vector{UInt8})
    mktemp() do fn, io
        write(io, data)
        close(io)
        String(chomp(read(pipeline(`file -b --mime-type $fn`; stdin=devnull), String)))
    end
end

function extract_video_frames(data::Vector{UInt8}; nframes=5, image_format="mjpeg")
    w, h, dur = parse_video_dimensions(data)
    frames = []
    for i in 1:nframes
        frame_pos = i*dur/(nframes+1)
        push!(frames, (frame_pos, read(pipeline(`ffmpeg -v error -i - -vframes 1 -an -ss $frame_pos -c:v $image_format -f image2pipe -`; stdin=IOBuffer(data), stdout=`magick - -`))))
    end
    frames
end

function cdn_url(url, size, animated)
    "https://primal.b-cdn.net/media-cache?s=$(string(size)[1])&a=$(Int(animated))&u=$(URIs.escapeuri(url))"
end
##
import Distributed
mutable struct DistSlot
    proc::Union{Nothing,Int}
    active::Bool
    activations::Int
end
execute_distributed_lock = ReentrantLock()
execute_distributed_slots = [DistSlot(nothing, false, 0) for _ in 1:20]
execute_distributed_active = Ref(true)
execute_distributed_active_slots = Ref(0) |> ThreadSafe
EXECUTE_DISTRIBUTED_MAX_ACTIVATIONS = Ref(200)
function execute_distributed(expr; timeout=20, includes=[])
    @show expr
    function update_active_slots()
        execute_distributed_active_slots[] = count([s.active for s in execute_distributed_slots])
    end

    lock(execute_distributed_lock) do
        for s in execute_distributed_slots
            if s.activations >= EXECUTE_DISTRIBUTED_MAX_ACTIVATIONS[]
                kill(Distributed.worker_from_id(s.proc).config.process, 15)
                s.proc = nothing
                s.active = false
                s.activations = 0
            end
            if isnothing(s.proc)
                newpid, = Distributed.addprocs(1; topology=:master_worker, exeflags="--project")
                for fn in includes
                    Distributed.remotecall_eval(Main, newpid, quote; include($fn); nothing; end)
                end
                s.proc = newpid
            end
        end
    end

    slot = nothing
    while execute_distributed_active[] && isnothing(slot)
        lock(execute_distributed_lock) do
            for (i, s) in enumerate(execute_distributed_slots)
                if !s.active
                    slot = s
                    s.active = true
                    s.activations += 1
                    break
                end
            end
        end
        sleep(1)
    end
    execute_distributed_active[] || return

    update_active_slots()

    pid = slot.proc

    r = Ref{Any}(nothing)
    restart = Ref(false)

    @sync begin
        @async begin
            tstart = time()
            while isnothing(r[]) && (time() - tstart < timeout); sleep(0.1); end
            if isnothing(r[])
                restart[] = true
            end
        end
        try
            r[] = Distributed.remotecall_eval(Main, pid, expr)
        catch ex
            r[] = ex
            # println(ex)
        end
    end

    lock(execute_distributed_lock) do
        if restart[]
            kill(Distributed.worker_from_id(pid).config.process, 15)
            slot.proc = nothing
            slot.activations = 0
        end
        slot.active = false
    end

    update_active_slots()

    r[]
end

function execute_distributed_kill_all()
    lock(execute_distributed_lock) do
        for (p, s) in Media.execute_distributed_slots
            println("killing process $(p[])")
            try kill(Distributed.worker_from_id(p[]).config.process, 15) catch _ end
            s[] = false
        end
    end
    for p in Distributed.workers()
        println("killing process $(p)")
        try kill(Distributed.worker_from_id(p).config.process, 15) catch _ end
    end
end
##

function fetch_resource_metadata_(url; proxy=MEDIA_PROXY[]) 
    includes = []
    fn = "fetch-web-page-meta-data.jl"
    for d in [".", "primal-server"]
        isfile("$d/$fn") && push!(includes, "$d/$fn")
    end
    @assert length(includes) == 1
    r = execute_distributed(:(fetch_meta_data($url, $proxy)); includes)
    # @show (url, r)
    # r isa Exception && println((url, r))
    r isa NamedTuple ? r : (; mimetype="", title="", image="", description="", icon_url="")
end

import Conda
#Conda.add(["beautifulsoup4", "requests", "html5lib", "boto3"]) # FIXME
function fetch_resource_metadata(url; proxy=MEDIA_METADATA_PROXY[]) 
    proxy = isnothing(proxy) ? "null" : proxy
    r = try
        NamedTuple([Symbol(k)=>v for (k, v) in JSON.parse(read(pipeline(`nice timeout 10 $(Conda.ROOTENV)/bin/python primal-server/link-preview.py $url $proxy`, stderr=devnull), String))])
    catch _
        (; mimetype="", title="", image="", description="", icon_url="")
    end
    r
end

function image_category(img_path)
    return ("", 1.0)
    try
        fn = "/home/pr"*img_path
        r = JSON.parse(String(HTTP.request("POST", "http://192.168.15.1:5000/classify";
                                           headers=["Content-Type"=>"application/json"],
                                           body=JSON.json([fn]), retry=false).body))[1]
        sfw_prob = r["drawings"] + r["neutral"]
        if sfw_prob >= 0.7
            (:sfw, sfw_prob)
        else
            (:nsfw, 1-sfw_prob)
        end
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        ("", 1.0)
    end
end

EXIFTOOL_RO_BINDS = []

function exiftool(args; stdin=devnull)
    exiftool_path = readlink(strip(read(`which exiftool`, String)))
    pipeline(Cmd(["bwrap", "--new-session", "--die-with-parent", "--unshare-net", 
                  "--ro-bind", "/nix", "/nix", 
                  Iterators.flatten([["--ro-bind", p, p] for p in EXIFTOOL_RO_BINDS])...,
                  exiftool_path, args...]);
             stdin, stderr=devnull)
end

function ffmpeg(args; stdin=devnull)
    ffmpeg_path = readlink(strip(read(`which ffmpeg`, String)))
    pipeline(Cmd(["bwrap", "--new-session", "--die-with-parent", "--unshare-net", 
                  "--ro-bind", "/nix", "/nix", 
                  Iterators.flatten([["--ro-bind", p, p] for p in EXIFTOOL_RO_BINDS])...,
                  ffmpeg_path, args...]);
             stdin, stderr=devnull)
end

function strip_metadata(data::Vector{UInt8})
    try
        read(exiftool(["-ignoreMinorErrors", "-all=", "-tagsfromfile", "@", "-Orientation", "-"]; stdin=IOBuffer(data)))
    catch _
        ext = replace(mimetype_ext[parse_mimetype(data)], '.'=>"")
        read(ffmpeg(["-y", "-i", "-", "-map_metadata", "-1", "-c:v", "copy", "-c:a", "copy", "-f", ext, "-"]; stdin=IOBuffer(data)))
    end
end

function is_image_rotated(data::Vector{UInt8})
    for s in readlines(pipeline(exiftool(["-t", "-"]; stdin=IOBuffer(data))))
        k, v = split(s, '\t')
        k == "Orientation" && v == "Rotate 90 CW" && return true
    end
    false
end

function extract_video_thumbnail(data::Vector{UInt8})
    mktemp() do fn, io
        write(io, data)
        close(io)
        # try read(pipeline(`ffmpeg -v error -i $fn -vframes 1 -an -ss 0 -c:v png -f image2pipe -`; stdin=devnull, stdout=`magick - -`)) catch _ end
        try read(pipeline(`ffmpeg -v error -i $fn -vframes 1 -an -ss 0 -c:v png -f image2pipe -`; stdin=devnull, stdout=`magick - -quality 90 jpg:-`)) catch _ end
    end
end

function resize_image(data::Vector{UInt8}; size=(512, 512))
    try read(pipeline(`systemd-run --quiet --scope -p MemoryMax=5G --user magick - -resize $(size[1])x$(size[2]) -`; stdin=IOBuffer(data))) catch _ end
end

function extract_video_beginning(data::Vector{UInt8}; duration=20, timeout=15)
    # input = IOBuffer(data)
    # output = IOBuffer()
    # run(pipeline(`ffmpeg -v error -i - -t $duration -c copy -f matroska -`; stdin=input, stdout=output))
    # seekstart(output)
    # take!(output)
    fn  = "/tmp/extract-video-beginning-"*join(rand('a':'z', 30))
    fn1 = fn*"-1"
    fn2 = fn*"-2.mp4"
    try
        write(fn1, data)
        run(pipeline(`timeout $timeout ffmpeg -v error -i $fn1 -t $duration -movflags faststart -c copy $fn2`; stdin=Base.devnull))
        read(fn2)
    finally
        try rm(fn1) catch end
        try rm(fn2) catch end
    end
end

DEFAULT_AI_HOST   = Ref("192.168.52.1")
task_ai_host()    = get(task_local_storage(), :ai_host, DEFAULT_AI_HOST[])
task_ai_timeout() = get(task_local_storage(), :ai_timeout, 30)

function async_tls_pass(body::Function)
    ai_host    = task_ai_host()
    ai_timeout = task_ai_timeout()
    function f(g::Function)
        task_local_storage(:ai_host, ai_host) do
            task_local_storage(:ai_timeout, ai_timeout) do
                g()
            end
        end
    end
    body(f)
end

function image_query(
        imgdata::Vector{UInt8}, query::String; 
        num_predict=1024, 
        model="llama3.2-vision", 
        endpoint="http://$(task_ai_host()):11434/api/chat",
        timeout=task_ai_timeout())
    req = (;
           model,
           keep_alive="180m",
           options=(; num_predict),
           messages=[
                     (;
                      role="user",
                      content=query,
                      images=[Base64.base64encode(imgdata)]
                     ),
                    ])

    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    res = []
    for s1 in split(s, '\n')
        # println(s1)
        r = JSON.parse(s1)
        r["done"] && break
        m = r["message"]
        m["role"] != "assistant" && break
        push!(res, m["content"])
    end
    join(res)
end

function media_classify(type::Symbol, model::String, data::Vector{UInt8}; timeout=task_ai_timeout())
    port =
    if     type == :image && model == "Falconsai/nsfw_image_detection"; 5012
    elseif type == :video && model == "Falconsai/nsfw_image_detection"; 5012
    elseif type == :image && model == "nudenet"; 5015
    elseif type == :image && model == "marqo_nsfw"; 5017
    elseif type == :image && model == "nsfw_detector"; 5018
    elseif type == :image && model == "opennsfw2"; 5016
    elseif type == :video && model == "opennsfw2"; 5016
    else; error("unknown model $model")
    end
    endpoint = "http://$(task_ai_host()):$port/classify"
    req = (; model, [type=>Base64.base64encode(data)]...)
    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    haskey(r, "error") && error(r["error"])
    @assert r["model"] == model
    r
end

function image_features(
        imgdata::Vector{UInt8}; 
        model="google/vit-base-patch16-384", 
        endpoint="http://$(task_ai_host()):5013/features", 
        timeout=task_ai_timeout(),
        pool=true)
    req = (; model, pool, image=Base64.base64encode(imgdata))
    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    haskey(r, "error") && error(r["error"])
    @assert r["model"] == model
    r
end

function video_features(
        videodata::Vector{UInt8}; 
        model="google/vivit-b-16x2-kinetics400", 
        endpoint="http://$(task_ai_host()):5014/features",
        timeout=task_ai_timeout())
    req = (; model, video=Base64.base64encode(videodata))
    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    haskey(r, "error") && error(r["error"])
    @assert r["model"] == model
    r
end

function text_features(
        text::String; 
        model="nomic-embed-text", 
        endpoint="http://$(task_ai_host()):11434/api/embeddings",
        timeout=task_ai_timeout())
    req = (;
           model,
           keep_alive="180m",
           prompt=text,
          )

    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    Dict(["model"=>model, "output"=>r["embedding"]])
end

function text_query(
        query::String; 
        model="llama3.2:1b", 
        endpoint="http://$(task_ai_host()):11434/api/chat",
        num_predict=1024, 
        timeout=task_ai_timeout())
    req = (;
           model,
           keep_alive="180m",
           options=(; num_predict),
           stream=false,
           messages=[
                     (;
                      role="user",
                      content=query,
                     ),
                    ])
    s = String(HTTP.request("POST", endpoint;
                            headers=["Content-Type"=>"application/json"],
                            body=JSON.json(req), retry=false,
                            readtimeout=timeout, connect_timeout=timeout).body)
    r = JSON.parse(s)
    Dict(["model"=>model, "output"=>r])
end

S3_TOOL_PATH = Ref("")
S3_CALL_IMPLEMENTATION = Ref(:s3_py)

function s3_call(provider::Symbol, req, data=UInt8[]; proxy=MEDIA_PROXY[], implementation=S3_CALL_IMPLEMENTATION[])
    # push!(Main.stuff, (:s3_call, (provider, req, data), (; proxy)))
    iob = IOBuffer()
    println(iob, JSON.json(req))
    write(iob, data)
    seek(iob, 0)
    timeout = trunc(Int, length(data)/(512*1024)) + 10
    try
        if     implementation == :s3_py
            JSON.parse(read(pipeline(`nice timeout $timeout $(Conda.ROOTENV)/bin/python primal-server/s3.py`, stdin=iob), String))
        elseif implementation == :s3_tool
            JSON.parse(read(pipeline(`nice timeout $timeout $S3_TOOL_PATH`, stdin=iob), String))
        end
    catch _
        println("s3_call failed: ", JSON.json(req))
        rethrow()
    end
end

function s3_upload(provider::Symbol, object::String, data::Vector{UInt8}, content_type::String; proxy=MEDIA_PROXY[])
    req = (; operation="upload", object, content_type, Main.S3_CONFIGS[provider]...)
    r = s3_call(provider, req, data; proxy)
    @assert r["status"]
    nothing
end

function s3_check(provider::Symbol, object::String; proxy=MEDIA_PROXY[])
    req = (; operation="check", object, Main.S3_CONFIGS[provider]...)
    r = s3_call(provider, req; proxy)
    r["exists"]
end

function s3_get(provider::Symbol, object::String; proxy=MEDIA_PROXY[], implementation=S3_CALL_IMPLEMENTATION[])::Vector{UInt8}
    req = (; operation="get", object, Main.S3_CONFIGS[provider]...)
    iob = IOBuffer()
    println(iob, JSON.json(req))
    seek(iob, 0)
    timeout = 120
    try
        if     implementation == :s3_py
            read(pipeline(`nice timeout 10 $(Conda.ROOTENV)/bin/python primal-server/s3.py`, stdin=iob))
        elseif implementation == :s3_tool
            read(pipeline(`nice timeout $timeout $S3_TOOL_PATH`, stdin=iob))
        end
    catch _
        println("s3_get failed: ", JSON.json(req))
        rethrow()
    end
end

function s3_delete(provider::Symbol, object::String; proxy=MEDIA_PROXY[])
    req = (; operation="delete", object, Main.S3_CONFIGS[provider]...)
    r = s3_call(provider, req; proxy)
    @assert r["status"]
end

function s3_copy(
        provider::Symbol, 
        source_bucket::String, source_object::String, 
        destination_bucket::String, destination_object::String; 
        proxy=MEDIA_PROXY[])
    req = (; operation="copy", Main.S3_CONFIGS[provider]...,
           source_bucket, source_object, destination_bucket, destination_object)
    r = s3_call(provider, req; proxy)
    @assert r["status"]
    nothing
end

function s3_presign_url(provider::Symbol, object::String, bucket=Main.S3_CONFIGS[provider].bucket; proxy=MEDIA_PROXY[])
    req = (; operation="pre-sign-url", object, Main.S3_CONFIGS[provider]..., bucket)
    r = s3_call(provider, req; proxy)
    @assert r["status"]
    r["url"]
end

URL = String
Resolution = Tuple{Int,Int}

@procnode function media_video_variants_pn(url::URL, media_url::URL, input_resolution::Resolution, input_duration::Real)
    E(; url, input_resolution, input_duration)
    variants = Dict{Resolution, URL}()
    horiz = input_resolution[1] > input_resolution[2]
    for (target, bitrate) in [
                         (1080, 6_000_000), 
                         (720, 3_000_000), 
                         (360, 1_000_000), 
                        ]
        target >= input_resolution[horiz ? 2 : 1] && continue
        r = transcode_video_pn(url, media_url, input_resolution, input_duration, target, bitrate).r
        if !isnothing(r)
            murl, dims = r
            variants[dims] = murl
        end
    end
    variants
end

VIDEO_TRANSCODING_SERVER = Ref("")
VIDEO_TRANSCODING_FFMPEG_PATH = Ref("")

video_transcodings = Dict{Tuple{URL, Int}, NamedTuple}() |> ThreadSafe

@procnode function transcode_video_pn(
        url::String, media_url::String, 
        input_resolution::Resolution, input_duration::Real, 
        target::Int, 
        bitrate::Int;
    )
    ext = splitext(media_url)[2]

    iw, ih = input_resolution
    @assert iw > 0 && ih > 0

    horiz = iw > ih
    ratio = Float64(iw)/Float64(ih)
    ow, oh = horiz ? 
    (trunc(Int, target * ratio), target) : 
    (target, trunc(Int, target / ratio))

    # @show ((iw, ih), horiz, (ow, oh))

    remoteoutfn = "/home/pr/tmp/transcoding/$(bytes2hex(rand(UInt8, 16)))$(ext)"

    mi = MediaImport(; key=(url, type=:transcoded_video, target_resolution=oh))
    
    mkpath(MEDIA_TMP_DIR[])
    outfn = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext)"
    logfile = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext).log"

    v = (; 
         url, media_url,
         input_duration, input_resolution, target, bitrate,
         outfn, logfile, remoteoutfn,
        )
    E(; v...)

    tkey = (url, target)

    start_time = Utils.current_time() 

    function update_progress(progress)
        video_transcodings[tkey] = (; v..., start_time, t=Utils.current_time(), progress)
        Postgres.execute(:p0, "update processing_nodes set progress = \$2 where id = \$1", [_id.id, progress])
    end

    cmd = Cmd(["ssh", 
               "-o", "ConnectTimeout=10", 
               "-o", "ServerAliveInterval=20", 
               "-o", "ServerAliveCountMax=3", 
               VIDEO_TRANSCODING_SERVER[],
               "$(VIDEO_TRANSCODING_FFMPEG_PATH[]) -nostats -progress /dev/stderr -y -hide_banner \
               -hwaccel cuda -hwaccel_output_format cuda \
               -i $media_url \
               -vf 'scale_cuda=$ow:$oh' \
               -c:v h264_nvenc \
               -b:v $bitrate -maxrate $bitrate -bufsize 5M \
               -c:a copy \
               $remoteoutfn && cat $remoteoutfn && rm -f $remoteoutfn",])

    err_pipe = Pipe()

    p = run(pipeline(cmd, stdout=outfn, stderr=err_pipe), wait=false)

    # speeds = []

    @async begin
        for line in eachline(err_pipe)
            # println("[STDERR] ", line)
            if startswith(line, "out_time_ms=")
                t = parse(Float64, split(line, '=')[2])/1_000_000
                progress = t/input_duration
                update_progress(progress)
            # elseif startswith(line, "speed=")
            #     push!(speeds, parse(Float64, replace(split(line, '=')[2], "x"=>"")))
            end
            open(logfile, "a") do f
                println(f, line)
            end
        end
    end

    wait(p)

    delete!(video_transcodings, tkey)

    # avg_speed = !isempty(speeds) ? sum(speeds)/length(speeds) : 0.0
    # println("Average speed: $avg_speed")

    variant_data = read(outfn)
    if length(variant_data) > 0
        (_, _, murl) = media_import((_)->variant_data, mi.key)
        try rm(outfn) catch _ end
        try rm(logfile) catch _ end
        murl, (ow, oh)
    else
        nothing
    end
end

DEFAULT_HANDLERS = (; download, media_import, run)

end

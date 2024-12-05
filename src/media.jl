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

import ..Utils
using ..Utils: ThreadSafe
import ..DB
import ..Postgres
using ..Tracing: @ti, @tc, @td, @tr

PRINT_EXCEPTIONS = Ref(false)

MEDIA_PATH = Ref("/mnt/ppr1/var/www/cdn/cache")
MEDIA_PATHS = Dict{Symbol, Vector}()
MEDIA_PATHS[:cache] = ["/mnt/ppr1/var/www/cdn/cache"]
MEDIA_URL_ROOT = Ref("https://media.primal.net/cache")
# MEDIA_TMP_DIR  = Ref("/tmp/primalmedia")
MEDIA_TMP_DIR = Ref("/mnt/ppr1/var/www/cdn/cache/tmp")
MEDIA_PROXY = Ref{Any}(nothing)
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
    "image/vnd.microsoft.icon" => ".ico",
    "text/plain" => ".txt",
    "application/json" => ".json",
])
##
downloader_headers = ["User-Agent"=>"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36"]

function clean_url(url::String)
    u = URIs.parse_uri(url)
    string(URIs.URI(; [p=>getproperty(u, p) for p in propertynames(u) if !(p in [:fragment, :uri])]...))
end

function download(est::DB.CacheStorage, url::String; proxy=MEDIA_PROXY[], timeout=2)::Vector{UInt8}
    try
        DB.incr(est, :media_downloads)
        # res = UInt8[]
        # chunksize = 512*1024
        # HTTP.open("GET", url; readtimeout=10, connect_timeout=5, headers=downloader_headers, proxy) do fin
        #     HTTP.startread(fin)
        #     empty!(res)
        #     while !eof(fin)
        #         d = read(fin, chunksize)
        #         # d = readavailable(fin)
        #         append!(res, d)
        #     end
        # end
        res = HTTP.get(url; readtimeout=timeout, connect_timeout=timeout, headers=downloader_headers, proxy, verbose=0, retry=true).body
        # res = fetch(Threads.@spawn HTTP.get(url; readtimeout=2, connect_timeout=2, headers=downloader_headers, proxy, verbose=0, retry=true).body)
        DB.incr(est, :media_downloaded_bytes; by=length(res))
        res
    catch _
        DB.incr(est, :media_download_errors)
        rethrow()
    end
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

function media_variants(est::DB.CacheStorage, url::String; variant_specs::Vector=all_variants, key=(;), proxy=MEDIA_PROXY[], sync=false)
    sync || @show (sync, url)
    funcname = "media_variants"
    @tr "media_variants_lock" url variant_specs key proxy sync lock(sync ? ReentrantLock() : media_variants_lock) do
        variants = Dict{Tuple{Symbol, Bool}, String}() |> ThreadSafe

        k = (; key..., url, type=:original)
        mi = MediaImport(; key=k)

        if @tr url k mi.h isempty(Postgres.execute(:p0, "select 1 from media_storage where h = \$1 limit 1", [mi.h])[2])
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
        @tr @elapsed (orig_data = download(est, orig_media_url; proxy))
        @tr url orig_media_url length(orig_data)

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
            if @tr url k mi.h :variant isempty(rs)
                if @tr k :variant !haskey(media_tasks, k)
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
                variants[(size, animated)] = rs[1][1]
            end
            @label cont2
        end
        variant_missing && return nothing

        variants.wrapped
    end
end

function media_import(fetchfunc::Union{Function,Nothing}, key; media_path::Symbol=:cache, pubkey=nothing)
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
            println("media_import to $media_path for key $key: ", typeof(ex))
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
            push!(excs, ex)
            ex isa Base.IOError && push!(failed, mp)
        end
    end
    @tr key external rs ()
    # filter!(mp->!(mp in failed), MEDIA_PATHS[media_path])
    isempty(rs) ? throw(excs[1]) : rs[1]
end

function media_import_local(fetchfunc::Union{Function,Nothing}, key, host::String, media_path::String)
    funcname = "media_import_local"
    @tr key host media_path ()
    mi = MediaImport(; key, media_path)
    rs = Postgres.execute(:p0, "select h, ext, media_url from media_storage where storage_provider = \$1 and h = \$2 limit 1",
                          [host, mi.h])[2]
    if @tr key mi.h isempty(rs)
        data = fetchfunc(key)
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
        Postgres.execute(:p0, "insert into media_storage values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8) on conflict do nothing",
                         [url, host, Utils.current_time(), mi.k, mi.h, ext, mt, length(data)])
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
        mt = parse_mimetype(data)
        ext = get(mimetype_ext, mt, ".bin")
        s3_upload(provider, p*ext, data, mt)
        u = URIs.parse_uri(Main.S3_CONFIGS[provider].endpoint)
        @tr key mi.h url = "https://primaldata."*u.host*"/"*p*ext
        Postgres.execute(:p0, "insert into media_storage values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8) on conflict do nothing",
                         [url, provider, Utils.current_time(), mi.k, mi.h, ext, mt, length(data)])
        lnk = mi.h*ext
    else
        lnk = "$(rs[1][1])$(rs[1][2])"
        url = rs[1][3]
    end
    @tr key lnk url ()
    @tr (mi, lnk, url)
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
    m = mktemp() do fn, io
        write(io, data)
        close(io)
        match(r", ([0-9]+) ?x ?([0-9]+)(, |$)", read(pipeline(`file $fn`; stdin=devnull), String))
    end
    isnothing(m) ? nothing : (parse(Int, m[1]), parse(Int, m[2]), try parse(Float64, m[3]) catch _ 0.0 end)
end

function parse_mimetype(data::Vector{UInt8})
    mktemp() do fn, io
        write(io, data)
        close(io)
        String(chomp(read(pipeline(`file -b --mime-type $fn`; stdin=devnull), String)))
    end
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
function fetch_resource_metadata(url; proxy=MEDIA_PROXY[]) 
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

function image_query(imgdata::Vector{UInt8}, query::String; num_predict=1024)
    try
        req = (;
               model="llama3.2-vision",
               keep_alive="30m",
               options=(; num_predict),
               messages=[
                         (;
                          role="user",
                          content=query,
                          images=[Base64.base64encode(imgdata)]
                         ),
                        ])

        s = String(HTTP.request("POST", "http://192.168.50.1:11434/api/chat";
                                headers=["Content-Type"=>"application/json"],
                                body=JSON.json(req), retry=false,
                                readtimeout=30, connect_timeout=30).body)
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
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        nothing
    end
end

function s3_call(provider::Symbol, req, data=UInt8[]; proxy=MEDIA_PROXY[])
    iob = IOBuffer()
    println(iob, JSON.json(req))
    write(iob, data)
    seek(iob, 0)
    timeout = trunc(Int, length(data)/(512*1024)) + 10
    try
        JSON.parse(read(pipeline(`nice timeout $timeout $(Conda.ROOTENV)/bin/python primal-server/s3.py`, stdin=iob), String))
    catch _
        # println("s3_call failed: ", JSON.json(req))
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

function s3_get(provider::Symbol, object::String; proxy=MEDIA_PROXY[])::Vector{UInt8}
    req = (; operation="get", object, Main.S3_CONFIGS[provider]...)
    iob = IOBuffer()
    println(iob, JSON.json(req))
    seek(iob, 0)
    read(pipeline(`nice timeout 10 $(Conda.ROOTENV)/bin/python primal-server/s3.py`, stdin=iob))
end

function s3_delete(provider::Symbol, object::String; proxy=MEDIA_PROXY[])
    req = (; operation="delete", object, Main.S3_CONFIGS[provider]...)
    r = s3_call(provider, req; proxy)
    @assert r["status"]
end

end


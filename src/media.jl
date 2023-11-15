module Media

import JSON
import SHA
import URIs
import Dates
using DataStructures: CircularBuffer
import HTTP
import EzXML
import Gumbo, Cascadia

import ..Utils
using ..Utils: ThreadSafe
import ..DB

PRINT_EXCEPTIONS = Ref(false)

MEDIA_PATH = Ref("/mnt/ppr1/var/www/cdn/cache")
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
    "video/mov" => ".mov",
    "video/webp" => ".webp",
    "video/quicktime"  => ".mov",
    "video/x-matroska" => ".mkv",
    "image/vnd.microsoft.icon" => ".ico",
])
##
downloader_headers = ["User-Agent"=>"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36"]

function download(est::DB.CacheStorage, url::String; proxy=MEDIA_PROXY[])::Vector{UInt8}
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
        res = HTTP.get(url; readtimeout=2, connect_timeout=2, headers=downloader_headers, proxy, verbose=0, retry=true).body
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

make_media_url(mi::MediaImport, ext::String) = "$(MEDIA_URL_ROOT[])/$(mi.subdir)/$(mi.h)$(ext)"

function media_variants(est::DB.CacheStorage, url::String, variant_specs::Vector=all_variants; key=(;), proxy=MEDIA_PROXY[], sync=false)
    lock(sync ? ReentrantLock() : media_variants_lock) do
        variants = Dict{Tuple{Symbol, Bool}, String}()

        k = (; key..., url, type=:original)
        mi = MediaImport(; key=k)
        if !isfile(mi.path)
            if !haskey(media_tasks, k)
                media_tasks[k] = 
                let k=k
                    tsk = @task task_wrapper(est, k, max_download_duration, downloads_per_period) do
                        try
                            push!(media_variants_log, (Dates.now(), k))
                            data = download(est, url; proxy)
                            media_import((_)->data, k)
                            media_variants(est, url, variant_specs; key, proxy, sync)
                        finally
                            delete!(media_tasks, k)
                            update_media_queue_executor_taskcnt(-1)
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

        !isfile(mi.path) && return nothing

        original_lnk = readlink(mi.path)
        _, ext = splitext(original_lnk)

        ext == ".bin" && return nothing

        original_mi = mi

        variant_missing = false
        for (size, animated) in variant_specs
            if size == :original
                variants[(size, animated)] = make_media_url(original_mi, ext)
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
            if !isfile(mi.path)
                if !haskey(media_tasks, k)
                    media_tasks[k] = 
                    let k=k, mi=mi, convopts=convopts
                        tsk = @task task_wrapper(est, k, max_task_duration, tasks_per_period) do
                            try
                                push!(media_variants_log, (Dates.now(), k))
                                mkpath(MEDIA_TMP_DIR[])
                                outfn = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext)"
                                logfile = "$(MEDIA_TMP_DIR[])/$(mi.h)$(ext).log"
                                cmd = Cmd([MEDIA_SSH_COMMAND[]..., "nice", "ionice", "-c3", "ffmpeg", "-y", "-i", original_mi.path, convopts..., outfn])
                                try
                                    run(pipeline(cmd, stdin=devnull, stdout=logfile, stderr=logfile))
                                catch _
                                    DB.incr(est, :media_processing_errors)
                                    rethrow()
                                end
                                fn = stat(original_mi.path).size <= stat(outfn).size ? original_mi.path : outfn
                                # fn = outfn #!!!
                                media_import((_)->read(fn), k)
                                rm(outfn)
                                rm(logfile)
                            finally
                                delete!(media_tasks, k)
                                update_media_queue_executor_taskcnt(-1)
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
            end
            @label cont2
            variants[(size, animated)] = make_media_url(mi, ext)
        end
        variant_missing && return nothing

        variants
    end
end

function media_import(fetchfunc::Union{Function,Nothing}, key; media_path=MEDIA_PATH[])
    mi = MediaImport(; key, media_path)
    if !isfile(mi.path)
        data = fetchfunc(key)
        mkpath(mi.dirpath)
        open(mi.path*".key.tmp", "w+") do f; write(f, mi.k); end
        mv(mi.path*".key.tmp", mi.path*".key"; force=true)
        open(mi.path*".tmp", "w+") do f; write(f, data); end
        mt = chomp(read(`file -b --mime-type $(mi.path*".tmp")`, String))
        ext = get(mimetype_ext, mt, ".bin")
        mv(mi.path*".tmp", mi.path*ext; force=true)
        islink(mi.path) && rm(mi.path)
        symlink("$(mi.h)$(ext)", mi.path)
    end
    lnk = readlink(mi.path)
    (mi, lnk)
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
        match(r", ([0-9]+)x([0-9]+), ", read(pipeline(`file $fn`; stdin=devnull), String))
    end
    isnothing(m) ? nothing : (parse(Int, m[1]), parse(Int, m[2]))
end

function parse_image_mimetype(data::Vector{UInt8})
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
function fetch_resource_metadata(url; proxy=MEDIA_PROXY[]) 
    proxy = isnothing(proxy) ? "null" : proxy
    r = try
        NamedTuple([Symbol(k)=>v for (k, v) in JSON.parse(read(pipeline(`nice timeout 10 $(Conda.ROOTENV)/bin/python primal-server/link-preview.py $url $proxy`, stderr=devnull), String))])
    catch _
        (; mimetype="", title="", image="", description="", icon_url="")
    end
    # @show (:fetch_resource_metadata, url, r)
    r
end

function image_category(img_path)
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

end


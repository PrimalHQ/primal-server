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

        make_url(mi::MediaImport) = "$(MEDIA_URL_ROOT[])/$(mi.subdir)/$(mi.h)$(ext)"

        original_mi = mi

        variant_missing = false
        for (size, animated) in variant_specs
            if size == :original
                variants[(size, animated)] = make_url(original_mi)
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
            variants[(size, animated)] = make_url(mi)
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

import Distributed
execute_distributed_lock = ReentrantLock()
function execute_distributed(body::Function; timeout=10, includes=[])
    lock(execute_distributed_lock) do
        ws = [pid for pid in Distributed.procs() if pid != 1]
        pid = if isempty(ws)
            newpid, = Distributed.addprocs(1; topology=:master_worker, exeflags="--project")
            Main.eval(quote
                          Distributed.remotecall_fetch(function(includes)
                                             for fn in includes
                                                 Main.include(fn)
                                             end
                                         end, $newpid, $includes)
                      end)
            newpid
        else
            rand(ws)
        end
        r = Ref{Any}(nothing)
        @sync begin
            @async begin
                tstart = time()
                while isnothing(r[]) && (time() - tstart < timeout); sleep(0.1); end
                if isnothing(r[])
                    kill(Distributed.worker_from_id(pid).config.process, 15)
                    Distributed.addprocs(1; topology=:master_worker, exeflags="--project")
                end
            end
            try
                r[] = Distributed.remotecall_fetch(body, pid)
            catch ex
                r[] = ex
                # println(ex)
            end
        end
        r[]
    end
end

function fetch_resource_metadata(url; proxy=MEDIA_PROXY[]) 
    includes = []
    fn = "fetch-web-page-meta-data.jl"
    for d in [".", "primal-server"]
        isfile("$d/$fn") && push!(includes, "$d/$fn")
    end
    @assert length(includes) == 1
    r = Main.eval(:(Media.execute_distributed(; includes=$includes) do
        fetch_meta_data($url, $proxy)
    end))
    # @show (url, r)
    r isa NamedTuple ? r : (; mimetype="", title="", image="", description="", icon_url="")
end

function _fetch_resource_metadata(url; proxy=MEDIA_PROXY[]) 
    resp = HTTP.get(url; 
                    readtimeout=15, connect_timeout=15, 
                    headers=["User-Agent"=>"WhatsApp/2"], proxy)

    doc = try 
        d = copy(collect(resp.body))
        doc = Gumbo.parsehtml(String(d))
    catch ex
        # @show string(ex)[1:200]
        # Utils.print_exceptions()
        error("error parsing html")
    end

    mimetype = string(get(Dict(resp.headers), "Content-Type", ""))
    title = image = description = ""
    for ee in eachmatch(Cascadia.Selector("html > head > meta"), doc.root)
        e = ee.attributes
        if haskey(e, "property") && haskey(e, "content")
            prop = e["property"]
            if     prop == "og:title"; title = e["content"]
            elseif prop == "og:image"; image = e["content"]
            elseif prop == "og:description"; description = e["content"]
            elseif prop == "twitter:title"; title = e["content"]
            elseif prop == "twitter:description"; description = e["content"]
            elseif prop == "twitter:image:src"; image = e["content"]
            end
        elseif haskey(e, "name") && haskey(e, "content")
            if e["name"] == "description"; description = e["content"]; end
        end
    end
    icon_url = ""
    for ee in eachmatch(Cascadia.Selector("html > head > link"), doc.root)
        e = ee.attributes
        # @show string(e)
        if haskey(e, "rel") && haskey(e, "href")
            (e["rel"] == "icon" || e["rel"] == "shortcut icon") || continue
            u = URIs.parse_uri(url)
            icon_url = try
                string(URIs.parse_uri(e["href"]))
            catch _
                try
                    string(URIs.URI(; scheme=u.scheme, host=u.host, port=u.port, path=URIs.normpath(u.path*e["href"])))
                catch _
                    ""
                end
            end
            break
        end
    end
    (; mimetype, title, image, description, icon_url)
end

end


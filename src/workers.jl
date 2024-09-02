module Workers

import Sockets
import JSON
using Serialization: serialize, deserialize

import ..Utils
import ..Postgres
using ..Postgres: handle_errors, Session, ConnStr, recv_int4, send_int4

struct TCPConnStr <: ConnStr
    connstr::String
end

const worker_lock = ReentrantLock()
const worker_index_max = Ref(0)
const free_worker_indexes = []

function Postgres.pre_connect_session(connstr::TCPConnStr, opts)
    idx = lock(worker_lock) do
        if isempty(free_worker_indexes)
            worker_index_max[] += 1
            push!(free_worker_indexes, worker_index_max[])
        end
        pop!(free_worker_indexes)
    end
    port = PORT[] + idx
    opts["port"] = "$port"
    extra = Dict()
    extra[:subprocess_idx] = idx
    extra[:subprocess_task] = 
    errormonitor(@async open(`julia --project -t1 -L pkg.jl start_cache_worker.jl /home/pr/work/itk/primal/primalnode_config_worker.jl $port`) do io
                     extra[:subprocess_io] = io
                     try
                         while !eof(io)
                             s = readline(io)
                             println("WORKER $idx: $s")
                         end
                     finally
                         lock(worker_lock) do
                             push!(free_worker_indexes, idx)
                         end
                     end
                 end)
    extra
end

function Postgres.post_init_session(connstr::TCPConnStr, session::Session)
    session.extra[:backendpid] = Int(recv_int4(session.socket))
end

PORT = Ref(31000)

server = Ref{Any}(nothing)
task = Ref{Any}(nothing)

function start_listener()
    @assert isnothing(task[])
    println("started listener on port $(PORT[])")
    server[] = Sockets.listen(PORT[])
    # task[] = errormonitor(@async begin
    #                           while true
    #                               sock = Sockets.accept(server[])
    #                               errormonitor(@async Base.invokelatest(handle_client, sock))
    #                           end
    #                       end)
    task[] = errormonitor(@async begin
                              sock = Sockets.accept(server[])
                              Base.invokelatest(handle_client, sock)
                          end)
    nothing
end

function stop_listener()
    @assert !isnothing(task[])
    @assert !isnothing(server[])
    close(server[])
    server[] = nothing
    wait(task[])
    task[] = nothing
    nothing
end

function handle_client(sock)
    try
        send_int4(sock, Int32(getpid()))

        while true
            pkttype = recv_int4(sock)
            pktlen = recv_int4(sock)

            pkt = read(sock, pktlen)

            resp =
            if     pkttype == EVALEXPR
                res = eval_expr(pkt)
                iob = IOBuffer()
                serialize(iob, res)
                take!(iob)

            elseif pkttype == APICALL
                reqjson = String(pkt)
                resjson = JSON.json(api_call(reqjson))
                collect(transcode(UInt8, resjson))

            else
                error("invalid command type")
            end

            send_int4(sock, length(resp))
            write(sock, resp)
            # flush(sock)
        end
    finally
        try close(sock) catch _ end
    end
end

function eval_expr(pkt::Vector{UInt8})
    try
        expr = deserialize(IOBuffer(pkt))
        (; ok=true, res=Main.eval(expr))
    catch ex
        Utils.print_exceptions()
        (; ok=false, res=string(typeof(ex)))
    end
end

function api_call(reqjson::String)
    try
        d = JSON.parse(reqjson)
        funcall = Symbol(d[1])
        kwargs = [Symbol(k)=>v for (k, v) in collect(d[2])]

        (; ok=true, res=Base.invokelatest(getproperty(Main.App, funcall), Main.cache_storage; kwargs...))
    catch ex
        Utils.print_exceptions()
        (; ok=false, res=string(typeof(ex)))
    end
end

EVALEXPR = 1
APICALL = 2

function execute(session::Session, expr::Expr)
    iob = IOBuffer()
    serialize(iob, expr)
    d = take!(iob)

    send_int4(session.socket, EVALEXPR)
    send_int4(session.socket, length(d))
    write(session.socket, d)
    # flush(session.socket)

    pktlen = recv_int4(session.socket)
    res = deserialize(IOBuffer(read(session.socket, pktlen)))

    res.ok ? res.res : error(res.res)
end

function execute(session::Session, reqjson::String)
    d = collect(transcode(UInt8, reqjson))
    send_int4(session.socket, APICALL)
    send_int4(session.socket, length(d))
    write(session.socket, d)
    # flush(session.socket)

    pktlen = recv_int4(session.socket)
    res = JSON.parse(String(read(session.socket, pktlen)))

    res["ok"] ? res["res"] : error(res["res"])
end

end

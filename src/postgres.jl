module Postgres

using Sockets: connect!, TCPSocket

import Dates
using Decimals: decimal, Decimal
import JSON, HTTP

import ..Utils
using ..Utils: ThreadSafe

import ..PushGatewayExporter

struct Session
    socket::TCPSocket
    parameters::Dict{String, String}
    backend_key_data::Any
    prepared_statements::Dict{String, String}
end

struct PreparedStatement
    session::Session
    name::String
end

struct PGConnPool
    sessions::Vector{Session}
    free_sessions::Vector{Session}
end

mutable struct PGServer
    connstr::String
    tracking_url::String
    exception::Any
    function PGServer(; connstr="", tracking_url="")
        @assert !isempty(connstr) || !isempty(tracking_url)
        new(connstr, tracking_url, nothing)
    end
end

PRINT_EXCEPTIONS = Ref(true)
print_exceptions_lock = ReentrantLock()

SESSIONS_PER_POOL = Ref(20)
MAX_WAIT_FOR_SESSION = Ref(30.0)
MAX_WAIT_FOR_CONNECTION = Ref(5.0)

connpools = Dict{String, PGConnPool}() |> ThreadSafe
servers = Dict{Symbol, PGServer}() |> ThreadSafe

const USE_TASK_LOCAL_STORAGE = Ref(true)

pg_to_jl_type_conversion = Dict{Int32, Function}()
jl_to_pg_type_conversion = Dict{Type, Function}()

@inline function log_time(; kwargs...)
    println("$(Dates.now())  $(JSON.json(kwargs))")
end

function make_session(connstr::String)
    opts = Dict([map(string, split(s, '=')) for s in split(connstr, ' ') if !isempty(s)])

    tstart = time()
    io = TCPSocket()
    connect!(io, opts["host"], parse(Int, get(opts, "port", "5432")))
    while io.status != Base.StatusOpen
        if time() - tstart >= MAX_WAIT_FOR_CONNECTION[]
            close(io)
            throw(Base.IOError("postgres waiting too long for TCP connection", 1000))
        end
        sleep(0.2)
    end

    send_ssl_request(io)
    @assert recv_int1(io) == 0x4e

    send_startup_message(io, [
                              ("user", opts["user"]),
                              ("database", opts["dbname"]), 
                              ("application_name", "postgres.jl")
                             ])

    parameters = Dict{String, String}()
    backend_key_data = nothing
    while true
        msg = recv_message(io)
        if msg.type == :ready_for_query
            break
        elseif msg.type == :parameter_status
            parameters[msg.name] = msg.value
        elseif msg.type == :backend_key_data
            backend_key_data = (; msg.process_id, msg.secret_key)
        end
    end

    @assert parameters["client_encoding"] == "UTF8"
    @assert parameters["server_encoding"] == "UTF8"
    @assert parameters["DateStyle"] == "ISO, MDY"

    Session(io, parameters, backend_key_data, Dict{String, PreparedStatement}())
end

Base.close(session::Session) = close(session.socket)

function simple_test(io::IO)
    # rows = execute_simple(io, "select 123, 'abc', 'bcd'::varchar, true, null, '\\x1234'::bytea, now()::timestamp")
    # rows = execute_simple(io, "select * from app_settings limit 1000")
    @time rows = execute_simple(io, "select * from app_settings limit 100000")
    # rows = execute_simple(io, "select aaa")
    @show length(rows)
    recv_until(io, msg->msg.type == :ready_for_query)
    send_terminate(io)
    close(io)
end

function connection_pool_stats()
    lock(connpools) do connpools
        [connstr=>(; sessions=length(pool.sessions), free_sessions=length(pool.free_sessions))
         for (connstr, pool) in connpools]
    end
end

function get_connection_pool(connpools, connstr::String)
    pool = get!(connpools, connstr) do
        PGConnPool([], [])
    end
    new_sessions = asyncmap(_->make_session(connstr), 1:(SESSIONS_PER_POOL[] - length(pool.sessions)))
    if !isempty(new_sessions)
        append!(pool.sessions, new_sessions)
        append!(pool.free_sessions, new_sessions)
    end
    pool
end

function get_session(connstr::String)
    tstart = time()
    while true
        session = lock(connpools) do connpools
            pool = get_connection_pool(connpools, connstr)
            if isempty(pool.free_sessions)
                nothing
            else
                pop!(pool.free_sessions)
            end
        end
        if !isnothing(session)
            return session
        else
            sleep(0.05)
            if time() - tstart >= MAX_WAIT_FOR_SESSION[]
                error("postgres waiting on free session for too long")
            end
        end
    end
end

function free_session(connstr::String, session::Session)
    lock(connpools) do connpools
        pool = get_connection_pool(connpools, connstr)
        push!(pool.free_sessions, session)
    end
end

function remove_session(connstr, session)
    lock(connpools) do connpools
        pool = get_connection_pool(connpools, connstr)
        deleteat!(pool.sessions,      findfirst(sess->sess==session, pool.sessions))
        deleteat!(pool.free_sessions, findfirst(sess->sess==session, pool.free_sessions))
        get_connection_pool(connpools, connstr)
    end
end

function close_sessions(connstr)
    lock(connpools) do connpools
        pool = get_connection_pool(connpools, connstr)
        for session in pool.sessions
            try close(session) catch _ end
        end
        empty!(pool.sessions)
        empty!(pool.free_sessions)
    end
end

function close_servers()
    for server in collect(values(servers))
        close_sessions(server.connstr)
    end
end

function collect_io(body::Function)
    bio = IOBuffer()
    body(bio)
    take!(bio)
end

function write_collect(body::Function, io::IO)
    write(io, collect_io(body))
end

function recv_int1(io::IO)::UInt8
    read(io, UInt8)
end

function send_int1(io::IO, v::UInt8)
    write(io, v)
end

function recv_int2(io::IO)::Int16
    ntoh(read(io, Int16))
end

function send_int2(io::IO, v::Int16)
    write(io, hton(v))
end

function recv_int4(io::IO)::Int32
    ntoh(read(io, Int32))
end

function send_int4(io::IO, v)
    write(io, hton(Int32(v)))
end

function recv_string(io::IO)
    s = UInt8[]
    while true
        b = read(io, UInt8)
        b == 0x00 && break
        push!(s, b)
    end
    String(s)
end

function send_string(io::IO, v::String)
    write(io, v)
    write(io, 0x00)
end

function send_ssl_request(io::IO)
    write(io, [0x00, 0x00, 0x00, 0x08, 0x04, 0xd2, 0x16, 0x2f])
end

function send_startup_message(io::IO, params::Vector{Tuple{String, String}})
    payload = collect_io() do io
        send_int2(io, Int16(3))
        send_int2(io, Int16(0))
        for p in params
            send_string(io, p[1])
            send_string(io, p[2])
        end
        send_int1(io, 0x00)
    end

    write_collect(io) do io
        send_int4(io, 4+length(payload))
        write(io, payload)
    end
end

function send_message(io::IO, msg_type::Char, payload::Vector{UInt8})
    write_collect(io) do io
        send_int1(io, UInt8(msg_type))
        send_int4(io, 4+length(payload))
        write(io, payload)
    end
end

function send_simple_query(io::IO, query::String)
    send_message(io, 'Q', collect_io() do io
        send_string(io, query)
    end)
end

function recv_field_description(io::IO)
    field_name = recv_string(io)
    table_oid = recv_int4(io)
    column_index = recv_int2(io)
    type_oid = recv_int4(io)
    column_length = recv_int2(io)
    type_modifier = recv_int4(io)
    format_ = recv_int2(io)
    format = 
    if     format_ == 0; :text
    elseif format_ == 1; :binary
    else; error("postgres unknown field format")
    end
    (; field_name, table_oid, column_index, type_oid, column_length, type_modifier, format)
end

function send_terminate(io::IO)
    send_message(io, 'X', UInt8[])
end

function send_parse(io::IO, prepared_stmt_name, query)
    send_message(io, 'P', collect_io() do io
                     send_string(io, prepared_stmt_name)
                     send_string(io, query)
                     send_int2(io, Int16(0)) # number of parameters
                 end)
end

function send_sync(io::IO)
    send_message(io, 'S', UInt8[])
end

function send_bind(io::IO, prepared_stmt_name, params::Vector; portal="")
    send_message(io, 'B', collect_io() do io
                     send_string(io, portal)
                     send_string(io, prepared_stmt_name)

                     send_int2(io, Int16(1))
                     send_int2(io, Int16(0)) # text format for parameters

                     send_int2(io, Int16(length(params)))
                     for p in params
                         if p isa Missing || p isa Nothing
                             send_int4(io, -1)
                         else
                             s = 
                             if     p isa Bool; p ? "1" : "0"
                             elseif p isa Number; string(p)
                             elseif p isa String; p
                             elseif p isa Dates.DateTime; replace(string(p), 'T'=>' ')
                             elseif p isa Vector{UInt8}; "\\x" * bytes2hex(p)
                             else
                                 s = nothing
                                 for (ty, f) in jl_to_pg_type_conversion
                                     if p isa ty
                                         s = f(p)
                                         break
                                     end
                                 end
                                 isnothing(s) && error("postgres unsupported parameter type for bind: $(typeof(p))")
                                 s
                             end
                             d = collect(transcode(UInt8, s))
                             send_int4(io, length(d))
                             write(io, d)
                         end
                     end

                     send_int2(io, Int16(1))
                     send_int2(io, Int16(0)) # text format for all result columns
                 end)
end

function send_describe(io::IO; portal="")
    send_message(io, 'D', collect_io() do io
                     send_int1(io, UInt8('P'))
                     send_string(io, portal)
                 end)
end

function send_execute(io::IO; portal="", max_rows=0)
    send_message(io, 'E', collect_io() do io
                     send_string(io, portal)
                     send_int4(io, max_rows) # max_rows=0 returns all rows
                 end)
end

function send_cancel_request(io::IO, process_id, secret_key)
    write_collect(io) do io
        send_int4(16)
        send_int4(80877102)
        send_int4(process_id)
        send_int4(secret_key)
    end
end

struct PostgresException <: Exception
    fields::Dict{Char, String}
end

function recv_message(io::IO)
    msg_type = recv_int1(io)
    msg_len = recv_int4(io)
    payload = read(io, msg_len-4)
    io = IOBuffer(payload)

    msg = 
    if     msg_type == UInt8('R')
        recv_int4(io) != 0 && error("postgres auth failed")
        (; type=:authentication_ok)

    elseif msg_type == UInt8('S')
        name = recv_string(io)
        value = recv_string(io)
        (; type=:parameter_status, name, value)

    elseif msg_type == UInt8('K')
        process_id = recv_int4(io)
        secret_key = recv_int4(io)
        (; type=:backend_key_data, process_id, secret_key)

    elseif msg_type == UInt8('Z')
        st = recv_int1(io)
        status = 
        if     st == UInt8('I'); :idle
        elseif st == UInt8('T'); :transaction_block
        elseif st == UInt8('E'); :failed_transaction_block
        else; error("postgres unknown status: $st")
        end
        (; type=:ready_for_query, status)

    elseif msg_type == UInt8('T')
        field_count = recv_int2(io)
        fields = [recv_field_description(io) for _ in 1:field_count]
        (; type=:row_description, fields)

    elseif msg_type == UInt8('D')
        field_count = recv_int2(io)
        fields = []
        for _ in 1:field_count
            len = recv_int4(io)
            push!(fields, len > 0 ? read(io, len) : missing)
        end
        (; type=:data_row, fields)

    elseif msg_type == UInt8('C')
        tag = recv_string(io)
        (; type=:command_complete, tag)

    elseif msg_type == UInt8('E') || msg_type == UInt8('N')
        fields = []
        while true
            field_type = recv_int1(io)
            if field_type == 0x00
                break
            else
                push!(fields, (Char(field_type), recv_string(io)))
            end
        end
        (; type=msg_type == UInt8('E') ? :error_response : :notice_response, fields)

    elseif msg_type == UInt8('1')
        (; type=:parse_complete)

    elseif msg_type == UInt8('2')
        (; type=:bind_complete)

    elseif msg_type == UInt8('n')
        (; type=:no_data)

    elseif msg_type == UInt8('A')
        process_id = recv_int4(io)
        channel = recv_string(io)
        notif_payload = recv_string(io)
        (; type=:notification_response, process_id, channel, payload=notif_payload)

    else
        error("postgres unknown message received: $msg_type")
        (; type=:unknown_message, payload)

    end

    msg
end

function recv_rows(io::IO)
    columns = nothing
    rows = Any[]
    row_desc = nothing
    while true
        msg = recv_message(io)
        if msg.type == :command_complete
            break
        elseif msg.type == :error_response
            throw(PostgresException(Dict(msg.fields)))
        elseif msg.type == :notice_response
            for (ft, fd) in msg.fields
                ft == 'M' && println("postgres notice: $fd")
            end
        elseif msg.type == :row_description
            row_desc = msg.fields
            # dump(row_desc)
            columns = [f.field_name for f in row_desc]
            
        elseif msg.type == :data_row
            push!(rows, Any[f.format != :text ? d : 
                            if     ismissing(d) || isnothing(d); d
                            elseif f.type_oid == 16; String(d) == "t" # bool
                            elseif f.type_oid == 17 # bytea
                                @assert d[1] == UInt8('\\') && d[2] == UInt8('x')
                                hex2bytes(d[3:end])
                            elseif f.type_oid == 20; parse(Int, String(d)) # int8
                            elseif f.type_oid == 23; parse(Int, String(d)) # int4
                            elseif f.type_oid == 25; String(d) # text
                            elseif f.type_oid == 114; String(d) # json
                            elseif f.type_oid == 700; parse(Float64, String(d)) # float4
                            elseif f.type_oid == 1043; String(d) # varchar
                            elseif f.type_oid == 1114; Dates.DateTime(first(replace(String(d), ' '=>'T'), 23)) # timestamp
                            elseif f.type_oid == 1700; decimal(String(d)) # numeric
                            elseif f.type_oid == 3802; String(d) # jsonb
                            elseif haskey(pg_to_jl_type_conversion, f.type_oid); pg_to_jl_type_conversion[f.type_oid](d)
                            else; @show (; type_oid=f.type_oid, data=d)
                            end
                            for (f, d) in zip(row_desc, msg.fields)])
        end
    end
    recv_until(io, msg->msg.type == :ready_for_query)
    (columns, rows)
end

function recv_until(io::IO, cond::Function=(msg) -> msg.type == :command_complete)
    while true
        msg = recv_message(io)
        if cond(msg)
            break
        elseif msg.type == :error_response
            for (ft, fd) in msg.fields
                ft == 'M' && error("postgres error response: $fd")
            end
            error("postgres error response: $(msg.fields)")
        end
    end
end

function execute_simple(io::IO, query::String)
    send_simple_query(io, query)
    recv_rows(io)
end

function handle_errors(body::Function, connstr::String)
    try
        session = get_session(connstr)
        try
            body(session)
        finally
            free_session(connstr, session)
        end
    catch ex 
        PRINT_EXCEPTIONS[] && lock(print_exceptions_lock) do
            Utils.print_exceptions()
        end
        if ex isa Base.IOError
            close_sessions(connstr)
            sleep(10)
        end
        rethrow()
    end
end

function handle_errors(body::Function, server::Symbol)
    handle_errors(body, servers[server].connstr)
end

function transaction(body::Function, server::Symbol=:default)
    handle_errors(server) do session
        execute(session, "begin")
        res = nothing
        try
            res = body(session)
        catch _
            execute(session, "rollback")
            rethrow()
        end
        execute(session, "commit")
        res
    end
end

function transaction_tls(body::Function, server::Symbol=:default)
    if isnothing(get(task_local_storage(), (:postgres_transaction_session, server), nothing))
        transaction(server) do session
            task_local_storage((:postgres_transaction_session, server), session) do 
                body()
            end
        end
    else
        body()
    end
end

function prepare(session::Session, query::String)
    PreparedStatement(session, 
                      get!(session.prepared_statements, query) do
                          stmt_name = "__pg_stmt_$(length(session.prepared_statements)+1)__"
                          write_collect(session.socket) do io
                              send_parse(io, stmt_name, query)
                              send_sync(io)
                          end
                          recv_until(session.socket, msg->msg.type == :parse_complete)
                          stmt_name
                      end)
end

function execute_simple(session::Session, query::String)
    send_simple_query(session.socket, query)
    recv_rows(session.socket)
end

function execute(connstr::String, query::String)
    handle_errors(connstr) do session
        execute(session, query)
    end
end

function execute(prepared_stmt::PreparedStatement, params::Any=[])
    params = collect(params)
    session = prepared_stmt.session
    write_collect(session.socket) do io
        send_bind(io, prepared_stmt.name, params)
        send_describe(io)
        send_execute(io)
        send_sync(io)
    end
    recv_until(session.socket, msg->msg.type == :bind_complete)
    recv_rows(session.socket)
end

function execute(session::Session, query::String, params::Any=[])
    try
        if '$' in query
            execute(prepare(session, query), params)
        else
            @assert isempty(params)
            execute_simple(session, query)
        end
    catch _
        PRINT_EXCEPTIONS[] && lock(print_exceptions_lock) do
            @show (query, params)
        end
        rethrow()
    end
end

function execute(server::Symbol, query::String, params::Any=[])
    if USE_TASK_LOCAL_STORAGE[]
        if !isnothing(local session = get(task_local_storage(), (:postgres_transaction_session, server), nothing))
            return execute(session, query, params)
        end
    end

    handle_errors(server) do session
        execute(session, query, params)
    end
end

function monitoring()
    PushGatewayExporter.set!("postgres_min_free_sessions", 
                             minimum([v.free_sessions for (_, v) in connection_pool_stats()]))
end

function server_tracking()
    connstrs = Set()

    for server in collect(values(servers))
        if isempty(server.tracking_url) && !isempty(server.connstr)
            push!(connstrs, server.connstr)
        else
            d = JSON.parse(String(HTTP.request("GET", server.tracking_url; retry=false, timeout=5, connect_timeout=5).body))
            session = make_session(d["postgres"])
            try
                if execute(session, "select pg_is_in_recovery()")[2][1][1]
                    execute(session, "select pg_promote()")
                end
                server.connstr = d["primal"]
                push!(connstrs, server.connstr)
            finally
                try close(session) catch _ end
            end
        end
    end

    for connstr in collect(keys(connpools))
        if !(connstr in connstrs)
            close_sessions(connstr)
            delete!(connpools, connstr)
        end
    end
end

tasks = [(monitoring, 15.0), (server_tracking, 1.0)]

function start()
    for (f, period) in tasks
        Utils.start_periodic_tasked(f, period)
    end
end

function stop()
    for (f, period) in tasks
        Utils.stop_periodic_tasked(f)
    end
end

end

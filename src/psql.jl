#module DB

import LibPQ
struct LibPQConn <: DBConn
    dbs::Vector{LibPQ.Connection} # one DB connection per thread
    # stmts::Vector...
    LibPQConn(dbs) = new(dbs)
end

exe_replacing_args(conn::LibPQ.Connection, query, args...) = LibPQ.execute(conn, replace(query, "?"=>"\$"), args...)

function exe(conn::LibPQ.Connection, query, args...) 
    r = try
        exe_replacing_args(conn, query, args...)
    catch ex
        if ex isa LibPQ.Errors.UnknownError
            try
                LibPQ.reset!(conn)
            catch ex2
                @warn "conn reset failed"
                rethrow(ex2)
            end
            try
                exe_replacing_args(conn, query, args...)
            catch ex3
                @warn "second exe_replacing_args invocation failed"
                rethrow(ex3)
            end
        elseif ex isa LibPQ.Errors.PostgreSQLException
            try exe(conn, "abort") catch _ end
            rethrow(ex)
        else
            rethrow(ex)
        end
    end
    map(collect, r)
end

# exe(conn::ThreadSafe{LibPQConn}, args...) = exe(conn.wrapped, args...)
exe(conn::ThreadSafe{LibPQConn}, args...) = lock(conn) do conn; exe(conn, args...); end
exe(conn::LibPQConn, args...) = exe(conn.dbs[Threads.threadid()], args...)

exd(conn::LibPQ.Connection, query, args...) = [NamedTuple(zip(propertynames(row), collect(row))) 
                                               for row in exe_replacing_args(conn, query, args...)]
exd(conn::ThreadSafe{LibPQConn}, args...) = lock(conn) do conn; exd(conn, args...); end
exd(conn::LibPQConn, args...) = exd(conn.dbs[Threads.threadid()], args...)

struct PQDict{K, V} <: ShardedDBDict{K, V}
    table::String
    keycolumn::String
    valuecolumn::String
    dbconns::Vector{ThreadSafe{LibPQConn}}
    hashfunc::Function
    keyfuncs::DBConversionFuncs
    valuefuncs::DBConversionFuncs
    function PQDict{K, V}(table::String,
                          connstr::String;
                          keycolumn="key",
                          valuecolumn="value",
                          keysqltype::String=sqltype(PQDict{K, V}, K),
                          valuesqltype::String=sqltype(PQDict{K, V}, V),
                          hashfunc::Function=(x)->0,
                          keyfuncs::DBConversionFuncs=db_conversion_funcs(PQDict{K, V}, K),
                          valuefuncs::DBConversionFuncs=db_conversion_funcs(PQDict{K, V}, V),
                          init_extra_columns="",
                          init_extra_indexes=String[],
                          init_queries=vcat(["create table if not exists $table ($keycolumn $keysqltype primary key not null, $valuecolumn $valuesqltype $init_extra_columns)"
                                             "create index if not exists $(table)_$(keycolumn) on $table ($keycolumn asc)"],
                                            init_extra_indexes),
                         ) where {K, V}
        dbconn = LibPQConn([LibPQ.Connection(connstr) for _ in 1:Threads.nthreads()])
        for q in init_queries
            exe(dbconn.dbs[1], q)
        end
        new{K, V}(table, keycolumn, valuecolumn, [dbconn |> ThreadSafe], hashfunc, keyfuncs, valuefuncs)
    end
end

sqltype(::Type{PQDict{K, V}}, ::Type{Bool}) where {K, V} = "boolean"
sqltype(::Type{PQDict{K, V}}, ::Type{Int}) where {K, V} = "int8"
sqltype(::Type{PQDict{K, V}}, ::Type{String}) where {K, V} = "text"
sqltype(::Type{PQDict{K, V}}, ::Type{Symbol}) where {K, V} = "varchar(500)"
sqltype(::Type{PQDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = "bytea"
sqltype(::Type{PQDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = "bytea"
sqltype(::Type{PQDict{K, V}}, ::Type{Nostr.Event}) where {K, V} = "text"
sqltype(::Type{PQDict{K, V}}, ::Type{Dates.DateTime}) where {K, V} = "timestamp"
sqltype(::Type{PQDict{K, V}}, ::Type{Base.UUID}) where {K, V} = "uuid"

db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Missing}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Nothing}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Bool}) where {K, V} = DBConversionFuncs(x->Int(x), x->Bool(x))
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Int}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Float64}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{String}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Symbol}) where {K, V} = DBConversionFuncs(x->string(x), x->Symbol(x))
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = DBConversionFuncs(eid->collect(eid.hash), eid->Nostr.EventId(eid))
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = DBConversionFuncs(pk->collect(pk.pk), pk->Nostr.PubKeyId(pk))
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Nostr.Event}) where {K, V} = DBConversionFuncs(JSON.json, e->Nostr.Event(JSON.parse(e)))
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Dates.DateTime}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Dict{String, Any}}) where {K, V} = DBConversionFuncs(JSON.json, s->JSON.parse(s))
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Vector{UInt8}}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Vector{Any}}) where {K, V} = DBConversionFuncs(JSON.json, s->JSON.parse(s))
db_conversion_funcs(::Type{PQDict{K, V}}, ::Type{Base.UUID}) where {K, V} = DBConversionFuncs(string, s->Base.UUID(s))

LibPQ.string_parameter(v::Vector{UInt8}) = string("\\x", bytes2hex(v))
LibPQ.string_parameter(v::Tuple) = string("(", join(v, ","), ")")

LibPQ.LIBPQ_TYPE_MAP.type_map[LibPQ.oid(:uuid)] = Base.UUID
LibPQ.LIBPQ_CONVERSIONS.func_map[(LibPQ.oid(:uuid), Base.UUID)] = x->Base.UUID(LibPQ.string_view(x))

function Base.setindex!(ssd::PQDict{K, V}, v::V, k::K)::V where {K, V}
    exe(ssd.dbconns[shard(ssd, k)],
        @sql("INSERT INTO $(ssd.table) ($(ssd.keycolumn), $(ssd.valuecolumn))
              VALUES (\$1, \$2)
              ON CONFLICT ($(ssd.keycolumn)) DO UPDATE 
              SET $(ssd.valuecolumn) = excluded.$(ssd.valuecolumn)
              "),
        (ssd.keyfuncs.to_sql(k), ssd.valuefuncs.to_sql(v)))
    v
end

function exd(ssd::PQDict{K, V}, query_rest::String, args...)::Vector where {K, V}
    @assert length(ssd.dbconns) == 1
    exd(ssd.dbconns[1], "select * from $(ssd.table) $query_rest", db_args_mapped(typeof(ssd), args))
end

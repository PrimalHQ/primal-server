#module DB

import ..Postgres

ConnSelector = Union{String,Symbol}

struct PGConnection
    connsel::ConnSelector
end

struct PGConn <: DBConn
    dbs::Vector{PGConnection} # just one element
    PGConn(dbs) = new(dbs)
end

function exe_replacing_args(conn::PGConnection, query, args...) 
    Postgres.execute(conn.connsel, replace(query, "?"=>"\$"), args...)
end
function exe(conn::PGConnection, query, args...) 
    _, rows = exe_replacing_args(conn, query, args...)
    rows
end

# exe(conn::ThreadSafe{PGConn}, args...) = exe(conn.wrapped, args...)
exe(conn::ThreadSafe{PGConn}, args...) = lock(conn) do conn; exe(conn, args...); end
exe(conn::PGConn, args...) = exe(conn.dbs[1], args...)

function exd(conn::PGConnection, query, args...)
    columns, rows = exe_replacing_args(conn, query, args...)
    columns = map(Symbol, columns)
    [NamedTuple(zip(columns, row)) for row in rows]
end
exd(conn::ThreadSafe{PGConn}, args...) = lock(conn) do conn; exd(conn, args...); end
exd(conn::PGConn, args...) = exd(conn.dbs[1], args...)

struct PGDict{K, V} <: ShardedDBDict{K, V}
    table::String
    keycolumn::String
    valuecolumn::String
    dbconns::Vector{ThreadSafe{PGConn}}
    hashfunc::Function
    keyfuncs::DBConversionFuncs
    valuefuncs::DBConversionFuncs
    function PGDict{K, V}(table::String,
                           connsel::ConnSelector;
                           keycolumn="key",
                           valuecolumn="value",
                           keysqltype::String=sqltype(PGDict{K, V}, K),
                           valuesqltype::String=sqltype(PGDict{K, V}, V),
                           hashfunc::Function=(x)->0,
                           keyfuncs::DBConversionFuncs=db_conversion_funcs(PGDict{K, V}, K),
                           valuefuncs::DBConversionFuncs=db_conversion_funcs(PGDict{K, V}, V),
                           init_extra_columns="",
                           init_extra_indexes=String[],
                           init_queries=vcat(["create table if not exists $table ($keycolumn $keysqltype primary key not null, $valuecolumn $valuesqltype $init_extra_columns)"
                                              "create index if not exists $(table)_$(keycolumn) on $table ($keycolumn asc)"],
                                             init_extra_indexes),
                         ) where {K, V}
        dbconn = PGConn([PGConnection(connsel)])
        for q in init_queries
            exe(dbconn.dbs[1], q)
        end
        new{K, V}(table, keycolumn, valuecolumn, [dbconn |> ThreadSafe], hashfunc, keyfuncs, valuefuncs)
    end
end

sqltype(::Type{PGDict{K, V}}, ::Type{Bool}) where {K, V} = "boolean"
sqltype(::Type{PGDict{K, V}}, ::Type{Int}) where {K, V} = "int8"
sqltype(::Type{PGDict{K, V}}, ::Type{String}) where {K, V} = "text"
sqltype(::Type{PGDict{K, V}}, ::Type{Symbol}) where {K, V} = "varchar(500)"
sqltype(::Type{PGDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = "bytea"
sqltype(::Type{PGDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = "bytea"
sqltype(::Type{PGDict{K, V}}, ::Type{Nostr.Event}) where {K, V} = "text"
sqltype(::Type{PGDict{K, V}}, ::Type{Dates.DateTime}) where {K, V} = "timestamp"
sqltype(::Type{PGDict{K, V}}, ::Type{Base.UUID}) where {K, V} = "uuid"

db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Missing}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Nothing}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Bool}) where {K, V} = DBConversionFuncs(x->Int(x), x->Bool(x))
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Int}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Float64}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{String}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Symbol}) where {K, V} = DBConversionFuncs(x->string(x), x->Symbol(x))
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = DBConversionFuncs(eid->collect(eid.hash), eid->Nostr.EventId(eid))
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = DBConversionFuncs(pk->collect(pk.pk), pk->Nostr.PubKeyId(pk))
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Nostr.Event}) where {K, V} = DBConversionFuncs(JSON.json, e->Nostr.Event(JSON.parse(e)))
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Dates.DateTime}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Dict{String, Any}}) where {K, V} = DBConversionFuncs(JSON.json, s->JSON.parse(s))
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Vector{UInt8}}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Vector{Any}}) where {K, V} = DBConversionFuncs(JSON.json, s->JSON.parse(s))
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{Base.UUID}) where {K, V} = DBConversionFuncs(string, s->Base.UUID(s))

# Postgres.jl_to_pg_type_conversion[Any] = string
# Postgres.jl_to_pg_type_conversion[Tuple] = v->string("(", join(v, ","), ")")
Postgres.jl_to_pg_type_conversion[Nostr.EventId] = v -> "\\x" * bytes2hex(collect(v.hash))
Postgres.jl_to_pg_type_conversion[Nostr.PubKeyId] = v -> "\\x" * bytes2hex(collect(v.pk))

Postgres.pg_to_jl_type_conversion[2950] = d->Base.UUID(String(d))

function Base.setindex!(ssd::PGDict{K, V}, v::V, k::K)::V where {K, V}
    exe(ssd.dbconns[shard(ssd, k)],
        @sql("INSERT INTO $(ssd.table) ($(ssd.keycolumn), $(ssd.valuecolumn))
              VALUES (\$1, \$2)
              ON CONFLICT ($(ssd.keycolumn)) DO UPDATE 
              SET $(ssd.valuecolumn) = excluded.$(ssd.valuecolumn)
              "),
        (ssd.keyfuncs.to_sql(k), ssd.valuefuncs.to_sql(v)))
    v
end

function exd(ssd::PGDict{K, V}, query_rest::String, args...)::Vector where {K, V}
    @assert length(ssd.dbconns) == 1
    exd(ssd.dbconns[1], "select * from $(ssd.table) $query_rest", db_args_mapped(typeof(ssd), args))
end

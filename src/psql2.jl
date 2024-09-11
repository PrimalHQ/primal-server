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

function exe_replacing_args(conn::PGConnection, query::Int, args...) 
    exe_replacing_args(conn, registered_queries[query], args...)
end
function exe_replacing_args(conn::PGConnection, query::String, args...) 
    # @show (query, args)
    tdur = @elapsed res = Postgres.execute(conn.connsel, replace(query, "?"=>"\$"), args...)
    tdur > SLOW_QUERY_TIME[] && @show (:slow_psql2_query, tdur, replace(query, "?"=>"\$"), args...)
    res
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
    dbqueries::Vector{String}
    function PGDict{K, V}(;
                           connsel::ConnSelector,
                           table::String,

                           keycolumn="key",
                           valuecolumn="value",
                           keysqltype::String=sqltype(PGDict{K, V}, K),
                           valuesqltype::String=sqltype(PGDict{K, V}, V),
                           hashfunc::Function=(x)->0,
                           keyfuncs::DBConversionFuncs=db_conversion_funcs(PGDict{K, V}, K),
                           valuefuncs::DBConversionFuncs=db_conversion_funcs(PGDict{K, V}, V),
                           init_extra_columns="",
                           init_extra_indexes=String[],
                           init_queries=vcat(["create table if not exists $table ($keycolumn $keysqltype primary key not null, $valuecolumn $valuesqltype $init_extra_columns)",
                                              # "create index if not exists $(table)_$(keycolumn)_idx on $table ($keycolumn asc)",
                                              "alter table $(table) add primary key ($(keycolumn))",
                                             ],
                                             init_extra_indexes),
                           skipinit=false,
                         ) where {K, V}
        dbconn = PGConn([PGConnection(connsel)])
        if !skipinit && !exe(dbconn.dbs[1], "select pg_is_in_recovery()")[1][1]
            for q in init_queries
                if startswith(q, '!')
                    q = replace(q[2:end], " blob"=>" bytea", " int"=>" int8", " number"=>" float8")
                end
                table_exists = !isempty(exe(dbconn.dbs[1], "select 1 from pg_tables where tablename = ?1 and schemaname = 'public'", (table,)))
                view_exists = !isempty(exe(dbconn.dbs[1], "select 1 from pg_views where viewname = ?1 and schemaname = 'public'", (table,)))
                view_exists && continue
                if !occursin("add primary key", q) || isempty(exe(dbconn.dbs[1], "select constraint_name from information_schema.table_constraints where table_name = '$table' and constraint_type = 'PRIMARY KEY'"))
                    exe(dbconn.dbs[1], q)
                end
            end
        end
        ssd = new{K, V}(table, keycolumn, valuecolumn, [dbconn |> ThreadSafe], hashfunc, keyfuncs, valuefuncs, [])
        append!(ssd.dbqueries, mkdbqueries(ssd))
        ssd
    end
end

function PSQLSet(K::Type, table::String; kwargs...)
    PGDict{K, Bool}(; table, kwargs...)
end

function PSQLDict(K::Type, V::Type, table::String; kwargs...)
    PGDict{K, V}(; table, kwargs...)
end

sqltype(::Type{PGDict{K, V}}, ::Type{Bool}) where {K, V} = "boolean"
sqltype(::Type{PGDict{K, V}}, ::Type{Int}) where {K, V} = "int8"
sqltype(::Type{PGDict{K, V}}, ::Type{Float64}) where {K, V} = "float8"
sqltype(::Type{PGDict{K, V}}, ::Type{String}) where {K, V} = "text"
sqltype(::Type{PGDict{K, V}}, ::Type{Symbol}) where {K, V} = "varchar(500)"
sqltype(::Type{PGDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = "bytea"
sqltype(::Type{PGDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = "bytea"
sqltype(::Type{PGDict{K, V}}, ::Type{Vector{UInt8}}) where {K, V} = "bytea"
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

Postgres.pg_to_jl_type_conversion[114] = v -> JSON.parse(String(v))
Postgres.pg_to_jl_type_conversion[3802] = v -> JSON.parse(String(v))

function Base.setindex!(ssd::PGDict{K, V}, v::V, k::K)::V where {K, V}
    exe(ssd.dbconns[shard(ssd, k)],
        ssd.dbqueries[@dbq("INSERT INTO $(ssd.table) ($(ssd.keycolumn), $(ssd.valuecolumn))
                           VALUES (\$1, \$2)
                           ON CONFLICT ($(ssd.keycolumn)) DO UPDATE 
                           SET $(ssd.valuecolumn) = excluded.$(ssd.valuecolumn)
                           ")],
        (ssd.keyfuncs.to_sql(k), ssd.valuefuncs.to_sql(v)))
    v
end

function exd(ssd::PGDict{K, V}, query_rest::String, args...)::Vector where {K, V}
    @assert length(ssd.dbconns) == 1
    exd(ssd.dbconns[1], "select * from $(ssd.table) $query_rest", db_args_mapped(typeof(ssd), args))
end

function Base.close(conn::PGConnection) end

##

function Base.setindex!(ssd::PGDict{Nostr.EventId, Nostr.Event}, v::Nostr.Event, k::Nostr.EventId)
    @assert v.id == k
    exe(ssd.dbconns[shard(ssd, k)],
           "INSERT INTO $(ssd.table) (
               $(ssd.keycolumn),
               pubkey,
               created_at,
               kind,
               tags,
               content,
               sig,
               imported_at 
           ) VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
           ON CONFLICT ($(ssd.keycolumn)) DO UPDATE 
           SET 
               pubkey      = excluded.pubkey,
               created_at  = excluded.created_at,
               kind        = excluded.kind,
               tags        = excluded.tags,
               content     = excluded.content,
               sig         = excluded.sig,
               imported_at = excluded.imported_at
           ",
           (
            collect(v.id.hash), 
            collect(v.pubkey.pk),
            v.created_at,
            v.kind,
            JSON.json(v.tags),
            v.content,
            collect(v.sig.sig),
            Utils.current_time(),
           ))
    v
end

function mkevents(dbargs; 
        init_queries=["create table if not exists events (
                      id          bytea  primary key not null,
                      pubkey      bytea  not null,
                      created_at  int8   not null,
                      kind        int8   not null,
                      tags        jsonb  not null,
                      content     text   not null,
                      sig         bytea  not null,
                      imported_at int8   not null
                      )",
                      "create index if not exists events_created_at_idx on events (created_at)",
                      "create index if not exists events_created_at_kind_idx on events (created_at, kind)",
                      "create index if not exists events_imported_at_idx on events (imported_at)",
                      "create index if not exists events_kind_idx on events (kind)",
                      "create index if not exists events_pubkey_idx on events (pubkey)",
                     ])
    PSQLDict(Nostr.EventId, Nostr.Event, "events"; dbargs...,
                keycolumn="id", 
                valuecolumn="json_build_object('id', encode(id, 'hex'), 'pubkey', encode(pubkey, 'hex'), 'created_at', created_at, 'kind', kind, 'tags', tags, 'content', content, 'sig', encode(sig, 'hex'))::text",
                init_queries)
end


#module DB

struct PGSPIConnection end

struct PGSPIConn <: DBConn
    dbs::Vector{PGSPIConnection} # just one element
    PGSPIConn(dbs) = new(dbs)
end

pg_spi_plans = Dict{Tuple{String, Vector{DataType}}, Main.SPIPlan}()
pg_spi_readonly = Ref(true)

function exe_replacing_args(conn::PGSPIConnection, query::Int, args=()) 
    exe_replacing_args(conn, registered_queries[query], args) 
end
function exe_replacing_args(conn::PGSPIConnection, query::String, args=()) 
    # println()
    # @show (query, args)
    tdur = @elapsed res = if isempty(args)
        Main.spi_execute(query; readonly=pg_spi_readonly[])
    else
        query = replace(query, "?"=>"\$")
        tys = [typeof(a) for a in args]
        plan = get!(pg_spi_plans, (query, tys)) do
            # @show (:prep, (query, tys))
            Main.spi_prepare(query, tys)
        end
        Main.spi_execute_plan(plan, collect(args); readonly=pg_spi_readonly[])
    end
    tdur > SLOW_QUERY_TIME[] && @show (:slow_psql2_execute, tdur, query, args)
    return res
end
function exe(conn::PGSPIConnection, query, args...) 
    _, rows = exe_replacing_args(conn, query, args...)
    rows
end

# exe(conn::ThreadSafe{PGSPIConn}, args...) = exe(conn.wrapped, args...)
exe(conn::ThreadSafe{PGSPIConn}, args...) = lock(conn) do conn; exe(conn, args...); end
exe(conn::PGSPIConn, args...) = exe(conn.dbs[1], args...)

function exd(conn::PGSPIConnection, query, args...)
    columns, rows = exe_replacing_args(conn, query, args...)
    columns = map(Symbol, columns)
    [NamedTuple(zip(columns, row)) for row in rows]
end
exd(conn::ThreadSafe{PGSPIConn}, args...) = lock(conn) do conn; exd(conn, args...); end
exd(conn::PGSPIConn, args...) = exd(conn.dbs[1], args...)

struct PGSPIDict{K, V} <: ShardedDBDict{K, V}
    table::String
    keycolumn::String
    valuecolumn::String
    dbconns::Vector{ThreadSafe{PGSPIConn}}
    hashfunc::Function
    keyfuncs::DBConversionFuncs
    valuefuncs::DBConversionFuncs
    dbqueries::Vector{String}
    function PGSPIDict{K, V}(;
                           table::String,

                           keycolumn="key",
                           valuecolumn="value",
                           keysqltype::String=sqltype(PGSPIDict{K, V}, K),
                           valuesqltype::String=sqltype(PGSPIDict{K, V}, V),
                           hashfunc::Function=(x)->0,
                           keyfuncs::DBConversionFuncs=db_conversion_funcs(PGSPIDict{K, V}, K),
                           valuefuncs::DBConversionFuncs=db_conversion_funcs(PGSPIDict{K, V}, V),
                           init_extra_columns="",
                           init_extra_indexes=String[],
                           init_queries=vcat(["create table if not exists $table ($keycolumn $keysqltype primary key not null, $valuecolumn $valuesqltype $init_extra_columns)"
                                              "create index if not exists $(table)_$(keycolumn) on $table ($keycolumn asc)"],
                                             init_extra_indexes),
                         ) where {K, V}
        dbconn = PGSPIConn([PGSPIConnection()])
        ssd = new{K, V}(table, keycolumn, valuecolumn, [dbconn |> ThreadSafe], hashfunc, keyfuncs, valuefuncs, [])
        append!(ssd.dbqueries, mkdbqueries(ssd))
        ssd
    end
end

function PSQLSPISet(K::Type, table::String; kwargs...)
    PGSPIDict{K, Bool}(; table, kwargs...)
end

function PSQLSPIDict(K::Type, V::Type, table::String; kwargs...)
    PGSPIDict{K, V}(; table, kwargs...)
end

sqltype(::Type{PGSPIDict{K, V}}, ::Type{Bool}) where {K, V} = "boolean"
sqltype(::Type{PGSPIDict{K, V}}, ::Type{Int}) where {K, V} = "int8"
sqltype(::Type{PGSPIDict{K, V}}, ::Type{String}) where {K, V} = "text"
sqltype(::Type{PGSPIDict{K, V}}, ::Type{Symbol}) where {K, V} = "varchar(500)"
sqltype(::Type{PGSPIDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = "bytea"
sqltype(::Type{PGSPIDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = "bytea"
sqltype(::Type{PGSPIDict{K, V}}, ::Type{Nostr.Event}) where {K, V} = "text"
sqltype(::Type{PGSPIDict{K, V}}, ::Type{Dates.DateTime}) where {K, V} = "timestamp"
sqltype(::Type{PGSPIDict{K, V}}, ::Type{Base.UUID}) where {K, V} = "uuid"

db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Missing}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Nothing}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Bool}) where {K, V} = DBConversionFuncs(x->Int(x), x->Bool(x))
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Int}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Float64}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{String}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Symbol}) where {K, V} = DBConversionFuncs(x->string(x), x->Symbol(x))
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = DBConversionFuncs(eid->collect(eid.hash), eid->Nostr.EventId(eid))
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = DBConversionFuncs(pk->collect(pk.pk), pk->Nostr.PubKeyId(pk))
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Nostr.Event}) where {K, V} = DBConversionFuncs(JSON.json, e->Nostr.Event(JSON.parse(e)))
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Dates.DateTime}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Dict{String, Any}}) where {K, V} = DBConversionFuncs(JSON.json, s->JSON.parse(s))
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Vector{UInt8}}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Vector{Any}}) where {K, V} = DBConversionFuncs(JSON.json, s->JSON.parse(s))
db_conversion_funcs(::Type{PGSPIDict{K, V}}, ::Type{Base.UUID}) where {K, V} = DBConversionFuncs(string, s->Base.UUID(s))

# Postgres.jl_to_pg_type_conversion[Any] = string
# Postgres.jl_to_pg_type_conversion[Tuple] = v->string("(", join(v, ","), ")")
Postgres.jl_to_pg_type_conversion[Nostr.EventId] = v -> "\\x" * bytes2hex(collect(v.hash))
Postgres.jl_to_pg_type_conversion[Nostr.PubKeyId] = v -> "\\x" * bytes2hex(collect(v.pk))

Postgres.pg_to_jl_type_conversion[2950] = d->Base.UUID(String(d))

Postgres.pg_to_jl_type_conversion[114] = v -> JSON.parse(String(v))
Postgres.pg_to_jl_type_conversion[3802] = v -> JSON.parse(String(v))

function Base.setindex!(ssd::PGSPIDict{K, V}, v::V, k::K)::V where {K, V}
    exe(ssd.dbconns[shard(ssd, k)],
        ssd.dbqueries[@dbq("INSERT INTO $(ssd.table) ($(ssd.keycolumn), $(ssd.valuecolumn))
                           VALUES (\$1, \$2)
                           ON CONFLICT ($(ssd.keycolumn)) DO UPDATE 
                           SET $(ssd.valuecolumn) = excluded.$(ssd.valuecolumn)
                           ")],
        (ssd.keyfuncs.to_sql(k), ssd.valuefuncs.to_sql(v)))
    v
end

function exd(ssd::PGSPIDict{K, V}, query_rest::String, args...)::Vector where {K, V}
    @assert length(ssd.dbconns) == 1
    exd(ssd.dbconns[1], "select * from $(ssd.table) $query_rest", db_args_mapped(typeof(ssd), args))
end

function Base.close(conn::PGSPIConnection) end


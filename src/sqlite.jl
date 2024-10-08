#module DB

import SQLite, DBInterface, JSON

import ..PerfStats

struct SQLiteConn <: DBConn
    dbs::Vector{SQLite.DB} # one DB connection per thread
    stmts::Vector{Union{Nothing, SQLite.Stmt}}
    SQLiteConn(dbs) = new(dbs, [])
end

function get_stmt(conn::SQLiteConn, query::Int)
    for i in length(conn.stmts)+1:query
        push!(conn.stmts, nothing)
    end
    stmt = conn.stmts[query]
    if isnothing(stmt)
        q = registered_queries[query]
        try
            stmt = conn.stmts[query] = DBInterface.prepare(conn.dbs[Threads.threadid()], q)
        catch ex
            println("exception: $(ex), for query $(repr(q))")
            rethrow()
        end
    end
    stmt
end

function exe(body::Function, conn::SQLiteConn, query::Int, args...)
    # PerfStats.record!(:sqlite_queries, query) do
        stmt = get_stmt(conn, query)
        DBInterface.execute(body, stmt, args...)
    # end
end
function exe(body::Function, db::SQLiteConn, query::String, args...)
    # dbname = split(db.dbs[1].file, '/')[end-1]
    # PerfStats.record!(:sqlite_queries, (dbname, query)) do
        # DBInterface.execute(body, db.db, query, args...)
        DBInterface.execute(body, db.dbs[Threads.threadid()], query, args...)
    # end
end

asvector(q::SQLite.Query) = map(collect, q)

# exe(body::Function, db::ThreadSafe{SQLite.DB}, args...) = lock(db) do db; exe(body, db, args...); end
# exe(db::SQLite.DB, query::Union{Int,String}, args...) = exe(asvector, db, query, args...)
# exe(db::ThreadSafe{SQLite.DB}, query::Union{Int,String}, args...) = lock(db) do db; exe(db, query, args...); end

exe(conn::SQLiteConn, args...) = exe(asvector, conn, args...)
# exe(conn::ThreadSafe{SQLiteConn}, args...) = lock(conn) do conn; exe(conn, args...); end
exe(conn::ThreadSafe{SQLiteConn}, args...) = exe(conn.wrapped, args...)

function exe(body::Function, db::SQLite.DB, query::String, args...)
    DBInterface.execute(body, db, query, args...)
end

# https://www.sqlite.org/pragma.html#pragma_synchronous
SYNCHRONOUS_EXTRA=3
SYNCHRONOUS_FULL=2
SYNCHRONOUS_NORMAL=1
SYNCHRONOUS_OFF=0

function open_db(dburi="file:data/primaldb"; readonly=false, memory=true, cache_shared=false, synchronous=SYNCHRONOUS_OFF, journal_mode="OFF")
    memory && (dburi *= "?mode=memory")
    cache_shared && (dburi *= "&cache=shared")

    db = SQLite.DB(dburi)
    DBInterface.execute(db, "PRAGMA journal_mode = $journal_mode")
    close(db)

    # wierd, why do i have to open DB twice to work..

    db = SQLite.DB(dburi)
    DBInterface.execute(db, "PRAGMA journal_mode = $journal_mode")
    readonly && DBInterface.execute(db, "PRAGMA query_only = ON")
    DBInterface.execute(db, "PRAGMA synchronous = $synchronous")
    # PRAGMA cache_size was responsible for mem leak
    DBInterface.execute(db, "PRAGMA temp_store = MEMORY")
    DBInterface.execute(db, "PRAGMA busy_timeout = 10000")
    @assert "THREADSAFE=1" in [r[1] for r in DBInterface.execute(db, "PRAGMA compile_options")]

    db
end

function dbconns_for_sharded_sqlite(dir, init_queries, ndbs; skipinit=false, memory=false, readonly=false, journal_mode="OFF", synchronous=SYNCHRONOUS_OFF)
    dbconns = Vector{ThreadSafe{SQLiteConn}}()
    isdir(dir) || mkpath(dir)
    for i in 0:ndbs-1
        dbfn = @sprintf "file:%s/%02x.sqlite" dir i
        dbs = [open_db(dbfn; memory, readonly, journal_mode, synchronous)
               for _ in 1:Threads.nthreads()]
        skipinit || for q in init_queries; DBInterface.execute(dbs[1], q); end
        push!(dbconns, ThreadSafe(SQLiteConn(dbs)))
    end
    dbconns
end

struct ShardedSqliteDict{K, V} <: ShardedDBDict{K, V}
    rootdirectory::String
    dbname::String
    table::String
    keycolumn::String
    valuecolumn::String
    dbconns::Vector{ThreadSafe{SQLiteConn}}
    hashfunc::Function
    keyfuncs::DBConversionFuncs
    valuefuncs::DBConversionFuncs
    dbqueries::Vector{String}
    function ShardedSqliteDict{K, V}(; 
                                     dbname::String,
                                     rootdirectory::String, 
                                     table=dbname,

                                     keycolumn="key",
                                     valuecolumn="value",
                                     keysqltype::String=sqltype(ShardedSqliteDict{K, V}, K),
                                     valuesqltype::String=sqltype(ShardedSqliteDict{K, V}, V),
                                     hashfunc::Function=hashfunc(K),
                                     keyfuncs::DBConversionFuncs=db_conversion_funcs(ShardedSqliteDict{K, V}, K),
                                     valuefuncs::DBConversionFuncs=db_conversion_funcs(ShardedSqliteDict{K, V}, V),
                                     init_extra_columns="",
                                     init_extra_indexes=String[],
                                     init_queries=vcat(["create table if not exists $table ($keycolumn $keysqltype primary key not null, $valuecolumn $valuesqltype $init_extra_columns)"
                                                        "create index if not exists $(table)_$(keycolumn) on $table ($keycolumn asc)"],
                                                       init_extra_indexes),
                                     skipinit=false,

                                     ndbs=256,
                                     memory=false,
                                     readonly=false,
                                     journal_mode="OFF",
                                     synchronous=SYNCHRONOUS_OFF,
                                    ) where {K, V}
        dbconns = dbconns_for_sharded_sqlite("$rootdirectory/$dbname", init_queries, ndbs; skipinit, memory, readonly, journal_mode, synchronous)
        ssd = new{K, V}(rootdirectory, dbname, table, keycolumn, valuecolumn, dbconns, hashfunc, keyfuncs, valuefuncs, [])
        append!(ssd.dbqueries, mkdbqueries(ssd))
        ssd
    end
end

function last_insert_rowid(ssd::ShardedSqliteDict{K, V}, k::K) where {K, V}
    lock(ssd.dbconns[shard(ssd, k)]) do dbconn
        SQLite.last_insert_rowid(dbconn.dbs[Threads.threadid()])
    end
end

# function Base.in(k::K, ssd::ShardedSqliteDict{K, V})::Bool where {K, V}
#     lock(ssd.dbconns[shard(ssd, k)]) do dbconn
#         SQLite.execute(get_stmt(dbconn, @sql("select 1 from $(ssd.table) where $(ssd.keycolumn) = ?1 limit 1")),
#                        (ssd.keyfuncs.to_sql(k),)) == SQLite.C.SQLITE_ROW
#     end
# end

function ShardedSqliteSet(K::Type, dbname::String; kwargs...)
    ShardedSqliteDict{K, Bool}(; dbname, kwargs...)
end

function SqliteSet(K::Type, dbname::String; kwargs...)
    ShardedSqliteDict{K, Bool}(;
                               dbname, 
                               hashfunc=k->0, 
                               ndbs=1,
                               kwargs...)
end

function SqliteDict(K::Type, V::Type, dbname::String; kwargs...)
    ShardedSqliteDict{K, V}(;
                            dbname, 
                            hashfunc=k->0, 
                            ndbs=1,
                            kwargs...)
end

sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{Bool}) where {K, V} = "integer"
sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{Int}) where {K, V} = "integer"
sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{String}) where {K, V} = "text"
sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{Symbol}) where {K, V} = "text"
sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = "blob"
sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = "blob"
sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{Nostr.Event}) where {K, V} = "text"
sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{Tuple{Nostr.PubKeyId, Nostr.EventId}}) where {K, V} = "blob"

db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Nothing}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Missing}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Bool}) where {K, V} = DBConversionFuncs(x->Int(x), x->Bool(x))
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Int}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Float64}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{String}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Symbol}) where {K, V} = DBConversionFuncs(x->string(x), x->Symbol(x))
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Vector{UInt8}}) where {K, V} = DBConversionFuncs(identity, identity)
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Nostr.EventId}) where {K, V} = DBConversionFuncs(eid->collect(eid.hash), eid->Nostr.EventId(eid))
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Nostr.PubKeyId}) where {K, V} = DBConversionFuncs(pk->collect(pk.pk), pk->Nostr.PubKeyId(pk))
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Nostr.Event}) where {K, V} = DBConversionFuncs(JSON.json, e->Nostr.Event(JSON.parse(e)))
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{Tuple{Nostr.PubKeyId, Nostr.EventId}}) where {K, V} = DBConversionFuncs(p->vcat(collect(p[1].pk), collect(p[2].hash)),
                                                                                                                                    p->(Nostr.PubKeyId(p[1:32]), Nostr.EventId(p[33:64])))


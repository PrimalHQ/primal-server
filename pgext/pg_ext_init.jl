pplog(args...) = println(getpid(), ": ", args...)

rootdir = ENV["PRIMALSERVER_CODE_ROOT"]

import Pkg
Pkg.activate(rootdir)
Pkg.instantiate()

import PrimalServer
include("$rootdir/primal-server/module-globals.jl")

function Utils.GCTask(args...; kwargs...)
    pplog((:dummy_GCTask, args, kwargs))
    nothing
end

import Dates
import Decimals
import JSON

struct PGUnsupportedType; oid; d; end

function p_convert_pg_to_jl(oid::Int, d)
    try
        if     oid == 1114 # timestamp
            Dates.unix2datetime((d::Int)/1e6) + Dates.Year(30) - Dates.Day(1)
        elseif oid == 1700 # numeric
            Decimals.decimal(d::String)
        elseif oid == 114 || oid == 3802 # json/jsonb
            JSON.parse(d::String)
        else
            @show "convert_pg_to_jl: unsupported oid: $(oid)"
            PGUnsupportedType(oid, d)
        end
    catch ex
        pplog(typeof(ex))
    end
end

SPI_ERROR_CONNECT       = (-1)
SPI_ERROR_COPY          = (-2)
SPI_ERROR_OPUNKNOWN     = (-3)
SPI_ERROR_UNCONNECTED   = (-4)
SPI_ERROR_CURSOR        = (-5)
SPI_ERROR_ARGUMENT      = (-6)
SPI_ERROR_PARAM         = (-7)
SPI_ERROR_TRANSACTION   = (-8)
SPI_ERROR_NOATTRIBUTE   = (-9)
SPI_ERROR_NOOUTFUNC     = (-10)
SPI_ERROR_TYPUNKNOWN    = (-11)
SPI_ERROR_REL_DUPLICATE = (-12)
SPI_ERROR_REL_NOT_FOUND = (-13)

SPI_OK_CONNECT          = 1
SPI_OK_FINISH           = 2
SPI_OK_FETCH            = 3
SPI_OK_UTILITY          = 4
SPI_OK_SELECT           = 5
SPI_OK_SELINTO          = 6
SPI_OK_INSERT           = 7
SPI_OK_DELETE           = 8
SPI_OK_UPDATE           = 9
SPI_OK_CURSOR           = 10
SPI_OK_INSERT_RETURNING = 11
SPI_OK_DELETE_RETURNING = 12
SPI_OK_UPDATE_RETURNING = 13
SPI_OK_REWRITTEN        = 14
SPI_OK_REL_REGISTER     = 15
SPI_OK_REL_UNREGISTER   = 16
SPI_OK_TD_REGISTER      = 17
SPI_OK_MERGE            = 18
SPI_OK_MERGE_RETURNING  = 19

function spi_connect()
    ret = @ccall SPI_connect()::Int
    @assert ret >= 0 ret
    nothing
end

function spi_finish()
    ret = @ccall SPI_finish()::Int
    @assert ret >= 0 ret
    nothing
end

function spi_collect_results()
    @ccall p_collect_results()::Any
end

function spi_execute(command::String; cnt=0, readonly=false)
    spi_connect()
    try
        GC.@preserve command begin
            ret = @ccall SPI_execute(command::Cstring, readonly::Bool, cnt::Int)::Int
            @assert ret >= 0 ret
            spi_collect_results()
        end
    finally
        try spi_finish() catch ex pplog(ex) end
    end
end

Datum = Ptr{UInt64}
SPIPlanPtr = Ptr{Cvoid}
Oid = Int32

struct SPIPlan
    ptr::SPIPlanPtr
    argtypes::Vector{Oid}
end

jl_types_oids = Tuple{Type, Oid}[
                 (Bool, 16), # bool
                 (Vector{UInt8}, 17), # bytea
                 (Int64, 20), # int8
                 (Int32, 23), # int4
                 (String, 25), # text
                 (Float32, 700), # float4
                 (Float64, 701), # float8
                 (String, 1043), # varchar
                 (Dates.DateTime, 1114), # timestamp
                 (Decimals.Decimal, 1700), # numeric
                 (Dict, 114), # json
                 (Dict, 3802), # jsonb
                 (Nothing, 16), # special bool for null values

                 (Nostr.PubKeyId, 17), # bytea
                 (Nostr.EventId, 17), # bytea
                ]

jl_type_to_oid = Dict([ty=>oid for (ty, oid) in jl_types_oids])
# oid_to_jl_type = Dict([oid=>ty for (ty, oid) in jl_types_oids])

function spi_prepare(command::String, argtypes::Vector{T}) where T <: Type
    spi_prepare(command, Oid[jl_type_to_oid[ty] for ty in argtypes])
end
function spi_prepare(command::String, argtypes::Vector{Oid})
    spi_connect()
    try
        GC.@preserve command argtypes begin
            planptr = @ccall SPI_prepare(command::Cstring, length(argtypes)::Int, pointer(argtypes)::Ptr{Oid})::SPIPlanPtr
            @assert 0 == @ccall SPI_keepplan(planptr::SPIPlanPtr)::Int
            SPIPlan(planptr, argtypes)
        end
    finally
        try spi_finish() catch ex pplog(ex) end
    end
end

function spi_execute_plan(plan::SPIPlan, params::Vector; cnt=0, readonly=false)
    @assert length(plan.argtypes) == length(params)

    spi_connect()
    try
        datums = Datum[]
        for (oid, p) in zip(plan.argtypes, params)
            d =
            if     isnothing(p) || ismissing(p); #= null as bool value =# reinterpret(Datum, 0::Int64)
            elseif oid == 16; #= bool =# reinterpret(Datum, Int64(p)::Int64)
            elseif oid == 17 && p isa Nostr.PubKeyId; #= bytea =# let d = collect(p.pk);   GC.@preserve d @ccall p_bytes_to_varlena_datum(pointer(d)::Ptr{UInt8}, length(d)::Int)::Datum; end
            elseif oid == 17 && p isa Nostr.EventId;  #= bytea =# let d = collect(p.hash); GC.@preserve d @ccall p_bytes_to_varlena_datum(pointer(d)::Ptr{UInt8}, length(d)::Int)::Datum; end
            elseif oid == 17; #= bytea =# @ccall p_bytes_to_varlena_datum(pointer(p)::Ptr{UInt8}, length(p)::Int)::Datum
            elseif oid == 20; #= int8 =# reinterpret(Datum, p::Int64)
            elseif oid == 23; #= int4 =# reinterpret(Datum, p::Int32)
            elseif oid == 25; #= text =# @ccall cstring_to_text_with_len(p::Cstring, length(p)::Int)::Datum
            elseif oid == 700; #= float4 =# reinterpret(Datum, p::Float32)
            elseif oid == 701; #= float8 =# reinterpret(Datum, p::Float64)
            elseif oid == 1043; #= varchar =# @ccall p_bytes_to_varlena_datum(pointer(p)::Ptr{UInt8}, length(p)::Int)::Datum
                # 1114; # timestamp
                # 1700; # numeric
                # 114; # json
                # 3802; # jsonb
            else; error("unsupported type conversion for oid $(oid)")
            end
            push!(datums, d)
        end

        nulls = UInt8[(isnothing(p) || ismissing(p)) ? UInt8('n') : UInt8(' ') for p in params]

        GC.@preserve plan params datums nulls begin
            ret = @ccall SPI_execute_plan(plan.ptr::SPIPlanPtr, pointer(datums)::Ptr{Datum}, pointer(nulls)::Ptr{UInt8}, readonly::Bool, cnt::Int)::Int
            @assert ret >= 0 ret
            spi_collect_results()
        end
    finally
        try spi_finish() catch ex pplog(ex) end
    end
end

function spi_freeplan(plan::SPIPlan)
    spi_connect()
    try
        ret = GC.@preserve plan @ccall SPI_freeplan(plan.ptr::SPIPlanPtr)::Int
        @assert ret >= 0 ret
    finally 
        try spi_finish() catch ex pplog(ex) end
    end
end

cache_storage = nothing

function p_api_call(s::String)
    try
        d = JSON.parse(s)
        funcall = Symbol(d[1])
        kwargs = [Symbol(k)=>v for (k, v) in collect(d[2])]

        pplog(funcall)

        global cache_storage

        res = try
            [JSON.json(["EVENT", e]) for e in Base.invokelatest(getproperty(Main.App, funcall), cache_storage; kwargs...)]
        catch ex
            Utils.print_exceptions()
            [JSON.json(["NOTICE", string(typeof(ex))])]
        end

        values = [reinterpret(Datum, 0), Datum(0)]
        nulls = [UInt8(0), UInt8(0)]
        # values = [Datum(0)]
        # nulls = [UInt8(0)]
        @assert length(values) == length(nulls)
        for s in res
            # dat = @ccall cstring_to_text_with_len(s::Cstring, length(s)::Int)::Datum
            dat = @ccall cstring_to_text(s::Cstring)::Datum
            values[2] = dat
            @ccall p_push_result_record(pointer(values)::Ptr{Datum}, pointer(nulls)::Ptr{UInt8})::Cvoid
        end
    catch _
        Utils.print_exceptions()
    end
end

import Sockets
pg_dummy_session = Postgres.Session(Sockets.TCPSocket(),
                                    Dict{String, String}(),
                                    nothing,
                                    Dict{String, String}(),
                                    ReentrantLock(),
                                    Dict())
function Postgres.handle_errors(body::Function, server::Symbol)
    body(pg_dummy_session)
end

function Postgres.execute(session::Postgres.Session, query::String, args::Any=[]; callbacks=nothing)
    query = replace(query, "?"=>"\$")
    tys = [typeof(a) for a in args]
    plan = get!(DB.pg_spi_plans, (query, tys)) do
        Main.spi_prepare(query, tys)
    end
    tdur = @elapsed res = Main.spi_execute_plan(plan, collect(args); readonly=DB.pg_spi_readonly[])
    tdur > DB.SLOW_QUERY_TIME[] && @show (:slow_pg_execute, tdur, query, args)
    res
end

#####

using Test: @testset, @test

function spi_runtests(; n=30000)
    testvals = [
                222, 
                true, 
                UInt8[0x12, 0x34], 
                "abc", 
                "def", 
                nothing, 
                Dates.DateTime("2024-07-21T14:47:34.143"), 
                Decimals.decimal("1.23"),
                Dict("a" => 111),
               ]

    function testres(res)
        for (x, y) in zip(res, testvals)
            @test x == y
        end
    end

    function testspi()
        @test spi_execute("select 123+234")[2][1][1] == 123+234

        # res = spi_execute("select 
        #                   222 as a1, 
        #                   true as a2, 
        #                   '\\x1234'::bytea, 
        #                   'abc'::text, 
        #                   'def'::varchar, 
        #                   null, 
        #                   '2024-07-21T14:47:34.143'::timestamp, 
        #                   '1.23'::numeric, 
        #                   '{\"a\":111}'::jsonb
        #                   ")[2][1]
        # testres(res)

        plan1 = spi_prepare("select \$1+\$2", [Int, Int])
        @test spi_execute_plan(plan1, [123, 234])[2][1][1] == 123+234
        spi_freeplan(plan1)

        plan2 = spi_prepare(
                          "select 
                          \$1 as a1, 
                          \$2 as a2, 
                          \$3, 
                          \$4::text, 
                          \$5::varchar, 
                          \$6, 
                          '2024-07-21T14:47:34.143'::timestamp, 
                          '1.23'::numeric, 
                          '{\"a\":111}'::jsonb
                          ",
                          [typeof(v) for v in testvals[1:6]])

        res = spi_execute_plan(plan2, testvals[1:6])[2][1]
        testres(res)

        spi_freeplan(plan2)
    end

    @testset "spi" testspi()

    1==1 && @testset "spi-stress" begin
        for _ in 1:n; testspi(); end
        # GC.gc()
    end

    nothing
end

DB.include("$rootdir/primal-server/src/psql3spi.jl")

function init_cache_storage()
    pplog("primal postgres extension cache service initialization")

    STORAGEPATH = ENV["PRIMALSERVER_STORAGE_PATH"]
    NODEIDX = parse(Int, ENV["PRIMALSERVER_NODE_IDX"])
    directory="$(STORAGEPATH)/primalnode$(NODEIDX)/cache"

    dbargs = (; )
    SCmns = DB.StorageCommons{(args...; kwargs...)->Dict()}
    DBDummyDict = (args...; kwargs...)->nothing
    global cache_storage = DB.CacheStorage{SCmns, DB.PSQLSPIDict, DB.PSQLSPISet, DBDummyDict}(;
                                dbargs,
                                commons = SCmns(; dbargs=(; rootdirectory="$directory/db")),
                                pqconnstr = "",
                                events = DB.PSQLSPIDict(Nostr.EventId, Nostr.Event, "events"; dbargs...,
                                                        keycolumn="id",
                                                        valuecolumn="json_build_object('id', encode(id, 'hex'), 'pubkey', encode(pubkey, 'hex'), 'created_at', created_at, 'kind', kind, 'tags', tags, 'content', content, 'sig', encode(sig, 'hex'))::text"))

    DB.init(cache_storage; noperiodic=true)

    1==0 && @time "pgext-precompile" try
        pk = "88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079" # qa user
        App.feed(cache_storage; pubkey=pk, user_pubkey=pk)
        App.user_profile(cache_storage; pubkey=pk)
        App.user_profile_scored_content(cache_storage; pubkey=pk, user_pubkey=pk)
        # App.scored(cache_storage; selector="trending_24h", user_pubkey=pk)
        # App.get_directmsg_contacts(cache_storage; user_pubkey=pk)
        # App.get_notifications(cache_storage; user_pubkey=pk, pubkey=pk, type_group="all")
    catch ex
        pplog("pgext-precompile: ", ex)
    end

    nothing
end

App.DAG_OUTPUTS_DB[] = :local

pplog("primal postgres extension initialized")


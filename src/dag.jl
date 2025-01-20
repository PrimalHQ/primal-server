module DAG

using JSON
import HTTP
import Dates
using Dates: DateTime, unix2datetime, datetime2unix
import SHA
using ..Iterators: flatten

import Random
using DataStructures: Accumulator
import AbstractTrees

import PikaParser as P
import JuliaFormatter

import Languages

import ..Utils
using ..Utils: ThreadSafe, current_time
import ..Nostr
using ..Nostr: EventId, PubKeyId
import ..DB
import ..Postgres

using ..DAGBase

PRINT_EXCEPTIONS = Ref(true)
print_exceptions_lock = ReentrantLock()

PROCESS_SEGMENTS_TASKS = Ref(8)

PROTECTED_TABLES = ["event"]

MAIN_SERVER = Ref(:p0)

const logs = Ref{Any}(nothing)
const node_outputs = Ref{Any}(nothing)
const coverages = Ref{Any}(nothing)
const dag = Ref{Any}(nothing)
# const propagators = Ref{Any}(nothing)

struct RunCtx
    runtag
    running
    progress
    log
    on_exception
    explain
    since::Int
    until::Int
    stats
    targetserver::Symbol
    est::DB.CacheStorage
    state::Utils.Dyn
    opts::NamedTuple
end
            
struct ImportInterrupted <: Exception end

struct BigSerial serial::Int end
struct TSVector s::String end

Base.string(st::ServerTable) = "$(st.servertype)-$(st.server)-$(st.table)"

function init()
    init_tables()
    init_parsing()
end

function init_tables()
    logs[] = dbtable(:postgres, MAIN_SERVER[], "logs", 1, [],
                     [
                      (:t,      DateTime),
                      (:module, String),
                      (:func,   String),
                      (:type,   String),
                      (:d,      Dict),
                     ], 
                     [
                      :t,
                      :module,
                      :func,
                      :type,
                      "create index if not exists TABLE_eid on TABLE ((d->>'eid'))",
                     ])

    node_outputs[] = dbtable(:postgres, MAIN_SERVER[], "node_outputs", 1, [],
                             [
                              (:output, (String, "primary key")),
                              (:def,    Dict),
                             ])

    coverages[] = dbtable(:postgres, MAIN_SERVER[], "coverages", 1, [],
                          [
                           (:name, String),
                           (:t,    Int),
                           (:t2,   Int),
                           "unique (name, t)",
                          ],
                          [
                           :name,
                          ])

    dag[] = dbtable(:postgres, MAIN_SERVER[], "dag", 1, [],
                    [
                     (:output, String),
                     (:input,  String),
                     "unique (output, input)",
                    ],
                    [
                     :output,
                     :input,
                    ])

    nothing
end

function runnode(nodefunc::Function; modname=:DAG_20240803_1, mkviews=false, days=nothing)
    m = methods(Base.bodyfunction(methods(nodefunc)[1]))[1]
    args = Dict(zip(split(m.slot_syms, '\0'), m.sig.parameters))
    stargs = [Symbol(n) for (n, ty) in args if ty == ServerTable]
    dag = Main.DAGRunner.dags[modname]
    outputs = dag.successful[end].result.outputs
    r = runsimple(; dag.runtag, [k=>v for (k, v) in dag.runkwargs if !(k in [:pipeline])]..., days) do targetserver, xn, o
        xn(nodefunc; [n=>getproperty(outputs, n) for n in stargs]...)
    end
    mkviews && r.runctx.running[] && for schema in [:prod, :public]; mkviews!(r.outputs; schema); end
    r
end

function runsimple(pipeline=default_pipeline; runtag, days=nothing, kwargs...)
    init()

    global g_running
    try g_running[] catch _ false end || (g_running = Utils.PressEnterToStop())

    if days == :skipprocessing
        since = until = 0
    elseif !isnothing(days)
        since = current_time() - days*24*3600
        until = current_time()
    else
        since = until = nothing
    end

    @time "run" r = run(;
                        pipeline, 
                        est=Main.cache_storage, 
                        state=Utils.Dyn(),
                        running=g_running, 
                        since, until, 
                        runtag, 
                        log=:default, progress=:default, on_exception=:print,
                        kwargs...)
    display(r.stats)
    r
end

function run(;
        pipeline=default_pipeline, 
        est::DB.CacheStorage, 
        state::Utils.Dyn,
        since=nothing, until=nothing, 
        runtag=nothing, 
        opts=(;),
        targetserver=MAIN_SERVER[],
        running=Utils.PressEnterToStop(), 
        progress=nothing, log=nothing, on_exception=nothing, 
        explain=false,
    )
    since = isnothing(since) ? 0 : since
    until = isnothing(until) ? current_time() : until

    since = max(since, datetime2unix(DateTime("2023-01-01")))
    until = min(until, current_time())

    tstart = Ref(0.0)
    if progress == :default
        progress_periodic = Utils.Throttle(; period=0.5, t=0.0)
        progress = function (p)
            progress_periodic() do
                println(let days = p.ttotal/(24*3600), dt = time()-tstart[]
                            (cov=string(p.coverage), p.cnt, p.errs, days, rate=days/dt)
                        end)
            end
        end
    end
    if isnothing(log)
        log = (_="")->nothing
    elseif log == :default
        log = println
    end

    runctx = RunCtx(runtag, running, 
                    progress, 
                    (s="")->log(Dates.now(), ' ', s), 
                    on_exception, 
                    explain, 
                    since, until, 
                    Ref(zero_usage_stats) |> ThreadSafe, 
                    targetserver,
                    est,
                    state,
                    opts,
                   )

    node_stats = Dict{Symbol, Any}()
    o = outputs = Utils.Dyn()

    function execnode(f, args...; kwargs...)
        tstart[] = time()
        runctx.stats[] = zero_usage_stats
        tdur = @elapsed res = f(args...; runctx, kwargs...)
        dt = time()-tstart[]
        node_stats[nameof(f)] = (; stats=runctx.stats[], rate=(until-since)/(24*3600)/dt)
        merge!(outputs, Dict(pairs(res)))
    end

    pipeline(targetserver, execnode, o)

    s = reduce(+, [v.stats for v in values(node_stats)]; init=zero_usage_stats)
    stats = (; cputime=s.cputime, readGBs=s.readbytes/1024^3, writeGBs=s.writebytes/1024^3, s.readcalls, s.writecalls)

    (; 
     outputs=NamedTuple(collect(outputs)),
     runctx,
     stats,
     node_stats,
    )
end

function override_runtag(node_func::Function, runtag)
    function (; runctx::RunCtx, kwargs...)
        node_func(; 
                  runctx=RunCtx(runtag, [getproperty(runctx, p) for p in propertynames(runctx)[2:end]]...),
                  kwargs...)
    end
end

function default_pipeline(targetserver, xn, o)
    o.events           = ServerTable(:postgres, targetserver, "event")
    o.pubkey_trustrank = ServerTable(:postgres, targetserver, "pubkey_trustrank")
    o.pubkey_bookmarks = ServerTable(:postgres, targetserver, "pubkey_bookmarks")
    o.human_override   = ServerTable(:postgres, targetserver, "human_override")

    xn(basic_tags_node, o.events)
    # xn(events_simplified_node, o.events)
    # xn(event_stats_node, o.events, o.events_simplified)
    xn(zap_receipts_node, o.events)
    xn(a_tags_node, o.events)
    # xn(sqlite2pg_node; skipprocessing=true)
    xn(override_runtag(sqlite2pg_node, :dev27); skipprocessing=true)
    xn(reads_node, o.events, o.basic_tags, o.zap_receipts, o.event_replies, o.a_tags)
    xn(pubkey_media_cnt_node, o.events, o.event_media)
    xn(pubkey_content_zap_cnt_node, o.zap_receipts)
    xn(advsearch_node, o.events, o.basic_tags)
    xn(event_mentions_node, o.events, o.parametrized_replaceable_events)
    xn(note_length_node; o.events)
    xn(note_stats_node; o.events, o.pubkey_trustrank)
    xn(update_user_search_node; o.human_override)

    # xn(event_sentiment_node; o.events, o.pubkey_trustrank)
end

function sqlite2pg_pipeline(targetserver, xn, o)
    xn(sqlite2pg_node)
end

# prep_log_insert(session) = Postgres.prepare(session, replace("insert into $(logs[].table) values (?1, ?2, ?3, ?4, ?5)", '?'=>'$')) 

function logexec(pslog, func, type="", d=(;))
    Postgres.execute(pslog, [Dates.now(),
                             join(map(String, fullname(@__MODULE__)[2:end]), '.'),
                             func,
                             type,
                             JSON.json(d)])
    nothing
end

function delete_table_coverages!(session, st::ServerTable)
    Postgres.execute(session, "delete from $(node_outputs[].table) where output = \$1", [string(st)])
    Postgres.execute(session, "delete from $(coverages[].table) where name like \$1 || '%'", [string(st)])
    nothing
end
function drop_table!(st::ServerTable; cascade=false)
    Postgres.transaction(st.server) do session
        Postgres.execute(session, "drop table if exists $(st.table) $(cascade ? "cascade" : "")")
        delete_table_coverages!(session, st)
    end
    nothing
end
function reset_table!(st::ServerTable)
    Postgres.transaction(st.server) do session
        Postgres.execute(session, "truncate $(st.table)")
        delete_table_coverages!(session, st)
    end
    nothing
end
function reimport_tables!(sts::Vector{ServerTable}; days=nothing, modname::Symbol=:DAG_20240803_1)
    Main.DAGRunner.stop()
    for st in sts
        reset_table!(st)
    end
    Main.DAGRunner.dags[modname].since = isnothing(days) ? datetime2unix(DateTime("2023-01-01")) : current_time()-days*24*3600
    Main.DAGRunner.LOG[] = true
    Main.DAGRunner.start()
    nothing
end
##
using MLStyle: @match
function _pg(args...)
    Base.remove_linenums!(args[end])

    # @show args

    server, body = args

    # dump(body; maxdepth=100)
    # AbstractTrees.print_tree(body; maxdepth=100)

    params = []
    function P(e)
        push!(params, e)
        "\$$(length(params))"
    end

    function mkctx()
        (;
         ctes = [],
         sels = [],
         tables = Set(),
         conds = [],
         opts = [],
         setops = [],
        )
    end

    function sql_(ctx, e, flags...)
        flags = Tuple(Set(flags))
        sql(e, args...) = sql_(ctx, e, flags..., args...)

        # @show e
        # dump(e)
        res = @match e begin
            Expr(:block, args...) => begin
                let ctx = mkctx()
                    for a in args[1:end-1]
                        s = sql_(ctx, a, flags...)
                        if !isempty(s)
                            if !(s[1] isa Vector)
                                push!(ctx.conds, s)
                            end
                        end
                    end
                    g = sql_(ctx, args[end], flags...)
                    @match args[end] begin
                        Expr(:., a, Expr(:tuple, :(*))) => push!(ctx.sels, g)
                        Expr(:., a, Expr(:tuple, _...)) => append!(ctx.sels, g)
                        Expr(:tuple, args...)           => append!(ctx.sels, g)
                        _                               => push!(ctx.sels, g)
                    end
                    ctx2vec(ctx)
                end
            end
            Expr(:(=), a, Expr(:call, f, args...)) => push!(ctx.ctes, [sql(a)[1], " as (", sql(Expr(:block, Expr(:call, f, args...)))..., ")"])
            Expr(:(=), a, b) => push!(ctx.ctes, [sql(a)[1], " as (", sql(b)..., ")"])
            Expr(:&&, a, b) => ["(", sql(a)..., " and ", sql(b)..., ")"]
            Expr(:||, a, b) => ["(", sql(a)..., " or ", sql(b)..., ")"]
            Expr(:call, :!, a) => ["(not (", sql(a)..., "))"]
            Expr(:call, :(==), a, b) => ["(", sql(a)..., " = ", sql(b)..., ")"]
            Expr(:call, :(=>), a, b) => [sql(a)..., " as ", sql(b)...]
            Expr(:call, :(>=), a, b) => [sql(a)..., " >= ", sql(b)...]
            Expr(:call, :(<=), a, b) => [sql(a)..., " <= ", sql(b)...]
            Expr(:call, op, a, b) && if op in [:union, :intersect, :except] end => begin
                push!(ctx.setops, (op, sql(a), sql(b)))
                []
            end
            Expr(:call, f, args...) => [sql(f)..., "(", flatten(map(sql, args))..., ")"]
            Expr(:., a, b::QuoteNode) => begin
                push!(ctx.tables, sql(a, :noparams)[1])
                [sql(a, :noparams)[1], ".", "$(sql(b)[1])"]
            end
            Expr(:., a, Expr(:tuple, :(*))) => begin
                b = :(*)
                push!(ctx.tables, sql(a, :noparams)[1])
                [sql(a, :noparams)[1], ".", "$(sql(b)[1])"]
            end
            Expr(:., a, Expr(:tuple, args...)) => begin
                push!(ctx.tables, sql(a, :noparams)[1])
                [[sql(a, :noparams)[1], ".", "$(sql(b)[1])"] for b in args]
            end
            Expr(:$, a) => :noparams in flags ? [esc(a)] : [P(esc(a))]
            Expr(:macrocall, m::Symbol, ::LineNumberNode, a, args...) || 
            Expr(:macrocall, m::Symbol, a, args...) => begin
                if m == Symbol("@limit")
                    push!(ctx.opts, "limit $(a)")
                    []
                elseif m == Symbol("@offset")
                    push!(ctx.opts, "offset $(a)")
                    []
                elseif m == Symbol("@groupby")
                    push!(ctx.opts, "group by $(a)")
                    []
                elseif m == Symbol("@orderby")
                    push!(ctx.opts, "order by $(a)")
                    append!(ctx.opts, ["$b" for b in args])
                    []
                else
                    error("@pg: unsupported macrocall: $m $args")
                end
            end
            Expr(:tuple, args...) => map(sql, args)
            a::Symbol => ["$(a)"]
            a::QuoteNode => ["$(a.value)"]
            a::String => ["'", replace(a, '\''=>"''"), "'"]
            a::Int => [string(a)]
            _ => begin
                dump(e)
                error("@pg: unsupported expression: $e")
            end
        end
        # println("$e --> $res")
        res
    end

    aliasidx = Ref(0)
    function genalias()
        aliasidx[] += 1
        "_a$(aliasidx[])"
    end

    function ctx2vec(ctx)
        # display(collect(pairs(ctx)))
        [
         (isempty(ctx.ctes) ? [] : ["with ", reduce((a, b)->[a..., ", ", b...], ctx.ctes)...])...,

         if isempty(ctx.setops)
             [
              " ( ",

              "select ",
              flatten(withseparators(ctx.sels, [", "]))...,

              (isempty(ctx.tables) ? [] : [" from ",
                                           withseparators(ctx.tables, ", ")...,
                                          ])...,

              (isempty(ctx.conds) ? [] : [" where ", reduce((a, b)->[a..., " and ", b...], ctx.conds)...])..., 

              (isempty(ctx.opts) ? [] : [" $(join(ctx.opts, ' '))"])...,

              " ) ",
              "$(genalias())",
             ] 
         else 
             let sop = ctx.setops[1]
                 ["( select * from ", sop[2]..., " ) ", string(sop[1]), " ( select * from ", sop[3]..., " )"]
             end
         end..., 
        ]
    end

    q = Expr(:string, sql_(mkctx(), body)[1:end-1]...)
    # @show q
    
    res = quote
        Postgres.execute($(esc(server)), $q, [$(params...)])
    end
    # dump(res; maxdepth=10)
    # AbstractTrees.print_tree(res; maxdepth=100)
    # println(res)
    res
end

function withseparators(v, sep)
    v = collect(v)
    res = []
    push!(res, v[1])
    for x in v[2:end]
        push!(res, sep)
        push!(res, x)
    end
    res
end

macro pg(args...); _pg(args...); end

function pgpretty(s::String)
    string(strip(read(pipeline(`pg_format`; stdin=IOBuffer(s*";")), String)))
end

macro pgpretty(args...)
    e = _pg(args...)
    Base.remove_linenums!(e)
    s = Ref("")
    for n in AbstractTrees.PostOrderDFS(e)
        @match n begin
            Expr(:string, args...) => (s[] = s[] * join(args))
            _ => nothing
        end
    end
    # println()
    # println(s[])
    println()
    println(pgpretty(s[]))
    nothing
end

macro pgexplain(args...)
    e = _pg(args...)
    Base.remove_linenums!(e)
    server = e.args[1].args[2]
    code = Expr(:string, "explain ", e.args[1].args[3].args...)
    params = e.args[1].args[4]
    quote
        Postgres.execute($server, $code, $params)
    end
end

#
function rename_tables!(from::NamedTuple, to::NamedTuple)
    @assert collect(keys(from)) == collect(keys(to))
    for k in keys(from)
        st1 = getproperty(from, k)
        st2 = getproperty(  to, k)

        # if (@pg st1.server begin
        #         bbb = begin
        #             tbl1.x == 1
        #             (tbl2.y => z, aa)
        #         end
        #         pg_tables.schemaname == "public" && pg_tables.tablename == $(st1.table) 
        #         @limit 1
        #         1
        #     end) |> !isempty
        #     println(k)
        # end
    end
end
##

function mkschema!(name::Symbol, outputs::NamedTuple)
    @assert name != :public

    servers = Set([st.server for st in values(outputs)])
    @assert length(servers) == 1 servers

    server = first(collect(servers))

    function exe(q)
        println(q)
        Postgres.execute(server, q)
    end

    exe("drop schema if exists $name cascade")
    exe("create schema $name")

    for (k, st) in pairs(outputs)
        exe("create view $name.$k as (select * from public.$(st.table))")
    end
end

function mkviews!(outputs::NamedTuple; schema=:public)
    servers = Set([st.server for st in values(outputs)])
    @assert length(servers) == 1 servers

    server = first(collect(servers))

    function exe(q, args=[])
        # println(q)
        Postgres.execute(server, q, args)
    end

    exe("create schema if not exists $schema")

    for (k, st) in pairs(outputs)
        k in PROTECTED_TABLES && continue
        isempty(exe("select * from pg_tables where schemaname = \$1 and tablename = \$2", ["public", k])) || continue
        exe("drop view if exists $schema.$k")
        exe("create view $schema.$k as (select * from public.$(st.table))")
    end
end

function drop_all_tables!(servertype::Symbol, server::Symbol)
    if servertype == :postgres
        for (tbl,) in Postgres.pex(server, "select table_name from information_schema.tables where table_schema = 'public'")
            tbl in PROTECTED_TABLES && continue
            println("dropping table $(tbl)")
            Postgres.pex(server, "drop table $(tbl)")
        end
    end
end

function dbtable(servertype::Symbol, server::Symbol, name::String, version::Int, inputs::Vector, columns, indexes=[]; keyextra=nothing, runtag=nothing)
    # k = (; server, name, version, runtag, inputs, columns, indexes)
    k = (; server, name, version, runtag, inputs, columns)
    !isnothing(keyextra) && (k = (; k..., extra=keyextra))

    keyjson = JSON.json(k)
    keyjson = replace(keyjson, "PrimalServer."=>"Main.")
    sha = bytes2hex(SHA.sha256(keyjson))[1:10]

    tblname = "$(name)_$(version)_$(sha)"

    extra_ddl = [s for s in columns if s isa String]
    columns = [s for s in columns if !(s isa String)]

    columns = [(name, 
                typeopts isa Tuple ? typeopts : 
                typeopts isa String ? typeopts : 
                (typeopts, "not null"))
               for (name, typeopts) in columns]

    # if isempty(Postgres.pex(server, "select 1 from information_schema.tables where table_schema = 'public' and table_name = ?1 limit 1", (tblname,)))
    if true
        columns_ = [let (type, opts) = typeopts
                        ty = 
                        if     type isa Symbol; type
                        elseif type == Int; :int8
                        elseif type == Float64; "double precision"
                        elseif type == String; :varchar
                        elseif type == Char; :char
                        elseif type == Vector{UInt8}; :bytea
                        elseif type == Dict; :jsonb
                        elseif type == DateTime; :timestamp
                        elseif type == BigSerial; :bigserial
                        elseif type == TSVector; :tsvector
                        elseif type == EventId; :bytea
                        elseif type == PubKeyId; :bytea
                        else; error("unsupported type for dbtable: $type")
                        end
                        (name, (ty, opts))
                    end for (name, typeopts) in columns]

        Postgres.transaction(server) do session
            Postgres.pex(session, "set client_min_messages to warning")
            create_ddl = join(vcat(["$name $ty $opts" for (name, (ty, opts)) in columns_], 
                                   extra_ddl), 
                              ", ")
            # Postgres.pex(session, "create unlogged table if not exists $tblname ($create_ddl)")
            Postgres.pex(session, "create table if not exists $tblname ($create_ddl)")
            for idx in indexes
                cols, extra = if idx isa Symbol
                    [string(idx)], ""
                elseif idx isa Pair
                    [string(idx[1])], idx[2]
                elseif idx isa Tuple
                    idx, ""
                elseif idx isa String
                    Postgres.pex(session, replace(idx, "TABLE"=>tblname))
                    continue
                else
                    error("unsupported index type: $(idx)")
                end
                idxname = "$(tblname)_$(join(cols, '_'))_idx"
                key = join(cols, ',')
                Postgres.pex(session, "create index if not exists $idxname on $tblname $extra ($key)")
            end
            Postgres.pex(session, "set client_min_messages to notice")
        end
    end

    columns = [(name, type) for (name, (type, opts)) in columns]
    output = ServerTable(servertype, server, tblname, columns)

    if !isnothing(node_outputs[])
        Postgres.pex(node_outputs[].server, "
                     insert into $(node_outputs[].table) values (?1, ?2)
                     on conflict (output) do update set def = ?2",
                     (string(output), JSON.json(inputs)))
    end

    if !isnothing(dag[])
        Postgres.pex(dag[].server, "delete from $(dag[].table) where output = ?1", (string(output),))
        for input in inputs
            Postgres.pex(dag[].server, "insert into $(dag[].table) values (?1, ?2) on conflict do nothing",
                         (string(output), string(input)))
        end
    end

    output
end

function advsearch_node(
        events::ServerTable,
        basic_tags::ServerTable;
        runctx::RunCtx,
        version=5, 
        maxdays=get(runctx.opts, :advsearch_maxdays, 30),
    )
    advsearch = dbtable(:postgres, runctx.targetserver, "advsearch", version, 
                        [
                         events,
                         basic_tags,
                        ],
                        [
                         (:i,          (BigSerial, "primary key")),

                         (:id,         (EventId, "unique")),
                         (:pubkey,     PubKeyId),
                         (:created_at, Int),
                         (:kind,       Int),

                         (:content_tsv, :tsvector),
                         (:hashtag_tsv, :tsvector),
                         (:reply_tsv,   :tsvector),
                         (:mention_tsv, :tsvector),
                         (:filter_tsv,  :tsvector),
                         (:url_tsv,     :tsvector),
                        ],
                        [
                         :id,
                         :pubkey,
                         :created_at,
                         :kind,

                         :content_tsv => "using GIN",
                         :hashtag_tsv => "using GIN",
                         :reply_tsv => "using GIN",
                         :mention_tsv => "using GIN",
                         :filter_tsv => "using GIN",
                         :url_tsv => "using GIN",

                         "create index if not exists TABLE_pubkey_created_at_desc_idx on TABLE (pubkey, created_at desc)",
                        ];
                        runtag=runctx.runtag)

    process_segments(advsearch; runctx, step=24*3600, 
                     since=max(runctx.since, current_time() - maxdays*24*3600),
                    ) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats) do session1
            transaction_with_execution_stats(advsearch.server; runctx.stats) do session2
                psinsert = Postgres.prepareR(session2, "
                                             insert into $(advsearch.table) values (
                                                 default, ?1, ?2, ?3, ?4, 
                                                 to_tsvector('simple', ?5), 
                                                 to_tsvector('simple', ?6), 
                                                 to_tsvector('simple', ?7), 
                                                 to_tsvector('simple', ?8), 
                                                 to_tsvector('simple', ?9), 
                                                 to_tsvector('simple', ?10)
                                             ) on conflict do nothing")

                events_q = "
                    select 
                        es.* 
                    from 
                        $(events.table) es
                    where 
                        es.imported_at >= \$1 and es.imported_at <= \$2 and
                        (es.kind = $(Int(Nostr.TEXT_NOTE)) or es.kind = $(Int(Nostr.LONG_FORM_CONTENT)))
                    order by es.id
                "

                # @time "replies" 
                rs = Postgres.execute(session1, "
                    select ev1.id, ev2.pubkey 
                    from 
                        ($events_q) as ev1,
                        $(events.table) as ev2,
                        $(basic_tags.table) bt1
                    where
                        ev1.id = bt1.id and bt1.arg3 in ('reply', 'root') and bt1.arg1 = ev2.id
                    ", [t1, t2])[2]

                replies = Dict(EventId(eid)=>PubKeyId(pk) for (eid, pk) in rs)
                # @show length(replies)

                # max_size = 1_000_000
                max_size = 200_000

                # @time "evts" 
                evts = Postgres.execute(session1, events_q, [t1, t2])[2]

                # @time "insert" 
                for r in evts
                    runctx.running[] || throw(ImportInterrupted())

                    r[6] = ismissing(r[6]) ? "" : r[6]
                    length(r[6]) > max_size && continue

                    e = event_from_row(r)

                    hashtags = Set()
                    DB.for_hashtags(runctx.est, e) do ht
                        push!(hashtags, ht)
                    end
                    for t in e.tags
                        if length(t.fields) >= 2 && t.fields[1] == "t"
                            push!(hashtags, lowercase(t.fields[2]))
                        end
                    end

                    hashtags_c = join(collect(hashtags), ' ')
                    length(hashtags_c) > max_size && continue

                    reply = haskey(replies, e.id) ? Nostr.hex(replies[e.id]) : ""

                    mentions = Set()
                    DB.for_mentiones(runctx.est, e) do t
                        if length(t.fields) >= 4 && t.fields[1] == "p" && t.fields[4] == "mention"
                            if !isnothing(local pk = try Nostr.PubKeyId(t.fields[2]) catch _ end)
                                push!(mentions, Nostr.hex(pk))
                            end
                        end
                    end

                    mentions_c = join(collect(mentions), ' ')
                    length(mentions_c) > max_size && continue

                    filters = Set()
                    urls = []
                    DB.for_urls(runctx.est, e) do url
                        _, ext = splitext(lowercase(url))
                        if any((startswith(ext, ext2) for ext2 in DB.image_exts))
                            push!(filters, "image")
                        elseif any((startswith(ext, ext2) for ext2 in DB.video_exts))
                            push!(filters, "video")
                        elseif any((startswith(ext, ext2) for ext2 in DB.audio_exts))
                            push!(filters, "audio")
                        else
                            push!(filters, "link")
                            push!(urls, replace(url, r"[/\.:?=&]"=>' '))
                        end
                    end

                    filters_c = join(collect(filters), ' ')
                    length(filters_c) > max_size && continue

                    urls_c = join(urls, ' ')
                    length(urls_c) > max_size && continue

                    # @show (; hashtags, reply, mentions, filters, urls)

                    Postgres.execute(psinsert, [
                                                e.id, e.pubkey, e.created_at, e.kind,

                                                e.content,
                                                hashtags_c,
                                                reply,
                                                mentions_c,
                                                filters_c,
                                                urls_c,
                                               ])
                end
            end
        end
    end

    (; advsearch)
end

function import_basic_tags(connsel, events::ServerTable, basic_tags::ServerTable, since, until)
    insert_q = "
    insert into $(basic_tags.table)
        (id, pubkey, created_at, kind, tag, arg1, arg3, imported_at)
    select * from (
        select id, pubkey, created_at, kind, t->>0 as tag, decode(t->>1, 'hex') as arg1, coalesce(t->>3, '') as arg3, imported_at from (
            select id, pubkey, created_at, kind, jsonb_array_elements(tags) as t, imported_at from $(events.table)
            where 
                imported_at >= \$1 and imported_at <= \$2 and 
                jsonb_array_length(tags) < 50
        ) a where t->>0 in ('p', 'P', 'e') and t->>1 ~* '^[0-9a-f]{64}\$'
    ) b on conflict do nothing
    "
        # (kind = $(Int(Nostr.TEXT_NOTE)) or kind = $(Int(Nostr.REACTION)) or kind = $(Int(Nostr.REPOST)) or kind = $(Int(Nostr.ZAP_RECEIPT)) or kind = 9802) and
    Postgres.execute(connsel, insert_q, [since, until])
end

function basic_tags_node(
        events::ServerTable;
        runctx::RunCtx,
        version=6, 
    )
    basic_tags = dbtable(:postgres, runctx.targetserver, "basic_tags", version, 
                         [
                          events,
                         ],
                         [
                          (:i, (BigSerial, "primary key")),

                          (:id,          EventId),
                          (:pubkey,      PubKeyId),
                          (:created_at,  Int),
                          (:kind,        Int),

                          (:tag,         Char),
                          (:arg1,        Vector{UInt8}),
                          (:arg3,        String),
                          (:imported_at, Int),

                          "unique (id, tag, arg1, arg3)",
                         ],
                         [
                          :id,
                          :pubkey,
                          :created_at,
                          :arg1 => "using HASH",
                          :imported_at,
                         ];
                         runtag=runctx.runtag)

    @assert basic_tags.server == events.server

    process_segments(basic_tags; runctx, step=24*3600) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats) do session1
            import_basic_tags(session1, events, basic_tags, t1, t2)
        end
    end

    (; basic_tags)
end

function event_stats_node(
        events::ServerTable,
        events_simplified::ServerTable;
        runctx::RunCtx,
        version=1, 
    )
    out = dbtable(:postgres, runctx.targetserver, "event_stats", version, 
                  [
                   events,
                   events_simplified,
                  ],
                  [
                   (:event_id,      (EventId, "primary key")),
                   (:author_pubkey, PubKey),
                   (:created_at,    Int),
                   (:likes,         Int),
                   (:replies,       Int),
                   (:mentions,      Int),
                   (:reposts,       Int),
                   (:zaps,          Int),
                   (:satszapped,    Int),
                   (:score,         Int),
                   (:score24h,      Int),
                  ],
                  [
                  ];
                  runtag=runctx.runtag)

    @assert out.server == events.server

    process_segments(out; runctx, step=24*3600) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats) do session1
            
            event_likes      = Accumulator{EventId, Int}()
            event_zaps       = Accumulator{EventId, Int}()
            event_satszapped = Accumulator{EventId, Int}()

            # @time "likes"
            for (eid, likes) in Postgres.pex(events.server, "
                    select
                        decode(t->>1, 'hex'),
                        count(1)
                    from (
                        select pubkey, created_at, jsonb_array_elements(tags) as t from $(events.table)
                        where imported_at >= \$1 and imported_at <= \$2 and kind = $(Int(Nostr.REACTION))
                    ) a
                    where t->>0 = 'e' and t->>1 ~* '^[0-9a-f]{64}\$'
                    group by t->>1
                ", [t1, t2])
                event_likes[EventId(eid)] += likes
            end
            
            # @time "zaps"
            for (tags,) in Postgres.pex(events.server, "
                                        select tags from $(events.table) 
                                        where kind = $(Int(Nostr.ZAP_RECEIPT)) and imported_at >= ?1 and imported_at <= ?2
                                        ", [t1, t2])
                runctx.running[] || break
                try
                    p = parse_zap_receipt(tags)
                    if !isnothing(p.eid) && p.amount_sats > 0
                        event_zaps[p.eid]       += 1
                        event_satszapped[p.eid] += p.amount_sats
                    end
                catch _
                    # DB.incr(errs)
                end
            end

            Postgres.execute(session1, "
                             create temp table tmp1 (
                                 event_id bytea primary key not null,
                                 likes int8 not null,
                                 zaps int8 not null,
                                 satszapped int8 not null
                             ) on commit drop")

            eids = sort(union(
                              collect(keys(event_likes)),
                              collect(keys(event_zaps)),
                              collect(keys(event_satszapped)),
                             ))

            # @show length(eids)

            # @time "instmp"
            for eid in eids
                runctx.running[] || break

                Postgres.execute(session1, rep("insert into tmp1 values (?1, ?2, ?3, ?4)"), 
                                 [eid, 
                                  get(event_likes, eid, 0), 
                                  get(event_zaps, eid, 0), 
                                  get(event_satszapped, eid, 0), 
                                 ])
            end

            # @time "ins"
            Postgres.execute(session1, "
                    insert into $(out.table) (
                        event_id,
                        author_pubkey,
                        created_at,

                        likes,
                        replies,
                        mentions,
                        reposts,
                        zaps,
                        satszapped,
                        score,
                        score24h
                    )
                    select * from (
                        select 
                            id, pubkey, created_at,
                            0, 0, 0, 0, 0, 0, 0, 0
                        from $(events_simplified.table)
                        where id in (select event_id from tmp1)
                        order by id
                    ) b on conflict do nothing
                    ")

            # @time "upd"
            Postgres.execute(session1, "
                    update $(out.table)
                    set 
                        likes = $(out.table).likes + t.likes,
                        zaps = $(out.table).zaps + t.zaps,
                        satszapped = $(out.table).satszapped + t.satszapped
                    from (select * from tmp1 order by event_id) as t
                    where $(out.table).event_id = t.event_id
                    ")

            runctx.running[] || Postgres.execute(session1, "abort")
        end

    end
end

function events_simplified_node(
        events::ServerTable;
        runctx::RunCtx,
        version=1, 
    )
    out = dbtable(:postgres, runctx.targetserver, "events_simplified", version, 
                  [
                   events,
                  ],
                  [
                   (:id,         (EventId, "primary key")),
                   (:pubkey,     PubKey),
                   (:kind,       Int),
                   (:created_at, Int),
                  ],
                  [
                   :pubkey,
                   :kind,
                   :created_at,
                  ];
                  runtag=runctx.runtag)

    @assert out.server == events.server

    process_segments(out; runctx, step=24*3600) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats) do session1
            Postgres.execute(session1, "
                             insert into $(out.table) (
                                 id,
                                 pubkey,
                                 kind,
                                 created_at
                             )
                             select * from (
                                 select 
                                     id, pubkey, kind, created_at
                                 from $(events.table)
                                 where imported_at >= \$1 and imported_at <= \$2 and kind = $(Int(Nostr.TEXT_NOTE))
                                 order by id
                             ) b on conflict do nothing
                             ", [t1, t2])
        end
    end
end

function zap_receipts_node(
        events::ServerTable;
        runctx::RunCtx,
        version=1
    )
    zap_receipts = dbtable(:postgres, runctx.targetserver, "zap_receipts", version, 
                           [
                            events,
                           ],
                           [
                            (:eid,           EventId),
                            (:created_at,    Int),
                            (:target_eid,    EventId),
                            (:sender,        PubKeyId),
                            (:receiver,      PubKeyId),
                            (:satszapped,    Int),
                            (:imported_at,   Int),

                            "primary key (eid)",
                           ],
                           [
                            :target_eid,
                            :imported_at,
                            :sender,
                            :receiver,
                           ];
                           runtag=runctx.runtag)

    process_segments(zap_receipts; runctx, step=24*3600, sequential=false) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats) do session1
            pgt = PGTable(zap_receipts, session1)
            for r in Postgres.execute(session1, "
                                      select 
                                          id, pubkey, created_at, kind, tags, '', sig, imported_at
                                      from $(events.table)
                                      where 
                                          imported_at >= ?1 and imported_at <= ?2 and 
                                          kind = $(Int(Nostr.ZAP_RECEIPT))
                                      order by imported_at
                                      " |> rep,
                                      [t1, t2])[2]
                e = event_from_row(r)
                try
                    p = parse_zap_receipt(r[5])
                    if !isnothing(p.eid) && !isnothing(p.receiver) && !isnothing(p.sender) && p.amount_sats > 0
                        push!(pgt, (e.id, e.created_at, p.eid, p.sender, p.receiver, p.amount_sats, r[end]))
                    end
                catch ex
                    println(ex)
                end
            end
        end
    end

    (; zap_receipts)
end

function reads_node(
        events::ServerTable,
        basic_tags::ServerTable,
        zap_receipts::ServerTable,
        event_replies::ServerTable,
        a_tags::ServerTable;
        runctx::RunCtx,
        version=12,
    )
    reads = dbtable(:postgres, runctx.targetserver, "reads", version, 
                    [
                     events,
                     basic_tags,
                     zap_receipts,
                     event_replies,
                     a_tags,
                    ],
                    [
                     (:pubkey,            PubKeyId),
                     (:identifier,        String),

                     (:published_at,      Int), 
                     (:latest_eid,        EventId),
                     (:latest_created_at, Int),

                     (:likes,      Int),
                     (:zaps,       Int),
                     (:satszapped, Int),
                     (:replies,    Int),
                     (:reposts,    Int),

                     (:topics,    TSVector),
                     (:words,     Int),
                     (:lang,      String),
                     (:lang_prob, Float64),

                     (:image,   String),
                     (:summary, String),

                     "primary key (pubkey, identifier)",
                    ],
                    [
                     :pubkey,
                     :identifier,
                     :published_at,
                     :topics => "using GIN",
                    ];
                    runtag=runctx.runtag)

    reads_versions = dbtable(:postgres, runctx.targetserver, "reads_versions", version, 
                             [
                              events,
                             ],
                             [
                              (:pubkey,     PubKeyId),
                              (:identifier, String),
                              (:eid,        EventId),
                              "unique (pubkey, identifier, eid)",
                             ],
                             [
                              :pubkey,
                              :identifier,
                              :eid => "using HASH",
                              # "create index if not exists TABLE_eid on TABLE (eid) include (pubkey, identifier)",
                             ];
                             runtag=runctx.runtag)

    # step = nothing
    step = 90*24*3600
    # parallel_workers = 8
    parallel_workers = 0

    process_segments([reads, 1]; runctx, step, sequential=false) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats, parallel_workers) do session1
            reads_pgt = PGTable(reads, session1)
            reads_versions_pgt = PGTable(reads_versions, session1)

            rs = []
            for r in Postgres.execute(session1, "
                                      select 
                                          id, pubkey, created_at, kind, tags, content, sig, imported_at
                                      from $(events.table)
                                      where 
                                          imported_at >= ?1 and imported_at <= ?2 and 
                                          kind = $(Int(Nostr.LONG_FORM_CONTENT))
                                      " |> rep,
                                      [t1, t2])[2]
                runctx.running[] || break

                e = try
                    event_from_row(r)
                catch ex
                    println(ex)
                    continue
                end

                identifier = nothing
                topics = []
                published_at = nothing
                image = ""
                summary = ""
                try
                    for t in e.tags
                        if length(t.fields) >= 2
                            if t.fields[1] == "d"
                                identifier = t.fields[2]
                            end
                            if t.fields[1] == "t"
                                push!(topics, replace(t.fields[2], ' '=>'-'))
                            end
                            if t.fields[1] == "published_at"
                                published_at = parse(Int, t.fields[2])
                            end
                            if t.fields[1] == "image"
                                image = t.fields[2]
                            end
                            if t.fields[1] == "summary"
                                summary = t.fields[2]
                            end
                        end
                    end
                catch ex
                    println(ex)
                    continue
                end

                if !isnothing(identifier) && !isnothing(published_at)
                    words = length(split(e.content))

                    lang, lang_prob = if isempty(e.content)
                        "", 0.0
                    else
                        try
                            lr = Languages.detect(e.content)
                            Languages.isocode(lr[1]), lr[3]
                        catch _
                            "", 0.0
                        end
                    end

                    push!(rs, (; e.pubkey, identifier, eid=e.id, e.created_at, published_at, topics, words, lang, lang_prob, image, summary))
                end
            end

            for r in sort(rs; by=r->(r.pubkey, r.identifier))
                runctx.running[] || break

                @assert !isnull(r.identifier) r.identifier

                rd = get!(reads_pgt, (; r.pubkey, r.identifier)) do
                    (; 
                     r.pubkey, 
                     r.identifier, 

                     r.published_at, 
                     latest_eid=r.eid, 
                     latest_created_at=r.created_at,

                     likes=0,
                     zaps=0,
                     satszapped=0,
                     replies=0,
                     reposts=0,

                     topics=join(r.topics, ' '),
                     r.words,
                     r.lang,
                     r.lang_prob,

                     r.image,
                     r.summary,
                    )
                end

                if r.created_at > rd.latest_created_at
                    rd.latest_created_at = r.created_at
                    rd.latest_eid = r.eid
                    rd.words = r.words
                    rd.lang = r.lang
                    rd.lang_prob = r.lang_prob
                    rd.image = r.image
                    rd.summary = r.summary
                end

                save!(rd)

                push!(reads_versions_pgt, (rd.pubkey, rd.identifier, r.eid))
            end
        end
    end

    process_segments([reads, 2]; runctx, step) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats, parallel_workers) do session1
            Postgres.execute(session1, "
                             with a as (
                                 select 
                                     pubkey, identifier, count(1) as zaps, sum(zr.satszapped) as satszapped
                                 from 
                                     $(reads_versions.table) rv,
                                     $(zap_receipts.table) zr
                                 where 
                                    zr.imported_at >= \$1 and zr.imported_at <= \$2 and 
                                    zr.target_eid = rv.eid
                                group by (rv.pubkey, rv.identifier)
                                order by (rv.pubkey, rv.identifier)
                             )
                             update $(reads.table)
                             set zaps = $(reads.table).zaps + a.zaps, satszapped = $(reads.table).satszapped + a.satszapped
                             from a
                             where $(reads.table).pubkey = a.pubkey and $(reads.table).identifier = a.identifier
                             ", [t1, t2])
        end
    end

    process_segments([reads, 3]; runctx, step) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats, parallel_workers) do session1
            Postgres.execute(session1, "
                             with a as (
                                 select rv.pubkey, rv.identifier, count(1) as cnt
                                 from 
                                     $(reads_versions.table) rv,
                                     $(basic_tags.table) bt
                                 where 
                                    bt.imported_at >= \$1 and bt.imported_at <= \$2 and 
                                    bt.kind = $(Int(Nostr.REACTION)) and bt.arg1 = rv.eid
                                group by (rv.pubkey, rv.identifier)
                                order by (rv.pubkey, rv.identifier)
                             )
                             update $(reads.table)
                             set likes = likes + a.cnt
                             from a
                             where $(reads.table).pubkey = a.pubkey and $(reads.table).identifier = a.identifier
                             ", [t1, t2])
        end
    end

    process_segments([reads, 4]; runctx, step) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats, parallel_workers) do session1
            seen_reids = Set{Nostr.EventId}()
            for (pubkey, identifier, reid) in Postgres.execute(session1, "
                         WITH a AS (
                             SELECT
                                 reads_versions.pubkey,
                                 reads_versions.identifier,
                                 event_replies.reply_event_id
                             FROM
                                 $(reads_versions.table) reads_versions,
                                 $(event_replies.table) event_replies
                             WHERE
                                 reads_versions.eid = event_replies.event_id AND
                                 event_replies.reply_created_at >= \$1 AND
                                 event_replies.reply_created_at <= \$2
                         ), b AS (
                             SELECT
                                 a_tags.ref_pubkey AS pubkey,
                                 a_tags.ref_identifier AS identifier,
                                 a_tags.eid
                             FROM
                                 $(a_tags.table) a_tags
                             WHERE
                                 a_tags.kind = $(Int(Nostr.TEXT_NOTE)) AND
                                 a_tags.ref_kind = $(Int(Nostr.LONG_FORM_CONTENT)) AND
                                 a_tags.created_at >= \$1 AND
                                 a_tags.created_at <= \$2
                         )
                         SELECT * FROM ((SELECT * FROM a) UNION ALL (SELECT * FROM b)) c
                         ORDER BY (c.pubkey, c.identifier)
                         ", [t1, t2])[2]
                reid = EventId(reid)
                reid in seen_reids && continue
                push!(seen_reids, reid)
                r = Postgres.execute(session1, "select * from events where id = \$1", [reid])[2]
                if !isempty(r)
                    re = event_from_row(r[1])
                    if !any(true for t in re.tags if (t.fields[1] == "e" || t.fields[1] == "a") && (length(t.fields) < 4 || t.fields[4] != "root"))
                        Postgres.execute(session1, "
                                         UPDATE $(reads.table)
                                         SET replies = replies + 1
                                         WHERE $(reads.table).pubkey = \$1 AND $(reads.table).identifier = \$2
                                         ", [pubkey, identifier])
                    end
                end
            end
        end
    end

    process_segments([reads, 5]; runctx, step) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats, parallel_workers) do session1
            Postgres.execute(session1, "
                             with a as (
                                 select rv.pubkey, rv.identifier, count(1) as cnt
                                 from 
                                     $(reads_versions.table) rv,
                                     $(basic_tags.table) bt
                                 where 
                                    bt.imported_at >= \$1 and bt.imported_at <= \$2 and 
                                    bt.kind = $(Int(Nostr.REPOST)) and bt.arg1 = rv.eid
                                group by (rv.pubkey, rv.identifier)
                                order by (rv.pubkey, rv.identifier)
                             )
                             update $(reads.table)
                             set reposts = reposts + a.cnt
                             from a
                             where $(reads.table).pubkey = a.pubkey and $(reads.table).identifier = a.identifier
                             ", [t1, t2])
        end
    end

    (; reads, reads_versions)
end

function a_tags_node(
        events::ServerTable;
        runctx::RunCtx,
        version=1, 
    )
    a_tags = dbtable(:postgres, runctx.targetserver, "a_tags", version, 
                         [
                          events,
                         ],
                         [
                          (:i, (BigSerial, "primary key")),

                          (:eid,        EventId),
                          (:kind,       Int),
                          (:created_at, Int),

                          (:ref_kind,       Int),
                          (:ref_pubkey,     PubKeyId),
                          (:ref_identifier, String),
                          (:ref_arg4,       String),

                          (:imported_at, Int),

                          "unique (eid, ref_kind, ref_pubkey, ref_identifier, ref_arg4)",
                         ],
                         [
                          :eid,
                          :created_at,
                          (:ref_kind, :ref_pubkey),
                          (:ref_kind, :ref_pubkey, :ref_identifier),
                          :imported_at,
                         ];
                         runtag=runctx.runtag)
    # return (; a_tags)

    @assert a_tags.server == events.server

    process_segments(a_tags; runctx, step=90*24*3600, sequential=true) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats, parallel_workers=8) do session1
            mktmp_q = "
            create temp table t as 
            select 
                id, 
                kind,
                created_at,
                split_part(t->>1, ':', 1)::int8 as ref_kind, 
                decode(split_part(t->>1, ':', 2), 'hex') as ref_pubkey, 
                split_part(t->>1, ':', 3) as ref_identifier, 
                coalesce(t->>4, '') as ref_arg4, 
                imported_at 
            from (
                select 
                    id, kind, created_at, jsonb_array_elements(tags) as t, imported_at from $(events.table)
                where 
                    imported_at >= \$1 and imported_at <= \$2 and 
                    jsonb_array_length(tags) < 50
                ) a 
                where 
                    t->>0 = 'a' and 
                    split_part(t->>1, ':', 1) ~* '^[0-9]+\$' and
                    split_part(t->>1, ':', 2) ~* '^[0-9a-f]{64}\$'
            "
            runctx.explain && runctx.log(display_to_string(Postgres.execute(session1, "explain $(mktmp_q)", [t1, t2])[2]))
            Postgres.execute(session1, mktmp_q, [t1, t2])

            # @show Postgres.execute(session1, "select count(1) from t")[2]

            insert_q = "
            insert into $(a_tags.table)
                (eid, kind, created_at, ref_kind, ref_pubkey, ref_identifier, ref_arg4, imported_at)
            select * from t on conflict do nothing
            "
            # println(insert_q)
            runctx.explain && runctx.log(display_to_string(Postgres.execute(session1, "explain $(insert_q)")[2]))
            Postgres.execute(session1, insert_q)

            Postgres.execute(session1, "drop table t")
        end
    end

    (; a_tags)
end

# function events_no_spam_node(
#         events::ServerTable;
#         runctx::RunCtx,
#         version=1,
#     )
#     events_no_spam = dbtable(:postgres, runctx.targetserver, "events_no_spam", version, 
#                             [
#                              events,
#                             ],
#                             [
#                              (:eid,         EventId),
#                              (:created_at,  Int),
#                              (:imported_at, Int),

#                              "primary key eid",
#                             ],
#                             [
#                              :created_at,
#                              :imported_at,
#                             ];
#                             runtag=runctx.runtag)

#     process_segments(events_no_spam; runctx, step=24*3600, sequential=true) do t1, t2
#         transaction_with_execution_stats(events.server; runctx.stats) do session1
#             events_no_spam_pgt = PGTable(events_no_spam, session1)

#             rs = []
#             for r in Postgres.execute(session1, "
#                                       select 
#                                           id, created_at, content, imported_at
#                                       from $(events.table)
#                                       where 
#                                           imported_at >= ?1 and imported_at <= ?2 and 
#                                           kind = $(Int(Nostr.TEXT_NOTE))
#                                       " |> rep,
#                                       [t1, t2])[2]
#                 imported_at = r[4]
#                 e = try
#                     Nostr.Event(Nostr.EventId(r[1]), Nostr.PubKeyId(zeros(UInt8, 32)), r[2], 1, [], r[3], Nostr.Sig(zeros(UInt8, 64)))
#                 catch ex
#                     println(ex)
#                     continue
#                 end

#                 push!(events_no_spam_pgt, (e.id, e.created_at, imported_at))
#             end
#         end
#     end

#     (; events_no_spam)
# end

function get_sentiments(sequences::Vector{String})
    JSON.parse(String(HTTP.request("POST", "http://192.168.50.1:5010/classify", ["Content-Type"=>"application/json"], 
                                   JSON.json((; sequences, labels=["positive", "negative", "question", "neutral"])); 
                                   retry=false, connect_timeout=5, read_timeout=5).body))
end

function event_sentiment_node(;
        events::ServerTable,
        pubkey_trustrank::ServerTable,
        runctx::RunCtx,
        version=1,
        since=max(runctx.since, current_time() - 1800),
        until=min(runctx.until, current_time()),
    )

    event_sentiment = dbtable(:postgres, runctx.targetserver, "event_sentiment", version, 
                              [
                               events,
                               pubkey_trustrank,
                              ],
                              [
                               (:eid,       EventId),
                               (:model,     String),

                               (:topsentiment, Char), # + - 0 ?

                               (:positive_prob, Float64),
                               (:negative_prob, Float64),
                               (:question_prob, Float64),
                               (:neutral_prob, Float64),

                               (:imported_at, Int),

                               "primary key (eid, model)",
                              ],
                              [
                               :topsentiment,
                              ];
                              runtag=runctx.runtag)

    process_segments(event_sentiment; runctx, step=24*3600, sequential=false,
                     since, until,
                    ) do t1, t2
        transaction_with_execution_stats(events.server; runctx.stats) do session1
            event_sentiment_pgt = PGTable(event_sentiment, session1)

            rs = Postgres.pex(session1, "
                              SELECT
                                  es.*
                              FROM
                                  $(events.table) es,
                                  $(pubkey_trustrank.table) tr
                              WHERE 
                                  es.imported_at >= ?1 AND es.imported_at <= ?2 AND 
                                  es.pubkey = tr.pubkey AND
                                  es.kind = $(Int(Nostr.TEXT_NOTE))
                              ", [t1, t2])

            cnt = 0
            for (i, r) in enumerate(rs)
                runctx.running[] || break

                e = try
                    event_from_row(r)
                catch ex
                    println(ex)
                    continue
                end

                # ok = false
                # for w in [
                #           "primal",
                #           Nostr.bech32_encode(Main.test_pubkeys[:miljan]),
                #           "npub12vkcxr0luzwp8e673v29eqjhrr7p9vqq8asav85swaepclllj09sylpugg", # primal@primal.net
                #          ]
                #     if occursin(w, lowercase(e.content))
                #         ok = true
                #         break
                #     end
                # end
                # for w in [
                #           "https://m.primal.net",
                #           "https://primal.net",
                #           "https://primal.b-cdn.net",
                #          ]
                #     if occursin(w, lowercase(e.content))
                #         ok = false
                #         break
                #     end
                # end
                # ok || continue

                # s = join(first(filter(!isempty, map(string, split(e.content))), 100), ' ')
                s = e.content
                isempty(s) && continue

                # @show s
                res = get_sentiments([s])[1]
                nt = NamedTuple(zip(map(Symbol, res["labels"]), res["scores"]))
                toplabel = res["labels"][argmax(res["scores"])]
                tl = 
                if     toplabel == "positive"; '+'
                elseif toplabel == "negative"; '-'
                elseif toplabel == "question"; '?'
                elseif toplabel == "neutral";  '0'
                else; error("unexpected toplabel: $toplabel")
                end

                push!(event_sentiment_pgt, (e.id,
                                            res["model"],
                                            tl,

                                            nt.positive,
                                            nt.negative,
                                            nt.question,
                                            nt.neutral,

                                            r[end]))

                cnt += 1
                runctx.log("$i / $(length(rs)) / $cnt   $tl")
            end
        end
    end

    (; event_sentiment)
end

function pubkey_media_cnt_node(
        events::ServerTable,
        event_media::ServerTable;
        runctx::RunCtx,
        version=1,
    )
    pubkey_media_cnt = dbtable(:postgres, runctx.targetserver, "pubkey_media_cnt", version, 
                    [
                     events,
                     event_media,
                    ],
                    [
                     (:pubkey, PubKeyId),
                     (:cnt,    Int), 

                     "primary key (pubkey)",
                    ],
                    [
                     :pubkey,
                    ];
                    runtag=runctx.runtag)

    # step = nothing
    step = 90*24*3600

    process_segments([pubkey_media_cnt, 1]; runctx, step) do t1, t2
        transaction_with_execution_stats(runctx.targetserver; runctx.stats) do session1
            Postgres.execute(session1, "
                             with a as (
                                 select
                                    es.pubkey,
                                    count(1)
                                 from 
                                    $(events.table) es, 
                                    $(event_media.table) em
                                 where 
                                    es.imported_at >= \$1 and es.imported_at <= \$2 and 
                                    es.id = em.event_id and es.kind = $(Int(Nostr.TEXT_NOTE))
                                group by (es.pubkey)
                                order by (es.pubkey)
                             )
                             insert into $(pubkey_media_cnt.table) (pubkey, cnt)
                             select * from a
                             on conflict (pubkey) do update set cnt = $(pubkey_media_cnt.table).cnt + excluded.cnt
                             ", [t1, t2])
        end
    end

    (; pubkey_media_cnt)
end

function pubkey_content_zap_cnt_node(
        zap_receipts::ServerTable;
        runctx::RunCtx,
        version=1,
    )
    pubkey_content_zap_cnt = dbtable(:postgres, runctx.targetserver, "pubkey_content_zap_cnt", version, 
                                     [
                                      zap_receipts,
                                     ],
                                     [
                                      (:pubkey, PubKeyId),
                                      (:cnt,    Int), 

                                      "primary key (pubkey)",
                                     ],
                                     [
                                      :pubkey,
                                     ];
                                     runtag=runctx.runtag)

    # step = nothing
    step = 90*24*3600

    process_segments([pubkey_content_zap_cnt, 1]; runctx, step) do t1, t2
        transaction_with_execution_stats(runctx.targetserver; runctx.stats) do session1
            Postgres.execute(session1, "
                             with a as (
                                 select
                                    zr.sender,
                                    count(1)
                                 from 
                                    $(zap_receipts.table) zr
                                 where 
                                    zr.imported_at >= \$1 and zr.imported_at <= \$2
                                group by (zr.sender)
                                order by (zr.sender)
                             )
                             insert into $(pubkey_content_zap_cnt.table) (pubkey, cnt)
                             select * from a
                             on conflict (pubkey) do update set cnt = $(pubkey_content_zap_cnt.table).cnt + excluded.cnt
                             ", [t1, t2])
        end
    end

    (; pubkey_content_zap_cnt)
end

function parse_zap_receipt(tags::Vector)
    eid = nothing
    receiver = sender = nothing
    amount_sats = 0
    for t in tags
        if length(t) >= 2
            if t[1] == "e"
                eid = EventId(t[2])
            elseif t[1] == "p"
                receiver = PubKeyId(t[2])
            elseif t[1] == "P"
                sender = PubKeyId(t[2])
            elseif t[1] == "a"
                kind, pubkey, identifier = map(string, split(t[2], ':'))
                for r in Postgres.execute(MAIN_SERVER[], "select event_id from parametrized_replaceable_events where kind = \$1 and pubkey = \$2 and identifier = \$3 limit 1",
                                          [kind, Nostr.PubKeyId(pubkey), identifier])[2]
                    eid = EventId(r[1])
                end
            elseif t[1] == "bolt11"
                if !isnothing(local amount = DB.parse_bolt11(t[2]))
                    if amount <= DB.MAX_SATSZAPPED[]
                        amount_sats = amount
                    end
                end
            end
        end
    end
    (; eid, sender, receiver, amount_sats)
end

function import_event_mentions(est::DB.CacheStorage, event_mentions::ServerTable, e::Nostr.Event; connsel=est.dbargs.connsel)
    DB.for_mentiones(est, e; resolve_parametrized_replaceable_events=false) do tag
        tag = tag.fields
        argeid = argpubkey = argkind = argid = nothing
        if length(tag) >= 2
            if tag[1] == "e" && !isnothing(local subeid = try Nostr.EventId(tag[2]) catch _ end)
                argeid = subeid
            elseif tag[1] == "p" && !isnothing(local pk = try Nostr.PubKeyId(tag[2]) catch _ end)
                argpubkey = pk
            elseif tag[1] == "a"
                if !isnothing(local args = try
                                  kind, pk, identifier = map(string, split(tag[2], ':'))
                                  kind = parse(Int, kind)
                                  (Nostr.PubKeyId(pk), kind, identifier)
                              catch _ end)
                    argpubkey, argkind, argid = args
                end
            end
        end
        if !isnothing(argeid) || !isnothing(argpubkey)
            Postgres.execute(connsel, "
                             insert into $(event_mentions.table)
                             values (\$1, \$2, \$3, \$4, \$5, \$6)
                             on conflict do nothing
                             ",
                             [e.id, tag[1], argeid, argpubkey, argkind, argid])
        end
    end
end

function event_mentions_node(
        events::ServerTable,
        parametrized_replaceable_events::ServerTable;
        runctx::RunCtx,
        version=1,
        # since=max(runctx.since, current_time() - 30*24*3600),
        # until=min(runctx.until, current_time()),
    )
    event_mentions = dbtable(:postgres, runctx.targetserver, "event_mentions", version, 
                             [
                              events,
                              parametrized_replaceable_events,
                             ],
                             [
                              (:eid, EventId),
                              (:tag, Char), 
                              (:argeid, (EventId, "")),
                              (:argpubkey, (PubKeyId, "")),
                              (:argkind, (Int, "")),
                              (:argid, (String, "")),
                             ],
                             [
                              :eid,
                              # "create unique index if not exists TABLE_unique on TABLE (eid, tag, argeid, argpubkey, argkind, argid) nulls not distinct",
                             ];
                             runtag=runctx.runtag)

    # step = nothing
    step = 1*24*3600

    process_segments([event_mentions, 1]; runctx, step) do t1, t2
        transaction_with_execution_stats(runctx.targetserver; runctx.stats) do session1
            for r in Postgres.execute(session1, "
                                      select * from $(events.table)
                                      where 
                                        imported_at >= \$1 and imported_at <= \$2 and
                                        (kind = $(Int(Nostr.TEXT_NOTE)) or kind = $(Int(Nostr.LONG_FORM_CONTENT)) or kind = $(Int(Nostr.REPOST)))
                                      ", [t1, t2])[2]
                e = event_from_row(r)
                import_event_mentions(runctx.est, event_mentions, e; connsel=session1)
            end
        end
    end

    (; event_mentions)
end

function note_length_node(;
        events::ServerTable,
        runctx::RunCtx,
        version=1,
        since=max(runctx.since, current_time() - 15*24*3600),
    )
    note_length = dbtable(:postgres, runctx.targetserver, "note_length", version, 
                          [
                           events,
                          ],
                          [
                           (:eid, EventId),
                           (:length, Int), 
                           "primary key (eid)",
                          ],
                          [
                          ];
                          runtag=runctx.runtag)

    step = 1*24*3600

    process_segments([note_length, 1]; runctx, step, since) do t1, t2
        transaction_with_execution_stats(runctx.targetserver; runctx.stats) do session1
            Postgres.execute(session1, "
                             insert into $(note_length.table)
                             select id as eid, length(content) 
                             from $(events.table)
                             where 
                                 imported_at >= \$1 and imported_at <= \$2 and
                                 (kind = $(Int(Nostr.TEXT_NOTE)) or kind = $(Int(Nostr.LONG_FORM_CONTENT)) or kind = $(Int(Nostr.REPOST)))
                             on conflict do nothing
                             ", [t1, t2])
        end
    end

    (; note_length)
end

function note_stats_node(;
        events::ServerTable,
        pubkey_trustrank::ServerTable,
        runctx::RunCtx,
        version=1,
        since=max(runctx.since, current_time() - 30*24*3600),
    )
    note_stats = dbtable(:postgres, runctx.targetserver, "note_stats", version, 
                         [
                          events,
                         ],
                         [
                          (:eid, EventId),
                          (:long_replies, Int), 
                          "primary key (eid)",
                         ],
                         [
                         ];
                          runtag=runctx.runtag)

    step = 1*24*3600

    process_segments([note_stats, 1]; runctx, step, since) do t1, t2
        transaction_with_execution_stats(runctx.targetserver; runctx.stats) do session1
            pex(q, args=[]) = Postgres.execute(session1, q, args)[2]
            rank = pex("select humaness_threshold_trustrank()")[1][1]
            peids = Nostr.EventId[]
            for r in pex("
                    select 
                        es.* 
                    from 
                        $(events.table) es
                    where 
                        es.imported_at >= \$1 and es.imported_at <= \$2 and
                        es.kind = $(Int(Nostr.TEXT_NOTE))
                    order by es.id
                    ", [t1, t2])
                yield()
                runctx.running[] || break
                e = event_from_row(r)
                isempty(pex("select 1 from $(pubkey_trustrank.table) where pubkey = \$1 and rank >= \$2", [e.pubkey, rank])) && continue
                if !isnothing(local parent_eid = DB.parse_parent_eid(runctx.est, e))
                    if length(e.content) >= 600
                        push!(peids, parent_eid)
                    end
                end
            end
            for peid in sort(peids)
                pex("insert into $(note_stats.table) values (\$1, 0) on conflict do nothing", [peid])
                pex("update $(note_stats.table) set long_replies = long_replies + 1 where eid = \$1", [peid])
            end
        end
    end

    (; note_stats)
end

function update_user_search_node(;
        human_override::ServerTable,
        runctx::RunCtx,
        version=1,
        since=max(runctx.since, current_time() - 3*24*3600),
    )
    step = 1*24*3600

    process_segments(["update_user_search/1", human_override]; runctx, step, since) do t1, t2
        transaction_with_execution_stats(runctx.targetserver; runctx.stats) do session1
            for (pk, added_at) in Postgres.execute(session1, "
                    select 
                        ho.pubkey, ho.added_at
                    from 
                        $(human_override.table) ho
                    where 
                        ho.added_at >= to_timestamp(\$1) and ho.added_at <= to_timestamp(\$2)
                    order by ho.pubkey
                    ", [t1, t2])[2]
                yield()
                runctx.running[] || break
                pk = Nostr.PubKeyId(pk)
                Main.DB.update_user_search(runctx.est, pk)
            end
        end
    end

    (; )
end

function postgres_dbtable_code_from_sqlite(source, destname::String)
    columns = []
    indexes = []
    for (type, name, table, _, sql) in DB.exec(source, "SELECT * FROM sqlite_schema")
        ismissing(sql) && continue
        table != source.table && continue
        if type == "table"
            primarykey = nothing
            s = sql[findfirst('(', sql)+1:findlast(')', sql)-1]
            for f in map(strip, split(s, ','))
                isempty(f) && continue
                ps = split(f)
                @show ps
                if length(ps) < 2
                    @warn "postgres_dbtable_code_from_sqlite: skipping column $(repr(f))"
                    name = :UNRECOGNIZED
                    type = f
                else
                    name = ps[1]
                    ty   = ps[2]
                    if     ty == "blob"; type = Vector{UInt8}
                    elseif ty == "text"; type = String
                    elseif ty == "int" || ty == "integer"; type = Int
                    elseif ty == "number"; type = Float64
                    else
                        @warn "postgres_dbtable_code_from_sqlite: skipping column $name, unrecognized type $(repr(f))"
                        type = :UNRECOGNIZED
                    end
                    occursin("primary key", f) && (primarykey = name)
                end
                push!(columns, (Symbol(name), type))
            end
            push!(columns, (:rowid, Int))
            !isnothing(primarykey) && push!(columns, "primary key ($primarykey)")
        elseif type == "index"
            cols = []
            s = sql[findfirst('(', sql)+1:findlast(')', sql)-1]
            for f in map(strip, split(s, ','))
                ps = split(f)
                @show ps
                name = ps[1]
                order = "asc"
                length(ps) >= 2 && (order = ps[2])
                push!(cols, Symbol(name))
            end
            push!(indexes, length(cols) == 1 ? cols[1] : Tuple(cols))
        end
    end
    push!(indexes, :rowid)
    expr = :($(Symbol(destname)) = 
             sqlite_to_postgres_transfer(runctx.est.$(Symbol(destname)), 
                                         dbtable(:postgres, runctx.targetserver, $destname, 1,
                                                 [],
                                                 $columns,
                                                 $indexes;
                                                 runctx.runtag);
                                         runctx))

    JuliaFormatter.format_text(replace(string(expr), "Any["=>"["))
end

using Printf: @sprintf

function sqlite_to_postgres_transfer(source, dest::ServerTable; runctx, wheres=nothing, transform=identity, recentonly=false)
    @assert dest.columns[end][1] == :rowid  display(dest)
    process_segments([dest, 1]; runctx, step=nothing, sequential=true) do t1, t2
        i, j = transaction_with_execution_stats(dest.server; runctx.stats) do session1
            r = DB.exec(source, "select rowid from $(source.table) order by rowid desc limit 1")
            j = isempty(r) ? 0 : r[1][1]

            r = Postgres.execute(session1, "select rowid from $(dest.table) order by rowid desc limit 1")[2]
            i = isempty(r) ? 0 : r[1][1]

            i, j
        end

        if recentonly
            i = max(i, j-300000)
        end

        n = 100000
        is = collect(i:n:(j-1))

        for i in is
            runctx.running[] || break
            runctx.log("$(string(dest)): $i / $j "*(@sprintf "(%.1f%%)" (100.0*i/j)))
            transaction_with_execution_stats(dest.server; runctx.stats) do session1
                rs = DB.exec(source, "
                        select $(join([string(c[1]) for c in dest.columns], ", "))
                        from $(source.table)
                        where rowid > ?1 and rowid <= ?2 $(isnothing(wheres) ? "" : "and "*wheres)
                        order by rowid
                        ", (i, i+n-1))
                multi_insert(session1, dest, map(transform, rs))
            end
        end
    end
end

function sqlite2pg_node(;
        runctx::RunCtx,
        version=2,
        skipprocessing=false,
    )
    sources = 
    [
     (:event_created_at, ()->runctx.est.event_created_at, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_created_at", 1,
              [],
              [
               (:event_id, EventId),
               (:created_at, Int),
               (:rowid, (Int64, "default 0")), 
               "primary key (event_id)",
              ],
              [
               :created_at,
               :rowid, 
              ];
              runctx.runtag)),

     (:pubkey_events, ()->runctx.est.pubkey_events, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "pubkey_events", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:event_id, EventId),
               (:created_at, Int64),
               (:is_reply, Int64),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :pubkey, 
               :event_id, 
               :created_at,
               (:pubkey, :created_at),
               (:pubkey, :is_reply),
               :rowid, 
              ];
              runctx.runtag)),

     (:pubkey_ids, ()->runctx.est.pubkey_ids, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "pubkey_ids", 1,
              [],
              [
               (:key, PubKeyId), 
               (:value, Int64), 
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key,
               :rowid, 
              ];
              runctx.runtag,
             )),

     (:pubkey_followers, ()->runctx.est.pubkey_followers, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "pubkey_followers", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:follower_pubkey, PubKeyId),
               (:follower_contact_list_event_id, EventId),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :pubkey, 
               :follower_pubkey, 
               :follower_contact_list_event_id,
               (:follower_pubkey, :pubkey),
               :rowid,
              ];
              runctx.runtag)),

     (:pubkey_followers_cnt, ()->runctx.est.pubkey_followers_cnt, "", [],
      dbtable(:postgres, runctx.targetserver, "pubkey_followers_cnt", 1,
              [],
              [
               (:key, PubKeyId), 
               (:value, Int64), 
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key, 
               :value,
               :rowid,
              ];
              runctx.runtag)),

     (:contact_lists, ()->runctx.est.contact_lists, "", [],
      dbtable(:postgres, runctx.targetserver, "contact_lists", 1,
              [],
              [
               (:key, PubKeyId), 
               (:value, EventId), 
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key,
               :rowid,
              ];
              runctx.runtag)),

     (:meta_data, ()->runctx.est.meta_data, "", [],
      dbtable(:postgres, runctx.targetserver, "meta_data", 1,
              [],
              [
               (:key, PubKeyId), 
               (:value, EventId), 
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key,
               :rowid,
              ];
              runctx.runtag)),

     (:event_stats, ()->runctx.est.event_stats, "", [:testwithrecent],
      (r)->(r[1:3]..., [trunc(Int, x) for x in r[4:end]]...),
      dbtable(:postgres, runctx.targetserver, "event_stats", 1,
              [],
              [
               (:event_id, EventId),
               (:author_pubkey, PubKeyId),
               (:created_at, Int64),
               (:likes, Int64),
               (:replies, Int64),
               (:mentions, Int64),
               (:reposts, Int64),
               (:zaps, Int64),
               (:satszapped, Int64),
               (:score, Int64),
               (:score24h, Int64),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :event_id,
               :author_pubkey,
               :created_at,
               :score,
               :score24h,
               :satszapped,

               :likes,
               :replies,
               :mentions,
               :reposts,
               :zaps,

               (:created_at, :satszapped),
               (:created_at, :score24h),
               (:author_pubkey, :created_at),
               (:author_pubkey, :score),
               (:author_pubkey, :score24h),
               (:author_pubkey, :satszapped),

               :rowid,
              ];
              runctx.runtag,
             )),

     (:event_stats_by_pubkey, ()->runctx.est.event_stats_by_pubkey, "", [:testwithrecent],
      (r)->(r[1:3]..., [trunc(Int, x) for x in r[4:end]]...),
      dbtable(:postgres, runctx.targetserver, "event_stats_by_pubkey", 1,
              [],
              [
               (:event_id, EventId),
               (:author_pubkey, PubKeyId),
               (:created_at, Int64),
               (:likes, Int64),
               (:replies, Int64),
               (:mentions, Int64),
               (:reposts, Int64),
               (:zaps, Int64),
               (:satszapped, Int64),
               (:score, Int64),
               (:score24h, Int64),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :event_id,
               :author_pubkey,
               :created_at,
               :score,
               :score24h,
               :satszapped,
               (:created_at, :satszapped),
               (:created_at, :score24h),
               :rowid,
              ];
              runctx.runtag,
             )),

     (:event_replies, ()->runctx.est.event_replies, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_replies", 1,
              [],
              [
               (:event_id, EventId),
               (:reply_event_id, EventId),
               (:reply_created_at, Int),
               (:rowid, (Int64, "default 0")), 
              ],
              [
               :event_id,
               :reply_created_at,
               :rowid,
              ];
              runctx.runtag)),

     (:event_thread_parents, ()->runctx.est.event_thread_parents, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_thread_parents", 1,
              [],
              [
               (:key, EventId),
               (:value, EventId),
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key,
               :rowid, 
              ];
              runctx.runtag)),

     (:event_pubkey_actions, ()->runctx.est.event_pubkey_actions, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_pubkey_actions", 1,
              [],
              [
               (:event_id, EventId),
               (:pubkey, PubKeyId),
               (:created_at, Int64),
               (:updated_at, Int64),
               (:replied, Int64),
               (:liked, Int64),
               (:reposted, Int64),
               (:zapped, Int64),
               (:rowid, (Int64, "default 0")),
               "primary key (event_id, pubkey)",
              ],
              [
               :event_id, 
               :pubkey, 
               :created_at, 
               :updated_at,
               :rowid, 
              ];
              runctx.runtag)),

     (:event_pubkey_action_refs, ()->runctx.est.event_pubkey_action_refs, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_pubkey_action_refs", 1,
              [],
              [
               (:event_id, EventId),
               (:ref_event_id, EventId),
               (:ref_pubkey, PubKeyId),
               (:ref_created_at, Int64),
               (:ref_kind, Int64),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :event_id,
               :ref_event_id,
               :ref_pubkey,
               :ref_created_at,
               :ref_kind,
               (:ref_event_id, :ref_pubkey),
               (:ref_event_id, :ref_kind),
               :rowid, 
              ];
              runctx.runtag)),

     (:deleted_events, ()->runctx.est.deleted_events, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "deleted_events", 1,
              [],
              [
               (:event_id, EventId),
               (:deletion_event_id, EventId),
               (:rowid, (Int64, "default 0")), 
               "primary key (event_id)",
              ],
              [
               :event_id,
               :rowid, 
              ];
              runctx.runtag)),

     (:mute_list, ()->runctx.est.mute_list, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "mute_list", 1,
              [],
              [
               (:key, PubKeyId),
               (:value, EventId),
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key,
               :rowid, 
              ];
              runctx.runtag)),

     (:mute_list_2, ()->runctx.est.mute_list_2, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "mute_list_2", 1,
              [],
              [
               (:key, PubKeyId),
               (:value, EventId),
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key,
               :rowid, 
              ];
              runctx.runtag)),

     (:mute_lists, ()->runctx.est.mute_lists, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "mute_lists", 1,
              [],
              [
               (:key, PubKeyId),
               (:value, EventId),
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key,
               :rowid, 
              ];
              runctx.runtag)),

     (:allow_list, ()->runctx.est.allow_list, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "allow_list", 1,
              [],
              [
               (:key, PubKeyId),
               (:value, EventId),
               (:rowid, (Int64, "default 0")), 
               "primary key (key)",
              ],
              [
               :key,
               :rowid, 
              ];
              runctx.runtag)),

     (:parameterized_replaceable_list, ()->runctx.est.parameterized_replaceable_list, "", [],
      dbtable(:postgres, runctx.targetserver, "parameterized_replaceable_list", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:identifier, String),
               (:created_at, Int),
               (:event_id, EventId),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :pubkey, 
               :identifier, 
               :created_at,
               :rowid, 
              ];
              runctx.runtag)),

     (:pubkey_directmsgs, ()->runctx.est.pubkey_directmsgs, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "pubkey_directmsgs", 1,
              [],
              [
               (:receiver, PubKeyId),
               (:sender, PubKeyId),
               (:created_at, Int),
               (:event_id, EventId),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :receiver, 
               :sender, 
               :created_at, 
               (:receiver, :sender),
               (:receiver, :event_id),
               :rowid, 
              ];
              runctx.runtag)),

     (:pubkey_directmsgs_cnt, ()->runctx.est.pubkey_directmsgs_cnt, "", [],
      dbtable(:postgres, runctx.targetserver, "pubkey_directmsgs_cnt", 1,
              [],
              [
               (:receiver, PubKeyId),
               (:sender, (PubKeyId, "")),
               (:cnt, Int64),
               (:latest_at, Int64),
               (:latest_event_id, EventId),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :receiver, 
               :sender, 
               (:receiver, :sender),
               :rowid, 
              ];
              runctx.runtag)),

     (:og_zap_receipts, ()->runctx.est.zap_receipts, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "og_zap_receipts", 1,
              [],
              [
               (:zap_receipt_id, EventId),
               (:created_at, Int64),
               (:sender, PubKeyId),
               (:receiver, PubKeyId),
               (:amount_sats, Int64),
               (:event_id, EventId),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :sender, 
               :receiver, 
               :created_at, 
               :event_id, 
               :amount_sats,
               :rowid, 
              ];
              runctx.runtag)),

     (:pubkey_zapped, ()->runctx.est.ext[].pubkey_zapped,  "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "pubkey_zapped", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:zaps, Int64),
               (:satszapped, Int64),
               (:rowid, (Int64, "default 0")), 
               "primary key (pubkey)",
              ],
              [
               :pubkey, 
               :zaps, 
               :satszapped,
               :rowid, 
              ];
              runctx.runtag)),

     (:media, ()->runctx.est.ext[].media, "length(url) < 2000", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "media", 1,
              [],
              [
               (:url, String),
               (:media_url, String),
               (:size, String),
               (:animated, Int64),
               (:imported_at, Int64),
               (:download_duration, Float64),
               (:width, Int64),
               (:height, Int64),
               (:mimetype, String),
               (:category, String),
               (:category_confidence, Float64),
               (:duration, Float64),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :url, 
               :media_url, 
               (:url, :size, :animated),
               :imported_at, 
               :category,
               :rowid, 
              ];
              runctx.runtag)),

     (:event_media, ()->runctx.est.ext[].event_media,  "length(url) < 2000", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_media", 1,
              [],
              [
               (:event_id, EventId), 
               (:url, String),
               (:rowid, (Int64, "default 0")), 
               "primary key (event_id, url)",
              ],
              [
               :event_id, 
               :url,
               :rowid, 
              ];
              runctx.runtag)),

     (:preview, ()->runctx.est.ext[].preview, "length(url) < 2000", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "preview", 1,
              [],
              [
               (:url, String),
               (:imported_at, Int64),
               (:download_duration, Float64),
               (:mimetype, String),
               (:category, String),
               (:category_confidence, Float64),
               (:md_title, String),
               (:md_description, String),
               (:md_image, String),
               (:icon_url, String),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :url, 
               :imported_at, 
               :category,
               :rowid, 
              ];
              runctx.runtag)),

     (:event_preview, ()->runctx.est.ext[].event_preview, "length(url) < 2000", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_preview", 1,
              [],
              [
               (:event_id, EventId),
               (:url, String),
               (:rowid, (Int64, "default 0")), 
              ],
              [
               :event_id, 
               :url,
               :rowid, 
              ];
              runctx.runtag)),

     (:event_hashtags, ()->runctx.est.ext[].event_hashtags, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_hashtags", 1,
              [],
              [
               (:event_id, EventId),
               (:hashtag, String),
               (:created_at, Int64),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :event_id, 
               :hashtag, 
               :created_at,
               :rowid, 
              ];
              runctx.runtag)),

     (:hashtags, ()->runctx.est.ext[].hashtags, "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "hashtags", 1,
              [],
              [
               (:hashtag, String), 
               (:score, Int64),
               (:rowid, (Int64, "default 0")), 
              ],
              [
               :hashtag, 
               :score,
               :rowid, 
              ];
              runctx.runtag)),

     (:pubkey_notifications, ()->runctx.est.ext[].notifications.pubkey_notifications, "", [:testwithrecent],
      (r)->(r[1:5]..., [JSON.json(x) for x in r[6:7]]...),
      dbtable(:postgres, runctx.targetserver, "pubkey_notifications", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:created_at, Int64),
               (:type, Int64),
               (:arg1, Vector{UInt8}),
               (:arg2, (Vector{UInt8}, "")),
               (:arg3, (Dict, "")),
               (:arg4, (Dict, "")),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :pubkey, 
               :created_at, 
               :type, 
               :arg1,
               :arg2,
               (:pubkey, :created_at),
               (:pubkey, :created_at, :type),
               # (:pubkey, :arg1),
               # (:pubkey, :arg2),
               :rowid, 
               "create index if not exists TABLE_pubkey_arg1_idx_ on TABLE (pubkey, arg1) where type != 1 and type != 2",
               "create index if not exists TABLE_pubkey_arg2_idx_ on TABLE (pubkey, arg2) where type != 1 and type != 2",
              ];
              runctx.runtag)),

     (:pubkey_notification_cnts, ()->runctx.est.ext[].notifications.pubkey_notification_cnts, "", [],
      dbtable(:postgres, runctx.targetserver, "pubkey_notification_cnts", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:type1, (Int64, "default 0")),
               (:type2, (Int64, "default 0")),
               (:type3, (Int64, "default 0")),
               (:type4, (Int64, "default 0")),
               (:type5, (Int64, "default 0")),
               (:type6, (Int64, "default 0")),
               (:type7, (Int64, "default 0")),
               (:type8, (Int64, "default 0")),
               (:type101, (Int64, "default 0")),
               (:type102, (Int64, "default 0")),
               (:type103, (Int64, "default 0")),
               (:type104, (Int64, "default 0")),
               (:type201, (Int64, "default 0")),
               (:type202, (Int64, "default 0")),
               (:type203, (Int64, "default 0")),
               (:type204, (Int64, "default 0")),
               (:rowid, (Int64, "default 0")),
               "primary key (pubkey)",
              ],
              [
               :pubkey,
               :rowid, 
              ];
              runctx.runtag)),

     (:pubkey_ln_address, ()->runctx.est.dyn[:pubkey_ln_address], "", [],
      dbtable(:postgres, runctx.targetserver, "pubkey_ln_address", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:ln_address, String),
               (:rowid, (Int64, "default 0")),
               "primary key (pubkey)",
              ],
              [
               :pubkey, 
               :ln_address,
               :rowid, 
              ];
              runctx.runtag)),

     (:relay_list_metadata, ()->runctx.est.dyn[:relay_list_metadata], "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "relay_list_metadata", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:event_id, EventId),
               (:rowid, (Int64, "default 0")),
               "primary key (pubkey)",
              ],
              [
               :pubkey,
               :rowid, 
              ];
              runctx.runtag)),

     (:bookmarks, ()->runctx.est.dyn[:bookmarks], "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "bookmarks", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:event_id, EventId),
               (:rowid, (Int64, "default 0")),
               "primary key (pubkey)",
              ],
              [
               :pubkey,
               :rowid,
              ];
              runctx.runtag)),

     # (:event_relay, ()->runctx.est.dyn[:event_relay], "",
     #  dbtable(:postgres, runctx.targetserver, "event_relay", 1,
     #          [],
     #          [
     #           (:key, EventId),
     #           (:value, String),
     #           (:rowid, (Int64, "default 0")),
     #           "primary key (key)",
     #          ],
     #          [
     #           :key,
     #           :rowid, 
     #          ];
     #          runctx.runtag)),

     (:parametrized_replaceable_events, ()->runctx.est.dyn[:parametrized_replaceable_events],
      "length(identifier) < 2000", [],
      dbtable(:postgres, runctx.targetserver, "parametrized_replaceable_events", 1,
              [],
              [
               (:pubkey, PubKeyId),
               (:kind, Int64),
               (:identifier, String),
               (:event_id, EventId),
               (:created_at, Int64),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :pubkey,
               :kind,
               :identifier,
               :created_at,
               :event_id,
               :rowid,
              ];
              runctx.runtag)),

     (:event_zapped, ()->runctx.est.dyn[:event_zapped], "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_zapped", 1,
              [],
              [
               (:event_id, EventId),
               (:zap_sender, PubKeyId),
               (:rowid, (Int64, "default 0")), 
              ],
              [
               (:event_id, :zap_sender),
               :rowid, 
              ];
              runctx.runtag)),

     (:video_thumbnails, ()->runctx.est.dyn[:video_thumbnails], "length(video_url) < 2000", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "video_thumbnails", 1,
              [],
              [
               (:video_url, String),
               (:thumbnail_url, String),
               (:rowid, (Int64, "default 0")),
              ],
              [
               :video_url, 
               :thumbnail_url,
               :rowid, 
              ];
              runctx.runtag)),

     (:event_attributes, ()->runctx.est.dyn[:event_attributes], "", [:testwithrecent],
      dbtable(:postgres, runctx.targetserver, "event_attributes", 1,
              [],
              [
               (:event_id, EventId),
               (:key, String), 
               (:value, Int64),
               (:rowid, (Int64, "default 0")), 
              ],
              [
               :event_id, 
               (:key, :value),
               :rowid, 
              ];
              runctx.runtag)),
    ]

    sources = map(sources) do s
        length(s) == 6 ? s : (s[1], s[2], s[3], s[4], identity, s[5])
    end

    if skipprocessing
        map(sources) do s
            s[1] => s[end]
        end
    else
        @sync asyncmap(sources; ntasks=PROCESS_SEGMENTS_TASKS[]) do s
            k, srcf, wheres, flags, transform, tbl = s

            recentonly = get(runctx.opts, :recentonly, false) && :testwithrecent in flags

            xfer() = sqlite_to_postgres_transfer(srcf(), tbl; 
                                                 runctx, wheres=isempty(wheres) ? nothing : wheres,
                                                 transform, recentonly)

            if get(runctx.opts, :usethreads, false)
                Threads.@spawn xfer()
            else
                xfer()
            end
            k => tbl
        end
    end |> NamedTuple
end

function deploy(outputs; schema=:public)
    tbl(st) = (st.server, st.table)

    Main.App.DAG_OUTPUTS[] = (@__MODULE__, outputs)
    # Main.rex(3,17, :(App.DAG_OUTPUTS[] = $(NamedTuple([k=>tbl(v) for (k, v) in pairs(Main.App.DAG_OUTPUTS[][2])]))))
    mkviews!(outputs; schema)

    nothing
end

function process_segments(
        process_segment::Function, coverage; 
        runctx::RunCtx, 
        since=nothing, until=nothing, 
        step=nothing, sequential=false, ntasks=nothing)
    since = isnothing(since) ? runctx.since : since
    until = isnothing(until) ? runctx.until : until

    since == 0 && until == 0 && return

    ntasks = isnothing(ntasks) ? PROCESS_SEGMENTS_TASKS[] : ntasks

    coverage isa Vector || (coverage = [coverage])
    cov = join(map(string, coverage), '/')

    cnt = Ref(0) |> ThreadSafe
    errs = Ref(0) |> ThreadSafe
    ttotal = Ref(0) |> ThreadSafe

    ts = Dict()
    if isnothing(step)
        ts[-1] = since, until
    else
        tsdone = Dict(Postgres.pex(coverages[].server, 
                                   "select t, t2 from $(coverages[].table) where name = ?1", 
                                   [cov]))
        t = (since ÷ step) * step
        while t <= until
            if !haskey(tsdone, t)
                ts[t] = max(t, since), min(t + step, until)
            elseif tsdone[t] - t < step
                ts[t] = max(tsdone[t], since), min(t + step, until)
            end
            t += step
        end
    end
    ts = sort(collect(ts))

    runctx.log()
    # runctx.log("=== $cov:")
    # runctx.log(display_to_string([k=>map(unix2datetime, v) for (k, v) in ts]))

    tasks = Ref(0) |> ThreadSafe

    function proc_segment(t, t1, t2)
        try
            runctx.log("=== $cov: $(Dates.unix2datetime(t1)) .. $(Dates.unix2datetime(t2))")

            process_segment(t1, t2)

            if runctx.running[]
                if t >= 0
                    Postgres.pex(coverages[].server, 
                                 "insert into $(coverages[].table) values (?1, ?2, ?3)
                                 on conflict (name, t) do update set t = ?2, t2 = ?3",
                                 [cov, t, t2])
                end
            end
        catch ex
            runctx.running[] = false
            if !(ex isa ImportInterrupted)
                if !occursin("current transaction is aborted", string(ex))
                    lock(print_exceptions_lock) do
                        if !isnothing(runctx.on_exception)
                            if runctx.on_exception == :print
                                Utils.print_exceptions()
                            elseif runctx.on_exception isa Function
                                iob = IOBuffer()
                                Utils.print_exceptions(iob)
                                runctx.on_exception(ex, String(take!(iob)))
                            end
                        end
                    end
                end
                DB.incr(errs)
            end
        finally
            DB.decr(tasks)
            ttotal[] += t2 - t1
            !isnothing(runctx.progress) && runctx.progress((; coverage=cov, cnt=cnt[], errs=errs[], ttotal=ttotal[]))
        end
    end

    if sequential
        for (t, (t1, t2)) in ts
            runctx.running[] || break
            proc_segment(t, t1, t2)
        end
    else
        ts = Random.shuffle(ts)
        @sync for (t, (t1, t2)) in ts
            while runctx.running[] && tasks[] >= ntasks
                sleep(0.05)
            end
            runctx.running[] || break

            DB.incr(tasks)

            if get(runctx.opts, :usethreads, false)
                Threads.@spawn proc_segment(t, t1, t2)
            else
                @async proc_segment(t, t1, t2)
            end
        end
    end
end

# DB utils

function display_to_string(x)
    iob = IOBuffer()
    display(Base.TextDisplay(iob), x)
    strip(String(take!(iob)))
end

isnull(v) = isnothing(v) || ismissing(v)

rep(q) = replace(q, '?'=>'$')

function size(tbl::ServerTable)
    Postgres.pex(tbl.server, "select pg_total_relation_size(?1)", [tbl.table])[1][1]
end

function tablesizes(nt)
    [k=>Base.format_bytes(v) 
     for (k, v) in sort([k=>size(v) for (k, v) in pairs(nt)]; 
                        by=x->-x[2])]
end

function dump_to_file(tbl::ServerTable, directory)
    Postgres.pex(tbl.server, "copy $(tbl.table) to program 'zstd -T4 > $(directory)/$(tbl.table).bin.zst' with binary")
    nothing
end

CLK_TCK = parse(Int, read(`getconf CLK_TCK`, String))

function process_usage_stats(pid::Int)
    ps = split(readline("/proc/$pid/stat"))
    cputime = (parse(Int, ps[14]) + parse(Int, ps[15])) / CLK_TCK
    disktime = parse(Int, ps[42]) / CLK_TCK
    readcalls = writecalls = readbytes = writebytes = 0
    for s in readlines("/proc/$pid/io")
        ss = split(s)
        v = parse(Int, ss[2])
        if     ss[1] == "read_bytes:";  readbytes  = v
        elseif ss[1] == "write_bytes:"; writebytes = v
        elseif ss[1] == "syscr:";       readcalls  = v
        elseif ss[1] == "syscw:";       writecalls = v
        end
    end
    (; cputime, disktime, readcalls, writecalls, readbytes, writebytes)
end

function backend_usage_stats(session::Postgres.Session)
    process_usage_stats(Postgres.execute(session, "select pg_backend_pid()")[2][1][1])
end

function ntop(a::NamedTuple, f::Function, b::NamedTuple)
    @assert length(pairs(a)) == length(pairs(b))
    NamedTuple([begin
                @assert k1 == k2
                k1=>f(v1, v2) 
                end
                for ((k1, v1), (k2, v2)) in zip(sort(collect(pairs(a))),
                                                sort(collect(pairs(b))))])
end
Base.:+(a::NamedTuple, b::NamedTuple) = ntop(a, +, b)
Base.:-(a::NamedTuple, b::NamedTuple) = ntop(a, -, b)
const zero_usage_stats = let us = process_usage_stats(Int(getpid()))
    us - us
end
Base.zero(::Type{typeof(zero_usage_stats)}) = zero_usage_stats

function transaction_with_execution_stats(body, server::Symbol; stats=nothing, parallel_workers=0, new_connection=true)
    function body_wrapper(session)
        old = Postgres.execute(session, "show max_parallel_workers_per_gather")[2][1][1]
        pid = server == MAIN_SERVER[] ? Postgres.execute(session, "select pg_backend_pid()")[2][1][1] : Int(getpid()) # FIXME
        us0 = process_usage_stats(pid)
        try
            Postgres.execute(session, "set max_parallel_workers_per_gather = $(parallel_workers)")
            body(session)
        finally
            try Postgres.execute(session, "set max_parallel_workers_per_gather = $(old)") catch _ end
            us1 = process_usage_stats(pid)
            isnothing(stats) || lock(stats) do stats
                stats[] += us1 - us0
            end
        end
    end

    if new_connection
        session = Postgres.make_session(Postgres.servers[server].connstr; connection_check_period=0.0)
        try
            Postgres.transaction(body_wrapper, session)
        finally
            try close(session) catch _ end
        end
    else
        Postgres.transaction(body_wrapper, server)
    end
end

event_from_row(r) = Nostr.Event(r[1], r[2], r[3], r[4], [Nostr.TagAny(t) for t in r[5]], ismissing(r[6]) ? "" : r[6], r[7])

Postgres.jl_to_pg_type_conversion[Char] = v -> string(v)
Postgres.jl_to_pg_type_conversion[EventId] = v -> "\\x" * bytes2hex(collect(v.hash))
Postgres.jl_to_pg_type_conversion[PubKeyId] = v -> "\\x" * bytes2hex(collect(v.pk))
Postgres.jl_to_pg_type_conversion[Nostr.Sig] = v -> "\\x" * bytes2hex(collect(v.sig))
Postgres.jl_to_pg_type_conversion[ServerTable] = string
Postgres.jl_to_pg_type_conversion[TSVector] = v -> v.s

Postgres.pg_to_jl_type_conversion[18] = v -> String(v)
Postgres.pg_to_jl_type_conversion[19] = v -> String(v)
Postgres.pg_to_jl_type_conversion[26] = v -> parse(Int, String(v))
Postgres.pg_to_jl_type_conversion[27] = v -> NTuple{2, Int}(parse(Int, String(s)) for s in split(v[2:end-1], UInt8(',')))
Postgres.pg_to_jl_type_conversion[3614] = v -> String(v)
Postgres.pg_to_jl_type_conversion[3615] = v -> String(v)

Postgres.column_to_jl_type["id"] = v->EventId(v)
Postgres.column_to_jl_type["event_id"] = v->EventId(v)
Postgres.column_to_jl_type["pubkey"] = v->PubKeyId(v)
Postgres.column_to_jl_type["tags"] = v->[Nostr.TagAny(t) for t in v]
Postgres.column_to_jl_type["content"] = v->ismissing(v) ? "" : v
Postgres.column_to_jl_type["sig"] = v->Nostr.Sig(v)

Postgres.columnformatter(v::Vector{UInt8}, i, j) = bytes2hex(v)

multi_insert(session, target; kwargs...) = rows->multi_insert(session, target, rows; kwargs...)

function multi_insert(
        session::Postgres.Session, target::ServerTable, rows::Vector;
        batchsize=100,
    )
    isempty(rows) && return

    ncolumns = length(rows[1])

    params1 = "("*join(["\$$(i)" for i in 1:ncolumns], ',')*")"
    pstmt1 = Postgres.prepare(session, "insert into $(target.table) values $params1 on conflict do nothing")

    params2 = join([("("*join(["\$$(j*ncolumns+i)" for i in 1:ncolumns], ',')*")") for j in 0:(batchsize-1)], ',')
    pstmt2 = Postgres.prepare(session, "insert into $(target.table) values $params2 on conflict do nothing")

    for rs in Iterators.partition(rows, batchsize)
        if length(rs) == batchsize
            Postgres.execute(pstmt2, flatten(rs))
        else
            for r in rs
                Postgres.execute(pstmt1, r)
            end
        end
    end
end

# SQL DSL

function __wip__()
    events = ServerTable(MAIN_SERVER[], "event")
    since = until = 0
    quote
        eids = begin
            es2 = $(events)()
            (; eid=es2.id)
        end
        reids = begin
            r = begin
                es = $(events)()
                es.imported_at >= $(since) && es.imported_at <= $(until)
                es.kind == $(Nostr.REACTION)
                (; id=es.id, t=jsonb_array_elements(es.tags))
            end
            r.t[0] == "e" && match(r"^[0-9a-f]{64}\$", r.t[1])
            groupby(r.id, r.t[1])
            (; eid=decode(r.t[1], "hex"))
        end
        ready_eids = intersect(reids, eids)
        pending_eids = except(reids, eids)
    end
end

# ORM

struct PGTable
    st::ServerTable
    session::Postgres.Session
end

mutable struct PGObject
    pgt::PGTable
    key::NamedTuple
    props::Vector{Pair}
    dirty::Bool
    PGObject(pgt, key, props=[], dirty=false) = new(pgt, key, props, dirty)
end

function ormparams(body)
    params = []
    body(params, function (v)
        push!(params, v)
        "\$$(length(params))"
    end)
end

ormvalue(_, a::String) = a
ormvalue(::Type{TSVector}, a::String) = "to_tsvector('simple', $a)"

function Base.haskey(pgt::PGTable, key::NamedTuple)
    ormparams() do params, A
        !isempty(Postgres.execute(pgt.session, "
                                  select 1 from $(pgt.st.table)
                                  where $(join(["$k = $(A(v))" for (k, v) in pairs(key)], " and "))
                                  limit 1
                                  ", params)[2])
    end
end

function Base.getindex(pgt::PGTable, key::NamedTuple)
    cols, rows = ormparams() do params, A
        Postgres.execute(pgt.session, "
                         select * from $(pgt.st.table)
                         where $(join(["$k = $(A(v))" for (k, v) in pairs(key)], " and "))
                         limit 1
                         for update
                         ", params)
    end

    isempty(rows) && throw(KeyError(key))
    
    PGObject(pgt, key, 
             [c[1]=>c[2](v) for (c, v) in zip(pgt.st.columns, rows[1])],
             false)
end

function Base.setindex!(pgt::PGTable, props::NamedTuple, key::NamedTuple)
    row = (; key..., props...)
    row = NamedTuple([c[1]=>getproperty(row, c[1]) for c in pgt.st.columns])
    ormparams() do params, A
        Postgres.execute(pgt.session, "
                         insert into $(pgt.st.table) 
                         ($(join(["$k" for k in keys(row)], ", ")))
                         values ($(join([ormvalue(c[2], A(v)) for (c, v) in zip(pgt.st.columns, values(row))], ", ")))
                         on conflict ($(join(["$k" for k in keys(key)], ", ")))
                         do update set $(join(["$k = $(ormvalue(c[2], A(v)))" for (c, (k, v)) in zip(pgt.st.columns, pairs(props))], ", "))
                         ", params)
    end
    pgt
end

function Base.get!(body::Function, pgt::PGTable, key::NamedTuple)
    if !haskey(pgt, key)
        pgt[key] = body()
    end
    pgt[key]
end

function Base.get(body::Function, pgt::PGTable, key::NamedTuple, default)
    haskey(pgt, key) ? pgt[key] : default
end

function Base.push!(pgt::PGTable, vs::Union{Tuple, Vector})
    ormparams() do params, A
        Postgres.execute(pgt.session, "
                         insert into $(pgt.st.table) 
                         values ($(join([ormvalue(c[2], A(v)) for (c, v) in zip(pgt.st.columns, vs)], ", ")))
                         on conflict do nothing
                         ", params)
    end
    nothing
end

function Base.push!(pgt::PGTable, row::NamedTuple)
    row = NamedTuple([c[1]=>getproperty(row, c[1]) for c in pgt.st.columns])
    ormparams() do params, A
        Postgres.execute(pgt.session, "
                         insert into $(pgt.st.table) 
                         ($(join(["$k" for k in keys(row)], ", ")))
                         values ($(join([ormvalue(c[2], A(v)) for (c, v) in zip(pgt.st.columns, values(row))], ", ")))
                         on conflict do nothing
                         ", params)
    end
    nothing
end

function Base.getproperty(pgo::PGObject, prop::Symbol)
    if  prop == :pgt ||
        prop == :key ||
        prop == :props ||
        prop == :dirty
        getfield(pgo, prop)
    else
        for (k, v) in pgo.props
            k == prop && return v
        end
        error("PGObject has no property $prop")
    end
end

function Base.setproperty!(pgo::PGObject, prop::Symbol, x)
    if  prop == :pgt ||
        prop == :key ||
        prop == :props ||
        prop == :dirty
        setfield!(pgo, prop, x)
    else                  
        i = 1
        for (k, v) in pgo.props
            if k == prop
                if v != x
                    pgo.props[i] = prop=>x
                    pgo.dirty = true
                end
                return x
            end
            i += 1
        end
        error("PGObject has no property $prop")
    end
    x
end

function save!(pgo::PGObject)
    if pgo.dirty
        pgo.pgt[pgo.key] = NamedTuple(pgo.props)
        pgo.dirty = false
    end
    nothing
end

# search

const rules = Ref{Any}(nothing)
const grammar = Ref{Any}(nothing)

SEARCH_SERVER = Ref(:p0timelimit)

function search(est, user_pubkey, query; outputs::NamedTuple, since=0, until=nothing, limit=100, offset=0, kind=nothing, explain=false, logextra=(;))
    # @show query
    has_orderby = occursin("orderby:", query)

    isnothing(until) && (until = has_orderby ? 1<<61 : Utils.current_time())

    expr = parse_search_query(query)

    if expr isa O.And && any("1" in op.features for op in expr.ops if op isa O.PAS)
        if  isnothing(user_pubkey) || 
            user_pubkey == Nostr.PubKeyId("532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb") || # primal pubkey
            isempty(Postgres.execute(:membership, "select 1 from memberships where pubkey = \$1 and tier != 'free' limit 1", [user_pubkey])[2])
            limit = min(20, limit)
        end
    end

    stats = Ref(zero_usage_stats) |> ThreadSafe

    err = nothing

    # log = user_pubkey == Main.test_pubkeys[:pedja]
    log = false
    explain = nothing
    # explain = :full

    orderkey = nothing

    res = try
        transaction_with_execution_stats(SEARCH_SERVER[]; stats) do session
            Main.App.fetch_results(session, since, until, limit, offset; 
                                   has_orderby, timeout=9.0, explain,
                                   sql_generator=function (s, u, res)
                                       log && @show (length(res), u-s, Dates.unix2datetime(s), Dates.unix2datetime(u))
                                       sql, params, orderkey = to_sql(est, user_pubkey, outputs, expr, kind, s, u, limit, offset)
                                       sql, params
                                   end)
        end
    catch ex 
        err = string(ex)
        println("DAG.search, query=$(repr(query)): ", ex isa ErrorException ? ex : typeof(ex))
        if !(ex isa Postgres.PostgresException && occursin("statement timeout", ex.fields['M']))
            Utils.print_exceptions()
        end
        []
    end

    res, orderkey, stats[], err
end

# advanced search query parsing

macro t_str(t, flags...)
    P.tokens(unescape_string(t))
end

function init_parsing()
    rules[] = Dict(
                   :input => P.seq(:ws, :or_expr, :ws, P.end_of_input),

                   :sub_expr => P.seq(t"(", :ws, :or_expr, t")"),

                   :or_expr => P.first(P.seq(:exprs, t"OR ", :ws, :or_expr),
                                       :exprs),

                   :exprs => P.some(P.seq(:expr, :ws)),
                   :expr => P.seq(P.not_followed_by(t"OR "), 
                                  P.first(
                                          :sub_expr,
                                          :not_phrase_expr,
                                          :not_word_expr,
                                          :not_hashtag_expr,
                                          :hashtag_expr,
                                          :since_expr,
                                          :until_expr,
                                          :from_expr,
                                          :to_expr,
                                          :mention_expr,
                                          :kind_expr,
                                          :repliestokind_expr,
                                          :minduration_expr,
                                          :maxduration_expr,
                                          :filter_expr,
                                          :url_expr,
                                          :orientation_expr,
                                          :list_expr,
                                          :emoticon_expr,
                                          :question_expr,
                                          :mininteractions_expr,
                                          :maxinteractions_expr,
                                          :scope_expr,
                                          :minwords_expr,
                                          :maxwords_expr,
                                          :maxchars_expr,
                                          :minlongreplies_expr,
                                          :lang_expr,
                                          :features_expr,
                                          :ref_expr,
                                          :zappedby_expr,
                                          :orderby_expr,

                                          :minscore_expr,
                                          :maxscore_expr,
                                          :minlikes_expr,
                                          :maxlikes_expr,
                                          :minzaps_expr,
                                          :maxzaps_expr,
                                          :minreplies_expr,
                                          :maxreplies_expr,
                                          :minreposts_expr,
                                          :maxreposts_expr,
                                          :minsatszapped_expr,
                                          :maxsatszapped_expr,
                                          :mintrustrank_expr,

                                          :pas_expr,

                                          :word_expr,
                                          :phrase_expr,

                                         )), 
                   :word_expr => P.some(P.satisfy(c->isletter(c)||isdigit(c)||(c=='_')||(c=='-'))),
                   :phrase_expr => P.seq(t"\"", P.some(P.satisfy(c->c!='"')), t"\""),
                   :hashtag_expr => P.seq(t"#", :word_expr),
                   :not_phrase_expr => P.seq(t"-\"", P.some(P.satisfy(c->c!='"')), t"\""),
                   :not_word_expr => P.seq(t"-", :word_expr),
                   :not_hashtag_expr => P.seq(t"-#", :word_expr),
                   # :ts => P.some(P.satisfy(c->isdigit(c)||(c=='-')||(c=='_')||(c==':'))),
                   :ts => P.some(P.satisfy(c->isletter(c)||isdigit(c)||(c=='-')||(c=='_')||(c==':'))),
                   :since_expr => P.seq(t"since:", :ts),
                   :until_expr => P.seq(t"until:", :ts),
                   :pubkey_hex => P.some(P.satisfy(c->c in '0':'9' || c in 'a':'f' || c in 'A':'F')),
                   :pubkey_npub => P.seq(t"npub", P.some(P.satisfy(c->isletter(c)||isdigit(c)))),
                   :pubkey => P.first(:pubkey_hex, :pubkey_npub),
                   :from_expr => P.seq(t"from:", :pubkey),
                   :to_expr => P.seq(t"to:", :pubkey),
                   :mention_expr => P.seq(t"@", :pubkey),
                   :kind_expr => P.seq(t"kind:", :number),
                   :repliestokind_expr => P.seq(t"repliestokind:", :number),
                   :filter_expr => P.seq(t"filter:", :word_expr),
                   :url_expr => P.seq(t"url:", :word_expr),
                   :orientation_expr => P.seq(t"orientation:", :word_expr),
                   :minduration_expr => P.seq(t"minduration:", :number),
                   :maxduration_expr => P.seq(t"maxduration:", :number),
                   :list_expr => P.seq(t"list:", :word_expr),
                   :emoticon_expr => P.first(t":)", t":("),
                   :question_expr => t"?",
                   :mininteractions_expr => P.seq(t"mininteractions:", :number),
                   :maxinteractions_expr => P.seq(t"maxinteractions:", :number),
                   :scope_expr => P.seq(t"scope:", :word_expr),
                   :minwords_expr => P.seq(t"minwords:", :number),
                   :maxwords_expr => P.seq(t"maxwords:", :number),
                   :maxchars_expr => P.seq(t"maxchars:", :number),
                   :minlongreplies_expr => P.seq(t"minlongreplies:", :number),
                   :lang_expr => P.seq(t"lang:", :word_expr),
                   :features_expr => P.seq(t"features:", P.some(P.satisfy(c->isletter(c)||isdigit(c)||(c in "-_,")))),
                   :ref_expr => P.seq(t"ref:", :word_expr),
                   :zappedby_expr => P.seq(t"zappedby:", :pubkey),
                   :orderby_expr => P.seq(t"orderby:", :word_expr),

                   :minscore_expr => P.seq(t"minscore:", :number),
                   :maxscore_expr => P.seq(t"maxscore:", :number),
                   :minlikes_expr => P.seq(t"minlikes:", :number),
                   :maxlikes_expr => P.seq(t"maxlikes:", :number),
                   :minzaps_expr => P.seq(t"minzaps:", :number),
                   :maxzaps_expr => P.seq(t"maxzaps:", :number),
                   :minreplies_expr => P.seq(t"minreplies:", :number),
                   :maxreplies_expr => P.seq(t"maxreplies:", :number),
                   :minreposts_expr => P.seq(t"minreposts:", :number),
                   :maxreposts_expr => P.seq(t"maxreposts:", :number),
                   :minsatszapped_expr => P.seq(t"minsatszapped:", :number),
                   :maxsatszapped_expr => P.seq(t"maxsatszapped:", :number),
                   :mintrustrank_expr => P.seq(t"mintrustrank:", :number),

                   :pas_expr => P.seq(t"pas:", P.some(P.satisfy(c->isletter(c)||isdigit(c)||(c in "-_,")))),

                   :number => P.first(P.seq(t"-", P.some(P.satisfy(isdigit))),
                                      P.some(P.satisfy(isdigit))),
                   :ws => P.many(t" "),
                  )

    grammar[] = P.make_grammar([:input], P.flatten(rules[], Char))

    nothing
end

module O
import ..Nostr
struct Or;       ops; end
struct And;      ops; end
struct Word;     word::String; end
struct Phrase;   phrase::String; end
struct HashTag;  hashtag::String; end
struct NotWord;  word::String; end
struct NotPhrase; phrase::String; end
struct NotHashTag; hashtag::String; end
struct Since;    ts::Int; end
struct Until;    ts::Int; end
struct From;     pubkey::Nostr.PubKeyId; end
struct To;       pubkey::Nostr.PubKeyId; end
struct Mention;  pubkey::Nostr.PubKeyId; end
struct Kind;     kind::Int; end
struct RepliesToKind; kind::Int; end
struct Filter;   filter::String; end
struct Url;      word::String; end
struct List;     list::String; end
struct Orientation; orientation::String; end
struct MinDuration; duration::Float64; end
struct MaxDuration; duration::Float64; end
struct Emoticon; emo::String; end
struct Question; end
struct MinScore; score::Int; end
struct MaxScore; score::Int; end
struct MinInteractions; interactions::Int; end
struct MaxInteractions; interactions::Int; end
struct Scope; scope::String; end
struct MinWords; words::Int; end
struct MaxWords; words::Int; end
struct MaxChars; chars::Int; end
struct MinLongReplies; longreplies::Int; end
struct Lang; lang::String; end
struct Ref; ref::Union{Nostr.PubKeyId, Nostr.EventId}; end
struct ZappedBy; pubkey::Nostr.PubKeyId; end
struct OrderBy; field::String; end
struct EventStatsField; field::Symbol; operation::Symbol; argument::Int; end
struct MinTrustRank; trustrank::Int; end
struct Features; features::Vector{String}; end
struct PAS; features::Vector{String}; end
end
Base.:(==)(a::O.Features, b::O.Features) = a.features == b.features

function parse_search_query(query)
    query = replace(query, '\n'=>' ')

    p = P.parse(grammar[], query)

    function fold(m, p, sm)
        if 0==1
            println((m.rule, m.view, sm))
            dump(sm)
            println()
        end

        function score(v)
            v /= 100.0
            v = max(0.0, min(1.0, v))
            lock(Main.App.trending_24h_scores) do trending_24h_scores
                i = trunc(Int, 1+(length(trending_24h_scores)-1)*v)
                trending_24h_scores[i]
            end
        end
        
        if     m.rule == :input; sm[2]
        elseif m.rule == :sub_expr; sm[3]
        elseif m.rule == :or_expr; 
            if sm[1] isa Vector
                O.Or(Any[sm[1][2], sm[1][5]])
            else
                sm[1]
            end
        elseif m.rule == :exprs
            s = Any[x[2] for x in sm]
            if length(s) > 1
                O.And(s)
            else
                s[1]
            end
        elseif m.rule == :expr; sm[2][2]
        elseif m.rule == :word_expr; O.Word(string(m.view))
        elseif m.rule == :phrase_expr; O.Phrase(m.view[2:end-1])
        elseif m.rule == :hashtag_expr; O.HashTag(first(s.word for s in sm if s isa O.Word))
        elseif m.rule == :not_word_expr; O.NotWord(first(s.word for s in sm if s isa O.Word))
        elseif m.rule == :not_phrase_expr; O.NotPhrase(m.view[3:end-1])
        elseif m.rule == :not_hashtag_expr; O.NotHashTag(m.view[3:end])
        elseif m.rule == :ts; string(m.view)
        elseif m.rule == :since_expr
            if     sm[2] == "yesterday";  O.Since(Utils.current_time() -  1*24*3600)
            elseif sm[2] == "lastweek";   O.Since(Utils.current_time() -  7*24*3600)
            elseif sm[2] == "last2weeks"; O.Since(Utils.current_time() - 14*24*3600)
            elseif sm[2] == "lastmonth";  O.Since(Utils.current_time() - 30*24*3600)
            else;                         O.Since(datetime2unix(DateTime(replace(sm[2], '_'=>'T'))))
            end
        elseif m.rule == :until_expr; O.Until(datetime2unix(DateTime(replace(sm[2], '_'=>'T'))))
        elseif m.rule == :pubkey_hex; Nostr.PubKeyId(string(m.view))
        elseif m.rule == :pubkey_npub; Nostr.bech32_decode(string(m.view))
        elseif m.rule == :pubkey; sm[1]
        elseif m.rule == :from_expr; O.From(sm[2])
        elseif m.rule == :to_expr; O.To(sm[2])
        elseif m.rule == :mention_expr; O.Mention(sm[2])
        elseif m.rule == :kind_expr; O.Kind(sm[2])
        elseif m.rule == :repliestokind_expr; O.RepliesToKind(sm[2])
        elseif m.rule == :filter_expr; O.Filter(sm[2].word)
        elseif m.rule == :url_expr; O.Url(sm[2].word)
        elseif m.rule == :minduration_expr; O.MinDuration(Float64(sm[2]))
        elseif m.rule == :maxduration_expr; O.MaxDuration(Float64(sm[2]))
        elseif m.rule == :orientation_expr; O.Orientation(sm[2].word)
        elseif m.rule == :list_expr; O.List(sm[2].word)
        elseif m.rule == :emoticon_expr; O.Emoticon(string(m.view))
        elseif m.rule == :question_expr; O.Question()
        elseif m.rule == :mininteractions_expr; O.MinInteractions(sm[2])
        elseif m.rule == :maxinteractions_expr; O.MaxInteractions(sm[2])
        elseif m.rule == :scope_expr; O.Scope(sm[2].word)
        elseif m.rule == :minwords_expr; O.MinWords(sm[2])
        elseif m.rule == :maxwords_expr; O.MaxWords(sm[2])
        elseif m.rule == :maxchars_expr; O.MaxChars(sm[2])
        elseif m.rule == :minlongreplies_expr; O.MinLongReplies(sm[2])
        elseif m.rule == :lang_expr; O.Lang(sm[2].word)
        elseif m.rule == :features_expr; O.Features(map(string, split(sm[2][1][2], ',')))
        elseif m.rule == :ref_expr; O.Ref(Nostr.bech32_decode(sm[2].word))
        elseif m.rule == :zappedby_expr; O.ZappedBy(sm[2])
        elseif m.rule == :orderby_expr; O.OrderBy(sm[2].word)

        elseif m.rule == :minscore_expr; O.EventStatsField(:score, :(>=), score(sm[2]))
        elseif m.rule == :maxscore_expr; O.EventStatsField(:score, :(<=), score(sm[2]))
        elseif m.rule == :minlikes_expr; O.EventStatsField(:likes, :(>=), sm[2])
        elseif m.rule == :maxlikes_expr; O.EventStatsField(:likes, :(<=), sm[2])
        elseif m.rule == :minzaps_expr; O.EventStatsField(:zaps, :(>=), sm[2])
        elseif m.rule == :maxzaps_expr; O.EventStatsField(:zaps, :(<=), sm[2])
        elseif m.rule == :minreplies_expr; O.EventStatsField(:replies, :(>=), sm[2])
        elseif m.rule == :maxreplies_expr; O.EventStatsField(:replies, :(<=), sm[2])
        elseif m.rule == :minreposts_expr; O.EventStatsField(:reposts, :(>=), sm[2])
        elseif m.rule == :maxreposts_expr; O.EventStatsField(:reposts, :(<=), sm[2])
        elseif m.rule == :minsatszapped_expr; O.EventStatsField(:satszapped, :(>=), sm[2])
        elseif m.rule == :maxsatszapped_expr; O.EventStatsField(:satszapped, :(<=), sm[2])
        elseif m.rule == :mintrustrank_expr; O.MinTrustRank(sm[2])

        elseif m.rule == :pas_expr; O.PAS(map(string, split(sm[2][1][2], ',')))

        elseif m.rule == :number; parse(Int, m.view)
        elseif m.rule == :ws; nothing
        else; [(m.rule, string(m.view)), sm...]
        end
    end

    ast = P.traverse_match(p, P.find_match_at!(p, :input, 1); fold)

    # dump(ast; maxdepth=100)
    # println(ast)

    ast
end

# advanced search SQL codegen

function to_sql(est::DB.CacheStorage, user_pubkey, outputs::NamedTuple, expr, kind, since, until, limit, offset; extra_selects=[], order=:desc)
    o = outputs

    if !(expr isa O.Or || expr isa O.And)
        expr = O.And([expr])
    end

    params = []
    function P(v)
        push!(params, v)
        "\$$(length(params))"
    end

    selects = []
    function select(s)
        push!(selects, s)
    end

    tables = Set()
    function T(t::ServerTable)
        push!(tables, t.table)
        t.table
    end
    function T(t::String)
        push!(tables, t)
        t
    end

    conds = []
    function cond(s)
        push!(conds, s)
    end

    ctes = []
    function cte(s)
        push!(ctes, s)
    end

    # !isnothing(kind) && cond("$(T(o.advsearch)).kind = $(P(kind))")

    function user_pubkey_follows_conds(table)
        T(table)
        cte("with $table as (
                select pf1.pubkey
                from pubkey_followers pf1
                where pf1.follower_pubkey = $(P(user_pubkey))
            )")
    end

    function user_pubkey_network_conds(table)
        T(table)
        cte("with $table as ((
                select pf1.pubkey
                from pubkey_followers pf1
                where pf1.follower_pubkey = $(P(user_pubkey))
            ) union (
                select pf3.pubkey
                from pubkey_followers pf2, pubkey_followers pf3
                where
                    pf2.follower_pubkey = $(P(user_pubkey)) and 
                    pf3.follower_pubkey = pf2.pubkey
            ))")
    end

    kind = Nostr.TEXT_NOTE
    for op in expr.ops
        if op isa O.Kind
            cond("$(T(o.advsearch)).kind = $(P(op.kind))")
            kind = Nostr.Kind(op.kind)
            break
        end
    end

    if kind == Nostr.TEXT_NOTE
        select("$(T(o.advsearch)).id")
        orderkey = "$(T(o.advsearch)).created_at"
        cond("$(T(o.advsearch)).created_at >= $(P(since))")
        cond("$(T(o.advsearch)).created_at <= $(P(until))")
        orderby = "$(T(o.advsearch)).created_at"

    elseif kind == Nostr.LONG_FORM_CONTENT
        select("$(T(o.advsearch)).id")
        orderkey = "$(T(o.reads)).published_at"
        cond("$(T(o.advsearch)).id = $(T(o.reads)).latest_eid")
        cond("$(T(o.reads)).published_at >= $(P(since))")
        cond("$(T(o.reads)).published_at <= $(P(until))")
        orderby = "$(T(o.reads)).published_at"

    else
        error("unsupported kind")
    end

    for op in expr.ops
        if op isa O.OrderBy
            cond("$(T(o.event_stats)).event_id = $(T(o.advsearch)).id")
            if op.field == "interactions"
                orderby = "($(T(o.event_stats)).likes + $(T(o.event_stats)).replies + $(T(o.event_stats)).reposts + $(T(o.event_stats)).zaps)"
            else
                @assert op.field in ["score", "likes", "replies", "reposts", "zaps", "satszapped"]
                cond("$(T(o.event_stats)).$(op.field) > 0")
                orderby = "$(T(o.event_stats)).$(op.field)"
            end
            orderkey = orderby
            break
        end
    end

    for op in expr.ops
        if op isa O.RepliesToKind
            # if op.kind == Int(Nostr.TEXT_NOTE)
                T("basic_tags btrtk") 
                T("events esrtk") 
                cond("btrtk.id = $(T(o.advsearch)).id")
                cond("btrtk.kind = $(Int(Nostr.TEXT_NOTE))")
                cond("btrtk.tag = 'e' and btrtk.arg1 = esrtk.id and esrtk.kind = $(P(op.kind))")
            # elseif op.kind == Int(Nostr.LONG_FORM_CONTENT)
            #     T("a_tags atrtk") 
            #     cond("atrtk.eid = $(T(o.advsearch)).id")
            #     cond("atrtk.kind = $(Int(Nostr.TEXT_NOTE))")
            #     cond("atrtk.ref_kind = $(P(op.kind))")
            # else
            #     error("unsupported repliestokind operator argument")
            # end
        elseif op isa O.Scope
            if op.scope in ["myfollows", "mynetwork"]
                if     op.scope == "myfollows"
                    user_pubkey_follows_conds("scope_pks")
                elseif op.scope == "mynetwork"
                    user_pubkey_network_conds("scope_pks")
                end
                cond("$(T(o.advsearch)).pubkey = scope_pks.pubkey")
            elseif op.scope in ["myfollowsinteractions", "mynetworkinteractions"]
                # TODO: zaps
                T("basic_tags btscopeint") 
                if     op.scope == "myfollowsinteractions"
                    user_pubkey_follows_conds("scope_pks")
                elseif op.scope == "mynetworkinteractions"
                    user_pubkey_network_conds("scope_pks")
                end
                cond("btscopeint.kind in ($(Int(Nostr.TEXT_NOTE)), $(Int(Nostr.REPOST)), $(Int(Nostr.REACTION))) and 
                     btscopeint.pubkey = scope_pks.pubkey and btscopeint.tag = 'e' and btscopeint.arg1 = $(T(o.advsearch)).id") # TODO reads
            elseif op.scope == "notmyfollows"
                user_pubkey_follows_conds("scope_pks")
                cond("not exists (select 1 from scope_pks where scope_pks.pubkey = $(T(o.advsearch)).pubkey)")
            elseif op.scope == "mutedbyothers"
                T("cmr_pubkeys_scopes scope_cmrpks")
                cond("$(T(o.advsearch)).pubkey = scope_cmrpks.pubkey")
            elseif op.scope == "mynotifications"
                cond("$(T(o.pubkey_notifications)).pubkey = $(P(user_pubkey))")
                cond("$(T(o.pubkey_notifications)).type != $(Int(DB.NEW_USER_FOLLOWED_YOU))")
                cond("$(T(o.pubkey_notifications)).type != $(Int(DB.USER_UNFOLLOWED_YOU))")
                cond("($(T(o.advsearch)).id = $(T(o.pubkey_notifications)).arg1 or $(T(o.advsearch)).id = $(T(o.pubkey_notifications)).arg2)")
                if endswith(orderkey, ".created_at")
                    cond("$(T(o.pubkey_notifications)).created_at >= $(P(since))")
                    cond("$(T(o.pubkey_notifications)).created_at <= $(P(until))")
                end
            else
                error("unsupported scope: $(op.scope)")
            end
        elseif op isa O.Ref
            T("basic_tags btref") 
            cond("btref.kind in ($(Int(Nostr.TEXT_NOTE)), $(Int(Nostr.REPOST)), $(Int(Nostr.LONG_FORM_CONTENT)))")
            cond("btref.arg1 = $(P(op.ref)) and btref.id = $(T(o.advsearch)).id")
            if     op.ref isa Nostr.EventId;  cond("btref.tag = 'e'")
            elseif op.ref isa Nostr.PubKeyId; cond("btref.tag = 'p'")
            end
        end
    end

    function tosql_op(op)
        local conds = []
        function cond(s)
            push!(conds, s)
        end

        if     op isa O.And
            subconds = filter(!isnothing, map(tosql_op, op.ops))
            isempty(subconds) || append!(conds, subconds)
        elseif op isa O.Or
            subconds = filter(!isnothing, map(tosql_op, op.ops))
            isempty(subconds) || push!(conds, join(subconds, " or "))
        elseif op isa O.Word;      cond("$(T(o.advsearch)).content_tsv @@ plainto_tsquery('simple', $(P(op.word)))")
        elseif op isa O.Phrase;    cond("$(T(o.advsearch)).content_tsv @@ phraseto_tsquery('simple', $(P(op.phrase)))")
        elseif op isa O.HashTag
            if kind == Nostr.TEXT_NOTE
                cond("$(T(o.advsearch)).hashtag_tsv @@ plainto_tsquery('simple', $(P(op.hashtag)))")
            elseif kind == Nostr.LONG_FORM_CONTENT
                cond("$(T(o.reads)).topics @@ plainto_tsquery('simple', $(P(op.hashtag)))")
            end
        elseif op isa O.NotWord;   cond("$(T(o.advsearch)).content_tsv @@ to_tsquery('simple', $(P("! "*op.word)))")
        elseif op isa O.NotPhrase; cond("not ($(T(o.advsearch)).content_tsv @@ phraseto_tsquery('simple', $(P(op.phrase))))")
        elseif op isa O.NotHashTag
            if kind == Nostr.TEXT_NOTE
                cond("not ($(T(o.advsearch)).hashtag_tsv @@ plainto_tsquery('simple', $(P(op.hashtag))))")
            elseif kind == Nostr.LONG_FORM_CONTENT
                cond("not ($(T(o.reads)).topics @@ plainto_tsquery('simple', $(P(op.hashtag))))")
            end
        elseif op isa O.Since;     cond("$(T(o.advsearch)).created_at >= $(P(op.ts))")
        elseif op isa O.Until;     cond("$(T(o.advsearch)).created_at <= $(P(op.ts))")
        elseif op isa O.From;      cond("$(T(o.advsearch)).pubkey = $(P(op.pubkey))")
        elseif op isa O.To;        cond("$(T(o.advsearch)).reply_tsv @@ plainto_tsquery('simple', $(P(Nostr.hex(op.pubkey))))")
        elseif op isa O.Mention;   cond("$(T(o.advsearch)).mention_tsv @@ plainto_tsquery('simple', $(P(Nostr.hex(op.pubkey))))")
        elseif op isa O.Filter
            if startswith(op.filter, '-')
                cond("$(T(o.advsearch)).filter_tsv @@ to_tsquery('simple', $(P("! "*op.filter)))")
            else
                cond("$(T(o.advsearch)).filter_tsv @@ plainto_tsquery('simple', $(P(op.filter)))")
            end
        elseif op isa O.Url
            cond("$(T(o.advsearch)).url_tsv @@ plainto_tsquery('simple', $(P(op.word)))")
        elseif op isa O.Orientation
            compop = op.orientation == "vertical" ? ">" : "<"
            cond("$(T(o.event_media)).event_id = $(T(o.advsearch)).id and $(T(o.event_media)).url = $(T(o.media)).url and $(T(o.media)).height $compop 1.8 * $(T(o.media)).width")
        elseif op isa O.MinDuration
            cond("$(T(o.event_media)).event_id = $(T(o.advsearch)).id and $(T(o.event_media)).url = $(T(o.media)).url and $(T(o.media)).duration >= $(P(op.duration)) and $(T(o.media)).duration > 0")
        elseif op isa O.MaxDuration
            cond("$(T(o.event_media)).event_id = $(T(o.advsearch)).id and $(T(o.event_media)).url = $(T(o.media)).url and $(T(o.media)).duration <= $(P(op.duration)) and $(T(o.media)).duration > 0")
        elseif op isa O.Emoticon || op isa O.Question
            # cond("$(T(o.event_sentiment)).eid = $(T(o.advsearch)).id and $(T(o.event_sentiment)).topsentiment = $(P(if op isa O.Question; '?'
            #                                                                                                         elseif op.emo == ":)"; '+'
            #                                                                                                         elseif op.emo == ":("; '-'
            #                                                                                                         else; error("unexpected emoticon: $(op.emo)")
            #                                                                                                         end))")
            tbl = "event_sentiment_1_d3d7a00a54"
            cond("$(T(tbl)).eid = $(T(o.advsearch)).id and $(T(tbl)).topsentiment = $(P(if op isa O.Question; '?'
                                                                                        elseif op.emo == ":)"; '+'
                                                                                        elseif op.emo == ":("; '-'
                                                                                        else; error("unexpected emoticon: $(op.emo)")
                                                                                        end))")
        elseif op isa O.EventStatsField
            cond("$(T(o.event_stats)).event_id = $(T(o.advsearch)).id and $(T(o.event_stats)).$(op.field) $(op.operation) $(P(op.argument))")
            if endswith(orderby, ".created_at")
                cond("$(T(o.event_stats)).created_at >= $(P(since))")
                cond("$(T(o.event_stats)).created_at <= $(P(until))")
            end
        elseif op isa O.MinInteractions
            cond("$(T(o.event_stats)).event_id = $(T(o.advsearch)).id and $(T(o.event_stats)).likes + $(T(o.event_stats)).replies + $(T(o.event_stats)).reposts + $(T(o.event_stats)).zaps >= $(P(op.interactions))")
        elseif op isa O.MaxInteractions
            cond("$(T(o.event_stats)).event_id = $(T(o.advsearch)).id and $(T(o.event_stats)).likes + $(T(o.event_stats)).replies + $(T(o.event_stats)).reposts + $(T(o.event_stats)).zaps <= $(P(op.interactions))")
        elseif op isa O.MinWords
            cond("$(T(o.advsearch)).id = $(T(o.reads)).latest_eid and $(T(o.reads)).words >= $(P(op.words))")
        elseif op isa O.MaxWords
            cond("$(T(o.advsearch)).id = $(T(o.reads)).latest_eid and $(T(o.reads)).words <= $(P(op.words))")
        elseif op isa O.MaxChars
            cond("$(T(o.advsearch)).id = $(T(o.note_length)).eid and $(T(o.note_length)).length <= $(P(op.chars))")
        elseif op isa O.MinLongReplies
            cond("$(T(o.advsearch)).id = $(T(o.note_stats)).eid and $(T(o.note_stats)).long_replies >= $(P(op.longreplies))")
        elseif op isa O.MinTrustRank
            cond("$(T(o.advsearch)).pubkey = $(T(o.pubkey_trustrank)).pubkey and $(T(o.pubkey_trustrank)).rank >= $(P(10.0^op.trustrank))")
        elseif op isa O.Lang
            cond("$(T(o.advsearch)).id = $(T(o.reads)).latest_eid and $(T(o.reads)).lang = $(P(op.lang)) and $(T(o.reads)).lang_prob = 1.0")
        elseif op isa O.ZappedBy
            cond("$(T(o.zap_receipts)).sender = $(P(op.pubkey)) and $(T(o.zap_receipts)).target_eid = $(T(o.advsearch)).id")
        elseif op isa O.Features
            for feat in op.features
                if     feat == "summary"
                    cond("$(T(o.reads)).summary != '' and $(T(o.reads)).image != ''")
                elseif feat == "bookmarked-by-follows"
                    user_pubkey_follows_conds("bookmarked_by_follows_pks")
                    cond("$(T(o.advsearch)).id = $(T(o.pubkey_bookmarks)).ref_event_id and $(T(o.pubkey_bookmarks)).pubkey = bookmarked_by_follows_pks.pubkey")
                elseif feat == "cdnmedia"
                    cond("exists (
                         select 1 
                         from $(o.event_media.table) cdnmedia_em, $(o.media.table) cdnmedia_m
                         where $(o.advsearch.table).id = cdnmedia_em.event_id and cdnmedia_em.url = cdnmedia_m.url and cdnmedia_m.size = 'small' and cdnmedia_m.animated = 1
                         limit 1)")
                end
            end
        end
        # println((op, conds))
        if isempty(conds)
            nothing
        else
            "($(join(conds, " and ")))"
        end
    end

    @assert expr isa O.And || expr isa O.Or
    c = tosql_op(expr)
    !isnothing(c) && push!(conds, c)

    ("
     $(join(ctes, ", "))
     select $(join([selects..., "$orderkey as orderkey"], ", "))
     from $(join(tables, ", "))
     where $(join(conds, " and "))
     order by $orderby $order
     ", params, string(split(orderby, '.')[end]))
end

function debug_query(est, query; limit=40, user_pubkey=Main.test_pubkeys[:pedja], since=0, until=Utils.current_time(), explain=:full)
    # sql *= " limit $limit"
    # foreach(println, map(first, Postgres.execute(:p0timelimit, "explain (analyze,settings,buffers) "*sql, params)[2]))
    # r = Postgres.execute(:p0timelimit, sql, params)
    
    # foreach(println, map(first, Postgres.execute(:p0timelimit, "explain declare cur cursor for "*sql, params)[2]))
    # println()
    
    r = transaction_with_execution_stats(SEARCH_SERVER[]) do session
        @time Main.App.fetch_results(session, since, until, limit, 0;
                                     explain,
                                     sql_generator=function (s, u, rs_)
                                         @show (length(rs_), "$((u-s)/(24*3600)) days", "$(u-s) secs", Dates.unix2datetime(s), Dates.unix2datetime(u))
                                         sql, params = to_sql(est, user_pubkey, Main.App.DAG_OUTPUTS[][2], parse_search_query(query), 1, s, u, limit, 0)
                                         println(sql)
                                         println()
                                         sql2 = replace(sql, r"\$[0-9]+"=>function (s)
                                                            v = params[parse(Int, s[2:end])]
                                                            if v isa Nostr.EventId || v isa Nostr.PubKeyId
                                                                v = "'\\x"*Nostr.hex(v)*"'"
                                                            else
                                                                v = repr(v)
                                                            end
                                                            replace(v, '"'=>'\'')
                                                        end)
                                         println(pgpretty(sql2))
                                         println()
                                         (sql, params)
                                     end) 
    end
    @show length(r)

    r
end

# test

using Test: @testset, @test

function runtests()
    @testset "AdvancedSearch-Parsing-1" begin
        input = "word1 word2 \"phraseword1 phraseword2\" -notword1 -\"phraseword3 phraseword4\" #hashtag1 since:2011-02-03 until:2022-02-03_11:22 from:88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079 from:npub13rxpxjc6vh65aay2eswlxejsv0f7530sf64c4arydetpckhfjpustsjeaf to:88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079 @88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079 kind:123 filter:filter url:urlword1 orientation:vertical minduration:123 maxduration:234 :) list:list1 ? maxscore:123 mininteractions:5 scope:myfollows minwords:100 minlongreplies:11 mintrustrank:-9 lang:fra features:feat1,feat2"
        expr = parse_search_query(input)
        @assert expr isa O.And
        # dump(expr)
        for (result, expected) in zip(expr.ops, 
                                      (O.Word("word1"), O.Word("word2"), 
                                       O.Phrase("phraseword1 phraseword2"), 
                                       O.NotWord("notword1"), 
                                       O.NotPhrase("phraseword3 phraseword4"), 
                                       O.HashTag("hashtag1"),
                                       O.Since(1296691200),
                                       O.Until(1643887320),
                                       O.From(Nostr.PubKeyId("88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079")),
                                       O.From(Nostr.PubKeyId("88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079")),
                                       O.To(Nostr.PubKeyId("88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079")),
                                       O.Mention(Nostr.PubKeyId("88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079")),
                                       O.Kind(123),
                                       O.Filter("filter"),
                                       O.Url("urlword1"),
                                       O.Orientation("vertical"),
                                       O.MinDuration(123),
                                       O.MaxDuration(234),
                                       O.Emoticon(":)"),
                                       O.List("list1"),
                                       O.Question(),
                                       O.EventStatsField(:score, :(<=), 13516483516),
                                       O.MinInteractions(5),
                                       O.Scope("myfollows"),
                                       O.MinWords(100),
                                       O.MinLongReplies(11),
                                       O.MinTrustRank(-9),
                                       O.Lang("fra"),
                                       O.Features(["feat1", "feat2"]),
                                      ))
            @test result == expected
        end
    end
    @testset "AdvancedSearch-Parsing-2" begin
        input = "word1 word2 (word3 OR word4)"
        expr = parse_search_query(input)
        # dump(expr)
        # @test expr == O.And([O.Word("word1"), O.Word("word2"), O.Or([O.Word("word1"), O.Word("word2")])])
    end
end

end

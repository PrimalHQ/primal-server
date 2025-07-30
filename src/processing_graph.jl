module ProcessingGraph

import UUIDs
import JSON
import SHA
import Dates

import ..Utils
import ..Nostr
import ..Postgres
using ..PostgresMacros: @p0_str

PRINT_EXCEPTIONS = Ref(true)

CACHE_STORAGE = Ref{Any}(nothing)

CACHING_ENABLED = Ref(true)

LOG = Ref(false)

struct NodeId
    id::Vector{UInt8}
end

Base.show(io::IO, id::NodeId) = print(io, "NodeId(\"$(bytes2hex(id.id))\")")
NodeId(id::String) = NodeId(hex2bytes(id))

args_kwargs_serialize(args, kwargs) = (; args=arg_serialize(args), kwargs=arg_serialize(Dict(collect(pairs(kwargs)))))

function node_id(mod, func, args, kwargs)::NodeId
    mod = string(mod)
    func = string(func)
    a = args_kwargs_serialize(args, kwargs)
    NodeId(SHA.sha256(JSON.json((; mod, func, a.args, a.kwargs))))
end

function update_node(mod, func, args, kwargs; id=nothing, result=nothing, exception=false, started_at=nothing, finished_at=nothing, extra=nothing, code_sha256=nothing)::NodeId
    mod = string(mod)
    func = string(func)
    isnothing(id) && (id = node_id(mod, func, args, kwargs))
    a = args_kwargs_serialize(args, kwargs)
    result = isnothing(result) ? nothing : arg_serialize(result)
    extra = (isnothing(extra) || isempty(extra)) ? nothing : arg_serialize(Dict(collect(pairs(extra))))
    params = [id.id, 
              mod, func, 
              JSON.json(a.args), JSON.json(a.kwargs), 
              isnothing(result) ? nothing : JSON.json(result), 
              exception, 
              started_at, finished_at,
              isnothing(extra) ? nothing : JSON.json(extra), 
              code_sha256,
             ]
    LOG[] && println("update_node: $id: $params")
    Postgres.execute(:p0, "
                     insert into processing_nodes 
                     values (\$1, now(), now(), \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11)
                     on conflict (id) do update set 
                        updated_at = now(), 
                        mod = excluded.mod, 
                        func = excluded.func, 
                        args = excluded.args, 
                        kwargs = excluded.kwargs, 
                        result = excluded.result, 
                        exception = excluded.exception, 
                        started_at = excluded.started_at, 
                        finished_at = excluded.finished_at, 
                        extra = excluded.extra,
                        code_sha256 = excluded.code_sha256
                    ", 
                    params)
    id
end

function get_node(id::NodeId)
    rs = Postgres.execute(:p0, "select * from processing_nodes where id = \$1 limit 1", [id.id])
    if isempty(rs[2])
        nothing
    else
        (; [Symbol(k)=>arg_deserialize(v) for (k, v) in zip(rs[1][2:end], rs[2][1][2:end])]..., id)
    end
end

code_updates = []

function update_code(mod, code_info; extra=nothing)
    ci = code_info
    mod = string(mod)
    func = string(ci.func)
    extra = (isnothing(extra) || isempty(extra)) ? nothing : JSON.json(arg_serialize(Dict(collect(pairs(extra)))))
    params = [ci.code_sha256, mod, func, string(ci.file), ci.line, ci.source, ci.source_with_linenums, extra]
    push!(code_updates, (; ci, mod, func, extra, params))
    1==0 && insert_code_update(params)
    nothing
end

function insert_code_update(params)
    Postgres.execute(:p0, "
                     insert into processing_codes 
                     values (\$1, now(), \$2, \$3, \$4, \$5, \$6, \$7, \$8)
                     on conflict (code_sha256) do update set 
                        created_at = now(), 
                        mod = excluded.mod, 
                        func = excluded.func, 
                        file = excluded.file,
                        line = excluded.line,
                        source = excluded.source,
                        source_with_linenums = excluded.source_with_linenums,
                        extra = excluded.extra
                        ", params)
end

function get_code_info(expr)
    file = line = source_with_linenums = source = code_sha256 = nothing
    if expr.head in [:function, :(=)]
        file = expr.args[2].args[1].file
        line = expr.args[2].args[1].line
        source_with_linenums = string(expr)
        expr_ = copy(expr)
        Base.remove_linenums!(expr_)
        source = string(expr_)
        code_sha256 = SHA.sha256(source)
    else
        error("unsupported function syntax")
    end

    func = 
    if expr.args[1].head == :call
        expr.args[1].args[1]
    elseif expr.args[1].head == :(::)
        expr.args[1].args[1].args[1]
    else
        error("unsupported function syntax")
    end

    (; func, file, line, source, source_with_linenums, code_sha256)
end

proc_node_funcs = Dict{Symbol, Expr}()
proc_node_func_updates = []

macro procnode(expr)
    @assert expr.head in [:function, :(=)]
    innername = Base.esc(:__innerfunc__)
    # innername = :__innerfunc__
    if expr.args[1].head == :call
        funcname = expr.args[1].args[1]
        # expr.args[1].args[1] = innername
    elseif expr.args[1].head == :(::)
        @assert expr.args[1].args[1].head == :call
        funcname = expr.args[1].args[1].args[1]
        # expr.args[1].args[1].args[1] = innername
    else
        error("unsupported function syntax for @procnode macro")
    end

    expr_copy = copy(expr)
    proc_node_funcs[funcname] = expr_copy
    push!(proc_node_func_updates, (; t=Dates.now(), func=funcname, expr=expr_copy))

    function get_argnames(exprs)
        names = Symbol[]
        for a in exprs
            if     a isa Symbol
                push!(names, a)
            elseif a isa Expr && a.head == :kw
                e = a.args[1]
                if e isa Symbol
                    push!(names, e)
                elseif e isa Expr
                    @assert e.args[1] isa Symbol
                    push!(names, e.args[1])
                end
            elseif a isa Expr && a.head == :(::)
                a.args[1] isa Symbol && push!(names, a.args[1])
            end
        end
        names
    end

    # dump(expr)
    argnames = get_argnames(expr.args[1].args[2:end])
    # @show argnames

    kwargnames = Symbol[]
    for a in expr.args[1].args[2:end]
        if a isa Expr && a.head == :parameters
            append!(kwargnames, get_argnames(a.args))
        end
    end
    # @show kwargnames

    collectargs0 = Expr(:tuple, argnames...)
    # println(collectargs0)

    collectkwargs0 = :((; $(Expr(:vect, [Expr(:call, :(=>), QuoteNode(a), a) for a in kwargnames]...))...))
    # println(collectkwargs0)
    
    mod = __module__
    @show mod
    ci = get_code_info(expr)
    update_code(mod, ci)

    res = Expr(:function, expr.args[1], 
               :(let args0 = $collectargs0,
                   kwargs0 = $collectkwargs0,
                   _PG = Main.ProcessingGraph,
                   _funcname = $(QuoteNode(funcname)),
                   _code_sha256 = $(ci.code_sha256),
                   _mod = $(mod),
                   _id = _PG.node_id(_mod, _funcname, args0, kwargs0),
                   _tls = task_local_storage(),
                   _stack = get(_tls, :processing_graph_stack, []),
                   _extra = Dict(),
                   _reverting = get(_tls, :processing_graph_reverting, false),
                   _started_at = _PG.Dates.now()

                   if _PG.CACHING_ENABLED[] && !get(_tls, :processing_graph_no_caching, false) && !isnothing(local _node = _PG.get_node(_id))
                       # @show _node
                       !isnothing(_node.finished_at) && return (; ok=!_node.exception, result=_node.result, id=_id)
                   end

                   isempty(_stack) || _PG.subnode(_stack[end], _id)
                   
                   if !isempty(local rs = Postgres.execute(:p0, "select extra from processing_nodes where id = \$1 and extra is not null", [_id.id])[2])
                       merge!(_extra, rs[1][1])
                   end

                   function _update_extra()
                       Postgres.execute(:p0, "update processing_nodes set extra = \$2 where id = \$1", [_id.id, JSON.json(_extra)])
                   end
                   function E(; kwargs...)
                       merge!(_extra, pairs(kwargs))
                       _update_extra()
                       kwargs
                   end
                   function extralog(v)
                       if !haskey(_extra, :log)
                           _extra[:log] = []
                       end
                       push!(_extra[:log], v)
                       _update_extra()
                       v
                   end
                   function extralogexception()
                       extralog((; exception=Utils.get_exceptions()))
                       PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                   end

                   _PG.update_node(_mod, _funcname, args0, kwargs0; started_at=_started_at, code_sha256=_code_sha256)

                   # @show (args0, _funcname, _tstart)
                   
                   try
                       push!(_stack, _id)
                       _result = try
                           task_local_storage(:processing_graph_stack, _stack) do
                               $(expr.args[2])
                           end
                       finally
                           pop!(_stack)
                       end
                       _PG.update_node(_mod, _funcname, args0, kwargs0; result=_result, started_at=_started_at, finished_at=_PG.Dates.now(), extra=_extra, code_sha256=_code_sha256)
                       (; ok=true, r=_result, id=_id)
                   catch _ex
                       _result = Utils.get_exceptions()
                       _PG.update_node(_mod, _funcname, args0, kwargs0; result=_result, started_at=_started_at, finished_at=_PG.Dates.now(), extra=_extra, code_sha256=_code_sha256, exception=true)
                       # (; ok=false, r=_result, id=_id)
                       rethrow()
                   end
               end)) |> Base.esc
    # println(Base.remove_linenums!(copy(res)))
    
    res
end

function pn(expr, mod_; rand_id=false, delayed=false)
    dump(expr)
    mod = nothing
    if expr.head == :call
        if expr.args[1] isa Symbol
            funcname = expr.args[1]
        elseif expr.args[1] isa Expr && expr.args[1].head == :(.)
            mod, funcname = expr.args[1].args
            funcname = funcname.value
        else
            error("unsupported call syntax for @pn macro")
        end
    else
        error("unsupported call syntax for @pn macro")
    end

    if isnothing(mod)
        mod = Meta.parse(string(mod_))
    end
    @show (mod, funcname)

    args = []
    kwargs = []
    for a in expr.args[2:end]
        if     a isa Symbol
            push!(args, a)
        elseif a isa Expr && a.head == :parameters
            for av in a.args
                if av isa Expr && av.head == :kw
                    push!(kwargs, av.args[1] => av.args[2])
                else
                    push!(kwargs, av)
                end
            end
        elseif a isa Expr && a.head == :kw
            push!(kwargs, a.args[1] => a.args[2])
        else
            push!(args, a)
        end
    end
    @show args
    @show kwargs

    # dump(args)
    # dump(kwargs)

    collectargs0 = Expr(:tuple, [v for v in args]...)
    println(collectargs0)

    collectkwargs0 = :((; $(Expr(:vect, [let (k, v) = a isa Pair ? (a[1], a[2]) : (a, a)
                                             Expr(:call, :(=>), QuoteNode(k), v)
                                         end for a in kwargs]...))...))
    println(collectkwargs0)

    res = :(let args0 = $collectargs0,
                kwargs0 = $collectkwargs0,
                _PG = Main.ProcessingGraph,
                _mod = $(mod),
                _funcname = $(QuoteNode(funcname)),
                _id = $(rand_id ? :(_PG.NodeId(rand(UInt8, 32))) : :(_PG.node_id(_mod, _funcname, args0, kwargs0))),
                _started_at = _PG.Dates.now(),
                _stack = get(task_local_storage(), :processing_graph_stack, [])

                isempty(_stack) || _PG.subnode(_stack[end], _id)

                $(if delayed
                      :(begin
                            _PG.update_node(_mod, _funcname, args0, kwargs0; id=_id)
                            _id
                        end)
                  else
                      :(begin
                            _PG.update_node(_mod, _funcname, args0, kwargs0; id=_id, started_at=_started_at)
                            try
                                push!(_stack, _id)
                                _result = try
                                    task_local_storage(:processing_graph_stack, _stack) do
                                        $(mod).$(funcname)(args0...; kwargs0...)
                                    end
                                finally
                                    pop!(_stack)
                                end
                                _extra = Postgres.execute(:p0, "select extra from processing_nodes where id = \$1", [_id.id])[2][1][1]
                                _extra = ismissing(_extra) ? nothing : _extra
                                _PG.update_node(_mod, _funcname, args0, kwargs0; id=_id, result=_result, started_at=_started_at, finished_at=_PG.Dates.now(), extra=_extra)
                                _result
                            catch _ex
                                _result = Utils.get_exceptions()
                                _extra = Postgres.execute(:p0, "select extra from processing_nodes where id = \$1", [_id.id])[2][1][1]
                                _extra = ismissing(_extra) ? nothing : _extra
                                _PG.update_node(_mod, _funcname, args0, kwargs0; id=_id, result=_result, started_at=_started_at, finished_at=_PG.Dates.now(), extra=_extra, exception=true)
                                rethrow()
                            end
                        end)
                  end)
            end) |> Base.esc
    # println(Base.remove_linenums!(copy(res)))
    
    println(res)

    res
end

macro pnd(expr); pn(expr, __module__; rand_id=false, delayed=true); end

macro pn(expr); pn(expr, __module__; rand_id=true, delayed=false); end

function log(args...; kwargs...); end

macro pnl(expr); pn(:(Main.ProcessingGraph.log($(expr)...)), @__MODULE__; rand_id=true, delayed=false); end

function uncached(f::Function)
    task_local_storage(:processing_graph_no_caching, true) do
        f()
    end
end

function collect_node_ids(a)::Vector{NodeId}
    ids = []
    if a isa NodeId
        push!(ids, a)
    elseif a isa Vector || a isa Set || a isa Tuple || a isa Pair
        for v in a
            append!(ids, collect_node_ids(v))
        end
    elseif a isa Dict
        for v in keys(a)
            append!(ids, collect_node_ids(v))
        end
        for v in values(a)
            append!(ids, collect_node_ids(v))
        end
    end 
    ids |> Set |> collect
end

function subnode(pid::NodeId, nid::NodeId; extra=nothing)
    Postgres.execute(:p0, "
                     insert into processing_edges values ('ancestry', \$1, \$2, now(), now(), \$3)
                     on conflict (type, id1, id2) do update set updated_at = excluded.updated_at, extra = excluded.extra
                     ", [pid.id, nid.id, isnothing(extra) ? nothing : JSON.json(extra)])
end

function execute_node(id::NodeId; force=false, reverting=false)
    castnothing(v) = ismissing(v) ? nothing : v

    rs = p0"select mod, func, args, kwargs, extra from processing_nodes where id = $(id.id) and (case when not $(force || reverting) then finished_at is null else true end) limit 1"
    isempty(rs) && return
    r = rs[1]

    started_at = Dates.now()

    args = kwargs = mod = func = f = nothing
    try
        args   = arg_deserialize(r.args)
        kwargs = (; [Symbol(k)=>v for (k, v) in arg_deserialize(r.kwargs)]...)
        mod    = Main.eval(Meta.parse(r.mod))
        @assert mod isa Module
        func  = Symbol(r.func)
        f = getproperty(mod, func)
        # @show (func, id, node_id(r.mod, r.func, args, kwargs))
    catch ex
        result = Utils.get_exceptions()
        p0"update processing_nodes set updated_at = now(), result = $(JSON.json(result)), exception = true, started_at = $started_at, finished_at = $started_at where id = $(id.id)" 
        return (; ok=false, r=result, id)
    end

    update_node(r.mod, r.func, r.args, r.kwargs; id, started_at, extra=castnothing(r.extra))
    return try
        result = task_local_storage(:processing_graph_stack, [id]) do
            task_local_storage(:processing_graph_reverting, reverting) do
                f(args...; kwargs...)
            end
        end
        extra = p0"select extra from processing_nodes where id = $(id.id)"[1].extra |> castnothing
        update_node(r.mod, r.func, r.args, r.kwargs; id, result, started_at, finished_at=Dates.now(), extra)
        try 
            # println(JSON.json(r.args, 2))
            cleanup_binary_cache_arguments(r.args) 
            # println(JSON.json(r.kwargs, 2))
            cleanup_binary_cache_arguments(collect(values(r.kwargs)))
        catch _ Utils.print_exceptions() end
        (; ok=true, r=result, id)
    catch _ex
        result = Utils.get_exceptions()
        extra = p0"select extra from processing_nodes where id = $(id.id)"[1].extra |> castnothing
        update_node(r.mod, r.func, r.args, r.kwargs; id, result, exception=true, started_at, finished_at=Dates.now(), extra)
        (; ok=false, r=result, id)
    end
end

function execute_delayed_nodes(func; limit=1, ntasks=4)
    asyncmap(p0"select * from processing_nodes where func = $func and started_at is null and finished_at is null order by created_at limit $limit"; ntasks) do r
        id = NodeId(r.id)
        # @show id
        id=>execute_node(id)
    end
end

revert_node(id::NodeId) = execute_node(id; reverting=true)

@procnode function invoke_non_node(; mod, name, args, kwargs)
    f = getproperty(getproperty(Main, mod), name)
    f(args...; kwargs...)
end

export arg_serialize
arg_serialize(v) = v

arg_serialize(v::Symbol) = (; _ty="Symbol", _v=v)
arg_serialize(v::NodeId) = (; _ty="NodeId", _v=bytes2hex(v.id))
arg_serialize(v::Nostr.PubKeyId) = (; _ty="PubKeyId", _v=v)
arg_serialize(v::Nostr.EventId) = (; _ty="EventId", _v=v)
arg_serialize(v::Nostr.Event) = (; _ty="Event", _v=v.id)
arg_serialize(v::Dict) = Dict([k=>arg_serialize(v) for (k, v) in v])
arg_serialize(v::Vector) = [arg_serialize(v) for v in v]
arg_serialize(v::Tuple) = (; _ty="Tuple", _v=[arg_serialize(e) for e in v])
arg_serialize(v::NamedTuple) = (; _ty="NamedTuple", _v=arg_serialize(Dict(pairs(v))))
arg_serialize(v::Base.UUID) = (; _ty="UUID", _v=string(v))
arg_serialize(v::Function) = (; _ty="Function", _v=string(v))

BINARY_DATA_CACHE_DIR = Ref("./cache/procgraph")

function arg_serialize(v::Vector{UInt8})
    if length(v) <= 256
        (; _ty="Vector{UInt8}", _v=bytes2hex(v))
    else
        sha256 = SHA.sha256(v)
        hh = bytes2hex(sha256)
        fn = "$(BINARY_DATA_CACHE_DIR[])/$(hh[1:2])/$(hh[3:4])/$(hh)"
        dir = splitdir(fn)[1]
        isdir(dir) || mkpath(dir)
        isfile(fn) || write(fn, v)
        (; _ty="Vector{UInt8}", _cache_sha256=bytes2hex(sha256))
    end
end

arg_map = Dict([
                "Symbol"=>v->Symbol(v["_v"]),
                "NodeId"=>v->NodeId(hex2bytes(v["_v"])),
                "PubKeyId"=>v->Nostr.PubKeyId(v["_v"]),
                "EventId"=>v->Nostr.EventId(v["_v"]),
                "Event"=>v->CACHE_STORAGE[].events[Nostr.EventId(v["_v"])],
                "Tuple"=>v->tuple([arg_deserialize(e) for e in v["_v"]]...),
                "NamedTuple"=>v->(; [Symbol(k)=>arg_deserialize(e) for (k, e) in v["_v"]]...),
                "UUID"=>Base.UUID,
                "Function"=>v->error("function deserialization not supported yet: $(v["_v"])"),
                "Vector{UInt8}"=>function (v)
                    if haskey(v, "_cache_sha256")
                        hh = v["_cache_sha256"]
                        fn = "$(BINARY_DATA_CACHE_DIR[])/$(hh[1:2])/$(hh[3:4])/$(hh)"
                        read(fn)
                    else
                        hex2bytes(v["_v"])
                    end
                end,
               ])

function arg_deserialize(v)
    if v isa Dict
        if haskey(v, "_ty")
            if haskey(arg_map, v["_ty"])
                return arg_map[v["_ty"]](v)
            else
                error("arg_deserialize: unknown type: $(v["_ty"])")
            end
        end
        return Dict([k=>arg_deserialize(v) for (k, v) in v])
    elseif v isa Vector
        return [arg_deserialize(v) for v in v]
    else
        return v
    end
end

function cleanup_binary_cache_arguments(v)
    if v isa Dict
        if haskey(v, "_ty") && haskey(arg_map, v["_ty"])
            if v["_ty"] == "Vector{UInt8}" && haskey(v, "_cache_sha256")
                hh = v["_cache_sha256"]
                fn = "$(BINARY_DATA_CACHE_DIR[])/$(hh[1:2])/$(hh[3:4])/$(hh)"
                if isfile(fn)
                    # println("cleanup_binary_cache_arguments: rm $fn")
                    rm(fn)
                end
            end
            if v["_ty"] == "Tuple"
                for v in v["_v"]
                    cleanup_binary_cache_arguments(v)
                end
            end
            return
        end
        for (k, v) in v
            cleanup_binary_cache_arguments(v) 
        end
    elseif v isa Vector
        for v in v
            cleanup_binary_cache_arguments(v)
        end
    end
end

end

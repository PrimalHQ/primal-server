module Tracing

import JSON
import Dates
import UUIDs

import ..Utils
import ..Postgres

const ENABLED = Ref(true)
const PRINT_EXCEPTIONS = Ref(true)

const hostname = gethostname()

function handle_assignment(body::Function, expr)
    outvar, expr = 
    if !(expr isa Symbol) && expr.head == :(=)
        Base.esc(expr.args[1]), expr.args[2]
    else
        nothing, expr
    end

    r = body(expr)

    isnothing(outvar) ? r : :($outvar = $r)
end

macro td(expr)
    handle_assignment(expr) do expr
        :(task_local_storage(:tracing_depth, get(task_local_storage(), :tracing_depth, 0) + 1) do
              $(esc(expr))
          end)
    end
end

macro tc(exprs...)
    label, expr = if length(exprs) == 2 && exprs[1] isa String
        exprs[1], exprs[2]
    else
        "", exprs[1]
    end

    handle_assignment(expr) do expr
        :(let sub_context = string(UUIDs.uuid4())
              parent_context = get(task_local_storage(), :tracing_context, nothing)
              ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $label, "sub-context-enter"; extra=(; parent_context, sub_context))
              try
                  task_local_storage(:tracing_context, sub_context) do
                      @td $(esc(expr))
                  end
              finally
                  ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $label, "sub-context-exit"; extra=(; parent_context, sub_context))
              end
          end)
    end
end

macro ti(exprs...)
    label, expr = if length(exprs) == 2 && exprs[1] isa String
        exprs[1], exprs[2]
    else
        "", exprs[1]
    end

    handle_assignment(expr) do expr
        :(let sub_task = string(UUIDs.uuid4())
              parent_task = get(task_local_storage(), :tracing_task, nothing)
              ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $label, "sub-task-enter"; extra=(; parent_task, sub_task))
              try
                  task_local_storage(:tracing_task, sub_task) do
                      @tc $(esc(expr))
                  end
              finally
                  ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $label, "sub-task-exit"; extra=(; parent_task, sub_task))
              end
          end)
    end
end

function tr(exprs)
    expr = exprs[end]
    exprs = exprs[1:end-1]

    label, exprs = if length(exprs) >= 2 && exprs[1] isa String
        exprs[1], exprs[2:end]
    else
        string(expr), exprs
    end

    extra = if length(exprs) > 0
        Expr(:tuple, Expr(:parameters, [Expr(:kw, Symbol(string(n)), n) for n in exprs]...)) |> Base.esc
    else
        missing
    end

    val = gensym()
    t0 = gensym()
    depth = gensym()

    handle_assignment(expr) do expr
        :(let $t0 = time()
              $depth = get(task_local_storage(), :tracing_depth, 0)
              try
                  let $val = @td $(esc(expr))
                      ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $label, $val; duration=time()-$t0, depth=$depth, extra=$extra)
                      $val
                  end
              catch ex
                  ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $label, ex; duration=time()-$t0, depth=$depth, extra=$extra, exception=true)
                  rethrow()
              end
          end)
    end
end

macro tr(exprs...)
    tr(exprs)
end

# macro trc(exprs...)
#     expr = exprs[end]
#     tr([exprs[1:end-1]; [expr]])
# end

macro tasync(expr)
    taskvar = gensym()
    logvar  = gensym()
    quote
        let $taskvar = get(task_local_storage(), :tracing_task, nothing)
            $logvar  = get(task_local_storage(), :tracing_log, nothing)
            @async task_local_storage(:tracing_task, $taskvar) do
                task_local_storage(:tracing_log, $logvar) do
                    $(esc(expr))
                end
            end
        end
    end
end

macro named(expr)
    @assert expr.head == :function
    funcname = 
    if expr.args[1].head == :call
        string(expr.args[1].args[1])
    elseif expr.args[1].head == :(::)
        @assert expr.args[1].args[1].head == :call
        string(expr.args[1].args[1].args[1])
    else
        error("unsupported function syntax for @named macro")
    end
    res = Expr(:function, expr.args[1], Expr(:block, :(funcname = $funcname), expr.args[2].args...))
    Base.esc(res)
end

function log_trace(mod::Module, funcname, expr::String, value; duration=missing, depth=missing, extra=missing, exception=false)
    if exception
        bio = IOBuffer()
        Utils.print_exceptions(bio)
        value = (; type=string(typeof(value)), str=String(take!(bio)))
    end

    tls = task_local_storage()

    task_ptr = repr(UInt64(pointer_from_objref(Base.current_task())))
    task     = get(tls, :tracing_task, task_ptr)
    context  = get(tls, :tracing_context, missing)
    log      = get(tls, :tracing_log, nothing)

    isnothing(task) && (task = task_ptr)

    try
        params = [
                  hostname, 
                  string(Main.NODEIDX), 
                  task,
                  Threads.threadid(),
                  repr(mod),
                  funcname, missing, missing,
                  expr,
                  try JSON.json(value) catch _ JSON.json(string(value)) end,
                  Dates.now(),
                  exception,
                  duration,
                  depth,
                  ismissing(extra) ? missing : try JSON.json(extra) catch _ JSON.json(string(extra)) end,
                  ismissing(context) ? missing : context,
                  task_ptr,
                 ]
        Postgres.execute(:p7, "insert into trace values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13, \$14, \$15, \$16, default, \$17)",
                         params)
        isnothing(log) || push!(log, params)
    catch ex
        if PRINT_EXCEPTIONS[]
            Utils.print_exceptions()
            @show value extra
        end
    end
end

function logged(body::Function; log=[])
    task_local_storage(body, :tracing_log, log)
    log
end

function should_log_expr(expr)
    true
end

@named function testfunc1(a, b)
    @tr a+b
end

@named function testfunc2(a, b)
    @tr a b+1 testfunc1(a, b)
end

end

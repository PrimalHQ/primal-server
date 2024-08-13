module DAGRunner

import Dates
using DataStructures: CircularBuffer

import ..Utils
using ..Utils: ThreadSafe, current_time

const LOG = Ref(false)

const PRINT_EXCEPTIONS = Ref(false)
const print_exceptions_lock = ReentrantLock()

const RUN_PERIOD = Ref(5.0)

const DEACTIVATE_ON_ERROR = Ref(false)

const current_dag = Ref{Any}(nothing)
const current_logs = Ref{Any}(nothing)

const processing_times = CircularBuffer{Any}(1000)

mutable struct Dag
    modname
    mod
    active

    runkwargs
    runtag
    since
    until
    running

    failed
    successful
    lastok

    est
    state

    Dag(;
        modname,
        runtag, est, state=Utils.Dyn(),
        since=trunc(Int, Dates.datetime2unix(Dates.DateTime("2023-01-01"))),
        until=current_time(),
        active=true,
        runkwargs...,
       ) = new(modname, getproperty(Main, modname), active,
               runkwargs, runtag, since, until, Ref(false),
               CircularBuffer{Any}(1000), CircularBuffer{Any}(1000), nothing,
               est, state)
end

const dags = Dict{Symbol, Dag}() |> ThreadSafe

const task = Ref{Any}(nothing)
const running = Ref(true)

function start()
    @assert isnothing(task[]) || istaskdone(task[])

    running[] = true

    task[] = 
    errormonitor(@async while running[]
                     try
                         Base.invokelatest(run_dags)
                     catch _
                         PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                     end
                     Utils.active_sleep(RUN_PERIOD[], running)
                 end)

    nothing
end

function stop()
    @assert !isnothing(task[])
    running[] = false
    Utils.wait_for(()->istaskdone(task[]))
end

function run_dags()
    cnt = 0
    tdur = @elapsed for (modname, m) in collect(dags)
        m.active || continue
        cnt += 1
        current_dag[] = m
        m.mod = getproperty(Main, modname)
        started_at = Dates.now()
        finished_at = nothing
        exc = nothing
        current_logs[] = logs = []
        exceptions = []
        m.running[] = true
        m.lastok = nothing
        result = nothing
        processing_time = @elapsed try
            m.until = current_time()
            result = m.mod.run(; m.est, m.state,
                               m.since, m.until, m.runtag, 
                               m.running, 
                               log=function (args...)
                                   LOG[] && println(@__MODULE__, "(", modname, "): ", args...)
                                   push!(logs, args)
                               end,
                               on_exception=function (args...)
                                   LOG[] && println(@__MODULE__, "(", modname, "): exception: ", args...)
                                   push!(exceptions, args)
                               end,
                               m.runkwargs...)
            finished_at = Dates.now()
            m.running[] && (m.since = m.until)
        catch ex
            exc = ex
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
            iob = IOBuffer()
            Utils.print_exceptions(iob)
            push!(exceptions, (ex, String(take!(iob))))
        end
        m.lastok = ran_ok = m.running[]
        r = (; 
             started_at, 
             finished_at,
             result,
             processing_time, 
             ran_ok,
             runner_exception=isnothing(exc) ? nothing : string(exc), 
             exceptions,
             logs,
            )
        push!(ran_ok ? m.successful : m.failed, r)
        LOG[] && println(@__MODULE__, "(", modname, "): ", 
                         (; 
                          r.started_at, r.processing_time, r.ran_ok, 
                          exceptions=length(r.exceptions),
                          logs=length(r.logs),
                         ))
        if DEACTIVATE_ON_ERROR[] && (!running[] || !isempty(exceptions))
            m.active = false
            LOG[] && println(@__MODULE__, "(", modname, "): ", "deactivated due to error")
        end
    end
    current_dag[] = nothing
    current_logs[] = nothing
    push!(processing_times, (; t=Dates.now(), tdur, cnt))
    nothing
end

function register(modname::Symbol; kwargs...)
    dags[modname] = Dag(; modname, kwargs...)
    nothing
end

function unregister(modname::Symbol)
    delete!(dags, modname)
    nothing
end

end

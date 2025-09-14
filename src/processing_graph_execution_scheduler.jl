module ProcessingGraphExecutionScheduler

import Dates

using DataStructures: Accumulator

import ..Utils
import ..Postgres

import ..ProcessingGraph
using ..PostgresMacros: @p0_str

PRINT_EXCEPTIONS = Ref(true)

TASK_PERIOD = Ref(1.0)
task = Ref{Any}(nothing)
task_running = Ref(true)
subtasks = Dict{Symbol, Task}()

refresh_throttle = Utils.Throttle(; period=600)

function start()
    @assert task[] == nothing
    task_running[] = true
    task[] = errormonitor(@async while task_running[]
                              try
                                  Base.invokelatest(task_execute)
                              catch _
                                  PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                              end
                              Utils.active_sleep(TASK_PERIOD[], task_running)
                          end)
    nothing
end

function stop()
    task_running[] = false
    wait(task[])
    task[] = nothing
    nothing
end

function task_execute_once_1()
    rs = []
    for (func, ntasks) in [
                           (:block_media, 10),
                           (:purge_media_, 10),
                           # (:ext_event_batch, 1),
                          ]
        append!(rs, ProcessingGraph.execute_delayed_nodes(func; limit=ntasks, ntasks))
    end
    rs
end

function task_execute_import_media_pns_1(; limit, ntasks)
    asyncmap(p0"select * from processing_nodes where func = 'import_media_pn' and started_at is null and finished_at is null and     prioritized_media_import(id) order by created_at limit $limit"; ntasks) do r
        id = ProcessingGraph.NodeId(r.id)
        id=>ProcessingGraph.execute_node(id)
    end
end

function task_execute_import_media_pns_2(; limit, ntasks)
    asyncmap(p0"select * from processing_nodes where func = 'import_media_pn' and started_at is null and finished_at is null and not prioritized_media_import(id) order by created_at limit $limit"; ntasks) do r
        id = ProcessingGraph.NodeId(r.id)
        id=>ProcessingGraph.execute_node(id)
    end
end

function task_execute()
    yield()
    executed = Accumulator{Symbol, Int}()
    failed   = Accumulator{Symbol, Int}()
    for (n, f) in [
                   (:task_execute_once_1, ()->errormonitor(@async task_execute_once_1())),
                   (:import_upload_3, ()->errormonitor(@async ProcessingGraph.execute_delayed_nodes(:import_upload_3; limit=10, ntasks=10))),
                   ## (:import_media_pn, ()->errormonitor(@async ProcessingGraph.execute_delayed_nodes(:import_media_pn; limit=500, ntasks=100))),
                   # (:import_media_fast_pn, ()->errormonitor(@async ProcessingGraph.execute_delayed_nodes(:import_media_fast_pn; limit=100, ntasks=20))),
                   ### (:task_execute_import_media_pns_1, ()->errormonitor(@async task_execute_import_media_pns_1(; limit=100, ntasks=25))),
                   # (:task_execute_import_media_pns_2, ()->errormonitor(@async task_execute_import_media_pns_2(; limit=100, ntasks=25))),
                   ## (:import_preview_pn, ()->errormonitor(@async ProcessingGraph.execute_delayed_nodes(:import_preview_pn; limit=500, ntasks=100))),

                   ### (:import_media_pn, ()->errormonitor(@async ProcessingGraph.execute_delayed_nodes(:import_media_pn; limit=150, ntasks=30))),
                   ### (:import_preview_pn, ()->errormonitor(@async ProcessingGraph.execute_delayed_nodes(:import_preview_pn; limit=150, ntasks=30))),

                   # (:import_media_video_variants_pn, ()->errormonitor(@async ProcessingGraph.execute_delayed_nodes(:import_media_video_variants_pn; limit=2, ntasks=2))),

                   # (:ext_after_import_upload_2, ()->errormonitor(@async ProcessingGraph.execute_delayed_nodes(:ext_after_import_upload_2; limit=10, ntasks=10))),
                  ]
        if !haskey(subtasks, n)
            subtasks[n] = f()
        elseif istaskdone(subtasks[n])
            try
                c = length(fetch(subtasks[n]))
                if c > 0; executed[n] += c; end
            catch ex
                println("task_execute | error in $n: $ex")
                Utils.print_exceptions()
            end
            subtasks[n] = f()
            # n == :import_media_pn && @show Dates.now()
        elseif istaskfailed(subtasks[n])
            failed[n] += 1
            subtasks[n] = f()
        end
    end
    if sum([c for (_, c) in executed]) + sum([c for (_, c) in failed]) > 0
        println("task_execute | executed: $(Any[x for x in collect(executed)]) failed: $(Any[x for x in collect(failed)])")
    end

    refresh_throttle() do
        Postgres.execute(:p0, "refresh materialized view concurrently pn_time_for_pubkeys")
    end
end

end


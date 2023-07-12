#module MetricsLogger

import CPUTime

CPUTIME_PERIOD = Ref(0.1)
CPUTIME_AVG_PERIOD = Ref(10.0)

cputime_task = Ref{Any}(nothing)
cputime_avg = Ref(0.0)

function ext_start(output_filename)
    cputime_task[] = 
    errormonitor(@async begin
                     cputime_sum = Ref(0.0)
                     avg_period = Throttle(; period=CPUTIME_AVG_PERIOD[])
                     while running[]
                         CPUTime.CPUtic()
                         sleep(CPUTIME_PERIOD[])
                         cputime = CPUTime.CPUtoq()
                         log((; t=time(), event=:cputime, dt=CPUTIME_PERIOD[], cputime))
                         cputime_sum[] += cputime
                         avg_period() do
                             cputime_avg[] = cputime_sum[]/CPUTIME_AVG_PERIOD[]
                             cputime_sum[] = 0.0
                         end
                     end
                     @debug "cputime_task is stopped"
                 end)
end

function ext_stop()
    wait(cputime_task[])
    cputime_task[] = nothing
end


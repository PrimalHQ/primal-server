module Tracing

import ..JSON
import ..Dates

import ..Utils
import ..Postgres

const ENABLED = Ref(true)

const hostname = gethostname()

macro tr(expr)
    val = gensym()
    t0 = gensym()
    quote
        let $t0 = time()
            try
                let $val = $(esc(expr))
                    ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $(string(expr)), $val; duration=time()-$t0)
                    $val
                end
            catch ex
                ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $(string(expr)), ex; duration=time()-$t0, exception=true)
                rethrow()
            end
        end
    end
end

function log_trace(mod::Module, funcname, expr::String, value; duration=nothing, exception=false)
    if exception
        bio = IOBuffer()
        Utils.print_exceptions(bio)
        value = (; type=string(typeof(value)), str=String(take!(bio)))
    end

    Postgres.execute(:p7, "insert into trace values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13)",
                     [
                      hostname, 
                      string(Main.NODEIDX), 
                      repr(UInt64(pointer_from_objref(Base.current_task()))),
                      Threads.threadid(),
                      repr(mod),
                      funcname, missing, missing,
                      expr,
                      JSON.json(value),
                      Dates.now(),
                      exception,
                      duration,
                     ])
end

function testfunc1(a, b)
    funcname = "testfunc1"
    @tr a+b
    # @tr asdf
end

end

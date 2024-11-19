module Tracing

import ..JSON
import ..Dates

import ..Utils
import ..Postgres

const ENABLED = Ref(true)

const hostname = gethostname()

macro tr(expr)
    tmpval = gensym()
    quote
        try
            let $tmpval = $(esc(expr))
                ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $(string(expr)), $tmpval)
                $tmpval
            end
        catch ex
            ENABLED[] && log_trace(@__MODULE__, try $(esc(:funcname)) catch _ nothing end, $(string(expr)), ex; exception=true)
            rethrow()
        end
    end
end

function log_trace(mod::Module, funcname, expr::String, value; exception=false)
    if exception
        bio = IOBuffer()
        Utils.print_exceptions(bio)
        value = (; type=string(typeof(value)), str=String(take!(bio)))
    end

    Postgres.execute(:p7, "insert into trace values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12)",
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
                     ])
end

function testfunc1(a, b)
    funcname = "testfunc1"
    @tr a+b
    # @tr asdf
end

end

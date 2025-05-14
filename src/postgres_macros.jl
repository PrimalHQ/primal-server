module PostgresMacros

import ..Nostr
import ..Postgres

function pgps(expr)
    # dump(expr)
    expr isa String && return :(($expr, []))
    @assert expr.head == :string
    pidx = 1
    qs = []
    ps = []
    for a in expr.args
        if a isa String
            push!(qs, a)
        else
            push!(qs, "\$$pidx")
            pidx += 1
            push!(ps, Base.esc(a))
        end
    end
    # @show (qs, ps)
    q = join(qs)
    p = Expr(:vect, ps...)
    res = Expr(:tuple, q, p)
    # dump(res)
    # println(res)
    res
end

macro pgps(expr); pgps(expr); end

function pg_str(query::String)
    q = replace(repr(query), "\\\$" => "\$")
    expr = Meta.parse(q)
    pgps(expr)
end

function exec_to_table(connsel::Symbol, query::String)
    :($(Base.esc(Postgres)).execute($(QuoteNode(connsel)), $(pg_str(query))...))
end
function exec_to_namedtuples(connsel::Symbol, query::String)
    :($(Base.esc(Postgres)).execute($(QuoteNode(connsel)), $(pg_str(query))...) |> tonamedtuples)
end
function exec_to_table(connsel::String, query::String)
    :(let Postgres = $(Base.esc(Postgres))
          session = Postgres.make_session(Postgres.PGConnStr($connsel))
          try
              Postgres.execute(session, $(pg_str(query))...)
          finally
              try close(session) catch _ end
          end
      end)
end
function exec_to_namedtuples(connsel::String, query::String)
    :(let Postgres = $(Base.esc(Postgres))
          session = Postgres.make_session(Postgres.PGConnStr($connsel))
          try
              Postgres.execute(session, $(pg_str(query))...) |> tonamedtuples
          finally
              try close(session) catch _ end
          end
      end)
end

macro pg_str(query::String); pg_str(query); end

macro p0_str(query::String); exec_to_namedtuples(:p0, query); end
macro p0tl_str(query::String); exec_to_namedtuples(:p0timelimit, query); end
macro p7_str(query::String); exec_to_namedtuples(:p7, query); end
macro ms_str(query::String); exec_to_namedtuples(:membership, query); end

macro p0__str(query::String); exec_to_table(:p0, query); end
macro p0tl__str(query::String); exec_to_table(:p0timelimit, query); end
macro p7__str(query::String); exec_to_table(:p7, query); end
macro ms__str(query::String); exec_to_table(:membership, query); end

column_to_jl_type = Dict{String, Function}()
tonamedtuples(r) = [(; [Symbol(k)=>
                        if     k in ["pubkey", "pk"]    || endswith(k, "_pk");  Nostr.PubKeyId(v)
                        elseif k in ["event_id", "eid"] || endswith(k, "_eid"); Nostr.EventId(v)
                        else;  get(column_to_jl_type, k, identity)(v)
                        end
                        for (k, v) in zip(r[1], row)]...) for row in r[2]]

end


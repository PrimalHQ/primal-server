import JSON, Base64, Sockets
using Serialization: serialize, deserialize

function rexec(sock::Sockets.TCPSocket, expr::Expr)
    bio = IOBuffer()
    serialize(bio, expr)
    println(sock, JSON.json(["EXPR", Base64.base64encode(take!(bio))]))
    deserialize(IOBuffer(Base64.base64decode(readline(sock))))
end

function rexe(sock, expr)
    r = rexec(sock, quote
              try
                  $expr
              catch ex
                  (:exception, string(ex))
              end
          end)
    if r isa Tuple && r[1] == :exception
        throw(ErrorException(r[2]))
    else
        r
    end
end

function rex(srvidx, nodeidx, expr; container=7)
    rsock = Ref{Any}(nothing)
    try
        rsock[] = Sockets.connect("192.168.$(10+srvidx).$(container)", 12000+nodeidx)
        rexe(rsock[], expr)
    catch _
        println("EXC: $srvidx $nodeidx $(string(expr))")
        rethrow()
    finally
        isnothing(rsock[]) || try close(rsock[]) catch _ end
    end
end


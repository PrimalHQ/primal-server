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

REX_TIMEOUT = Ref(600.0)

function rex(srvidx, nodeidx, expr; container=7, timeout=REX_TIMEOUT[])
    rsock = Ref{Any}(nothing)
    timer = Ref{Any}(nothing)
    try
        rsock[] = Sockets.connect("192.168.$(10+srvidx).$(container)", 12000+nodeidx)
        timer[] = Timer(timeout) do _
            println("rex timeout ($srvidx, $nodeidx): closing socket after $(timeout)s")
            try close(rsock[]) catch _ end
        end
        rexe(rsock[], expr)
    catch _
        println("EXC: $srvidx $nodeidx $(string(expr))")
        rethrow()
    finally
        isnothing(timer[]) || try close(timer[]) catch _ end
        isnothing(rsock[]) || try close(rsock[]) catch _ end
    end
end


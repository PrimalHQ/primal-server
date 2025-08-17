##
import Base64, JSON
using Serialization: serialize, deserialize
FirehoseServer.message_processors[:server] = function (msg)
    if startswith(msg, "[\"EVAL\"")
        try
            Main.eval(Meta.parse(JSON.parse(msg)[2]))
        catch _
            "error happened:\n" * Utils.get_exceptions()
        end
    elseif startswith(msg, "[\"EVAL2\"")
        try
            println("--------------------------------------------------------")
            code_str = JSON.parse(msg)[2]
            code_to_print = startswith(code_str, "include(") ? read(code_str[10:end-2], String) : code_str
            println("EVAL code:")
            println(code_to_print)
            println()
            code_expr = Meta.parse(code_str)
            c = IOCapture.capture(; rethrow=Nothing) do
                try
                    eval(code_expr)
                catch _
                    Utils.print_exceptions()
                    rethrow()
                end
            end
            println("EVAL result: $(c.value)")
            println()
            println("EVAL output:")
            println(c.output)
            println()
            value = c.error ? "" : c.value
            (; value, c.output, c.error)
        catch ex
            println("EVAL error: $ex")
            Utils.print_exceptions()
            "error happened:\n" * Utils.get_exceptions()
        end
    elseif startswith(msg, "[\"EVALSQL\"")
        try
            println("--------------------------------------------------------")
            code_str = JSON.parse(msg)[2]
            code_to_print = code_str
            println("EVALSQL query:")
            println(code_to_print)
            println()
            c = IOCapture.capture(; rethrow=Nothing) do
                try
                    if occursin("update ", lowercase(code_str)) ||
                       occursin("insert ", lowercase(code_str)) ||
                       occursin("delete ", lowercase(code_str))
                       error("Tool does not support update, insert, or delete queries.")
                    else
                        let ctx = IOContext(stdout, :display_size => (100, 1000))
                            show(ctx, Base.MIME("text/plain"), Postgres.execute(:p0, code_str))
                        end
                    end
                catch ex
                    Utils.print_exceptions()
                    error("$ex")
                    # rethrow()
                end
            end
            println("EVALSQL result: $(c.value)")
            println()
            println("EVALSQL output:")
            println(c.output)
            println()
            value = c.error ? "" : c.value
            (; value, c.output, c.error)
        catch ex
            println("EVALSQL error: $ex")
            Utils.print_exceptions()
            "error happened:\n" * Utils.get_exceptions()
        end
    elseif startswith(msg, "[\"EXPR\"")
        r = Main.eval(deserialize(IOBuffer(Base64.base64decode(JSON.parse(msg)[2]))))
        bio = IOBuffer()
        serialize(bio, r)
        Base64.base64encode(take!(bio))
    else
        DB.import_msg_into_storage(msg, cache_storage)
    end
end
##

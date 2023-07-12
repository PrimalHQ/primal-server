##
import Base64, JSON
using Serialization: serialize, deserialize
FirehoseServer.message_processors[:server] = function (msg)
    if startswith(msg, "[\"EVAL\"")
        eval(Meta.parse(JSON.parse(msg)[2]))
    elseif startswith(msg, "[\"EXPR\"")
        r = eval(deserialize(IOBuffer(Base64.base64decode(JSON.parse(msg)[2]))))
        bio = IOBuffer()
        serialize(bio, r)
        Base64.base64encode(take!(bio))
    else
        DB.import_msg_into_storage(msg, cache_storage)
    end
end
##

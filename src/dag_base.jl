module DAGBase

export ServerTable
struct ServerTable
    servertype::Symbol
    server::Symbol
    table::String
    columns::Union{Nothing, Vector}
    ServerTable(servertype, server, table, columns=nothing) = new(servertype, server, table, columns)
end

end


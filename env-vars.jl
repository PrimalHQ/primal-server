STORAGEPATH   = get(ENV, "PRIMALSERVER_STORAGE_PATH", "$(pwd())/var")
PROXY         = get(ENV, "PRIMALSERVER_PROXY", nothing)
FETCHER_SINCE = try parse(Int, ENV["PRIMALSERVER_FETCHER_SINCE"]) catch _ trunc(Int, time()) end
NODEIDX       = parse(Int, get(ENV, "PRIMALSERVER_NODE_IDX", "1"))
RELAYS_FILE   = get(ENV, "PRIMALSERVER_RELAYS", "relays-minimal.txt")


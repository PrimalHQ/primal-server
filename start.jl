DB.init(cache_storage)

Fetching.start(; since=FETCHER_SINCE)

MetricsLogger.start("$STORAGEPATH/metrics-cache$(NODEIDX).log")

CacheServerHandlers.netstats_start()

CacheServer.start()


Postgres.start()

MetricsLogger.start("$STORAGEPATH/metrics-cache$(NODEIDX).log")

Fetching.start(; since=FETCHER_SINCE)
fetching_pushgateway_sender_start()

App.start(pqconnstr)
App.load_lists()
App.start_periodics(cache_storage)

Media.start_media_queue()

CacheServerHandlers.netstats_start()

CacheServer.start()

FirehoseServer.start()

InternalServices.start(cache_storage, pqconnstr)

WSConnUnblocker.start()

Threads.@spawn CacheServerSync.start()

Blossom.start(cache_storage)


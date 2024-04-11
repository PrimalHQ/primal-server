MetricsLogger.start("$STORAGEPATH/metrics-cache$(NODEIDX).log")

Fetching.start(; since=FETCHER_SINCE)
fetching_pushgateway_sender_start()

App.start_periodics(cache_storage)

Media.start_media_queue()

CacheServerHandlers.netstats_start()

CacheServer.start()

Postgres.start_monitoring()

FirehoseServer.start()

InternalServices.start(cache_storage, pqconnstr)

WSConnUnblocker.start()

Threads.@spawn CacheServerSync.start()


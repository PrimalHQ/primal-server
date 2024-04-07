#module DB

@enum NotificationType::Int begin
    NEW_USER_FOLLOWED_YOU=1
    USER_UNFOLLOWED_YOU=2

    YOUR_POST_WAS_ZAPPED=3
    YOUR_POST_WAS_LIKED=4
    YOUR_POST_WAS_REPOSTED=5
    YOUR_POST_WAS_REPLIED_TO=6
    YOU_WERE_MENTIONED_IN_POST=7
    YOUR_POST_WAS_MENTIONED_IN_POST=8

    POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED=101
    POST_YOU_WERE_MENTIONED_IN_WAS_LIKED=102
    POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED=103
    POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO=104

    POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED=201
    POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED=202
    POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED=203
    POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO=204
end

JSON.lower(type::NotificationType) = Int(type)

sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{NotificationType}) where {K, V} = "int8"
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{NotificationType}) where {K, V} = DBConversionFuncs(x->Int(x), x->NotificationType(x))
##
notification_args = Dict([NEW_USER_FOLLOWED_YOU=>((:follower, Nostr.PubKeyId),),
                          USER_UNFOLLOWED_YOU=>((:follower, Nostr.PubKeyId),),

                          YOUR_POST_WAS_ZAPPED=>((:your_post, Nostr.EventId), (:who_zapped_it, Nostr.PubKeyId), (:satszapped, Int)),
                          YOUR_POST_WAS_LIKED=>((:your_post, Nostr.EventId), (:who_liked_it, Nostr.PubKeyId)),
                          YOUR_POST_WAS_REPOSTED=>((:your_post, Nostr.EventId), (:who_reposted_it, Nostr.PubKeyId)),
                          YOUR_POST_WAS_REPLIED_TO=>((:your_post, Nostr.EventId), (:who_replied_to_it, Nostr.PubKeyId), (:reply, Nostr.EventId)),

                          YOU_WERE_MENTIONED_IN_POST=>((:you_were_mentioned_in, Nostr.EventId), (:you_were_mentioned_by, Nostr.PubKeyId)),
                          YOUR_POST_WAS_MENTIONED_IN_POST=>((:your_post, Nostr.EventId), (:your_post_were_mentioned_in, Nostr.EventId), (:your_post_was_mentioned_by, Nostr.PubKeyId)),

                          POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED=>((:post_you_were_mentioned_in, Nostr.EventId), (:who_zapped_it, Nostr.PubKeyId), (:satszapped, Int)),
                          POST_YOU_WERE_MENTIONED_IN_WAS_LIKED=>((:post_you_were_mentioned_in, Nostr.EventId), (:who_liked_it, Nostr.PubKeyId)),
                          POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED=>((:post_you_were_mentioned_in, Nostr.EventId), (:who_reposted_it, Nostr.PubKeyId)),
                          POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO=>((:post_you_were_mentioned_in, Nostr.EventId), (:who_replied_to_it, Nostr.PubKeyId), (:reply, Nostr.EventId)),

                          POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED=>((:post_your_post_was_mentioned_in, Nostr.EventId), (:your_post, Nostr.EventId), (:who_zapped_it, Nostr.PubKeyId), (:satszapped, Int)),
                          POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED=>((:post_your_post_was_mentioned_in, Nostr.EventId), (:your_post, Nostr.EventId), (:who_liked_it, Nostr.PubKeyId)),
                          POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED=>((:post_your_post_was_mentioned_in, Nostr.EventId), (:your_post, Nostr.EventId), (:who_reposed_it, Nostr.PubKeyId)),
                          POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO=>((:post_your_post_was_mentioned_in, Nostr.EventId), (:your_post, Nostr.EventId), (:who_replied_to_it, Nostr.PubKeyId), (:reply, Nostr.EventId))])
##
Base.@kwdef struct Notifications
    directory::String
    pqconnstr::Union{String,Symbol}

    dbargs = (; )

    pubkey_notifications_seen = PQDict{Nostr.PubKeyId, Int}("pubkey_notifications_seen", pqconnstr;
                                                            keycolumn="pubkey", valuecolumn="seen_until",
                                                            init_extra_indexes=["create index if not exists pubkey_notifications_seen_seen_until on pubkey_notifications_seen (seen_until desc)"])

    pubkey_notifications = ShardedSqliteSet(Nostr.PubKeyId, "$(directory)/db/notifications/pubkey_notifications"; dbargs...,
                                            init_queries=["create table if not exists kv (
                                                             pubkey blob not null,
                                                             created_at int not null,
                                                             type int not null,
                                                             arg1,
                                                             arg2,
                                                             arg3,
                                                             arg4
                                                           )",
                                                          "create index if not exists kv_pubkey on kv (pubkey asc)",
                                                          "create index if not exists kv_created_at on kv (created_at desc)",
                                                          "create index if not exists kv_type on kv (type desc)",
                                                          "create index if not exists kv_arg1 on kv (arg1 desc)",
                                                         ])
##
    pubkey_notification_cnts_init = "create table if not exists kv (
      pubkey blob primary key not null,
      $(join(["type$(i|>Int) int not null default 0" for i in instances(DB.NotificationType)], ','))
    )
    "
    pubkey_notification_cnts = DB.ShardedSqliteSet(Nostr.PubKeyId, "$(directory)/db/notifications/pubkey_notification_cnts"; dbargs...,
                                                   keycolumn="pubkey",
                                                   init_queries=[pubkey_notification_cnts_init,
                                                                 "create index if not exists kv_pubkey on kv (pubkey asc)",
                                                                 ])
##
end



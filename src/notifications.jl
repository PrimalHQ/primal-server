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

    YOUR_POST_WAS_HIGHLIGHTED=301
    YOUR_POST_WAS_BOOKMARKED=302

    NEW_DIRECT_MESSAGE=401

    LIVE_EVENT_HAPPENING=501
end

JSON.lower(type::NotificationType) = Int(type)

sqltype(::Type{ShardedSqliteDict{K, V}}, ::Type{NotificationType}) where {K, V} = "int8"
db_conversion_funcs(::Type{ShardedSqliteDict{K, V}}, ::Type{NotificationType}) where {K, V} = DBConversionFuncs(x->Int(x), x->NotificationType(x))

sqltype(::Type{PGDict{K, V}}, ::Type{NotificationType}) where {K, V} = "int8"
db_conversion_funcs(::Type{PGDict{K, V}}, ::Type{NotificationType}) where {K, V} = DBConversionFuncs(x->Int(x), x->NotificationType(x))

##
notification_args = Dict([NEW_USER_FOLLOWED_YOU=>((:follower, Nostr.PubKeyId),),
                          USER_UNFOLLOWED_YOU=>((:follower, Nostr.PubKeyId),),

                          YOUR_POST_WAS_ZAPPED=>((:your_post, Nostr.EventId), (:who_zapped_it, Nostr.PubKeyId), (:satszapped, Int), (:message, String)),
                          YOUR_POST_WAS_LIKED=>((:your_post, Nostr.EventId), (:who_liked_it, Nostr.PubKeyId), (:reaction, String)),
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
                          POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO=>((:post_your_post_was_mentioned_in, Nostr.EventId), (:your_post, Nostr.EventId), (:who_replied_to_it, Nostr.PubKeyId), (:reply, Nostr.EventId)),

                          YOUR_POST_WAS_HIGHLIGHTED=>((:your_post, Nostr.EventId), (:who_highlighted_it, Nostr.PubKeyId), (:highlight, Nostr.EventId)),
                          YOUR_POST_WAS_BOOKMARKED=>((:your_post, Nostr.EventId), (:who_bookmarked_it, Nostr.PubKeyId)),

                          NEW_DIRECT_MESSAGE=>((:event_id, Nostr.EventId), (:sender, Nostr.PubKeyId)),

                          LIVE_EVENT_HAPPENING=>((:live_event_id, Nostr.EventId), (:host, Nostr.PubKeyId)),
                         ])
##

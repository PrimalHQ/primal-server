use std::marker::PhantomData;
use tokio::time::{timeout, Duration};
use deadpool_postgres::{Pool, Client};
use serde_json::{Value, json};
use tokio_postgres::types::ToSql;

use crate::shared::{ReqError, ReqStatus, get_sys_time_in_secs};
use crate::shared::protocol::{Response, Registration};
use primal_cache::{EventAddr, PubKeyId};

const POOL_GET_TIMEOUT: u64 = 15;

pub struct ReqHandlers {
    _phantom: PhantomData<()>,
}

impl ReqHandlers {
    pub async fn handle_request(
        conn_id: i64,
        sub_id: &str,
        funcall: &str,
        kwargs: &Value,
        pool: &Pool,
        membership_pool: &Pool,
        srv_name: &Option<String>,
        primal_pubkey: &Option<Vec<u8>>,
        default_app_settings_filename: &str,
        app_releases_filename: &str,
    ) -> Result<(ReqStatus, Response), ReqError> {
        match funcall {
            "set_primal_protocol" => {
                Ok((ReqStatus::NotHandled, Response::empty()))
            }
            "thread_view" => {
                Self::thread_view(conn_id, sub_id, kwargs, pool, primal_pubkey).await
            }
            "scored" => {
                Self::scored(conn_id, sub_id, kwargs, pool, primal_pubkey).await
            }
            "get_default_app_settings" => {
                Self::get_default_app_settings(conn_id, sub_id, kwargs, default_app_settings_filename).await
            }
            "get_app_releases" => {
                Self::get_app_releases(conn_id, sub_id, app_releases_filename).await
            }
            "get_bookmarks" => {
                Self::get_bookmarks(conn_id, sub_id, kwargs, pool).await
            }
            "user_infos" => {
                Self::user_infos(conn_id, sub_id, kwargs, pool).await
            }
            "server_name" => {
                Self::server_name(conn_id, sub_id, srv_name).await
            }
            "get_notifications_seen" => {
                Self::get_notifications_seen(conn_id, sub_id, kwargs, membership_pool).await
            }
            "feed" => {
                Self::feed(conn_id, sub_id, kwargs, pool, primal_pubkey).await
            }
            "mega_feed_directive" => {
                Self::mega_feed_directive(conn_id, sub_id, kwargs, pool, primal_pubkey).await
            }
            "live_feed" => {
                Self::live_feed(conn_id, sub_id, kwargs, pool).await
            }
            "live_events_from_follows" => {
                Self::live_events_from_follows(conn_id, sub_id, kwargs, pool).await
            }
            _ => Ok((ReqStatus::NotHandled, Response::empty()))
        }
    }

    async fn pool_get(pool: &Pool) -> Result<Client, ReqError> {
        match timeout(Duration::from_secs(POOL_GET_TIMEOUT), pool.get()).await {
            Ok(Ok(client)) => Ok(client),
            Ok(Err(e)) => {
                eprintln!("ws-slave: pool.get() error: {}", e);
                Err(ReqError::from("Database pool error"))
            },
            Err(_) => {
                eprintln!("ws-slave: pool.get() timeout after {} seconds", POOL_GET_TIMEOUT);
                Err(ReqError::from("Database pool timeout"))
            }
        }
    }

    fn rows_to_vec(rows: &Vec<tokio_postgres::Row>) -> Vec<String> {
        let mut res = Vec::new();
        for row in rows {
            if let Ok(r) = row.try_get::<_, &str>(0) {
                res.push(r.to_string().clone());
            } else {
                eprintln!("ws-slave: failed to get row as string: {:?}", row);
            }
        }
        res
    }

    async fn thread_view(_conn_id: i64, _sub_id: &str, kwargs: &Value, pool: &Pool, primal_pubkey: &Option<Vec<u8>>) -> Result<(ReqStatus, Response), ReqError> {
        let event_id = hex::decode(kwargs["event_id"].as_str().ok_or("invalid event_id")?.to_string())?;
        let limit = kwargs["limit"].as_i64().unwrap_or(20);
        let since = kwargs["since"].as_i64().unwrap_or(0);
        let until = kwargs["until"].as_i64().unwrap_or(get_sys_time_in_secs().try_into().unwrap());
        let offset = kwargs["offset"].as_i64().unwrap_or(0);
        let user_pubkey = 
            if let Some(v) = kwargs["user_pubkey"].as_str() {
                hex::decode(v.to_string()).ok()
            } else { primal_pubkey.clone() };
        
        let apply_humaness_check = true;

        let res = Self::rows_to_vec(
            &Self::pool_get(&pool).await?.query(
                "select e::text from thread_view($1, $2, $3, $4, $5, $6, $7) r(e)", 
                &[&event_id, &limit, &since, &until, &offset, &user_pubkey, &apply_humaness_check]).await?);
        
        Ok((ReqStatus::Handled, Response::messages(res)))
    }

    async fn scored(_conn_id: i64, _sub_id: &str, kwargs: &Value, pool: &Pool, primal_pubkey: &Option<Vec<u8>>) -> Result<(ReqStatus, Response), ReqError> {
        let selector = kwargs["selector"].as_str().unwrap();

        let user_pubkey = 
            if let Some(v) = kwargs["user_pubkey"].as_str() {
                hex::decode(v.to_string()).ok()
            } else { primal_pubkey.clone() };

        let mut k = String::from("precalculated_analytics_");
        k.push_str(selector);

        let res = Self::rows_to_vec(
            &Self::pool_get(&pool).await?.query(
                "select f.e::text from cache c, content_moderation_filtering(c.value, 'content', $2) f(e) where c.key = $1",
                &[&k, &user_pubkey]).await?);

        Ok((ReqStatus::Handled, Response::messages(res)))
    }

    async fn get_default_app_settings(_conn_id: i64, _sub_id: &str, kwargs: &Value, default_app_settings_filename: &str) -> Result<(ReqStatus, Response), ReqError> {
        let client = kwargs["client"].as_str().ok_or("invalid client")?;

        const PRIMAL_SETTINGS: i64 = 10000103;

        let default_app_settings = std::fs::read_to_string(default_app_settings_filename).unwrap();

        let e = json!({
            "kind": PRIMAL_SETTINGS,
            "tags": [["d", client]],
            "content": default_app_settings,
        });
        
        Ok((ReqStatus::Handled, Response::messages(vec![e.to_string()])))
    }

    async fn get_bookmarks(_conn_id: i64, _sub_id: &str, kwargs: &Value, pool: &Pool) -> Result<(ReqStatus, Response), ReqError> {
        let pubkey = hex::decode(kwargs["pubkey"].as_str().ok_or("invalid pubkey")?.to_string())?;

        let res = Self::rows_to_vec(
            &Self::pool_get(&pool).await?.query(
                "select e::text from get_bookmarks($1) r(e)", 
                &[&pubkey]).await?);
        
        Ok((ReqStatus::Handled, Response::messages(res)))
    }

    async fn user_infos(_conn_id: i64, _sub_id: &str, kwargs: &Value, pool: &Pool) -> Result<(ReqStatus, Response), ReqError> {
        if let Value::Array(pubkeys) = &kwargs["pubkeys"] {
            let mut pks = Vec::new();
            for pk in pubkeys {
                if let Value::String(pk) = &pk {
                    if pk.len() != 64 {
                        return Ok((ReqStatus::Notice("invalid pubkey".to_string()), Response::empty()));
                    }
                    if let Ok(_) = hex::decode(pk) {
                        pks.push(pk);
                    } else {
                        return Ok((ReqStatus::Notice("invalid pubkey".to_string()), Response::empty()));
                    }
                }
            }
            let res = Self::rows_to_vec(
                &Self::pool_get(&pool).await?.query(
                    "select e::text from user_infos(array(select jsonb_array_elements_text($1::jsonb))) r(e)", 
                    &[&json!(pks)])
                .await?);

            return Ok((ReqStatus::Handled, Response::messages(res)))
        }

        Ok((ReqStatus::NotHandled, Response::empty()))
    }

    async fn server_name(_conn_id: i64, _sub_id: &str, srv_name: &Option<String>) -> Result<(ReqStatus, Response), ReqError> {
        let e = json!({"content": srv_name});
        Ok((ReqStatus::Handled, Response::messages(vec![e.to_string()])))
    }

    async fn get_app_releases(_conn_id: i64, _sub_id: &str, app_releases_filename: &str) -> Result<(ReqStatus, Response), ReqError> {
        const APP_RELEASES: i64 = 10000138;

        let app_releases = std::fs::read_to_string(app_releases_filename).unwrap();

        let e = json!({
            "kind": APP_RELEASES, 
            "content": app_releases,
        });
        
        Ok((ReqStatus::Handled, Response::messages(vec![e.to_string()])))
    }

    async fn get_notifications_seen(_conn_id: i64, _sub_id: &str, kwargs: &Value, membership_pool: &Pool) -> Result<(ReqStatus, Response), ReqError> {
        const NOTIFICATIONS_SEEN_UNTIL: i64 = 10000111;

        let pubkey: Vec<u8> = hex::decode(kwargs["pubkey"].as_str().ok_or("invalid pubkey")?.to_string())?;

        let e = {
            let client = &Self::pool_get(&membership_pool).await?;
            match client.query_one("select seen_until from pubkey_notifications_seen where pubkey = $1",
                                   &[&pubkey]).await {
                Ok(row) => {
                    let t: i64 = row.get(0);
                    json!({
                        "kind": NOTIFICATIONS_SEEN_UNTIL, 
                        "content": json!(t).to_string()})
                },
                Err(err) => {
                    match err.code() {
                        Some(ec) => return Err(ec.code().into()),
                        None => return Ok((ReqStatus::Notice("unknown user".to_string()), Response::empty())),
                    }
                }
            }
        };
        
        Ok((ReqStatus::Handled, Response::messages(vec![e.to_string()])))
    }

    async fn feed(_conn_id: i64, _sub_id: &str, kwargs: &Value, pool: &Pool, primal_pubkey: &Option<Vec<u8>>) -> Result<(ReqStatus, Response), ReqError> {
        let limit = kwargs["limit"].as_i64().unwrap_or(20);
        let since = kwargs["since"].as_i64().unwrap_or(0);
        let until = kwargs["until"].as_i64().unwrap_or(get_sys_time_in_secs().try_into().unwrap());
        let offset = kwargs["offset"].as_i64().unwrap_or(0);
        let pubkey: Vec<u8> = hex::decode(
            kwargs["pubkey"].as_str().expect("pubkey argument required")
            ).expect("pubkey should be in hex");
        let user_pubkey = 
            if let Some(v) = kwargs["user_pubkey"].as_str() {
                hex::decode(v.to_string()).ok()
            } else { primal_pubkey.clone() };
        let notes = kwargs["notes"].as_str().unwrap_or("follows");
        let include_replies = kwargs["include_replies"].as_bool().unwrap_or(false) as i64;

        if notes == "follows" {
            let r = Self::pool_get(&pool).await?.query("select 1 from pubkey_followers pf where pf.follower_pubkey = $1 limit 1", 
                                                      &[&pubkey]).await?.len();
            if r > 0 {
                let q = "select distinct e::text, coalesce(e->>'created_at', '0')::int8 as t from feed_user_follows($1, $2, $3, $4, $5, $6, $7, $8) f(e) where e is not null order by t desc";
                let params: &[&(dyn ToSql + Sync)] = &[&pubkey, &since, &until, &include_replies, &limit, &offset, &user_pubkey, &true];
                let res = Self::rows_to_vec(&Self::pool_get(&pool).await?.query(q, params).await?);
                return Ok((ReqStatus::Handled, Response::messages(res)));
            }
        } else if notes == "authored" {
            let q = "select distinct e::text, coalesce(e->>'created_at', '0')::int8 as t from feed_user_authored($1, $2, $3, $4, $5, $6, $7, $8) f(e) where e is not null order by t desc";
            let params: &[&(dyn ToSql + Sync)] = &[&pubkey, &since, &until, &include_replies, &limit, &offset, &user_pubkey, &false];
            let res = Self::rows_to_vec(&Self::pool_get(&pool).await?.query(q, params).await?);
            return Ok((ReqStatus::Handled, Response::messages(res)));
        } else if notes == "replies" {
            let q = "select distinct e::text, coalesce(e->>'created_at', '0')::int8 as t from feed_user_authored($1, $2, $3, $4, $5, $6, $7, $8) f(e) where e is not null order by t desc";
            let params: &[&(dyn ToSql + Sync)] = &[&pubkey, &since, &until, &1i64, &limit, &offset, &user_pubkey, &false];
            let res = Self::rows_to_vec(&Self::pool_get(&pool).await?.query(q, params).await?);
            return Ok((ReqStatus::Handled, Response::messages(res)));
        }

        Ok((ReqStatus::NotHandled, Response::empty()))
    }

    async fn long_form_content_feed(_conn_id: i64, _sub_id: &str, kwargs: &Value, pool: &Pool, primal_pubkey: &Option<Vec<u8>>) -> Result<(ReqStatus, Response), ReqError> {
        let limit = kwargs["limit"].as_i64().unwrap_or(20);
        let since = kwargs["since"].as_i64().unwrap_or(0);
        let until = kwargs["until"].as_i64().unwrap_or(get_sys_time_in_secs().try_into().unwrap());
        let offset = kwargs["offset"].as_i64().unwrap_or(0);

        let pubkey = kwargs["pubkey"].as_str().and_then(|v| hex::decode(v.to_string()).ok());
        let user_pubkey = 
            kwargs["user_pubkey"].as_str().and_then(|v| hex::decode(v.to_string()).ok())
            .or(primal_pubkey.clone());

        let notes = kwargs["notes"].as_str();
        let topic = kwargs["topic"].as_str();
        let curation = kwargs["curation"].as_str();
        let minwords = kwargs["minwords"].as_i64().unwrap_or(0);

        let apply_humaness_check = true;

        let res = Self::rows_to_vec(
            &Self::pool_get(&pool).await?.query(
                "select distinct e::text, e->>'created_at' from long_form_content_feed($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) f(e) where e is not null order by e->>'created_at' desc",
                &[
                &pubkey, &notes, &topic, &curation, &minwords, 
                &limit, &since, &until, &offset, 
                &user_pubkey, &apply_humaness_check,
                ]).await?);

        Ok((ReqStatus::Handled, Response::messages(res)))
    }

    async fn mega_feed_directive(conn_id: i64, sub_id: &str, kwargs: &Value, pool: &Pool, primal_pubkey: &Option<Vec<u8>>) -> Result<(ReqStatus, Response), ReqError> {
        let mut kwargs = kwargs.as_object().unwrap().clone();
        let spec = kwargs["spec"].as_str().unwrap().to_string();
        kwargs.remove("spec");

        match serde_json::from_str::<Value>(&spec) {
            Err(_) => {
                return Ok((ReqStatus::Notice("invalid spec format".to_string()), Response::empty()));
            },
            Ok(Value::Object(s)) => {
                let mut skwa = s.clone();
                skwa.remove("id");
                skwa.remove("kind");

                let sg = |k: &str| -> &str {
                    s.get(k).and_then(Value::as_str).unwrap_or("")
                };

                if sg("id") == "nostr-reads-feed" {
                    return Ok((ReqStatus::NotHandled, Response::empty()));

                } else if sg("kind") == "reads" || sg("id") == "reads-feed" {
                    let minwords = s.get("minwords").and_then(Value::as_i64).unwrap_or(100);

                    if sg("scope") == "follows" {
                        return Ok((ReqStatus::NotHandled, Response::empty()));

                    } else if sg("scope") == "zappedbyfollows" {
                        let mut kwa = kwargs.clone();
                        kwa.insert("minwords".to_string(), json!(minwords));
                        kwa.insert("pubkey".to_string(), kwa.get("user_pubkey").expect("user_pubkey argument required").clone());
                        kwa.insert("notes".to_string(), json!("zappedbyfollows"));

                        return Self::long_form_content_feed(conn_id, sub_id, &Value::Object(kwa.clone()), pool, primal_pubkey).await;

                    } else if sg("scope") == "myfollowsinteractions" {
                        return Ok((ReqStatus::NotHandled, Response::empty()));

                    } else if let Some(topic) = s.get("topic") {
                        let mut kwa = kwargs.clone();
                        kwa.insert("minwords".to_string(), json!(minwords));
                        kwa.insert("topic".to_string(), topic.clone());

                        return Self::long_form_content_feed(conn_id, sub_id, &Value::Object(kwa.clone()), pool, primal_pubkey).await;
                    } else if let (Some(pubkey), Some(curation)) = (s.get("pubkey"), s.get("curation")) {
                        let mut kwa = kwargs.clone();
                        kwa.insert("minwords".to_string(), json!(minwords));
                        kwa.insert("pubkey".to_string(), pubkey.clone());
                        kwa.insert("curation".to_string(), curation.clone());

                        return Self::long_form_content_feed(conn_id, sub_id, &Value::Object(kwa.clone()), pool, primal_pubkey).await;
                    } else {
                        let mut kwa = kwargs.clone();
                        kwa.insert("minwords".to_string(), json!(minwords));
                        kwa.append(&mut skwa);

                        return Self::long_form_content_feed(conn_id, sub_id, &Value::Object(kwa.clone()), pool, primal_pubkey).await;
                    }

                } else if sg("kind") == "notes" {
                    if sg("id") == "latest" {
                        let mut kwa = kwargs.clone();
                        kwa.insert("pubkey".to_string(), kwa.get("user_pubkey").expect("user_pubkey argument required").clone());
                        kwa.append(&mut skwa);

                        return Self::feed(conn_id, sub_id, &Value::Object(kwa.clone()), pool, primal_pubkey).await;

                    } else if sg("id") == "feed" {
                        let mut kwa = kwargs.clone();
                        kwa.append(&mut skwa);

                        return Self::feed(conn_id, sub_id, &Value::Object(kwa.clone()), pool, primal_pubkey).await;
                    }
                }
            },
            Ok(_) => {
                return Ok((ReqStatus::Notice("invalid spec format".to_string()), Response::empty()));
            },
        }

        eprintln!("ws-slave: mega_feed_directive not handled for sub_id: {}", sub_id);
        Ok((ReqStatus::NotHandled, Response::empty()))
    }

    async fn live_feed(conn_id: i64, sub_id: &str, kwargs: &Value, pool: &Pool) -> Result<(ReqStatus, Response), ReqError> {
        let kind = kwargs["kind"].as_i64().ok_or("kind argument required")?;
        let pubkey = kwargs["pubkey"].as_str().and_then(|v| hex::decode(v.to_string()).ok()).ok_or("pubkey argument required")?;
        let identifier = kwargs["identifier"].as_str().ok_or("identifier argument required")?;

        let user_pubkey = kwargs["user_pubkey"].as_str().and_then(|v| hex::decode(v.to_string()).ok()).ok_or("user_pubkey argument required")?;

        let content_moderation_mode = kwargs["content_moderation_mode"].as_str().unwrap_or("all").to_string();

        let res = Self::rows_to_vec(
            &Self::pool_get(&pool).await?.query(
                "select distinct e::text from live_feed_initial_response($1, $2, $3, $4, $5) f(e) where e is not null",
                &[&kind, &pubkey, &identifier, &user_pubkey, &content_moderation_mode]).await?);

        let res = res.iter().map(|s| crate::shared::utils::fixup_live_event_p_tags_str(s.clone())).collect::<_>();
        
        Ok((ReqStatus::Handled, 
                Response {
                    messages: res, 
                    registrations: vec![
                        Registration::LiveEvents {
                            conn_id,
                            sub_id: sub_id.to_string(),
                            eaddr: EventAddr::new(kind, PubKeyId(pubkey), identifier.to_string()),
                            key: (PubKeyId(user_pubkey), content_moderation_mode),
                        }
                    ],
                }))
    }

    async fn live_events_from_follows(_conn_id: i64, sub_id: &str, kwargs: &Value, pool: &Pool) -> Result<(ReqStatus, Response), ReqError> {
        let user_pubkey = kwargs["user_pubkey"].as_str().and_then(|v| hex::decode(v.to_string()).ok()).ok_or("user_pubkey argument required")?;

        let res = Self::rows_to_vec(
            &Self::pool_get(&pool).await?.query(
                r#"
                select get_event_jsonb(lep.event_id)::text
                from live_event_participants lep, pubkey_followers pf
                where pf.follower_pubkey = $1
                  and pf.pubkey = lep.participant_pubkey
                  and lep.kind = 30311 
                  and lep.created_at >= extract(epoch from now() - interval '1h')::int8
                  and not exists (select 1 from live_event_pubkey_filterlist lepf where lepf.user_pubkey = pf.follower_pubkey and lepf.blocked_pubkey = lep.participant_pubkey)
                "#,
                &[&user_pubkey]).await?);

        let res = res.iter().map(|s| crate::shared::utils::fixup_live_event_p_tags_str(s.clone())).collect::<_>();

        Ok((ReqStatus::Handled, 
                Response {
                    messages: res, 
                    registrations: vec![
                        Registration::LiveEventsFromFollows {
                            user_pubkey: PubKeyId(user_pubkey),
                            sub_id: sub_id.to_string(),
                        }
                    ],
                }))
    }
}

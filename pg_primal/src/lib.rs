use pgrx::prelude::*;

use nostr_sdk::prelude::*;

pgrx::pg_module_magic!();

#[pg_extern]
fn cdn_url(a_url: Option<String>, a_size: Option<String>, a_animated: Option<bool>) -> ::std::result::Result<Option<String>, Box<dyn std::error::Error + Send + Sync + 'static>>
{
    let mut url = String::from("https://primal.b-cdn.net/media-cache");
    url.push_str("?s=");
    match a_size.unwrap().chars().nth(0) {
        None => panic!("a_url is empty"),
        Some(c) => url.push(c)
    };
    url.push_str("&a=");
    url.push(if a_animated.unwrap() { '1' } else { '0' });
    url.push_str("&u=");
    url.push_str(&urlencoding::encode(&a_url.unwrap()).into_owned());
    Ok(Some(url))
}

#[pg_extern(immutable, parallel_safe)]
fn nostr_parse(a_str: Option<String>) -> ::std::result::Result<Option<Vec<u8>>, Box<dyn std::error::Error + Send + Sync + 'static>>
{
    let s = a_str.unwrap();
    if let Ok(pk) = PublicKey::parse(&s) {
        return Ok(Some(pk.to_bytes().into()));
    }
    if let Ok(eid) = EventId::parse(&s) {
        return Ok(Some(eid.to_bytes().into()));
    }
    Ok(None)
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn test_hello_pg_primal() {
        assert_eq!("Hello, pg_primal", crate::hello_pg_primal());
    }

}

/// This module is required by `cargo pgrx test` invocations.
/// It must be visible at the root of your extension crate.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // perform one-off initialization when the pg_test framework starts
    }

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // return any postgresql.conf settings that are required for your tests
        vec![]
    }
}

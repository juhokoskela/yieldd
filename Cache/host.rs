// Host adapter compiled into the pinned cache service. Only the relay can reach this socket.
use std::collections::BTreeMap;
use std::io::Read as _;

use axum::http::{HeaderMap, HeaderValue};
use serde::Deserialize;
use sha2::{Digest as _, Sha256};

use crate::error::{Failure, Result};
use crate::routes::AppState;
use crate::scope::{CacheScope, Unauthorized};

#[derive(Debug, Deserialize, Ord, PartialOrd, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct Member {
    #[serde(rename = "repositoryID")]
    repository_id: String,
    #[serde(rename = "ref")]
    reference: String,
}

#[derive(Debug, Default)]
pub(crate) struct Policy(BTreeMap<Member, String>);

impl Policy {
    pub(crate) fn load() -> Result<Self> {
        let Some(value) = std::env::var_os("YIELDD_CACHE_POLICY") else {
            return Ok(Self::default());
        };
        Self::parse(value.as_encoded_bytes())
    }

    fn parse(json: &[u8]) -> Result<Self> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Config {
            #[serde(default, rename = "trustedGroups")]
            groups: Vec<Vec<Member>>,
        }
        let config: Config = serde_json::from_slice(json)
            .map_err(|_| Failure::msg("invalid yieldd cache policy"))?;
        let mut policy = Self::default();
        for mut group in config.groups {
            if group.is_empty() {
                return Err(Failure::msg("empty trusted group"));
            }
            // Membership changes create a new namespace. A newly trusted repository cannot
            // inherit previously shared bytes, even if the operator reuses a group name.
            group.sort_unstable();
            let mut hash = Sha256::new();
            hash.update(b"yieldd/shared/v1\0");
            for member in &group {
                if member.repository_id.is_empty()
                    || member.repository_id.starts_with('0')
                    || !member.repository_id.bytes().all(|b| b.is_ascii_digit())
                    || !member.reference.starts_with("refs/heads/")
                    || member.reference.len() == "refs/heads/".len()
                    || member.reference.contains(char::is_control)
                {
                    return Err(Failure::msg("invalid trusted branch or repository ID"));
                }
                hash.update(member.repository_id.as_bytes());
                hash.update([0]);
                hash.update(member.reference.as_bytes());
                hash.update([0]);
            }
            let namespace = format!("{:x}", hash.finalize());
            for member in group {
                if policy.0.insert(member, namespace.clone()).is_some() {
                    return Err(Failure::msg("duplicate trusted cache membership"));
                }
            }
        }
        Ok(policy)
    }

    fn scope(&self, repo: &str, reference: &str) -> String {
        let member = Member {
            repository_id: repo.to_owned(),
            reference: reference.to_owned(),
        };
        self.0.get(&member).cloned().unwrap_or_else(|| {
            let mut hash = Sha256::new();
            hash.update(b"yieldd/private/v1\0");
            hash.update(repo.as_bytes());
            hash.update([0]);
            hash.update(reference.as_bytes());
            format!("{:x}", hash.finalize())
        })
    }

    pub(crate) fn apply(&self, grants: &mut CacheScope) {
        for grant in &mut grants.scopes {
            grant.scope = self.scope(&grants.repo_id, &grant.scope);
        }
    }
}

impl AppState {
    pub(crate) async fn archive_scope(
        &self,
        headers: &HeaderMap,
    ) -> Result<CacheScope, Unauthorized> {
        let mut grants = self.verifier.cache_scope(headers).await?;
        self.policy.apply(&mut grants);
        // The resolved scope already includes the repository or its trusted sharing group.
        grants.repo_id = "yieldd".to_owned();
        Ok(grants)
    }
}

// The relay records paths actually issued to its authenticated job. The private header
// is stripped there; this works with both protobuf and JSON action clients.
pub(crate) fn transfer<T>(body: T, url: &str) -> twirp::Result<twirp::Response<T>> {
    let mut response = twirp::Response::new(body);
    if !url.is_empty() {
        let url = url::Url::parse(url).map_err(|_| twirp::internal("invalid transfer URL"))?;
        response.headers_mut().insert(
            "x-yieldd-transfer",
            HeaderValue::from_str(url.path())
                .map_err(|_| twirp::internal("invalid transfer path"))?,
        );
    }
    Ok(response)
}

pub(crate) fn owner() -> Result<std::fs::File> {
    // Parent death revokes the helper even if an HTTP client never finishes. SQLite WAL
    // and the service's existing startup reconciliation recover interrupted operations.
    std::thread::Builder::new()
        .name("yieldd-owner".to_owned())
        .spawn(|| {
            drop(std::io::stdin().read(&mut [0]));
            std::process::exit(0);
        })?;
    let lock = std::fs::File::create("yieldd.lock")?;
    lock.try_lock()
        .map_err(|_| Failure::msg("another process owns the archive store"))?;
    Ok(lock)
}

#[cfg(test)]
mod tests {
    use super::Policy;

    #[test]
    fn sharing_is_exact_and_membership_changes_invalidate_the_namespace() {
        let make = |members: &str| {
            Policy::parse(format!(r#"{{"trustedGroups":[[{members}]]}}"#).as_bytes()).unwrap()
        };
        let a = r#"{"repositoryID":"123","ref":"refs/heads/main"}"#;
        let b = r#"{"repositoryID":"456","ref":"refs/heads/release"}"#;
        let both = make(&format!("{a},{b}"));
        let shared = both.scope("123", "refs/heads/main");
        assert_eq!(shared, both.scope("456", "refs/heads/release"));
        assert_eq!(
            shared,
            make(&format!("{b},{a}")).scope("123", "refs/heads/main")
        );
        assert_ne!(shared, make(a).scope("123", "refs/heads/main"));
        assert_ne!(shared, both.scope("456", "refs/heads/main"));
        assert_ne!(shared, both.scope("123", "refs/pull/42/merge"));
        assert_ne!(
            both.scope("123", "refs/pull/42/merge"),
            both.scope("456", "refs/pull/42/merge")
        );
    }

    #[test]
    fn invalid_policy_stops_startup() {
        for json in [
            r#"{"trusted_group":[]}"#,
            r#"{"trustedGroups":[[]]}"#,
            r#"{"trustedGroups":[[{"repositoryID":"repo","ref":"refs/heads/main"}]]}"#,
            r#"{"trustedGroups":[[{"repositoryID":"0123","ref":"refs/heads/main"}]]}"#,
            r#"{"trustedGroups":[[{"repositoryID":"1","ref":"refs/pull/1/merge"}]]}"#,
            r#"{"trustedGroups":[[{"repositoryID":"1","ref":"refs/heads/"}]]}"#,
            r#"{"trustedGroups":[[{"repositoryID":"1","ref":"refs/heads/main","all":true}]]}"#,
            r#"{"trustedGroups":[[{"repositoryID":"1","ref":"refs/heads/main"}],[{"repositoryID":"1","ref":"refs/heads/main"}]]}"#,
        ] {
            assert!(Policy::parse(json.as_bytes()).is_err(), "{json}");
        }
    }
}

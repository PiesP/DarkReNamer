#[path = "../src/icon_requests.rs"]
mod icon_requests;

use std::io;

use darknamer_app::icon_cache::{IconCacheKey, icon_cache_key};
use darknamer_core::LegacyText;
use icon_requests::{
    CompletionDisposition, IconRequests, MAX_PENDING_ICON_REQUESTS, RequestKey, SubmitDisposition,
};

fn class(name: &str) -> RequestKey<IconCacheKey> {
    RequestKey::Class(icon_cache_key(&LegacyText::from(name), false))
}

#[test]
fn bootstrap_inflight_and_undrained_results_share_the_64_unique_slot_limit()
-> Result<(), Box<dyn std::error::Error>> {
    let mut requests = IconRequests::<IconCacheKey, i32>::new(11);
    assert_eq!(requests.generation(), 0);
    assert_eq!(
        requests.submit(RequestKey::Bootstrap),
        SubmitDisposition::Queued
    );
    for index in 0..(MAX_PENDING_ICON_REQUESTS - 2) {
        assert_eq!(
            requests.submit(class(&format!("file.ext{index}"))),
            SubmitDisposition::Queued
        );
    }
    let bootstrap = requests
        .take_next()
        .ok_or_else(|| io::Error::other("bootstrap was not dispatched"))?;
    assert_eq!(bootstrap.key, RequestKey::Bootstrap);
    assert!(requests.take_next().is_none());
    assert_eq!(
        requests.complete(bootstrap.token, 0),
        CompletionDisposition::Published
    );
    let first_class = requests
        .take_next()
        .ok_or_else(|| io::Error::other("first class was not dispatched"))?;
    assert_eq!(
        requests.submit(class("another.EXT0")),
        SubmitDisposition::Coalesced
    );
    assert_eq!(
        requests.submit(RequestKey::Bootstrap),
        SubmitDisposition::Coalesced
    );
    assert_eq!(
        requests.submit(class("file.ext62")),
        SubmitDisposition::Queued
    );
    assert_eq!(requests.pending_count(), MAX_PENDING_ICON_REQUESTS);
    assert_eq!(requests.queued_count(), MAX_PENDING_ICON_REQUESTS - 2);
    for index in 63..128 {
        assert_eq!(
            requests.submit(class(&format!("file.ext{index}"))),
            SubmitDisposition::Saturated
        );
        assert_eq!(requests.pending_count(), MAX_PENDING_ICON_REQUESTS);
    }
    assert_eq!(requests.in_flight_count(), 1);
    assert_eq!(requests.completed_count(), 1);
    assert_eq!(first_class.key, class("file.ext0"));
    let completion = requests
        .pop_completion()
        .ok_or_else(|| io::Error::other("bootstrap completion was missing"))?;
    assert_eq!(completion.request.key, RequestKey::Bootstrap);
    assert_eq!(completion.result, 0);
    assert_eq!(requests.pending_count(), MAX_PENDING_ICON_REQUESTS - 1);
    assert_eq!(
        requests.submit(class("file.ext63")),
        SubmitDisposition::Queued
    );
    Ok(())
}

#[test]
fn canonical_case_keys_coalesce_and_opaque_results_keep_zero_and_no_image_distinct()
-> Result<(), Box<dyn std::error::Error>> {
    #[derive(Debug, Eq, PartialEq)]
    enum IconResult {
        Image(i32),
        NoImage,
    }

    let mut requests = IconRequests::<IconCacheKey, IconResult>::new(21);
    assert_eq!(requests.submit(class("one.TXT")), SubmitDisposition::Queued);
    assert_eq!(
        requests.submit(class("two.txt")),
        SubmitDisposition::Coalesced
    );
    let zero = requests
        .take_next()
        .ok_or_else(|| io::Error::other("zero-icon class was not dispatched"))?;
    assert_eq!(
        requests.submit(class("THREE.TxT")),
        SubmitDisposition::Coalesced
    );
    assert_eq!(
        requests.complete(zero.token, IconResult::Image(0)),
        CompletionDisposition::Published
    );
    assert_eq!(
        requests.submit(class("four.txt")),
        SubmitDisposition::Coalesced
    );
    assert_eq!(
        requests.submit(class("five.bad")),
        SubmitDisposition::Queued
    );
    let failure = requests
        .take_next()
        .ok_or_else(|| io::Error::other("failure class was not dispatched"))?;
    assert_eq!(
        requests.complete(failure.token, IconResult::NoImage),
        CompletionDisposition::Published
    );
    assert_eq!(requests.completed_count(), 2);
    assert_eq!(
        requests
            .pop_completion()
            .ok_or_else(|| io::Error::other("zero completion was missing"))?
            .result,
        IconResult::Image(0)
    );
    assert_eq!(
        requests
            .pop_completion()
            .ok_or_else(|| io::Error::other("failure completion was missing"))?
            .result,
        IconResult::NoImage
    );
    Ok(())
}

#[test]
fn generation_change_discards_queued_and_late_results_without_reusing_an_inflight_key()
-> Result<(), Box<dyn std::error::Error>> {
    let mut requests = IconRequests::<u32, i32>::new(31);
    assert_eq!(
        requests.submit(RequestKey::Class(1)),
        SubmitDisposition::Queued
    );
    assert_eq!(
        requests.submit(RequestKey::Class(2)),
        SubmitDisposition::Queued
    );
    let old = requests
        .take_next()
        .ok_or_else(|| io::Error::other("old request was not dispatched"))?;
    assert_eq!(old.token.session(), 31);
    assert_eq!(old.token.generation(), 0);
    assert!(requests.advance_generation());
    assert_eq!(requests.pending_count(), 1);
    assert_eq!(
        requests.submit(RequestKey::Class(1)),
        SubmitDisposition::DeferredStaleInFlight
    );
    assert_eq!(
        requests.submit(RequestKey::Class(3)),
        SubmitDisposition::Queued
    );
    assert_eq!(
        requests.complete(old.token, 9),
        CompletionDisposition::Discarded
    );
    assert_eq!(requests.completed_count(), 0);
    assert_eq!(
        requests.submit(RequestKey::Class(1)),
        SubmitDisposition::Queued
    );
    let current = requests
        .take_next()
        .ok_or_else(|| io::Error::other("current request was not dispatched"))?;
    assert_eq!(current.key, RequestKey::Class(3));
    assert_eq!(current.token.session(), 31);
    assert_eq!(current.token.generation(), 1);
    assert_ne!(current.token, old.token);
    assert_eq!(
        requests.complete(old.token, 10),
        CompletionDisposition::Unexpected
    );
    assert_eq!(requests.in_flight_count(), 1);
    assert_eq!(
        requests.complete(current.token, 11),
        CompletionDisposition::Published
    );
    Ok(())
}

#[test]
fn generation_change_invalidates_an_undrained_completion() -> Result<(), Box<dyn std::error::Error>>
{
    let mut requests = IconRequests::<u32, i32>::new(35);
    assert_eq!(
        requests.submit(RequestKey::Class(1)),
        SubmitDisposition::Queued
    );
    let old = requests
        .take_next()
        .ok_or_else(|| io::Error::other("old request was not dispatched"))?;
    assert_eq!(
        requests.complete(old.token, 4),
        CompletionDisposition::Published
    );
    assert_eq!(requests.pending_count(), 1);
    assert!(requests.advance_generation());
    assert_eq!(requests.pending_count(), 0);
    assert!(requests.pop_completion().is_none());
    assert_eq!(
        requests.submit(RequestKey::Class(1)),
        SubmitDisposition::Queued
    );
    Ok(())
}

#[test]
fn more_than_256_sequential_classes_can_complete_without_a_side_pending_map()
-> Result<(), Box<dyn std::error::Error>> {
    let mut requests = IconRequests::<u32, u32>::new(61);
    for key in 0..300 {
        assert_eq!(
            requests.submit(RequestKey::Class(key)),
            SubmitDisposition::Queued
        );
        assert_eq!(requests.pending_count(), 1);
        let request = requests
            .take_next()
            .ok_or_else(|| io::Error::other("sequential class was not dispatched"))?;
        assert_eq!(request.key, RequestKey::Class(key));
        assert_eq!(
            requests.complete(request.token, key),
            CompletionDisposition::Published
        );
        let completion = requests
            .pop_completion()
            .ok_or_else(|| io::Error::other("sequential completion was missing"))?;
        assert_eq!(completion.result, key);
        assert_eq!(requests.pending_count(), 0);
    }
    Ok(())
}

#[test]
fn copied_delivery_batch_keeps_all_64_slots_until_explicit_ack()
-> Result<(), Box<dyn std::error::Error>> {
    let mut requests = IconRequests::<u32, u32>::new(71);
    for key in 0..MAX_PENDING_ICON_REQUESTS as u32 {
        assert_eq!(
            requests.submit(RequestKey::Class(key)),
            SubmitDisposition::Queued
        );
    }
    for key in 0..MAX_PENDING_ICON_REQUESTS as u32 {
        let request = requests
            .take_next()
            .ok_or_else(|| io::Error::other("queued class was not dispatched"))?;
        assert_eq!(request.key, RequestKey::Class(key));
        assert_eq!(
            requests.complete(request.token, key),
            CompletionDisposition::Published
        );
    }
    let batch = requests.completed_snapshot();
    assert_eq!(batch.len(), MAX_PENDING_ICON_REQUESTS);
    assert_eq!(requests.pending_count(), MAX_PENDING_ICON_REQUESTS);
    assert_eq!(
        requests.submit(RequestKey::Class(100)),
        SubmitDisposition::Saturated
    );
    assert_eq!(requests.acknowledge_completions(32), 32);
    assert_eq!(requests.pending_count(), 32);
    assert_eq!(batch[0].request.key, RequestKey::Class(0));
    assert_eq!(batch[63].result, 63);
    assert_eq!(
        requests.submit(RequestKey::Class(100)),
        SubmitDisposition::Queued
    );
    assert_eq!(requests.acknowledge_completions(usize::MAX), 32);
    assert_eq!(requests.pending_count(), 1);
    Ok(())
}

#[test]
fn another_session_cannot_publish_a_matching_serial_and_generation()
-> Result<(), Box<dyn std::error::Error>> {
    let mut first = IconRequests::<u32, i32>::new(41);
    let mut second = IconRequests::<u32, i32>::new(42);
    assert_eq!(
        first.submit(RequestKey::Class(1)),
        SubmitDisposition::Queued
    );
    assert_eq!(
        second.submit(RequestKey::Class(1)),
        SubmitDisposition::Queued
    );
    let old = first
        .take_next()
        .ok_or_else(|| io::Error::other("first request was not dispatched"))?;
    let current = second
        .take_next()
        .ok_or_else(|| io::Error::other("second request was not dispatched"))?;
    assert_eq!(
        second.complete(old.token, 1),
        CompletionDisposition::Unexpected
    );
    assert_eq!(second.in_flight_count(), 1);
    assert_eq!(
        second.complete(current.token, 2),
        CompletionDisposition::Published
    );
    Ok(())
}

#[test]
fn retirement_discards_queued_and_published_work_but_tracks_the_real_inflight_call()
-> Result<(), Box<dyn std::error::Error>> {
    let mut requests = IconRequests::<u32, i32>::new(51);
    assert_eq!(
        requests.submit(RequestKey::Bootstrap),
        SubmitDisposition::Queued
    );
    let bootstrap = requests
        .take_next()
        .ok_or_else(|| io::Error::other("bootstrap was not dispatched"))?;
    assert_eq!(
        requests.complete(bootstrap.token, 0),
        CompletionDisposition::Published
    );
    assert_eq!(
        requests.submit(RequestKey::Class(1)),
        SubmitDisposition::Queued
    );
    let active = requests
        .take_next()
        .ok_or_else(|| io::Error::other("active request was not dispatched"))?;
    assert_eq!(
        requests.submit(RequestKey::Class(2)),
        SubmitDisposition::Queued
    );
    requests.retire();
    requests.retire();
    assert_eq!(requests.pending_count(), 1);
    assert_eq!(requests.in_flight_count(), 1);
    assert_eq!(requests.completed_count(), 0);
    assert!(requests.take_next().is_none());
    assert!(requests.pop_completion().is_none());
    assert_eq!(
        requests.submit(RequestKey::Class(3)),
        SubmitDisposition::Retired
    );
    assert_eq!(
        requests.complete(active.token, -1),
        CompletionDisposition::Discarded
    );
    assert_eq!(requests.pending_count(), 0);
    assert_eq!(
        requests.complete(active.token, -1),
        CompletionDisposition::Unexpected
    );
    assert!(requests.pop_completion().is_none());
    Ok(())
}

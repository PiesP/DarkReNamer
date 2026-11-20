use super::{Decoder, JournalCodecError, JournalCodecErrorKind};

#[kani::proof]
#[kani::unwind(2)]
fn decoder_take_preserves_extent_and_cursor() {
    let storage: [u8; 16] = kani::any();
    let length: usize = kani::any();
    let offset: usize = kani::any();
    let count: usize = kani::any();
    let frame: usize = kani::any();
    kani::assume(length <= storage.len());
    kani::assume(offset <= length);

    let bytes = &storage[..length];
    let mut decoder = Decoder::new(bytes, frame);
    // Reach the second call from the actual constructor and a legal prefix read.
    assert_eq!(decoder.take(offset).map(<[u8]>::len), Ok(offset));

    let remaining = length - offset;
    let result = decoder.take(count);
    if count <= remaining {
        let Ok(taken) = result else {
            unreachable!("a read within the remaining payload must succeed");
        };
        assert_eq!(taken.len(), count);
        assert_eq!(taken.as_ptr(), bytes[offset..].as_ptr());
        assert_eq!(decoder.offset - offset, count);
        kani::cover!(count > 0 && count == remaining, "exact-end success");
        kani::cover!(count == 0 && remaining == 0, "empty read at end");
    } else {
        let kind = if count <= usize::MAX - offset {
            JournalCodecErrorKind::InvalidPayload
        } else {
            JournalCodecErrorKind::IntegerOutOfRange
        };
        assert_eq!(result, Err(JournalCodecError { frame, kind }));
        assert_eq!(decoder.offset, offset);
        kani::cover!(count == 16, "truncated 16-byte field");
        kani::cover!(count > usize::MAX - offset, "cursor addition overflow");
    }
}

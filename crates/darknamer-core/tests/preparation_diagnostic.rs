//! Opt-in, descriptive timings for the source-bound transformation investigation.
//! Run the identical test source against both revisions; fixture construction,
//! list reset and destruction are deliberately outside the timed operation.

use std::hint::black_box;
use std::time::Instant;

use darknamer_core::{
    LegacyList, LegacyListItem, LegacyText, MAX_PROPOSED_NAME_UTF16_UNITS,
    MAX_TOTAL_PLANNED_PATH_UTF16_UNITS,
};

#[derive(Clone, Copy)]
enum Operation {
    Clear,
    Front,
    Last,
    Delimited,
    Digits,
    Extension,
    ReplaceAbsent,
    ReplaceEqual,
    NormalizedExtension,
    ShortImport,
}

impl Operation {
    fn name(self) -> &'static str {
        match self {
            Self::Clear => "clear",
            Self::Front => "front",
            Self::Last => "last",
            Self::Delimited => "delimited",
            Self::Digits => "digits",
            Self::Extension => "extension",
            Self::ReplaceAbsent => "replace_absent",
            Self::ReplaceEqual => "replace_equal",
            Self::NormalizedExtension => "normalized_extension",
            Self::ShortImport => "short_import",
        }
    }

    fn fallible_noop(self) -> bool {
        matches!(
            self,
            Self::ReplaceAbsent
                | Self::ReplaceEqual
                | Self::NormalizedExtension
                | Self::ShortImport
        )
    }

    fn run(self, list: &mut LegacyList, import_input: &LegacyText) -> Box<[usize]> {
        match self {
            Self::Clear => list.clear_name_changed(),
            Self::Front => list.delete_front_range_changed(2, 2).expect("valid range"),
            Self::Last => list.delete_last_changed(1),
            Self::Delimited => list
                .delete_first_delimited_changed(&LegacyText::from("["), &LegacyText::from("]"))
                .expect("valid delimiters"),
            Self::Digits => list.keep_ascii_digits_changed(),
            Self::Extension => list.delete_extension_changed(),
            Self::ReplaceAbsent => list
                .replace_complete_changed(&LegacyText::from("ZZZ"), &LegacyText::from("Q"))
                .expect("bounded replacement"),
            Self::ReplaceEqual => list
                .replace_complete_changed(&LegacyText::from("a"), &LegacyText::from("a"))
                .expect("bounded replacement"),
            Self::NormalizedExtension => list
                .replace_extension_changed(&LegacyText::from(".txt"))
                .expect("bounded extension"),
            Self::ShortImport => list
                .import_names_changed(import_input)
                .expect("bounded import"),
        }
    }
}

#[derive(Clone, Copy)]
enum Shape {
    None,
    Half,
    All,
}

impl Shape {
    fn name(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Half => "half",
            Self::All => "all",
        }
    }

    fn changed_input(self, index: usize) -> bool {
        match self {
            Self::None => false,
            Self::Half => index % 2 == 0,
            Self::All => true,
        }
    }
}

fn source_name(operation: Operation, index: usize, changed: bool, length: usize) -> String {
    let base = match operation {
        Operation::Clear | Operation::Front | Operation::Last if !changed => {
            format!(".x{index:05}")
        }
        Operation::Extension if !changed => format!("ab{index:05}"),
        Operation::Delimited if changed => format!("a[drop]b{index:05}.txt"),
        Operation::Digits if !changed => format!("123{index:05}.txt"),
        Operation::Digits if changed => format!("ab{index:05}.txt"),
        _ => format!("ab{index:05}.txt"),
    };
    let filler = if matches!(operation, Operation::Digits) && !changed {
        '7'
    } else if matches!(operation, Operation::Digits) {
        'X'
    } else {
        'q'
    };
    let padding = filler.to_string().repeat(length.saturating_sub(base.len()));
    // Extend the stem, except for the intentionally empty stem of a dotfile.
    if base.starts_with('.') {
        format!("{base}{padding}")
    } else if let Some(dot) = base.rfind('.') {
        format!("{}{}{}", &base[..dot], padding, &base[dot..])
    } else {
        format!("{base}{padding}")
    }
}

fn expected_name(operation: Operation, name: &str) -> String {
    if operation.fallible_noop() {
        return name.to_string();
    }
    let dot = name.rfind('.');
    let (stem, extension) = match dot {
        Some(dot) => (&name[..dot], &name[dot..]),
        None => (name, ""),
    };
    match operation {
        Operation::Clear => extension.to_string(),
        Operation::Front => format!(
            "{}{}",
            stem.chars()
                .enumerate()
                .filter_map(|(i, ch)| (i != 1).then_some(ch))
                .collect::<String>(),
            extension
        ),
        Operation::Last => format!("{}{}", &stem[..stem.len().saturating_sub(1)], extension),
        Operation::Delimited => {
            if let Some(start) = stem.find('[') {
                if let Some(end) = stem[start + 1..].find(']') {
                    return format!(
                        "{}{}{}",
                        &stem[..start],
                        &stem[start + end + 2..],
                        extension
                    );
                }
            }
            name.to_string()
        }
        Operation::Digits => format!(
            "{}{}",
            stem.chars()
                .filter(char::is_ascii_digit)
                .collect::<String>(),
            extension
        ),
        Operation::Extension => stem.to_string(),
        Operation::ReplaceAbsent
        | Operation::ReplaceEqual
        | Operation::NormalizedExtension
        | Operation::ShortImport => unreachable!(),
    }
}

fn prepare_list(operation: Operation, count: usize, length: usize, shape: Shape) -> LegacyList {
    let items = (0..count)
        .map(|index| {
            let name = source_name(operation, index, shape.changed_input(index), length);
            LegacyListItem::new(format!(r"C:\p\{name}"), false, 0, 0, 0)
        })
        .collect::<Vec<_>>();
    let mut list = LegacyList::new();
    assert_eq!(list.append_batch(items), Ok(count));
    assert!(list.planned_path_utf16_units() <= MAX_TOTAL_PLANNED_PATH_UTF16_UNITS);
    list
}

#[test]
#[ignore = "run explicitly for bounded preparation comparisons; not a CI speed gate"]
fn source_bound_preparation_diagnostic() {
    let maximum_rows = std::env::var("DARKRENAMER_PREP_DIAGNOSTIC_MAX_ROWS")
        .map(|value| {
            value
                .parse::<usize>()
                .expect("maximum rows must be numeric")
        })
        .unwrap_or(10_000);
    assert!([100, 1_000, 10_000].contains(&maximum_rows));
    const OPERATIONS: [Operation; 10] = [
        Operation::Clear,
        Operation::Front,
        Operation::Last,
        Operation::Delimited,
        Operation::Digits,
        Operation::Extension,
        Operation::ReplaceAbsent,
        Operation::ReplaceEqual,
        Operation::NormalizedExtension,
        Operation::ShortImport,
    ];
    for operation in OPERATIONS {
        for count in [100, 1_000, 10_000] {
            if count > maximum_rows {
                continue;
            }
            for (length_name, length) in [
                ("short", 16),
                (
                    "near_limit",
                    (MAX_TOTAL_PLANNED_PATH_UTF16_UNITS / count - 8)
                        .min(MAX_PROPOSED_NAME_UTF16_UNITS - 5),
                ),
            ] {
                for shape in [Shape::None, Shape::Half, Shape::All] {
                    if operation.fallible_noop() && !matches!(shape, Shape::None) {
                        continue;
                    }
                    for repetition in 0..3 {
                        // Build and reset outside the measured interval.
                        let mut list = prepare_list(operation, count, length, shape);
                        let before_names = list
                            .items()
                            .iter()
                            .map(|row| row.proposed_name().to_string_lossy())
                            .collect::<Vec<_>>();
                        let expected_names = before_names
                            .iter()
                            .map(|name| expected_name(operation, name))
                            .collect::<Vec<_>>();
                        let expected_changed = before_names
                            .iter()
                            .zip(&expected_names)
                            .enumerate()
                            .filter_map(|(index, (before, after))| {
                                (before != after).then_some(index)
                            })
                            .collect::<Vec<_>>();
                        let prior_names = list.proposed_name_utf16_units();
                        let prior_paths = list.planned_path_utf16_units();
                        let import_input =
                            LegacyText::from(format!("{}\r\n", before_names[0]).as_str());
                        let start = Instant::now();
                        let changed = black_box(operation.run(black_box(&mut list), &import_input));
                        let elapsed = start.elapsed();
                        assert_eq!(&*changed, expected_changed, "{}", operation.name());
                        for (row, expected) in list.items().iter().zip(&expected_names) {
                            assert_eq!(row.proposed_name().to_string_lossy(), *expected);
                        }
                        let name_units = list
                            .items()
                            .iter()
                            .map(|row| row.proposed_name().len())
                            .sum::<usize>();
                        assert_eq!(list.proposed_name_utf16_units(), name_units);
                        assert_eq!(
                            list.planned_path_utf16_units(),
                            prior_paths + name_units - prior_names
                        );
                        println!(
                            "prep_case,{},{},{},{},{},{},{},{}",
                            operation.name(),
                            count,
                            length_name,
                            shape.name(),
                            repetition,
                            elapsed.as_nanos(),
                            changed.len(),
                            name_units,
                        );
                        drop(list);
                    }
                }
            }
        }
    }
}

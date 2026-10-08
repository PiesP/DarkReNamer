//! Read-only, injective UTF-16 diagnostics. These strings never become path inputs.

use std::fmt::Write;

pub(crate) const COMPACT_UNITS: usize = 56;
// Four sampled paths, four leaves and labels remain below the native details limit.
pub(crate) const DETAIL_FIELD_UNITS: usize = 49_152;
pub(crate) const DISPLAY_NOTE: &str = "[U+XXXX]는 원본 UTF-16 코드 단위의 표시이며 입력할 이름이 아닙니다. 대괄호와 원본 …도 코드로 표시합니다.";

#[derive(Clone, Copy)]
enum Glyph {
    Character(char),
    Escaped(u16),
}

#[derive(Clone, Copy)]
struct Token {
    start: usize,
    end: usize,
    glyph: Glyph,
}

impl Token {
    fn cost(self) -> usize {
        match self.glyph {
            Glyph::Character(value) => value.len_utf16(),
            Glyph::Escaped(_) => 8,
        }
    }

    fn append(self, text: &mut String) {
        match self.glyph {
            Glyph::Character(value) => text.push(value),
            Glyph::Escaped(unit) => {
                // Writing to String is infallible apart from the application's OOM policy.
                let _ = write!(text, "[U+{unit:04X}]");
            }
        }
    }
}

fn escaped(unit: u16) -> bool {
    matches!(unit,
        0x0000..=0x001F | 0x007F..=0x009F | 0x005B | 0x005D | 0x061C |
        0x200E..=0x200F | 0x2026 | 0x2028..=0x202E | 0x2066..=0x2069 | 0xFFFD)
}

fn tokens(units: &[u16]) -> Vec<Token> {
    let mut result = Vec::with_capacity(units.len());
    let mut index = 0;
    while index < units.len() {
        let unit = units[index];
        let (glyph, width) = if (0xD800..=0xDBFF).contains(&unit)
            && units
                .get(index + 1)
                .is_some_and(|next| (0xDC00..=0xDFFF).contains(next))
        {
            let scalar =
                0x10000 + ((u32::from(unit) - 0xD800) << 10) + u32::from(units[index + 1]) - 0xDC00;
            (
                Glyph::Character(char::from_u32(scalar).unwrap_or(char::REPLACEMENT_CHARACTER)),
                2,
            )
        } else if escaped(unit) || (0xD800..=0xDFFF).contains(&unit) {
            (Glyph::Escaped(unit), 1)
        } else {
            (
                Glyph::Character(
                    char::from_u32(u32::from(unit)).unwrap_or(char::REPLACEMENT_CHARACTER),
                ),
                1,
            )
        };
        result.push(Token {
            start: index,
            end: index + width,
            glyph,
        });
        index += width;
    }
    result
}

fn cost(tokens: &[Token]) -> usize {
    tokens.iter().copied().map(Token::cost).sum()
}

fn append(text: &mut String, tokens: &[Token]) {
    for token in tokens {
        token.append(text);
    }
}

fn render(tokens: &[Token], raw_start: usize, raw_end: usize, budget: usize) -> String {
    if budget == 0 {
        return String::new();
    }
    if cost(tokens) <= budget {
        let mut text = String::new();
        append(&mut text, tokens);
        return text;
    }
    if budget < 3 {
        return "…".to_owned();
    }
    let start = tokens.partition_point(|token| token.end <= raw_start);
    let end = tokens
        .partition_point(|token| token.start < raw_end)
        .max(start);
    let focus_cost = cost(&tokens[start..end]);
    let mut text = String::new();
    if focus_cost.saturating_add(2) <= budget {
        let mut left = start;
        let mut right = end;
        let mut remaining = budget - focus_cost - 2;
        let left_budget = remaining / 2;
        let mut used = 0;
        while left > 0 && used + tokens[left - 1].cost() <= left_budget {
            left -= 1;
            used += tokens[left].cost();
        }
        remaining -= used;
        while right < tokens.len() && tokens[right].cost() <= remaining {
            remaining -= tokens[right].cost();
            right += 1;
        }
        while left > 0 && tokens[left - 1].cost() <= remaining {
            left -= 1;
            remaining -= tokens[left].cost();
        }
        if left != 0 {
            text.push('…');
        }
        append(&mut text, &tokens[left..right]);
        if right != tokens.len() {
            text.push('…');
        }
    } else {
        let outer = usize::from(start != 0) + usize::from(end != tokens.len());
        let available = budget.saturating_sub(outer + 1);
        let mut head = start;
        let mut used = 0;
        while head < end && used + tokens[head].cost() <= available / 2 {
            used += tokens[head].cost();
            head += 1;
        }
        let mut tail = end;
        while tail > head && used + tokens[tail - 1].cost() <= available {
            tail -= 1;
            used += tokens[tail].cost();
        }
        if start != 0 {
            text.push('…');
        }
        append(&mut text, &tokens[start..head]);
        text.push('…');
        append(&mut text, &tokens[tail..end]);
        if end != tokens.len() {
            text.push('…');
        }
    }
    text
}

pub(crate) struct DisplayPair {
    pub(crate) before: String,
    pub(crate) after: String,
    pub(crate) elided: bool,
    pub(crate) hidden: bool,
}

pub(crate) fn pair(before: &[u16], after: &[u16], budget: usize) -> DisplayPair {
    let prefix = before.iter().zip(after).take_while(|(a, b)| a == b).count();
    let maximum_suffix = (before.len() - prefix).min(after.len() - prefix);
    let suffix = before
        .iter()
        .rev()
        .zip(after.iter().rev())
        .take(maximum_suffix)
        .take_while(|(a, b)| a == b)
        .count();
    let left = tokens(before);
    let right = tokens(after);
    let elided = cost(&left) > budget || cost(&right) > budget;
    let shown_before = render(&left, prefix, before.len() - suffix, budget);
    let shown_after = render(&right, prefix, after.len() - suffix, budget);
    let hidden = before != after && shown_before == shown_after;
    DisplayPair {
        before: shown_before,
        after: shown_after,
        elided,
        hidden,
    }
}

pub(crate) fn tail(units: &[u16], budget: usize) -> String {
    render(&tokens(units), units.len(), units.len(), budget)
}

pub(crate) fn difference_evidence(before: &[u16], after: &[u16]) -> String {
    let index = before.iter().zip(after).take_while(|(a, b)| a == b).count();
    let value =
        |unit: Option<&u16>| unit.map_or_else(|| "끝".to_owned(), |unit| format!("U+{unit:04X}"));
    format!(
        "원본 UTF-16 길이: {} → {} · 첫 차이: {}번째 코드 단위 {} → {}",
        before.len(),
        after.len(),
        index + 1,
        value(before.get(index)),
        value(after.get(index))
    )
}

/// Native infotips can be smaller than a field. Never cut an escape or scalar.
#[cfg(any(windows, test))]
pub(crate) fn clip_diagnostic(text: &str, budget: usize) -> String {
    if text.encode_utf16().count() <= budget {
        return text.to_owned();
    }
    if budget == 0 {
        return String::new();
    }
    let mut rest = text;
    let mut used = 0;
    let mut result = String::new();
    while !rest.is_empty() {
        let width = if rest.starts_with("[U+")
            && rest.as_bytes().get(7) == Some(&b']')
            && rest.as_bytes()[..8].is_ascii()
        {
            8
        } else {
            rest.chars().next().map_or(0, char::len_utf8)
        };
        let token = &rest[..width];
        let units = token.encode_utf16().count();
        if used + units > budget - 1 {
            break;
        }
        result.push_str(token);
        used += units;
        rest = &rest[width..];
    }
    result.push('…');
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_units_and_escape_looking_literals_are_distinct() {
        let cases = [
            vec![0xD800],
            vec![0xD801],
            vec![0xDC00],
            vec![0xFFFD],
            "[U+D800]".encode_utf16().collect(),
            r"\uD800".encode_utf16().collect(),
        ];
        let displays: Vec<_> = cases.iter().map(|units| tail(units, 256)).collect();
        assert_eq!(
            &displays[..4],
            ["[U+D800]", "[U+D801]", "[U+DC00]", "[U+FFFD]"]
        );
        for (index, value) in displays.iter().enumerate() {
            assert!(!displays[index + 1..].contains(value));
        }
        assert_eq!(displays[4], "[U+005B]U+D800[U+005D]");
    }

    #[test]
    fn ordinary_scripts_and_valid_pairs_remain_readable() {
        let raw = "한국어-日本語-𠮷-😀-العربية-עברית-\u{200D}";
        assert_eq!(tail(&raw.encode_utf16().collect::<Vec<_>>(), 256), raw);
        for unit in [
            0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068,
            0x2069, 0x2028, 0x2029, 0x2026, 0, 0x85,
        ] {
            assert_eq!(tail(&[unit], 256), format!("[U+{unit:04X}]"));
        }
    }

    #[test]
    fn raw_difference_survives_lossy_collision_and_token_elision() {
        let mut before = vec![0xD800; 200];
        let mut after = before.clone();
        after[100] = 0xD801;
        let shown = pair(&before, &after, COMPACT_UNITS);
        assert!(shown.before.contains("[U+D800]"));
        assert!(shown.after.contains("[U+D801]"));
        assert_ne!(shown.before, shown.after);
        assert!(shown.before.encode_utf16().count() <= COMPACT_UNITS);
        before.push(0xD800);
        let shown = pair(&before, &vec![0xD800; 200], COMPACT_UNITS);
        assert!(shown.hidden);
        assert!(difference_evidence(&before, &vec![0xD800; 200]).contains("201 → 200"));
    }

    #[test]
    fn expanded_paths_and_native_clips_have_finite_token_bounds() {
        let before = vec![0xD800; 32_767];
        let mut after = before.clone();
        after[16_000] = 0xDC00;
        let shown = pair(&before, &after, DETAIL_FIELD_UNITS);
        assert!(shown.elided);
        assert_ne!(shown.before, shown.after);
        for value in [&shown.before, &shown.after] {
            assert!(value.encode_utf16().count() <= DETAIL_FIELD_UNITS);
            for budget in 0..32 {
                let clipped = clip_diagnostic(value, budget);
                assert!(clipped.encode_utf16().count() <= budget);
                assert!(!clipped.ends_with("[U+"));
                assert_eq!(clipped.matches('[').count(), clipped.matches(']').count());
            }
        }
        assert_eq!(clip_diagnostic("𠮷[U+D800]尾", 4), "𠮷…");
    }
}

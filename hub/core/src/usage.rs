//! Data use per day, worked out from the hourly running totals.

use std::collections::HashMap;

use crate::store::UsagePoint;

/// Data per day for the last [days] days (oldest first) and a label for each.
pub fn daily_usage(points: &[UsagePoint], days: i64, now: i64) -> (Vec<f64>, Vec<String>) {
    let today_start = now - now.rem_euclid(86_400);
    let mut per_user: HashMap<&str, Vec<(i64, f64)>> = HashMap::new();
    for p in points {
        per_user.entry(p.user_id.as_str()).or_default().push((p.at, p.total_bytes));
    }
    let mut values = Vec::new();
    let mut labels = Vec::new();
    for i in (0..days).rev() {
        let start = today_start - i * 86_400;
        let end = start + 86_400;
        let mut total = 0.0;
        for series in per_user.values() {
            let in_day = || series.iter().filter(|(at, _)| *at >= start && *at < end).map(|(_, b)| *b);
            let before = series.iter().filter(|(at, _)| *at < start).map(|(_, b)| *b).fold(f64::NAN, f64::max);
            let within = in_day().fold(f64::NAN, f64::max);
            if within.is_nan() {
                continue;
            }
            let base = if before.is_nan() { in_day().fold(f64::INFINITY, f64::min) } else { before };
            total += (within - base).max(0.0);
        }
        values.push(total);
        labels.push(format!("{i} days ago"));
    }
    (values, labels)
}

/// How much one user's running total grew since [since]: [live] (the total now) less their last hourly snapshot
/// before [since]. `None` when the history doesn't reach back that far. A total lower than that snapshot means the
/// counter started over, so all of [live] counts.
///
/// Telegram-Stremio's own `daily` and `monthly` counters can keep an old figure while a token is idle, so the
/// Overview works it out from the Hub's hourly copies instead.
pub fn used_since(points: &[UsagePoint], user_id: &str, live: f64, since: i64) -> Option<f64> {
    let base = points.iter().filter(|p| p.user_id == user_id && p.at < since).max_by_key(|p| p.at)?.total_bytes;
    Some(if live >= base { live - base } else { live })
}

/// The start (UTC) of the day holding [now].
pub fn day_start(now: i64) -> i64 {
    now - now.rem_euclid(86_400)
}

/// The start (UTC) of the month holding [now].
pub fn month_start(now: i64) -> i64 {
    // Howard Hinnant's civil-from-days, then back to the 1st.
    let days = now.div_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day_of_month = doy - (153 * mp + 2) / 5; // 0-based
    (days - day_of_month) * 86_400
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn used_since_counts_from_the_last_snapshot_before() {
        let points = vec![p("a", 100, 1_000.0), p("a", 200, 1_500.0), p("a", 300, 1_800.0), p("b", 250, 40.0)];
        // A quiet day: nothing since the last copy before it.
        assert_eq!(used_since(&points, "a", 1_800.0, 400), Some(0.0));
        assert_eq!(used_since(&points, "a", 2_000.0, 250), Some(500.0));
        // History starts within the period: not enough to tell.
        assert_eq!(used_since(&points, "b", 90.0, 0), None);
        // The counter started over.
        assert_eq!(used_since(&points, "a", 300.0, 400), Some(300.0));
        assert_eq!(used_since(&points, "c", 5.0, 0), None);
    }

    #[test]
    fn month_and_day_starts() {
        // 2026-11-24 16:25:00 UTC → 2026-11-01 and 2026-11-24.
        assert_eq!(month_start(1_795_537_500), 1_793_491_200);
        assert_eq!(day_start(1_795_537_500), 1_795_478_400);
        // 2024-02-29 12:00 → 2024-02-01; 1970-01-01 → itself.
        assert_eq!(month_start(1_709_208_000), 1_706_745_600);
        assert_eq!(month_start(0), 0);
    }

    fn p(user: &str, at: i64, bytes: f64) -> UsagePoint {
        UsagePoint { user_id: user.into(), at, total_bytes: bytes }
    }

    #[test]
    fn daily_usage_takes_differences_of_running_totals() {
        let day = 86_400;
        let now = 10 * day + 500;
        let points = vec![
            p("a", 8 * day + 10, 100.0),
            p("a", 9 * day + 10, 150.0),
            p("a", 10 * day + 10, 400.0),
            p("b", 10 * day + 20, 50.0),
            p("b", 10 * day + 300, 80.0),
        ];
        let (values, _) = daily_usage(&points, 3, now);
        // day 8: first sight of a, no baseline → 0; day 9: 150-100; day 10: a 400-150 + b 80-50.
        assert_eq!(values, vec![0.0, 50.0, 280.0]);
    }
}

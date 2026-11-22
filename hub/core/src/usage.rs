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

#[cfg(test)]
mod tests {
    use super::*;

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

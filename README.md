# Exporter-timespan

```yaml
# config.yaml
metrics:
  - name: gitlab_total_commits
    aggregation: max  # or avg
    time_window:
      start: "09:00"
      end: "12:00"
    start_date: "2024-10-10"
  - name: another_metric
    aggregation: avg
    time_window:
      start: "10:00"
      end: "14:00"
    start_date: "2024-10-01"
```
# Output CSV format

One row per rally. Header is written once when the file is created.

```
rally_number,start_time,end_time,ending_reason,sport,shots_count
1,8.800,11.500,winner,badminton,9
2,24.389,46.589,unforced_error,badminton,21
3,49.183,54.683,let,badminton,
```

| Column | Type | Notes |
|---|---|---|
| `rally_number` | int | 1-based, monotonic; continues across re-opening the same CSV |
| `start_time` | float | rally start, **decimal seconds** from the video start |
| `end_time` | float | rally end, decimal seconds (always `> start_time`) |
| `ending_reason` | enum | `unknown` (default) / `winner` / `forced_error` / `unforced_error` / `service_fault` / `let` / `other` — see the decision guide in [ENDING_REASONS.md](ENDING_REASONS.md) |
| `sport` | enum | `badminton` / `tennis` / `table_tennis` / `pickleball` / `padel` |
| `shots_count` | int | **optional** — number of shots/strokes in the rally. **Blank** when not entered (as in row 3 above); added in v1.6. Older CSVs without this column still load. |

Notes:
- **Decimal seconds**, not `mm:ss` — downstream loaders parse floats.
- Rows are appended live; **Undo last** truncates the last row (one level).
- Consumers should read by **column name** (the header is stable but column *order* may evolve; extra
  columns may be added later). Most CSV `DictReader`-style loaders already tolerate extra columns.

## Ingesting the labels

This CSV is intentionally compatible with common rally-segmentation tooling that reads
`rally_number,start_time,end_time` by header name and drops rows where `end <= start`:

```bash
# Generic: any tool that takes a labels CSV of start/end seconds.

# Example — score a detector against these labels, or slice clips by them
# (badminton-highlight-indexer loaders read --labels <this.csv> directly):
python -m backend.eval.calibrate_wasb --trajectory traj.csv --labels match.rallies.csv --fps 59.94 --frame-width 1920
python -m backend.tools.rally_slicer --video match.mp4 --labels match.rallies.csv --rallies all

# Example — register as curated golden data in sports-data-collector:
python -m src.cli.curate import-local --sport badminton --video-path match.mp4 --annotations-path match.rallies.csv
```

The `sport` column is self-documenting; tools that take a `--sport` flag can ignore it.

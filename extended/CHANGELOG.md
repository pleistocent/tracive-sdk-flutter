## 0.3.0

The version moves with `tracive_sdk` 0.3.0, which adds QRIS.

- Tracive's form shows a QRIS identifier as `QRIS · <NMID>`.
- A QRIS is reported by its NMID (`TraciveQuery.qris` or `TraciveQuery.qrisNmid`), up to three per
  report, never by its PAN, and only for an organisation whose agreement covers QRIS.

## 0.2.2

First release.

- `TraciveReports`: `requirements`, `prepare`, `submit`, `cancelSubmit`, `status`, `openInTracive`.
- `TraciveReportForm` and `TraciveReportStatus` present Tracive's native screens.
- `TraciveReports(client:)` uses the grant of a `TraciveClient` and its single-flight refresh.
  `TraciveReports.withTokens` is for a partner that keeps tokens on its own backend.

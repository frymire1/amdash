// beforeTimestampMs is the previous page's oldest entry's timestamp — omit
// it to get the first (most recent) page. See listAuditLog (admin.ts).
export interface ListAuditLogRequest {
  beforeTimestampMs?: number;
}

# AWS Billing & Cost Data APIs – Research Summary

**Date:** June 2026  
**Purpose:** Evaluate AWS APIs for per-job cost tracking of Spot Instance render jobs

---

## 1. API-by-API Breakdown

### A. AWS Cost Explorer API (`ce:GetCostAndUsage`)

- **What it provides:** Aggregated actual cost and usage data, drawn from the same backend as the Billing Dashboard. Returns blended/unblended costs, amortized costs, and net amortized costs.
- **Granularity:** `DAILY` or `MONTHLY`. No hourly option.
- **Grouping/dimensions:** Can group by `SERVICE`, `USAGE_TYPE`, `LINKED_ACCOUNT`, `INSTANCE_TYPE`, `PURCHASE_TYPE` (On-Demand/Spot/RI), `REGION`, `AZ`, and many others. Can also group by user-defined **cost allocation tags**.
- **Resource-level:** Can enable **Cost Explorer Resource-Level Data** (opt-in via Billing console) which allows grouping by `RESOURCE_ID`. This gives per-instance-level cost breakdown — **including individual EC2 instance IDs and Spot Fleet request IDs** — but only at **daily** granularity.
- **Latency:** ~24-48 hours. Data for a given day typically appears by the end of the next day. AWS documentation states "up to 24 hours".
- **Spot Instances:** Yes — `PURCHASE_TYPE=Spot` filter works. With resource-level enabled, you see individual spot instance costs.
- **Limitations:**
  - Daily minimum granularity (no hourly/per-job)
  - Resource-level must be explicitly enabled; incurs a small additional cost
  - Rate-limited (1 TPS for most operations)
  - Data is aggregated; you cannot see per-hour spot price fluctuations per instance

### B. AWS Cost and Usage Report (CUR / CUR 2.0) — via S3

- **What it provides:** The most detailed billing data AWS offers. A CSV/Parquet report delivered to an S3 bucket you own. Contains **every line item** of usage with full metadata.
- **Granularity:** `HOURLY` or `DAILY`. Hourly is available and is the recommended setting.
- **Columns include:** `line_item_usage_start_date`, `line_item_usage_end_date`, `line_item_resource_id` (instance ID), `line_item_usage_type`, `pricing_term` (On-Demand/Spot), `line_item_unblended_cost`, `product_instance_type`, `reservation_*` fields, and many more. CUR 2.0 adds columns for savings plans, amortized costs, etc.
- **Resource-level:** **Yes, natively.** Every row has a `resource_id` column that contains the EC2 instance ID (e.g., `i-0abc123`). Spot Fleet requests appear as the resource ID on fleet-level line items, and individual instances within the fleet also appear.
- **Latency:** 8-24 hours typically. Reports are generated on a schedule (at least once daily; can be configured for more frequent delivery with CUR 2.0 which supports "near real-time" updates every few hours, though not truly real-time).
- **Spot Instances:** **Yes, first-class.** Spot usage has its own `line_item_usage_type` (e.g., `USE-SPOT:BoxUsage:c5.4xlarge`). Spot Instance Interruption Feedback is available. Spot pricing is captured per-hour.
- **Format:** GZIP CSV, or Parquet (recommended for Athena/Redshift querying).
- **Limitations:**
  - Not a real-time API — you poll S3 for new report files
  - Requires S3 bucket + Athena (or similar) to query efficiently
  - Hourly granularity still doesn't give per-second or per-minute
  - Spot Instances are billed per-second (1-minute minimum) but CUR reports per-hour aggregation
  - Report files can be large for heavy accounts

### C. AWS Budgets API (`budgets:*`)

- **What it provides:** Threshold-based budget monitoring. Can alert when actual or forecasted costs exceed a budget.
- **Granularity:** `DAILY`, `MONTHLY`, `QUARTERLY`, `ANNUALLY`.
- **Resource-level:** Can scope budgets by tags, but budgets themselves are aggregate constructs. Not useful for per-instance cost retrieval.
- **Latency:** Depends on underlying Cost Explorer data — ~24 hours.
- **Spot Instances:** Can filter by tag or linked account, but no spot-specific detail.
- **Verdict:** **Not suitable** for per-job cost tracking. This is an alerting mechanism, not a cost data retrieval API.

### D. CloudWatch Billing Metrics

- **What it provides:** A single metric — `EstimatedCharges` — in the `AWS/Billing` namespace. Shows estimated total charges for the account.
- **Granularity:** Updated every ~6 hours. Metric resolution is 1 data point per ~6 hours.
- **Resource-level:** **No.** Account-level only. Can filter by `Service` dimension (e.g., `AmazonEC2`) but not by instance, region, or purchase type.
- **Latency:** ~6 hours between updates.
- **Spot Instances:** No spot-specific visibility.
- **Verdict:** **Not suitable** for per-job cost tracking. Only useful for high-level account alerts.

### E. AWS Price List API (`pricing:*` / `GetProducts`)

- **What it provides:** **Catalog prices**, not actual billing data. Returns the public/contract price for any service/instance type/region.
- **Granularity:** N/A — this is a price catalog, not a usage/cost report.
- **Resource-level:** Prices are per instance-type, per region, per OS, per tenancy, per purchase option (including Spot). But it tells you the *listed price*, not what you *actually paid*.
- **Spot Instances:** The Price List API includes Spot pricing for some instance types, but Spot prices fluctuate in real-time based on supply/demand. The `DescribeSpotPriceHistory` EC2 API is more appropriate for current spot prices.
- **Verdict:** **Not suitable** for actual cost tracking. Can be used to *estimate* costs but not to retrieve actual billed amounts.

---

## 2. Spot-Instance-Specific APIs

Two additional APIs are relevant for Spot cost tracking:

### F. EC2 `DescribeSpotPriceHistory`
- Returns the spot price history for a given instance type / AZ.
- Granularity: Per price change event (can be multiple times per hour).
- Use case: Estimate what a job *should* cost based on spot prices at runtime.
- Limitation: Does not show your actual bill — just the market price.

### G. EC2 `DescribeInstanceStatus` / `DescribeInstances`
- Shows running instance metadata including launch time, instance type, and `InstanceLifecycle=spot`.
- Use case: Correlate instance runtime with cost data from CUR.
- Combined with `DescribeSpotPriceHistory`, you can compute estimated costs per-job in near-real-time.

---

## 3. Summary Comparison Table

| API | Actual Cost? | Granularity | Resource-Level | Spot Support | Latency | Best For |
|-----|-------------|-------------|----------------|--------------|---------|----------|
| **Cost Explorer** (`ce:GetCostAndUsage`) | YES | Daily / Monthly | Yes (opt-in) | Yes (filter by purchase type) | ~24-48h | Account/service-level analysis, trend reports |
| **CUR 2.0** (S3 + Athena) | YES | **Hourly** | **Yes (native)** | **Yes (dedicated line items)** | ~8-24h | **Per-instance, per-hour cost tracking** |
| **Budgets** | YES (aggregated) | Daily+ | Tag-scoped only | No | ~24h | Spend alerts, not cost retrieval |
| **CloudWatch Billing** | Estimated only | ~6-hourly | No | No | ~6h | High-level account alerts |
| **Price List API** | No (catalog only) | N/A | Per instance-type | Partial | Real-time catalog | Price estimation, not billing |
| **DescribeSpotPriceHistory** | No (market price) | Per price change | Per instance-type/AZ | Yes | Real-time | Spot price estimation |
| **DescribeInstances** | No (metadata) | Real-time | Per instance | Yes (lifecycle tag) | Real-time | Correlate runtime → cost |

---

## 4. Recommendation for Per-Job Cost Tracking of Spot Render Jobs

### Primary approach: CUR 2.0 + Athena

**This is the gold standard for actual per-instance Spot cost data.**

1. **Enable CUR 2.0** with `HOURLY` granularity, Parquet format, delivered to S3.
2. **Enable resource-level data** (included by default in CUR 2.0).
3. **Query with Athena** to get per-instance, per-hour costs:
   ```sql
   SELECT
     line_item_resource_id,
     line_item_usage_start_date,
     line_item_usage_end_date,
     line_item_unblended_cost,
     product_instance_type,
     line_item_usage_type
   FROM cur_table
   WHERE line_item_product_code = 'AmazonEC2'
     AND line_item_usage_type LIKE '%SPOT%'
     AND line_item_usage_start_date >= '2026-06-01'
   ORDER BY line_item_usage_start_date
   ```

4. **Tag instances with job IDs** (`job-id=render_shot_042`) via EC2 tags, which propagate to CUR as cost allocation tags (after enabling tag keys in Billing). Then you can GROUP BY the job tag to get per-job totals.

### Near-real-time approach: Compute from runtime + spot price

Since CUR has 8-24h latency, for immediate per-job cost feedback:

1. Record instance launch/termination timestamps per job.
2. Call `DescribeSpotPriceHistory` for the instance type + AZ during the job window.
3. Compute: `cost = sum(price_per_hour × hours_at_each_price_point)`.
4. Spot billing is per-second (1-minute minimum), so use exact seconds.
5. This is an **estimate** ( Spot price != necessarily your exact charge due to Spot blocks, interruptions, etc.) but it will be very close.
6. **Reconcile with CUR data** once available (next day) for actuals.

### Hybrid recommended architecture

```
Job completes
    │
    ├─► Record instance ID + start/end time + instance type + AZ
    │
    ├─► [Immediate] Compute estimated cost from DescribeSpotPriceHistory
    │   └─► Store as estimated_cost in DB
    │
    └─► [Next day] Athena query CUR 2.0 for actual cost by resource_id
        └─► Store as actual_cost in DB
        └─► Flag any variance > 5%
```

### Key gotchas

- **CUR 2.0 must be enabled** — it's not on by default. Takes ~24h to start producing data after enablement.
- **Cost allocation tags must be activated** in Billing console for EC2 tags to appear in CUR.
- **Spot Instance charges include a 1-minute minimum**, then per-second billing. CUR hourly reports aggregate these.
- **Spot interruptions** may result in partial-hour charges (you're not billed for the partial interrupted minute).
- **Spot Fleet** line items may appear at the fleet level AND individual instance level in CUR — query by `resource_id` containing the instance ID.
- **CUR data is immutable per report version** — AWS may regenerate reports, always use the latest version.

---

## 5. Quick Decision Matrix

| Need | Use This |
|------|----------|
| Per-job actual cost (next day) | CUR 2.0 + Athena, query by resource_id or job tag |
| Per-job estimated cost (immediate) | DescribeSpotPriceHistory + runtime calculation |
| Account-level daily spend | Cost Explorer API |
| Budget alerts | AWS Budgets |
| Spot price before launching | DescribeSpotPriceHistory or Price List API |
| Historical trend analysis | Cost Explorer API (daily/monthly) |

# FDS — Feature Ideas: Carding & Gestun

**Companion to:** `FDS_Feature_Breakdown.md` (existing feature inventory)
**Date:** 2026-08-05

> Features already in the model are referenced but not repeated. Every idea below is either new or
> a materially sharper version of an existing one. The **Data** column flags what each needs —
> `✅ have` = buildable from tables already used by the FDS notebooks; `⚠️ verify` = probably exists
> somewhere in the warehouse but I haven't confirmed the column; `❌ new` = needs instrumentation
> or a new source.

---

## 0. Why these two need separating first

Carding and gestun leave **opposite** fingerprints on several features the model already uses:

| Signal | Carding | Gestun |
|---|---|---|
| Account age | New, or dormant-then-suddenly-active | Established, often months old |
| KYC status | Often incomplete / rushed | Usually **fully verified** — they need the account to work |
| Counterparty | Random, unrelated to victim | Deliberately chosen, often self-linked |
| Intent | Extract value before detection | Repeat the same trick indefinitely |
| Velocity | Burst | Steady, deliberately unremarkable |

A single binary `Label` forces one gradient into both. `kyc_status_transformed` is a strong
positive-fraud signal for carding and a *negative* one for gestun — so in a pooled model those
partly cancel, and whichever class dominates the label set wins.

**Recommendation:** keep one production score for triage, but train and evaluate a
`fraud_type ∈ {carding, gestun, other}` head as well. At minimum, tag existing labels by type so
you can measure per-type recall. Right now you cannot tell which of the two the model is actually
catching.

---

## 1. Carding — someone else using the victim's card

The attacker holds card credentials but not the victim's habits. Every feature below tries to
measure *"does this card belong to this person"* or *"is this an automated probe."*

### 1A. Card ↔ identity mismatch

| Feature | Definition | Why it catches carding | Data |
|---|---|---|---|
| `cardholder_name_vs_kyc_sim` | Jaro-Winkler / token-set ratio between the name embossed on the card and `user_owner_name` (KYC name) | The single most direct carding signal. Existing `similarity_category` compares *payer vs beneficiary*, not *cardholder vs account owner* | ⚠️ verify |
| `cardholder_name_vs_company_sim` | Same, against `company_name` | Catches corporate-card misuse | ⚠️ verify |
| `bin_issuer_country_ne_company_country` | BIN country ≠ company registered country | Stolen cards are frequently cross-border | ⚠️ verify |
| `bin_type` | credit / debit / prepaid / commercial, from BIN table | Prepaid and foreign-issued BINs are over-represented in carding | ⚠️ verify |
| `bin_issuer_bank_rarity` | −log(share of platform volume from this issuer, L90d) | Rare issuers on a high-value transaction are anomalous | ⚠️ verify |
| `n_distinct_bins_per_company_l24h` | Distinct BINs used by this account in 24 h | Existing `cnt_uniquecc_*` counts cards; BIN-level catches a stolen *batch* from one breach | ⚠️ verify |

### 1B. Probing behaviour (card testing)

The attacker doesn't know if the card is live, so they probe.

| Feature | Definition | Why | Data |
|---|---|---|---|
| `n_declines_before_success_l60m` | Count of failed/declined auths on this account in the 60 min preceding this success | The canonical card-testing shape. `success_rate_transaction_l30d` is far too coarse to see it | ⚠️ verify |
| `n_distinct_cards_declined_l60m` | Distinct PANs declined in the last hour | Separates "one card, retried" from "many cards, sprayed" | ⚠️ verify |
| `decline_reason_entropy_l24h` | Shannon entropy over decline reason codes | Mixed reasons ⇒ credential stuffing rather than one genuine failure | ⚠️ verify |
| `amount_ascending_streak` | Length of the monotonically increasing amount run within the session/hour | Probe small → confirm live → cash out big | ✅ have |
| `first_attempt_amount_ratio` | `amount / first_attempt_amount_in_session` | A 100× jump from the probe is a strong tell | ✅ have |
| `is_micro_probe` | `amount <= p05` of the account's historical amounts, or below a fixed floor (e.g. 10 000 IDR) | Marks the probe leg itself | ✅ have |
| `time_since_prev_attempt_seconds` | Gap to the previous attempt, any status | Sub-second gaps ⇒ scripted | ⚠️ verify |
| `interattempt_cv_l24h` | Coefficient of variation of inter-attempt gaps | **Bots are too regular** — low CV is as suspicious as high velocity | ⚠️ verify |

### 1C. Authentication friction

| Feature | Definition | Why | Data |
|---|---|---|---|
| `threeds_outcome` | frictionless / challenged-passed / challenged-failed / not-attempted | Challenge failures are the strongest single carding signal where 3DS exists | ⚠️ verify |
| `n_otp_failures_l60m` | OTP failures on this account in the last hour | Attacker has the card but not the victim's phone | ⚠️ verify |
| `threeds_downgrade_flag` | 3DS attempted then abandoned, retried without it | Deliberate friction evasion | ⚠️ verify |

### 1D. Account takeover / dormancy

| Feature | Definition | Why | Data |
|---|---|---|---|
| `days_since_prev_trx` | Days since the account's previous transaction | Dormant → sudden activity is classic ATO | ✅ have |
| `dormancy_x_amount_zscore` | `days_since_prev_trx × z(amount vs account history)` | The interaction is much sharper than either alone | ✅ have |
| `credential_change_recency` | Minutes since last password / email / phone / bank-account change | ATO almost always involves a contact-detail change first, so the payout can't be reversed | ⚠️ verify |
| `is_first_cc_use_on_account` | This is the account's first-ever card payment | Combined with a large amount, very high signal | ✅ have |
| `minutes_card_added_to_first_use` | Card tokenised → first use | Legitimate users add a card and use it later; attackers use it immediately | ⚠️ verify |

### 1E. Temporal & behavioural deviation

| Feature | Definition | Why | Data |
|---|---|---|---|
| `hour_deviation_from_account_median` | Circular distance between this hour and the account's median transaction hour (L90d) | The attacker is in a different timezone or works at night | ✅ have |
| `is_outside_account_active_hours` | Outside the account's 5th–95th percentile hour band | Same idea, binary and more robust for sparse accounts | ✅ have |
| `weekday_deviation` | Is this the account's first-ever weekend/holiday transaction | B2B accounts are strongly weekday-shaped | ✅ have |
| `amount_zscore_vs_account_l90d` | `(amount − median) / IQR` on the account's own history | **The missing deviation feature** flagged in the feature report — you have `median_ticket_size_l30d` but never the ratio | ✅ have |

### 1F. Device & network *(the biggest gap — see §4)*

| Feature | Definition | Why | Data |
|---|---|---|---|
| `n_accounts_per_device_l30d` | Distinct companies seen on this device fingerprint | One device driving many accounts ⇒ a ring | ❌ new |
| `n_devices_per_account_l7d` | Distinct devices on this account | Sudden new device + new card ⇒ ATO | ❌ new |
| `ip_country_ne_bin_country` | IP geolocation vs card issuer country | Cheap, high-precision | ❌ new |
| `is_datacenter_or_vpn_asn` | ASN classified as hosting/VPN/proxy | Legitimate SME payments rarely originate from a datacenter | ❌ new |
| `n_accounts_per_ip_l24h` | Distinct accounts per IP | Ring detection | ❌ new |

---

## 2. Gestun — "gesek tunai", converting card limit to cash

The economic shape: a cardholder pays a **colluding or self-owned counterparty** by credit card for
goods that never exist, and receives cash back minus a 2–5% fee. On this platform it looks like a
CC-funded invoice payment to a mitra, followed quickly by a payout.

Everything below tries to detect either **circularity** (payer ≈ payee) or **cash conversion**
(money in by card, straight out as cash).

### 2A. Circularity — is the payee actually the payer?

This is the highest-value family and the least covered today.

| Feature | Definition | Why | Data |
|---|---|---|---|
| `payee_bank_acct_shared_with_payer` | Beneficiary bank account also registered to the paying company | Direct self-payment. Near-conclusive | ⚠️ verify |
| `n_companies_per_beneficiary_acct_l90d` | Distinct payer companies sending to this bank account | The payout-rail analogue of the excellent existing `cnt_comp_at_ccnum` | ⚠️ verify |
| `payer_payee_owner_name_sim` | Fuzzy match between payer's KYC owner name and payee's registered name | You already compute name similarity for `similarity_category` — reuse the same engine on this pair | ✅ have |
| `payer_payee_shared_phone` / `_email_domain` / `_address` | Exact or normalised match on contact fields | Cheap, and gestun rings reuse contact details constantly | ⚠️ verify |
| `graph_cycle_length_2` | Count of 2-cycles (A→B and B→A) involving this pair in L90d | Money returning to its source is the definition of circular flow | ✅ have |
| `shortest_cycle_len_containing_edge` | Length of the shortest directed cycle through this payer→payee edge | Catches 3- and 4-hop laundering rings that a 2-cycle check misses | ✅ have |
| `payer_payee_same_device_l30d` | Both sides authenticated from one device | Extremely strong; needs device data | ❌ new |

### 2B. Cash-conversion mechanics

| Feature | Definition | Why | Data |
|---|---|---|---|
| `minutes_cc_in_to_first_payout` | Minutes from this CC inbound to the recipient's next outbound payout | Gestun turns cash around fast; genuine trade does not | ✅ have |
| `payout_to_inbound_amount_ratio_24h` | max(payout amount) / this inbound amount, within 24 h | Should sit just below 1.0 | ✅ have |
| `is_fee_band_ratio` | Ratio ∈ [0.95, 0.98] — i.e. a 2–5% haircut | **The gestun fee signature.** Legitimate business flows have no reason to cluster there | ✅ have |
| `payout_ratio_stability_l90d` | Std-dev of that ratio across the pair's history | A *consistent* haircut across many transactions is a priced service, not commerce | ✅ have |
| `same_day_in_out_value_ratio` | Company's outbound value ÷ inbound value, same day | Pass-through accounts sit near 1.0 | ✅ have |
| `cc_funded_share_of_inbound_l30d` | Share of inbound value funded by credit card | Gestun is card-limit conversion by definition — near-100% CC funding is abnormal for a real merchant | ✅ have |

### 2C. Counterparty concentration & exclusivity

| Feature | Definition | Why | Data |
|---|---|---|---|
| `partner_hhi_outbound_l90d` | Herfindahl index of the payer's value across partners | A real business spreads spend; a gestun payer has one destination | ✅ have |
| `top1_partner_value_share_l90d` | Share of value going to the single largest partner | Simpler, nearly as strong | ✅ have |
| `n_distinct_payers_for_this_mitra` | Distinct companies that have ever paid this mitra | **`== 1` is a very strong flag** — a "merchant" with exactly one customer | ✅ have |
| `mitra_inbound_hhi` | Same concentration measure from the mitra's side | Catches the shell-merchant end of the pair | ✅ have |
| `mitra_age_days_at_first_payment` | Days between mitra creation and its first received payment | Extends existing `delta_created_mitra_to_payment_in_minutes` with the amount interaction below | ✅ have |
| `new_mitra_x_large_amount` | `(mitra_age_days < 1) × z(amount)` | Brand-new counterparty receiving an outsized first payment | ✅ have |
| `pair_transaction_count_l90d` | How many times this exact pair has transacted | Gestun repeats; distinguish one-off from a running arrangement | ✅ have |

### 2D. Invoice authenticity

Gestun needs a paper invoice, but nobody bothers making it look real.

| Feature | Definition | Why | Data |
|---|---|---|---|
| `seconds_invoice_created_to_paid` | Invoice creation → payment | Real invoices sit for days awaiting approval; fabricated ones are paid within minutes | ✅ have |
| `invoice_item_count` | Number of line items | Gestun invoices are single-line | ⚠️ verify |
| `item_desc_char_len` / `item_desc_token_entropy` | Length and character entropy of the description | Generic or near-empty descriptions | ⚠️ verify |
| `item_desc_is_generic` | Description matches a stoplist (`jasa`, `barang`, `pembayaran`, `invoice`, `-`, `.`) | Cheap and effective in the Indonesian context | ⚠️ verify |
| `has_no_invoice_backing` | Payment with no linked invoice at all | **See the finding in the feature report** — these 14% of rows are currently dropped before scoring entirely | ✅ have |
| `invoice_amount_equals_payment_exactly` | Zero variance between invoiced and paid | Combined with round amounts, indicates a number chosen backwards from a cash target | ✅ have |

### 2E. Amount fingerprints

| Feature | Definition | Why | Data |
|---|---|---|---|
| `amount_trailing_zeros` | Count of trailing zeros | Cash targets are round; real invoices carry odd totals and tax | ✅ have |
| `is_round_100k` / `is_round_1m` | Divisibility flags | Simple, strong for gestun; weak for carding | ✅ have |
| `amount_to_credit_limit_ratio` | `amount / available_credit_limit` | Gestun maximises limit extraction — expect clustering near 1.0 | ⚠️ verify |
| `is_limit_hugging` | Ratio ∈ [0.90, 1.00] | Binary version, more robust | ⚠️ verify |
| `n_days_with_identical_amount_l30d` | Days on which an identical amount went to the same partner | A recurring exact amount is a standing arrangement | ✅ have |
| `benford_first_digit_deviation_l90d` | Deviation of the account's first-digit distribution from Benford | Portfolio-level detector for fabricated amount sets | ✅ have |

### 2F. Peer-relative plausibility

Absolute thresholds age badly. Compare each account to its own peer group
(`business_child_cat` × company size × tenure band):

| Feature | Definition | Why | Data |
|---|---|---|---|
| `cc_share_vs_peer_median` | This account's CC-funded share ÷ peer-group median | A retailer taking 100% card is normal; a construction supplier is not | ✅ have |
| `ticket_size_percentile_in_peer_group` | Percentile rank of ticket size within peers | Normalises across very different business types | ✅ have |
| `payout_speed_percentile_in_peer_group` | Percentile of in→out latency vs peers | Same normalisation for the conversion-speed signal | ✅ have |
| `business_type_vs_flow_mismatch` | Learned residual: predict expected CC-share from `business_child_cat`, take the residual | Turns a category into a deviation score | ✅ have |

---

## 3. Two SQL sketches for the highest-value ideas

**Gestun — cash-conversion latency and fee band** (needs an inbound and an outbound event table):

```sql
WITH cc_in AS (
  SELECT external_id, company_id, digpay_datetime AS in_ts, amount AS in_amt
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
  WHERE LOWER(digital_payment_type_name) = 'in'
    AND payment_attempt_using_cc = 1          -- verify the actual column
),
payout AS (
  SELECT company_id, digpay_datetime AS out_ts, amount AS out_amt
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
  WHERE LOWER(digital_payment_type_name) = 'out'
)
SELECT
  i.external_id,
  MIN(TIMESTAMP_DIFF(o.out_ts, i.in_ts, MINUTE))          AS minutes_cc_in_to_first_payout,
  MAX(SAFE_DIVIDE(o.out_amt, i.in_amt))                   AS payout_to_inbound_ratio_24h,
  MAX(CASE WHEN SAFE_DIVIDE(o.out_amt, i.in_amt)
                BETWEEN 0.95 AND 0.98 THEN 1 ELSE 0 END)  AS is_fee_band_ratio
FROM cc_in i
LEFT JOIN payout o
  ON  i.company_id = o.company_id
  AND o.out_ts >  i.in_ts
  AND o.out_ts <= TIMESTAMP_ADD(i.in_ts, INTERVAL 24 HOUR)
GROUP BY i.external_id;
```

**Gestun — merchant exclusivity** (`n_distinct_payers_for_this_mitra == 1` is the flag):

```sql
SELECT
  partner_id,
  COUNT(DISTINCT company_id)                                    AS n_distinct_payers_l90d,
  SUM(amount)                                                   AS total_received,
  SAFE_DIVIDE(MAX(payer_value), SUM(amount))                    AS top1_payer_value_share
FROM (
  SELECT partner_id, company_id, amount,
         SUM(amount) OVER (PARTITION BY partner_id, company_id) AS payer_value
  FROM `<partner-level payment fact>`
  WHERE digpay_datetime >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
)
GROUP BY partner_id;
```

---

## 4. Data gaps, ranked by value-per-effort

| Gap | Unlocks | Effort |
|---|---|---|
| **Declined / failed auth events** | All of §1B — card testing is currently near-invisible because only successful payments are scored | Medium — the events likely exist upstream but aren't in the feature mart |
| **Payout / outbound leg joined to inbound** | All of §2B — the entire cash-conversion family | Medium |
| **BIN reference table** (country, type, issuer) | §1A | Low — commercial BIN lists are cheap |
| **Device fingerprint + IP/ASN** | §1F and `payer_payee_same_device` | High, but the highest ceiling of anything here |
| **3DS / OTP outcomes** | §1C | Medium |
| **Credit limit per account** | `amount_to_credit_limit_ratio` | Low if the lending side already stores it |
| **Invoice line items & descriptions** | §2D | Low — likely already in the invoice tables |

---

## 5. Where I'd start

If you build only six things, build these — highest signal, lowest dependency:

1. **`n_distinct_payers_for_this_mitra`** — a merchant with exactly one customer is the cleanest gestun tell available, and it needs nothing you don't have.
2. **`minutes_cc_in_to_first_payout` + `is_fee_band_ratio`** — the cash-conversion pair. The 2–5% haircut has no legitimate analogue.
3. **`amount_zscore_vs_account_l90d`** — the deviation feature the model is currently missing entirely, useful for *both* fraud types.
4. **`seconds_invoice_created_to_paid`** — near-zero cost, and fabricated invoices are paid within minutes.
5. **`n_declines_before_success_l60m`** — requires plumbing declined auths in, but carding is largely undetectable without it.
6. **`cardholder_name_vs_kyc_sim`** — you already run a name-similarity engine for `similarity_category`; point it at a second pair.

Two structural notes to pair with the above:

- **Score the invoice-less transactions.** The 14% of rows currently dropped by the
  `amount_to_invoice_amount != inf` filter are exactly where `has_no_invoice_backing` would fire.
  Gestun without an invoice is being excluded from scoring by construction.
- **Tag labels by fraud type before adding these.** Half of these features are gestun-specific and
  half carding-specific. Pooled into one binary target with a 43%-fraud training set, the
  gestun features will look weak simply because carding dominates the positives — and you'll drop
  the wrong ones during selection.

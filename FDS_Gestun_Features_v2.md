# Gestun Features — v2, grounded in verified schema

Supersedes §2 of `FDS_Feature_Ideas_Carding_Gestun.md`, which was written before I could
inspect the warehouse. Everything here is checked against `data_warehouse_layer` on
2026-08-05.

---

## 0. What the mechanism actually is on this platform

I originally assumed gestun would show up as **self-payment at the payout leg** — company
pays a bank account it owns. That is wrong here:

```
disbursements, Jul 2026     20,824
  destination account owned by the disbursing company   19,754  (100% of joined)
  destination account owned by any OTHER company             0
```

The platform only allows disbursement to your **own** registered accounts, so
`payee_bank_acct_shared_with_payer` is constant-true and carries no signal. **Dropped.**

The real shape is one step further out:

```
  cardholder  ──pays by card──▶  receiving company  ──disburses──▶  its own bank account
       └──────────── same person / connected entities ────────────────────┘
```

The cardholder and the company owner are the same person behind two identities. So the
highest-value features are **identity linkage between the card payer and the receiving
company** — not anything about the payout account itself.

The 2022 review table supports this: for confirmed gestun,
`user_account_name_similarity_rate` averaged **98.5** vs **88.8** for cleared cases. The
payout account holder's name matches the *user's* name almost exactly.

### Also dropped

`partner_id` is **company-scoped** — each company keeps its own address book. All 8,865
partners of the labelled companies have exactly one payer platform-wide, so every partner
is "exclusive" by construction. `n_exclusive_partners`, `share_exclusive_partners` and
`avg_payers_per_partner` are degenerate. Rebuild them on `partner_email` /
`partner_phone_number` / normalised `partner_name` instead (§E).

---

## A. Payer ↔ payee identity linkage — the core family

Newly possible: `fact__paper__digital_payment_transaction` carries cardholder identity
(25.7% of Jul-2026 rows, 27,233 distinct cards).

| Feature | Definition | Why |
|---|---|---|
| `cardholder_name_vs_company_owner_sim` | Jaro-Winkler: `success_attempt_card_holder_data_full_name` vs the receiving company's KYC owner name | The direct test. Reuse the engine behind `similarity_category` |
| `cardholder_name_vs_finance_acct_name_sim` | vs `dim__paper__finance_account.bank_account_name` of the payout account | This is the 2022 signal that separated 98.5 / 88.8 |
| `cardholder_email_eq_company_email` | `success_attempt_card_holder_data_email` = company email, exact and domain-only | Cheap, high precision |
| `cardholder_phone_eq_company_phone` | normalised phone equality | Same |
| `companies_are_connected` | receiving company and any company owned by the cardholder appear in `dim__paper__company_connection` | Pre-computed graph, 21 cols — check what edges it holds |
| `card_ever_used_by_receiving_company` | has this PAN previously appeared on a payment *made by* the receiving company | Owner paying their own company |
| `n_shared_identity_signals` | count of the above that fire (0–5) | Any one can be coincidence; three cannot |

## B. Device & network collusion — `fact__paper__auth_log`

19 columns including `fingerprint_id`, `ip_address_code`, `user_agent_name`,
`longitude_number`, `latitude_number`, `is_success_flag`, `attempt_counter_number`.

| Feature | Definition | Why |
|---|---|---|
| `payer_payee_shared_fingerprint` | payer and receiving company both authenticated from the same `fingerprint_id` within 30d | Near-conclusive. One human, two accounts |
| `payer_payee_shared_ip` | same `ip_address_code` within 30d | Weaker (shared offices, NAT) but cheap |
| `n_companies_per_fingerprint_l90d` | distinct companies per device | >3 is a ring operator |
| `n_companies_per_ip_l90d` | distinct companies per IP | Same, noisier |
| `payer_payee_geo_distance_km` | haversine between their login lat/long | Colluders are often physically together |
| `company_n_distinct_fingerprints_l30d` | devices per company | A "merchant" accessed from many devices |

## C. Card graph — newly available at parent layer

| Feature | Definition | Why |
|---|---|---|
| `n_companies_per_card_l90d` | distinct companies paid by this PAN | **A gestun broker's clients.** One card across many unrelated merchants |
| `n_cards_per_company_l90d` | distinct PANs paying this company | A cash-out shop serving many cardholders |
| `top1_card_share_of_inbound` | share of company inbound value from its single largest card | ~1.0 = one cardholder funding the whole "business" |
| `card_first_seen_to_use_minutes` | PAN first seen on platform → this payment | Card introduced solely to cash out |
| `repeat_cardholder_across_companies` | same cardholder name paying ≥2 companies | Ring |

## D. Cash conversion — join on `company_id` + time

**Verified:** `external_id` does *not* bridge payin and disbursement (221 of 205,378
matched). The only link is company + time window.

| Feature | Definition | Why |
|---|---|---|
| `minutes_payin_to_disbursement` | payin → company's next disbursement | Gestun turns around fast |
| `disb_to_payin_amount_ratio` | disbursement ÷ payin, within 24h | Sits just under 1.0 |
| `is_fee_band_ratio` | ratio ∈ [0.95, 0.98] | The 2–5% haircut — the gestun *fee* |
| `fee_band_ratio_stability` | std-dev of that ratio across the company's history | A **consistent** haircut is a priced service, not commerce |
| `share_payins_followed_by_disb_24h` | fraction of card payins with a payout behind them | Pass-through behaviour |
| `cc_funded_share_of_inbound` | share of inbound value on credit card | Card-limit conversion means near-total CC funding |

⚠️ These look **forward** in time. Fine for review-queue scoring, leakage for real-time
blocking. Prefix them `fwd_` and gate them on the model's purpose.

## E. Counterparty identity — rebuilt without `partner_id`

| Feature | Definition | Why |
|---|---|---|
| `n_payers_per_partner_email` | distinct paying companies per normalised `partner_email` | The exclusivity idea, on a key that actually generalises |
| `n_payers_per_partner_phone` | same for `partner_phone_number` | |
| `n_payers_per_partner_name_norm` | same for lowercased/punctuation-stripped `partner_name` | Weakest key, but broadest coverage |
| `partner_contact_eq_payer_contact` | partner email/phone equals the paying company's own | Self-dealing through the address book |
| `partner_bank_acct_n_companies` | distinct companies paying the same beneficiary account | Requires the partner-side account from `rpt__risk__0030…` or the ingestion layer |

## F. Invoice authenticity — `fact__paper__invoice` + `fact__paper__invoice_item`

| Feature | Definition | Why |
|---|---|---|
| `seconds_invoice_created_to_paid` | creation → payment | Real invoices await approval; fabricated ones are paid in minutes |
| `invoice_item_count` | line items (`fact__paper__invoice_item`, 17 cols) | Gestun invoices are single-line |
| `item_desc_len` / `item_desc_is_generic` | stoplist: `jasa`, `barang`, `pembayaran`, `-` | Nobody bothers making it look real |
| `invoice_amount_eq_payment_exactly` | zero variance | Amount chosen backwards from a cash target |
| `has_no_invoice_backing` | no linked invoice | Currently dropped from scoring entirely |

## G. Amount fingerprints

`amount_trailing_zeros`, `is_round_100k`, `is_round_1m`, `distinct_amount_ratio`,
`n_days_identical_amount_same_partner`, `amount_to_credit_limit_ratio` (needs the
lending-side limit).

## H. Peer-relative

Compare each company to its `business_child_cat` × size × tenure peer group rather than to
absolute thresholds: `cc_share_vs_peer_median`, `ticket_size_percentile_in_peer_group`,
`payout_speed_percentile_in_peer_group`.

Critical given what the current model learned — **all five selected features were pure
activity proxies** (partners, active days, channels), separating busy companies from
dormant ones rather than fraud from legitimate. Peer normalisation is how you stop that.

---

## Where to start

Ranked by signal ÷ effort, given what is now confirmed available:

1. **`cardholder_name_vs_finance_acct_name_sim`** — the 2022 review data already showed this separating confirmed gestun (98.5 vs 88.8). Both fields are in hand.
2. **`n_companies_per_card_l90d`** — one PAN across many merchants is a broker. Pure `GROUP BY` on newly-available data.
3. **`payer_payee_shared_fingerprint`** — near-conclusive, and `auth_log` makes it a join.
4. **`is_fee_band_ratio` + `fee_band_ratio_stability`** — the fee signature has no legitimate analogue.
5. **`n_payers_per_partner_email`** — the exclusivity idea rebuilt on a working key.

## Two caveats to carry

**Card coverage is 25.7%.** Every §A and §C feature is null for three quarters of
transactions. Model that as a missingness indicator rather than imputing it away — and
note that non-card payins can't be gestun by definition, so the null is informative.

**Fix the control group before trusting any of this.** The current 58 companies compare 24
active gestun firms against 34 near-dormant ones (5.3 active days out of 90). Any feature
correlated with volume will look predictive. Matched controls — clean companies of
comparable volume and tenure — are what will tell you whether these features work.

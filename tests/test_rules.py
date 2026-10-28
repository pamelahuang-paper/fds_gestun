"""The rule layer exists to catch what the model misses, so the tests pin the
three confirmed September cases: each must be caught by the rule named for it.
"""
import pandas as pd

from fds_gestun import rules


def _blank(n=1, **cols):
    frame = pd.DataFrame({"company_id": [f"c{i}" for i in range(n)]})
    for name, value in cols.items():
        frame[name] = value
    return frame


def test_r1_fires_on_payout_concentrated_on_one_person():
    # Soho Travel: 86% of Out value to one individual, 2 partners, ~36m average
    frame = _blank(top1_out_partner_amount_share=0.8593, top1_out_partner_is_personal=1,
                   n_out_partners=2, pct_partner_personal_name=1.0,
                   avg_txn_amount=36_029_834)
    out = rules.apply_rules(frame)
    assert out.rule_flag.iloc[0] and "R1" in out.rule_hits.iloc[0]


def test_r1_ignores_a_company_with_only_one_payout_partner():
    """Concentration needs something to concentrate away from. With one Out
    partner the share is 1.0 by arithmetic, which is a fact about counting, not
    about the company -- 220 of R1's 369 hits in the 17-23 Sep window were this.
    """
    frame = _blank(top1_out_partner_amount_share=1.0, top1_out_partner_is_personal=1,
                   n_out_partners=1, pct_partner_personal_name=1.0,
                   avg_txn_amount=50_000_000)
    out = rules.apply_rules(frame)
    assert not out.rule_flag.iloc[0]


def test_r2_fires_when_the_owner_funds_the_company_by_card():
    # CV Kreasi Sukses Makmur: 34.9% of In value from a partner named like the owner
    frame = _blank(pct_amount_in_partner_eq_self=0.3487, cc_amount_share=0.72)
    out = rules.apply_rules(frame)
    assert out.rule_flag.iloc[0] and "R2" in out.rule_hits.iloc[0]


def test_r3_fires_on_several_cards_for_one_payment():
    # Putaran Delapan Media: 3 distinct cards, 5 attempts, on its only transaction
    frame = _blank(max_cards_in_one_txn=3, pct_txn_multi_card=1.0)
    out = rules.apply_rules(frame)
    assert out.rule_flag.iloc[0] and "R3" in out.rule_hits.iloc[0]


def test_ordinary_company_is_not_flagged():
    frame = _blank(top1_out_partner_amount_share=0.22, top1_out_partner_is_personal=0,
                   n_out_partners=45, pct_partner_personal_name=0.1,
                   avg_txn_amount=1_500_000, pct_amount_in_partner_eq_self=0.0,
                   cc_amount_share=0.1, max_cards_in_one_txn=1, pct_txn_multi_card=0.0)
    out = rules.apply_rules(frame)
    assert not out.rule_flag.iloc[0] and out.rule_hits.iloc[0] == ""


def test_missing_features_never_fire():
    """A feature matrix built before these columns existed must score, not raise,
    and must not flag: NaN is 'unknown', not 'suspicious'."""
    out = rules.apply_rules(_blank(3))
    assert not out.rule_flag.any()
    assert (out.rule_hits == "").all()


def test_hits_are_joined_when_several_rules_fire():
    frame = _blank(pct_amount_in_partner_eq_self=0.9, cc_amount_share=0.9,
                   max_cards_in_one_txn=4, pct_txn_multi_card=1.0)
    assert rules.apply_rules(frame).rule_hits.iloc[0] == "R2|R3"


# --- the review gate ----------------------------------------------------------
# review is a capacity decision layered on the model, so it gets its own tests:
# a silent change here empties or floods the reviewers' queue.
import pytest

from fds_gestun import config
from fds_gestun.model import review_queue

TPV = 10_000_000


def test_high_score_with_enough_value_is_queued():
    assert review_queue([0.99], [False], [TPV]).iloc[0]


def test_high_score_on_a_tiny_week_is_not_queued():
    """The whole point of the rupiah floor: a 0.99 on a 50k week is not an hour
    of anyone's time."""
    assert not review_queue([0.99], [False], [50_000]).iloc[0]


def test_score_below_the_review_threshold_is_not_queued():
    assert not review_queue([config.REVIEW_THRESHOLD - 0.1], [False],
                            [5 * TPV]).iloc[0]


def test_a_rule_hit_reaches_the_queue_without_the_model():
    """The two confirmed September cases scored 0.62 and 0.64. They are in the
    queue on R1/R2 alone, and must stay there."""
    assert review_queue([0.6208], [True], [14_576_760]).iloc[0]
    assert review_queue([0.6382], [True], [135_000_000]).iloc[0]


def test_the_rupiah_floor_applies_to_rule_hits_too():
    assert not review_queue([0.10], [True], [15_000]).iloc[0]


def test_missing_tpv_fails_the_floor():
    """A company we cannot value is a company we cannot prioritise."""
    assert not review_queue([0.99], [True], [None]).iloc[0]


def test_floor_can_be_switched_off_for_a_windowless_run():
    assert review_queue([0.99], [False], [0], min_tpv=0).iloc[0]


@pytest.mark.parametrize("dp,dtpv,expected", [
    (0.0, 0, True),        # both exactly on the boundary: in
    (-0.0001, 0, False),   # a hair under the score: out
    (0.0, -1, False),      # a rupiah under the floor: out
])
def test_boundaries_are_inclusive(dp, dtpv, expected):
    """Read the cutoffs from config rather than repeating them: the point is
    that >= is inclusive, not what today's threshold happens to be."""
    assert bool(review_queue([config.REVIEW_THRESHOLD + dp], [False],
                             [config.REVIEW_MIN_TPV + dtpv]).iloc[0]) is expected


def test_the_model_never_sees_who_the_owner_is():
    """user_owner_name reached the deployed model once, carrying 4% of gain as
    280 memorised names. Identifying a company by its owner is not a behavioural
    signal, it measured worse, and it should not come back."""
    from fds_gestun import features as feat
    names = feat.model_feature_names()
    assert "user_owner_name" not in names
    assert "user_owner_phone" not in names

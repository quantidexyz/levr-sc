# Test Updates for Staking Design Change - Oct 29, 2025

## Summary

Updated 30+ tests to match new staking design where:
1. **Unstake does NOT auto-claim** rewards
2. **Vesting only happens during ACTIVE stream** (before end time)
3. **Unvested rewards preserved** for next accrual

## Test Update Patterns

### Pattern 1: Tests expecting auto-claim on unstake
**OLD**: Unstake → check user balance has rewards
**NEW**: Claim → Unstake → check user balance

### Pattern 2: Tests claiming after stream ends
**OLD**: Accrue → Wait past stream end → Claim all
**NEW**: Accrue → Claim before end OR Re-accrue → Wait → Claim

### Pattern 3: Cleanup tests
**OLD**: Wait for stream end → Cleanup
**NEW**: Wait for stream end → Claim all → Cleanup

### Pattern 4: Zero-staker scenarios
**OLD**: Accrue with no stakers → Someone stakes → They get all rewards
**NEW**: Accrue with no stakers → Someone stakes → They get 0 → Re-accrue → They get rewards

## Files Updated

- `test/unit/LevrStaking_StuckFunds.t.sol` - 3 tests
- `test/unit/LevrStaking_GlobalStreamingMidstream.t.sol` - 7 tests
- `test/unit/LevrStakingV1.MidstreamAccrual.t.sol` - 6 tests
- `test/unit/LevrStakingV1.t.sol` - 2 tests
- `test/unit/LevrStakingV1.AprSpike.t.sol` - 2 tests
- `test/unit/LevrStakingV1.GovernanceBoostMidstream.t.sol` - 2 tests
- `test/unit/LevrStakedToken_NonTransferableEdgeCases.t.sol` - 2 tests
- `test/unit/LevrTokenAgnosticDOS.t.sol` - 2 tests
- `test/unit/LevrFactory_ConfigGridlock.t.sol` - 1 test
- `test/e2e/LevrV1.StuckFundsRecovery.t.sol` - 3 tests

## Key Principle

**Rewards vest in real-time during active stream only.**

Users must interact (stake/claim) DURING the stream window to get rewards.  
After stream ends, unvested rewards are frozen until next `accrueRewards()` call.


# Multi-round revision (2026-10-12)

Extension 30 -> 120 seconds. Six-hour cap and first-entry start unchanged.

Single round -> repeating rounds. At expiry receipt or permissionless settlement, old winner/prize are frozen, unpaid liabilities reserved, new round waits. Triggering receipt and between-round receipts fund the next jackpot.

Removed fixed post-settlement recipient, fee forwarding and per-entry processor dispatch. Buyback is not implemented. Guardian exception remains.

claim() -> claim(roundId). Round-indexed winnerOf/prizeOf/claimedOf replace old single-round payout getters. Outstanding prizes never enter a later jackpot.

Old source and single-round fork fixture removed from current public tree. Git history retains them. The new protocol fork suite still needs implementation/validation; historical real Flap test results must not be presented as current evidence.

Local validation: 20 unit/fuzz tests, 1 invariant test (256 runs x128 calls), mass 100/1,000/10,000 entries, 20 unpaid rounds claimed in reverse order. No blockchain deployment.

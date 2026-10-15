# FOMO6 Flap integration candidate

Factory authenticates the canonical chain-specific VaultPortal, predicts the token before its code exists, requires native BNB and V3 tax token with 3% buy/sell tax and full vault allocation. No configuration data or recipient address is accepted.

Processor binding reads the token getter and verifies processor token/market/native quote/18 decimals links, once only. Early processor receipts are credited at binding; other early sources stay unaccounted. Forced BNB is excluded.

Received tax never starts a round. Expired receipt: settle current jackpot, reserve/pay old winner, advance round, then credit triggering receipt to new waiting jackpot. Settlement does not iterate over past rounds. claim(roundId) can recover unpaid prizes in any order, only to each winner.

The engineer-reported automatic Flap delivery replaces our former per-entry dispatch call. No dispatch, buyback or recipient forwarding remains in game code. This does not imply unprocessed/withheld Flap taxes are guaranteed delivered.

Winner automatic call forwards 30,000 gas; failure preserves the prize. The real dispatcher passed the five-path fork suite under the official 1,000,000-gas cap; see FORK-VERIFICATION.md for measured warm-call costs and limitations. Without receipt, anyone can settle manually. Incoming tax/settlement and payment cannot reenter the game.

Factory deployment is Testnet-only via the included script, no constructor arguments. No Mainnet deployment or keys are handled. New multi-round fork launch/graduation/sell/dispatch tests passed at block127782836; signed Testnet tests and external automatic-dispatch service confirmation remain outstanding. Old single-round fork results do not verify this version.

ABI migration: EXTENSION=120; roundId(), winnerOf(id), prizeOf(id), claimedOf(id), outstandingPrizes(); claim(uint256). Removed single-round winner/settled/claimed/prizeAtSettlement getters, post-recipient forwarding and collection functions. Frontend must migrate before enabling participation.
